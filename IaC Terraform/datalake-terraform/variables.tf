variable "aws_region" {
  description = "Regiao AWS onde os buckets serao criados."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Nome curto do projeto, em minusculas e sem espacos."
  type        = string
  default     = "lamar-autopecas"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.project_name))
    error_message = "project_name deve conter somente letras minusculas, numeros e hifens."
  }
}

variable "member_prefix" {
  description = "Identificador curto e exclusivo do integrante ou grupo, por exemplo grupo01 ou marcela."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.member_prefix)) && length(var.member_prefix) <= 20
    error_message = "member_prefix deve ter no maximo 20 caracteres e usar somente letras minusculas, numeros e hifens."
  }
}

variable "environment" {
  description = "Ambiente da stack."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment deve ser dev, test ou prod."
  }
}

variable "force_destroy_buckets" {
  description = "Permite apagar buckets com objetos durante terraform destroy. Use true somente em ambiente descartavel."
  type        = bool
  default     = false
}
