output "ec2_public_ip" {
  description = "Public IP of the app EC2 instance"
  value       = aws_eip.app.public_ip
}

output "rds_endpoint" {
  description = "RDS endpoint host (without port)"
  value       = split(":", aws_db_instance.postgres.endpoint)[0]
}
