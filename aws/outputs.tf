# =============================================================================
# OUTPUTS – Valores clave post-apply
# =============================================================================

output "instance_id" {
  description = "ID de la instancia EC2 de Odoo"
  value       = aws_instance.odoo.id
}

output "public_ip" {
  description = "IP publica de la instancia EC2"
  value       = aws_instance.odoo.public_ip
}

output "app_url" {
  description = "URL para acceder a Odoo desde el navegador"
  value       = "http://${aws_instance.odoo.public_ip}:8069"
}

output "ssm_session_command" {
  description = "Comando para abrir shell segura en la EC2 via SSM (sin necesidad de clave SSH)"
  value       = "aws ssm start-session --target ${aws_instance.odoo.id} --region ${var.aws_region}"
}

output "db_endpoint" {
  description = "Endpoint del servidor RDS PostgreSQL (host)"
  value       = aws_db_instance.postgres.address
}

output "db_port" {
  description = "Puerto de RDS PostgreSQL"
  value       = aws_db_instance.postgres.port
}

output "cloudwatch_log_group" {
  description = "Nombre del log group en CloudWatch"
  value       = aws_cloudwatch_log_group.app.name
}

output "cloudwatch_dashboard_name" {
  description = "Nombre del dashboard principal de CloudWatch"
  value       = aws_cloudwatch_dashboard.overview.dashboard_name
}
