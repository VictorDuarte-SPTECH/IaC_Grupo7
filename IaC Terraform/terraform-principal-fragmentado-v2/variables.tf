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

  validation {
    condition     = length(var.environment_name) >= 1 && length(var.environment_name) <= 25 && can(regex("^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$", var.environment_name))
    error_message = "environment_name deve ter de 1 a 25 caracteres e usar apenas letras, números e hífens, sem hífen no início ou no fim."
  }
}

variable "instance_type" {
  description = "Tipo das instâncias EC2 da aplicação e do banco."
  type        = string
  default     = "t3.micro"
}

variable "ubuntu_ami_parameter" {
  description = "Parâmetro SSM que resolve a AMI do Ubuntu Server 24.04."
  type        = string
  default     = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

variable "instance_profile_name" {
  description = "Nome do IAM instance profile associado à LabRole na conta AWS Academy."
  type        = string
  default     = "LabInstanceProfile"
}

variable "key_name" {
  description = "Nome do par de chaves EC2 usado para acesso SSH e SFTP."
  type        = string
}

variable "rabbitmq_user" {
  description = "Usuário da aplicação para conexão com o RabbitMQ."
  type        = string
  default     = "lamar"

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]+$", var.rabbitmq_user))
    error_message = "rabbitmq_user deve conter apenas letras, números, sublinhados e hífens."
  }
}

variable "rabbitmq_password" {
  description = "Senha da aplicação para conexão com o RabbitMQ."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.rabbitmq_password) >= 12 && can(regex("^[a-zA-Z0-9._~!@#%^+=-]+$", var.rabbitmq_password))
    error_message = "rabbitmq_password deve ter ao menos 12 caracteres, sem espaços."
  }
}

variable "database_name" {
  description = "Nome do banco MySQL utilizado pela aplicação."
  type        = string
  default     = "lamar"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]*$", var.database_name))
    error_message = "database_name deve começar com uma letra e conter apenas letras, números e sublinhados."
  }
}

variable "database_user" {
  description = "Usuário MySQL utilizado pelas instâncias backend."
  type        = string
  default     = "lamar"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]*$", var.database_user))
    error_message = "database_user deve começar com uma letra e conter apenas letras, números e sublinhados."
  }
}

variable "database_password" {
  description = "Senha MySQL utilizada pelas instâncias backend."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.database_password) >= 12 && can(regex("^[a-zA-Z0-9._~!@#%^+=-]+$", var.database_password))
    error_message = "database_password deve ter ao menos 12 caracteres, sem espaços."
  }
}
