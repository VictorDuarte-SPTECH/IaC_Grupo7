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

variable "instance_profile_name" {
  description = "Nome do IAM instance profile associado à LabRole na conta AWS Academy."
  type        = string
  default     = "LabInstanceProfile"
}

variable "alert_email" {
  description = "E-mail que receberá os alertas SNS. Deixe vazio para não criar a assinatura."
  type        = string
  default     = ""

  validation {
    condition     = var.alert_email == "" || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email deve estar vazio ou conter um endereço de e-mail válido."
  }
}
