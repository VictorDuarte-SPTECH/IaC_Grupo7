terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment_name" {
  type    = string
  default = "lamar-auto-pecas"
}

variable "instance_ids" {
  description = "IDs das EC2 da stack principal: database, rabbitmq, manager, web_az1, web_az2, backend_az1 e backend_az2."
  type        = map(string)

  validation {
    condition     = alltrue([for key in ["database", "rabbitmq", "manager", "web_az1", "web_az2", "backend_az1", "backend_az2"] : try(length(var.instance_ids[key]) > 0, false)])
    error_message = "Informe todos os sete IDs de EC2 no mapa instance_ids."
  }
}

variable "database_volume_id" {
  description = "ID do volume EBS do banco de dados da stack principal."
  type        = string
}

variable "load_balancer_full_name" {
  description = "Parte do ARN apos loadbalancer/ (app/nome/id)."
  type        = string
}

variable "target_group_full_name" {
  description = "Parte do ARN apos targetgroup/ (nome/id)."
  type        = string
}

variable "alert_email" {
  description = "Email de alertas; vazio cria apenas o topico SNS."
  type        = string
  default     = ""
}

locals {
  instance_labels = {
    database    = "MySQL"
    rabbitmq    = "RabbitMQ"
    manager     = "Swarm manager"
    web_az1     = "Web AZ1"
    web_az2     = "Web AZ2"
    backend_az1 = "Backend AZ1"
    backend_az2 = "Backend AZ2"
  }

  target_dimensions = {
    TargetGroup  = var.target_group_full_name
    LoadBalancer = var.load_balancer_full_name
  }

}

resource "aws_sns_topic" "operations" {
  name = "${var.environment_name}-observabilidade-ti"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.operations.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_dashboard" "operations" {
  dashboard_name = "${var.environment_name}-operacoes"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title   = "CPU por instancia (%)", region = var.aws_region, stat = "Average", period = 300
          metrics = [for key, label in local.instance_labels : ["AWS/EC2", "CPUUtilization", "InstanceId", var.instance_ids[key], { label = label }]]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title   = "Falhas de status EC2", region = var.aws_region, stat = "Maximum", period = 60
          metrics = [for key, label in local.instance_labels : ["AWS/EC2", "StatusCheckFailed", "InstanceId", var.instance_ids[key], { label = label }]]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title = "Operacoes do volume EBS do MySQL", region = var.aws_region, stat = "Sum", period = 300
          metrics = [
            ["AWS/EBS", "VolumeReadOps", "VolumeId", var.database_volume_id, { label = "Leituras" }],
            ["AWS/EBS", "VolumeWriteOps", "VolumeId", var.database_volume_id, { label = "Gravacoes" }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title = "Saude dos targets do ALB", region = var.aws_region, stat = "Maximum", period = 60
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", var.target_group_full_name, "LoadBalancer", var.load_balancer_full_name, { label = "Saudaveis" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", var.target_group_full_name, "LoadBalancer", var.load_balancer_full_name, { label = "Nao saudaveis" }]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 12, height = 6
        properties = {
          title   = "Erros HTTP dos targets", region = var.aws_region, stat = "Sum", period = 60
          metrics = [["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "TargetGroup", var.target_group_full_name, "LoadBalancer", var.load_balancer_full_name]]
        }
      },
      {
        type = "metric", x = 12, y = 12, width = 12, height = 6
        properties = {
          title   = "Latencia dos targets (p95)", region = var.aws_region, stat = "p95", period = 60
          metrics = [["AWS/ApplicationELB", "TargetResponseTime", "TargetGroup", var.target_group_full_name, "LoadBalancer", var.load_balancer_full_name]]
        }
      }
    ]
  })
}

resource "aws_cloudwatch_metric_alarm" "database_status" {
  alarm_name          = "${var.environment_name}-mysql-status-ec2"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  dimensions          = { InstanceId = var.instance_ids["database"] }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = [aws_sns_topic.operations.arn]
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  alarm_name          = "${var.environment_name}-web-targets-nao-saudaveis"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = local.target_dimensions
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.operations.arn]
}

resource "aws_cloudwatch_metric_alarm" "http_5xx" {
  alarm_name          = "${var.environment_name}-web-erros-5xx"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = local.target_dimensions
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 10
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.operations.arn]
}

output "dashboard_name" {
  value = aws_cloudwatch_dashboard.operations.dashboard_name
}

output "dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.operations.dashboard_name}"
}

output "alert_topic_arn" {
  value = aws_sns_topic.operations.arn
}