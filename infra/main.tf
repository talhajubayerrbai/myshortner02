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
  name        = "${var.project_name}-ec2-sg"
  description = "Allow HTTP and SSH"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project = var.project_name
    Name    = "${var.project_name}-ec2-sg"
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Allow Postgres from EC2 only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project = var.project_name
    Name    = "${var.project_name}-rds-sg"
  }
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

# ── Key pair ──────────────────────────────────────────────────────────────────
# The key pair is used as a fallback; the primary SSH auth is via user_data
# which writes SSH_PUBLIC_KEY into authorized_keys on first boot — this
# survives any key pair state drift across pipeline retries.
resource "aws_key_pair" "deployer" {
  key_name   = "${var.project_name}-key"
  public_key = var.ssh_public_key

  lifecycle {
    # If the public key changes (e.g. platform rotates it), recreate.
    create_before_destroy = false
  }
}

# ── EC2 instance ──────────────────────────────────────────────────────────────
resource "aws_instance" "app" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.small"
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.ec2.id]
  key_name               = aws_key_pair.deployer.key_name

  # Inject SSH public key via cloud-init so Ansible can always connect,
  # even if the key pair resource was recreated or imported with drift.
  user_data = <<-USERDATA
    #!/bin/bash
    set -e
    mkdir -p /home/ec2-user/.ssh
    chmod 700 /home/ec2-user/.ssh
    cat >> /home/ec2-user/.ssh/authorized_keys <<'PUBKEY'
${var.ssh_public_key}
PUBKEY
    chmod 600 /home/ec2-user/.ssh/authorized_keys
    chown -R ec2-user:ec2-user /home/ec2-user/.ssh
  USERDATA

  lifecycle {
    # Replace instance when user_data (SSH key) changes.
    replace_triggered_by = [aws_key_pair.deployer]
  }

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
