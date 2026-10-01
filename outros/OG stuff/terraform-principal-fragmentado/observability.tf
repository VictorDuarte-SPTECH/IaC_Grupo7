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