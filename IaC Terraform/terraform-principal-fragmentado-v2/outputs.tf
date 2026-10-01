# ==============================================================================
# OUTPUTS DA INFRAESTRUTURA PRINCIPAL
# ==============================================================================

output "application_url" {
  description = "URL HTTP pública do Application Load Balancer."
  value       = "http://${aws_lb.application.dns_name}"
}

output "bastion_public_ip" {
  description = "Endereço IP público fixo do bastion para acesso SSH."
  value       = aws_eip.bastion.public_ip
}

output "swarm_manager_private_ip" {
  description = "Endereço IP privado do manager Docker Swarm."
  value       = aws_instance.swarm_manager.private_ip
}

output "swarm_manager_ssh_command" {
  description = "Comando base para acessar o manager pelo bastion."
  value       = "ssh -i <chave.pem> -J ubuntu@${aws_eip.bastion.public_ip} ubuntu@${aws_instance.swarm_manager.private_ip}"
}

output "swarm_manager_sftp_command" {
  description = "Comando base para enviar arquivos ao manager pelo bastion."
  value       = "sftp -i <chave.pem> -o ProxyJump=ubuntu@${aws_eip.bastion.public_ip} ubuntu@${aws_instance.swarm_manager.private_ip}"
}

output "database_private_ip" {
  description = "Endereço IP privado da instância EC2 do banco de dados."
  value       = aws_instance.database_az2.private_ip
}

output "database_jdbc_url" {
  description = "URL JDBC privada utilizada pelo backend."
  value       = "jdbc:mysql://${aws_instance.database_az2.private_ip}:3306/${var.database_name}"
}

output "rabbitmq_private_ip" {
  description = "Endereço IP privado da instância EC2 do RabbitMQ."
  value       = aws_instance.rabbitmq.private_ip
}

output "rabbitmq_amqp_endpoint" {
  description = "Endpoint AMQP privado acessível pelas instâncias backend."
  value       = "amqp://${aws_instance.rabbitmq.private_ip}:5672"
}

output "rabbitmq_ssh_command" {
  description = "Comando base para acessar a VM RabbitMQ pelo bastion."
  value       = "ssh -i <chave.pem> -J ubuntu@${aws_eip.bastion.public_ip} ubuntu@${aws_instance.rabbitmq.private_ip}"
}

output "rabbitmq_management_tunnel_command" {
  description = "Túnel SSH para acessar a interface RabbitMQ em http://localhost:15672."
  value       = "ssh -i <chave.pem> -J ubuntu@${aws_eip.bastion.public_ip} -L 15672:localhost:15672 ubuntu@${aws_instance.rabbitmq.private_ip}"
}
