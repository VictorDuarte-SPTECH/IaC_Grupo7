terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      Component   = "data-lake"
      ManagedBy   = "Terraform"
      Member      = var.member_prefix
    }
  }
}

locals {
  bucket_prefix_base = "${var.project_name}-${var.member_prefix}-${var.environment}"
}
