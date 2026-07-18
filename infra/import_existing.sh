#!/usr/bin/env bash
# Idempotent pre-apply import script.
# Imports AWS resources that may already exist into the current Terraform state.
# Safe to run even when resources don't exist yet.
set -euo pipefail

PROJECT="${1:?Usage: $0 <project_name>}"
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" --output text)

echo "==> Project: $PROJECT  |  Default VPC: $VPC_ID"

# ── Helper: import only if not already in state ────────────────────────────────────────────
tf_import() {
  local addr="$1" id="$2"
  if terraform state show "$addr" > /dev/null 2>&1; then
    echo "  SKIP (already in state): $addr"
  else
    echo "  IMPORT: $addr => $id"
    terraform import "$addr" "$id" || echo "  WARN: import failed (resource may not exist yet) — continuing"
  fi
}

# ── EC2 security group ───────────────────────────────────────────────────────────────
EC2_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${PROJECT}-ec2-sg" "Name=vpc-id,Values=${VPC_ID}" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
[ "$EC2_SG_ID" != "None" ] && [ -n "$EC2_SG_ID" ] && \
  tf_import "aws_security_group.ec2" "$EC2_SG_ID"

# ── RDS security group ─────────────────────────────────────────────────────────────────
RDS_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${PROJECT}-rds-sg" "Name=vpc-id,Values=${VPC_ID}" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
[ "$RDS_SG_ID" != "None" ] && [ -n "$RDS_SG_ID" ] && \
  tf_import "aws_security_group.rds" "$RDS_SG_ID"

# ── DB subnet group ─────────────────────────────────────────────────────────────────────
DB_SUBNET_EXISTS=$(aws rds describe-db-subnet-groups \
  --db-subnet-group-name "${PROJECT}-db-subnet-group" \
  --query "DBSubnetGroups[0].DBSubnetGroupName" --output text 2>/dev/null || true)
[ "$DB_SUBNET_EXISTS" != "None" ] && [ -n "$DB_SUBNET_EXISTS" ] && \
  tf_import "aws_db_subnet_group.main" "${PROJECT}-db-subnet-group"

# ── RDS instance ───────────────────────────────────────────────────────────────────────────────
RDS_EXISTS=$(aws rds describe-db-instances \
  --db-instance-identifier "${PROJECT}-db" \
  --query "DBInstances[0].DBInstanceIdentifier" --output text 2>/dev/null || true)
[ "$RDS_EXISTS" != "None" ] && [ -n "$RDS_EXISTS" ] && \
  tf_import "aws_db_instance.postgres" "${PROJECT}-db"

# ── IAM role ────────────────────────────────────────────────────────────────────────────────
IAM_ROLE_EXISTS=$(aws iam get-role --role-name "${PROJECT}-ec2-ssm-role" \
  --query "Role.RoleName" --output text 2>/dev/null || true)
[ -n "$IAM_ROLE_EXISTS" ] && [ "$IAM_ROLE_EXISTS" != "None" ] && \
  tf_import "aws_iam_role.ec2_ssm" "${PROJECT}-ec2-ssm-role"

# ── IAM instance profile ────────────────────────────────────────────────────────────────────
IAM_PROFILE_EXISTS=$(aws iam get-instance-profile \
  --instance-profile-name "${PROJECT}-ec2-ssm-profile" \
  --query "InstanceProfile.InstanceProfileName" --output text 2>/dev/null || true)
[ -n "$IAM_PROFILE_EXISTS" ] && [ "$IAM_PROFILE_EXISTS" != "None" ] && \
  tf_import "aws_iam_instance_profile.ec2_ssm" "${PROJECT}-ec2-ssm-profile"

# ── IAM role policy attachment ────────────────────────────────────────────────────────────
ATTACHED=$(aws iam list-attached-role-policies --role-name "${PROJECT}-ec2-ssm-role" \
  --query "AttachedPolicies[?PolicyArn=='arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore'].PolicyArn" \
  --output text 2>/dev/null || true)
[ -n "$ATTACHED" ] && [ "$ATTACHED" != "None" ] && \
  tf_import "aws_iam_role_policy_attachment.ssm_core" \
    "${PROJECT}-ec2-ssm-role/arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

# ── Key pair ──────────────────────────────────────────────────────────────────────────────────
# Delete stale key pair so Terraform creates it fresh with current SSH_PUBLIC_KEY.
KEY_EXISTS=$(aws ec2 describe-key-pairs \
  --key-names "${PROJECT}-key" \
  --query "KeyPairs[0].KeyName" --output text 2>/dev/null || true)
if [ "$KEY_EXISTS" = "${PROJECT}-key" ]; then
  echo "  DELETE stale key pair: ${PROJECT}-key"
  aws ec2 delete-key-pair --key-name "${PROJECT}-key"
fi

# ── EC2 instance: wait for any terminating instance, then decide ───────────────────────
# If an instance with our Name tag is in running/stopped: terminate it and wait.
# If it's already terminating/terminated: just wait for it to finish.
# Either way, we don't import it — Terraform will create a fresh one.
EC2_INFO=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PROJECT}-app" \
  --query "Reservations[0].Instances[0].{Id:InstanceId,State:State.Name}" \
  --output json 2>/dev/null || echo '{}')
EC2_ID=$(echo "$EC2_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Id',''))" 2>/dev/null || true)
EC2_STATE=$(echo "$EC2_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('State',''))" 2>/dev/null || true)

echo "  EC2: id=$EC2_ID state=$EC2_STATE"

if [ -n "$EC2_ID" ] && [ "$EC2_ID" != "None" ]; then
  if [ "$EC2_STATE" = "running" ] || [ "$EC2_STATE" = "stopped" ] || [ "$EC2_STATE" = "pending" ]; then
    echo "  TERMINATE EC2 $EC2_ID (state: $EC2_STATE)"
    aws ec2 terminate-instances --instance-ids "$EC2_ID"
  fi
  echo "  WAIT for EC2 $EC2_ID to be fully terminated..."
  aws ec2 wait instance-terminated --instance-ids "$EC2_ID"
  echo "  EC2 terminated."
  # Remove from Terraform state if it somehow got imported
  terraform state rm aws_instance.app 2>/dev/null || true
fi

# ── Elastic IP ────────────────────────────────────────────────────────────────────────────────
# Also remove EIP from state so Terraform can re-associate it to the new instance.
terraform state rm aws_eip.app 2>/dev/null || true

EIP_ALLOC=$(aws ec2 describe-addresses \
  --filters "Name=tag:Name,Values=${PROJECT}-eip" \
  --query "Addresses[0].AllocationId" --output text 2>/dev/null || true)
[ "$EIP_ALLOC" != "None" ] && [ -n "$EIP_ALLOC" ] && \
  tf_import "aws_eip.app" "$EIP_ALLOC"

echo "==> Import phase complete."
