# =============================================================================
# DATA SOURCES
# =============================================================================

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# =============================================================================
# LOCALS
# =============================================================================

locals {
  app_name              = "odoo-s21-${var.environment}"
  log_group_name        = "/ec2/odoo-s21/${var.environment}"
  dashboard_name        = "${local.app_name}-overview"
  ec2_status_alarm_name = "${local.app_name}-ec2-status-check"
}

# =============================================================================
# CLOUDWATCH LOGS
# =============================================================================

resource "aws_cloudwatch_log_group" "app" {
  name              = local.log_group_name
  retention_in_days = var.cloudwatch_log_retention_in_days
}

# =============================================================================
# SECURITY GROUPS
# =============================================================================

resource "aws_security_group" "ec2" {
  name        = "${local.app_name}-ec2-sg"
  description = "Trafico entrante a Odoo (puerto 8069)"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Odoo web interface"
    from_port   = 8069
    to_port     = 8069
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Solo la EC2 puede conectarse a RDS — la DB no es accesible desde internet
resource "aws_security_group" "rds" {
  name        = "${local.app_name}-rds-sg"
  description = "Acceso a PostgreSQL unicamente desde la EC2 de Odoo"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "PostgreSQL desde EC2"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# =============================================================================
# RDS – PostgreSQL administrado
# =============================================================================

resource "aws_db_subnet_group" "main" {
  name       = "${local.app_name}-db-subnet-group"
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_db_instance" "postgres" {
  identifier        = "${local.app_name}-db"
  engine            = "postgres"
  engine_version    = "15"
  instance_class    = var.db_instance_class
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  publicly_accessible     = false # DB privada, no expuesta a internet
  backup_retention_period = var.db_backup_retention_period
  deletion_protection     = false # Cambiar a true en produccion real
  skip_final_snapshot     = true  # Cambiar a false en produccion real
  multi_az                = false # Cambiar a true para HA real
}

# =============================================================================
# IAM – Rol para la instancia EC2
# =============================================================================

resource "aws_iam_role" "ec2" {
  name = "${local.app_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "cloudwatch_logs" {
  name = "${local.app_name}-cloudwatch-logs"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "${aws_cloudwatch_log_group.app.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.app_name}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# =============================================================================
# EC2 – Servidor de aplicacion Odoo
# Conecta a RDS (no levanta una DB local)
# =============================================================================

resource "aws_instance" "odoo" {
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = true
  user_data_replace_on_change = true

  root_block_device {
    volume_size = var.ec2_root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 obligatorio (seguridad)
  }

  user_data = <<-EOF
    #!/bin/bash
    # Loguear todo pero NO abortar ante errores individuales
    exec > >(tee /var/log/odoo-bootstrap.log) 2>&1
    set -uxo pipefail

    echo "=== [1/4] Instalando Docker ==="
    dnf update -y
    dnf install -y docker
    systemctl enable --now docker
    echo "=== Docker listo ==="

    echo "=== [2/4] Creando directorios ==="
    mkdir -p /opt/odoo/odoo /opt/odoo/custom_addons
    # uid 101 = usuario "odoo" dentro del contenedor oficial odoo:16.0
    chown -R 101:101 /opt/odoo/odoo /opt/odoo/custom_addons

    echo "=== [3/4] Descargando imagen Odoo 16 ==="
    docker pull odoo:16.0
    echo "=== Imagen descargada ==="

    echo "=== [4/4] Iniciando contenedor Odoo ==="
    docker run -d \
      --name odoo-web \
      --restart unless-stopped \
      -p 8069:8069 \
      -e HOST=${aws_db_instance.postgres.address} \
      -e USER=${var.db_username} \
      -e "PASSWORD=${var.db_password}" \
      -v /opt/odoo/odoo:/var/lib/odoo \
      -v /opt/odoo/custom_addons:/mnt/extra-addons \
      --log-driver=awslogs \
      --log-opt awslogs-group=${aws_cloudwatch_log_group.app.name} \
      --log-opt awslogs-region=${var.aws_region} \
      --log-opt awslogs-stream=odoo-web \
      odoo:16.0 odoo -i base -d odoo --without-demo=all && echo "=== Contenedor iniciado OK ===" || echo "=== ERROR: fallo docker run ==="

    echo "=== Bootstrap finalizado ==="
  EOF

  depends_on = [
    aws_db_instance.postgres,
    aws_iam_role_policy_attachment.ssm,
    aws_iam_role_policy.cloudwatch_logs,
    aws_cloudwatch_log_group.app
  ]

  lifecycle {
    # Evita reemplazar la instancia si AWS publica una AMI más nueva (most_recent drift)
    # o si el user_data cambia en el código — la instancia ya está configurada y corriendo.
    # Para forzar un reemplazo intencional, comentá estas líneas y hacé apply.
    ignore_changes = [ami, user_data]
  }
}

# =============================================================================
# CLOUDWATCH MONITORING
# =============================================================================

resource "aws_cloudwatch_metric_alarm" "ec2_cpu_high" {
  alarm_name          = "${local.app_name}-ec2-cpu-high"
  alarm_description   = "CPU alta en la instancia EC2 que ejecuta Odoo"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = var.ec2_cpu_alarm_threshold
  treat_missing_data  = "missing"

  dimensions = {
    InstanceId = aws_instance.odoo.id
  }
}

resource "aws_cloudwatch_metric_alarm" "ec2_status_check_failed" {
  alarm_name          = local.ec2_status_alarm_name
  alarm_description   = "Fallo en status checks de la instancia EC2"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  treat_missing_data  = "missing"

  dimensions = {
    InstanceId = aws_instance.odoo.id
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "${local.app_name}-rds-cpu-high"
  alarm_description   = "CPU alta en la instancia RDS de PostgreSQL"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = var.rds_cpu_alarm_threshold
  treat_missing_data  = "missing"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.postgres.id
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_free_storage_low" {
  alarm_name          = "${local.app_name}-rds-free-storage-low"
  alarm_description   = "Espacio libre bajo en el almacenamiento de RDS"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = var.rds_free_storage_alarm_threshold_bytes
  treat_missing_data  = "missing"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.postgres.id
  }
}

resource "aws_cloudwatch_dashboard" "overview" {
  dashboard_name = local.dashboard_name

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "EC2 Odoo"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.odoo.id],
            ["AWS/EC2", "StatusCheckFailed", "InstanceId", aws_instance.odoo.id]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "RDS PostgreSQL"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.postgres.id],
            ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", aws_db_instance.postgres.id]
          ]
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 6
        width  = 24
        height = 6
        properties = {
          region = var.aws_region
          title  = "Logs Odoo"
          query  = "SOURCE '${aws_cloudwatch_log_group.app.name}' | fields @timestamp, @message | sort @timestamp desc | limit 50"
          view   = "table"
        }
      }
    ]
  })
}