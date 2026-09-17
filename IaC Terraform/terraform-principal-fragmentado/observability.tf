# ==============================================================================
# NOTIFICAÇÕES DE ALERTA COM SNS
# ==============================================================================

resource "aws_sns_topic" "alerts" {
  name = "${var.environment_name}-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = "email.do.marcos@lamar.com" # endereço de email mockado
}

# ==============================================================================
# ALARME DE OCUPAÇÃO DO DISCO
# ==============================================================================

resource "aws_cloudwatch_metric_alarm" "ebs_used_percent" {
  alarm_name          = "${var.environment_name}-ebs-used-70-percent"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "disk_used_percent"
  namespace           = "CWAgent"
  period              = 60
  statistic           = "Average"
  threshold           = 70
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "missing"

  dimensions = {
    InstanceId = aws_instance.database_az2.id
    path       = "/var/lib/mysql"
    fstype     = "ext4"
  }
}
