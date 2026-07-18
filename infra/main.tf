terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {}
}

provider "aws" {
  region = var.region
}

# ── Data: default VPC & subnets ──────────────────────────────────────────────
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── Security groups ───────────────────────────────────────────────────────────
resource "aws_security_group" "ec2" {
  name                   = "${var.project_name}-ec2-sg"
  description            = "Allow HTTP and SSH"
  vpc_id                 = data.aws_vpc.default.id
  revoke_rules_on_delete = true

  tags = {
    Project = var.project_name
    Name    = "${var.project_name}-ec2-sg"
  }
}

resource "aws_security_group_rule" "ec2_ingress_ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.ec2.id
  description       = "SSH from anywhere"
}

resource "aws_security_group_rule" "ec2_ingress_http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.ec2.id
  description       = "HTTP from anywhere"
}

resource "aws_security_group_rule" "ec2_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.ec2.id
  description       = "All outbound traffic"
}

# The RDS security group has a cross-SG ingress rule (rds_from_ec2) that
# references aws_security_group.ec2 as its source.  That AWS-level reference
# is what caused the 15-minute hang + DependencyViolation: Terraform was
# trying to delete the EC2 SG while the RDS SG still held a rule pointing at
# it as a source.
#
# depends_on = [aws_security_group.ec2] fixes the destroy order:
#   1. Terraform destroys aws_security_group.rds FIRST (it depends on ec2 SG
#      at the Terraform level, so it is created after and destroyed before).
#   2. revoke_rules_on_delete fires on the RDS SG, calling
#      RevokeSecurityGroupIngress on rds_from_ec2 — removing the cross-SG
#      reference from AWS.
#   3. aws_security_group.ec2 is then deleted with no remaining dependents.
resource "aws_security_group" "rds" {
  name                   = "${var.project_name}-rds-sg"
  description            = "Allow Postgres from EC2 only"
  vpc_id                 = data.aws_vpc.default.id
  revoke_rules_on_delete = true

  depends_on = [aws_security_group.ec2]

  tags = {
    Project = var.project_name
    Name    = "${var.project_name}-rds-sg"
  }
}

resource "aws_security_group_rule" "rds_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.rds.id
  description       = "All outbound traffic"
}

# Cross-SG rule: allows EC2 instances to reach RDS on port 5432.
# Defined as a standalone resource (no inline blocks) so Terraform's dependency
# graph destroys this rule before either security group.
resource "aws_security_group_rule" "rds_from_ec2" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.ec2.id
  description              = "Postgres from EC2 security group"
}

# ── RDS subnet group ──────────────────────────────────────────────────────────
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = data.aws_subnets.default.ids

  tags = {
    Project = var.project_name
    Name    = "${var.project_name}-db-subnet-group"
  }
}

# ── RDS instance ──────────────────────────────────────────────────────────────
resource "aws_db_instance" "postgres" {
  identifier              = "${var.project_name}-db"
  engine                  = "postgres"
  engine_version          = "15"
  instance_class          = "db.t3.micro"
  allocated_storage       = 20
  storage_type            = "gp2"
  db_name                 = "shortener"
  username                = "shortener"
  password                = var.db_password
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  publicly_accessible     = false
  skip_final_snapshot     = true
  deletion_protection     = false
  multi_az                = false
  backup_retention_period = 0

  tags = {
    Project = var.project_name
    Name    = "${var.project_name}-db"
  }
}

# ── IAM role for SSM ─────────────────────────────────────────────────────────
resource "aws_iam_role" "ec2_ssm" {
  name = "${var.project_name}-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = { Project = var.project_name }
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_ssm" {
  name = "${var.project_name}-ec2-ssm-profile"
  role = aws_iam_role.ec2_ssm.name
}

# ── Key pair ──────────────────────────────────────────────────────────────────
resource "aws_key_pair" "deployer" {
  key_name   = "${var.project_name}-key"
  public_key = var.ssh_public_key
}

# ── EC2 instance ──────────────────────────────────────────────────────────────
resource "aws_instance" "app" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.small"
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.ec2.id]
  key_name               = aws_key_pair.deployer.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name

  tags = {
    Project = var.project_name
    Name    = "${var.project_name}-app"
  }
}

# ── Elastic IP ────────────────────────────────────────────────────────────────
resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"

  tags = {
    Project = var.project_name
    Name    = "${var.project_name}-eip"
  }
}
