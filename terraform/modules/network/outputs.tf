output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "ALB 用パブリックサブネット"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "ECS / RDS 用プライベートサブネット"
  value       = aws_subnet.private[*].id
}
