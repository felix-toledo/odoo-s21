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
  app_name       = "odoo-s21-${var.environment}"
  log_group_name = "/ec2/odoo-s21/${var.environment}"
}

# =============================================================================
# CLOUDWATCH LOGS
# =============================================================================

resource "aws_cloudwatch_log_group" "app" {
  name              = local.log_group_name
  retention_in_days = 7
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

  publicly_accessible     = false  # DB privada, no expuesta a internet
  backup_retention_period = 7
  deletion_protection     = false  # Cambiar a true en produccion real
  skip_final_snapshot     = true   # Cambiar a false en produccion real
  multi_az                = false  # Cambiar a true para HA real
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
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 obligatorio (seguridad)
  }

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    dnf update -y
    dnf install -y docker docker-compose-plugin
    systemctl enable --now docker

    mkdir -p /opt/odoo/odoo /opt/odoo/custom_addons

    cat >/opt/odoo/docker-compose.yml <<'YAML'
    services:
      web:
        image: odoo:16.0
        container_name: odoo-web
        restart: unless-stopped
        ports:
          - "8069:8069"
        environment:
          HOST: ${aws_db_instance.postgres.address}
          USER: ${var.db_username}
          PASSWORD: ${var.db_password}
          DBNAME: ${var.db_name}
        volumes:
          - /opt/odoo/odoo:/var/lib/odoo
          - /opt/odoo/custom_addons:/mnt/extra-addons
        logging:
          driver: awslogs
          options:
            awslogs-group: ${aws_cloudwatch_log_group.app.name}
            awslogs-region: ${var.aws_region}
            awslogs-stream-prefix: odoo
    YAML

    cd /opt/odoo
    docker compose up -d
  EOF

  depends_on = [
    aws_db_instance.postgres,
    aws_iam_role_policy_attachment.ssm,
    aws_iam_role_policy.cloudwatch_logs,
    aws_cloudwatch_log_group.app
  ]
}