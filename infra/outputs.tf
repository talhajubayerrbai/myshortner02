output "ec2_public_ip" {
  description = "Public IP of the app EC2 instance (via EIP)"
  value       = aws_eip.app.public_ip
}

output "ec2_instance_id" {
  description = "EC2 instance ID (needed for SSM Run Command)"
  value       = aws_instance.app.id
}

output "rds_endpoint" {
  description = "RDS endpoint host (without port)"
  value       = split(":", aws_db_instance.postgres.endpoint)[0]
}
