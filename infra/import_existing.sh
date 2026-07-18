#!/usr/bin/env bash
# Idempotent pre-apply import script.
# Imports AWS resources that may already exist (e.g. from a partial prior run)
# into the current Terraform state. Safe to run even when resources don't exist yet.
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

# ── Key pair ──────────────────────────────────────────────────────────────────────────────
KEY_EXISTS=$(aws ec2 describe-key-pairs \
  --key-names "${PROJECT}-key" \
  --query "KeyPairs[0].KeyName" --output text 2>/dev/null || true)
[ "$KEY_EXISTS" != "None" ] && [ -n "$KEY_EXISTS" ] && \
  tf_import "aws_key_pair.deployer" "${PROJECT}-key"

# ── EC2 instance ──────────────────────────────────────────────────────────────────────────────
EC2_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PROJECT}-app" "Name=instance-state-name,Values=running,stopped,pending" \
  --query "Reservations[0].Instances[0].InstanceId" --output text 2>/dev/null || true)
[ "$EC2_ID" != "None" ] && [ -n "$EC2_ID" ] && \
  tf_import "aws_instance.app" "$EC2_ID"

# ── Elastic IP ────────────────────────────────────────────────────────────────────────────────
EIP_ALLOC=$(aws ec2 describe-addresses \
  --filters "Name=tag:Name,Values=${PROJECT}-eip" \
  --query "Addresses[0].AllocationId" --output text 2>/dev/null || true)
[ "$EIP_ALLOC" != "None" ] && [ -n "$EIP_ALLOC" ] && \
  tf_import "aws_eip.app" "$EIP_ALLOC"

# ── RDS instance ───────────────────────────────────────────────────────────────────────────────
RDS_EXISTS=$(aws rds describe-db-instances \
  --db-instance-identifier "${PROJECT}-db" \
  --query "DBInstances[0].DBInstanceIdentifier" --output text 2>/dev/null || true)
[ "$RDS_EXISTS" != "None" ] && [ -n "$RDS_EXISTS" ] && \
  tf_import "aws_db_instance.postgres" "${PROJECT}-db"

echo "==> Import phase complete."
