# ==============================================================================
# VARIÁVEIS DA STACK PRINCIPAL
# ==============================================================================

variable "aws_region" {
  description = "Região AWS em que a infraestrutura será criada."
  type        = string
  default     = "us-east-1"
}

variable "environment_name" {
  description = "Nome base utilizado nos recursos da aplicação."
  type        = string
  default     = "lamar-auto-pecas"
}

variable "instance_type" {
  description = "Tipo das instâncias EC2 da aplicação e do banco."
  type        = string
  default     = "t3.micro"
}
