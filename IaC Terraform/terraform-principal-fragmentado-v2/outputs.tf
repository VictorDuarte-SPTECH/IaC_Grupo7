# ==============================================================================
# OUTPUTS DA INFRAESTRUTURA PRINCIPAL
# ==============================================================================

output "application_url" {
  description = "URL HTTP pública do Application Load Balancer."
  value       = "http://${aws_lb.application.dns_name}"
}

output "database_private_ip" {
  description = "Endereço IP privado da instância EC2 do banco de dados."
  value       = aws_instance.database_az2.private_ip
}
