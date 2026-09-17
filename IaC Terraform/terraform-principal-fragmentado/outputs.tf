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

# ==============================================================================
# OUTPUTS DO DATA LAKE LEGADO
# ==============================================================================
# Remova ou comente estes outputs junto com os recursos de storage.tf.

/*
output "bronze_bucket" {
  value = aws_s3_bucket.bronze.id
}

output "silver_bucket" {
  value = aws_s3_bucket.silver.id
}

output "gold_bucket" {
  value = aws_s3_bucket.gold.id
}
*/