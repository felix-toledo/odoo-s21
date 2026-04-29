terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "allowed_cidr" {
  type    = string
  default = "0.0.0.0/0"
}

provider "aws" {
  region = var.aws_region
}

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

locals {
  app_name       = "odoo-s21"
  log_group_name = "/ec2/odoo-s21"
}

resource "aws_cloudwatch_log_group" "app" {
  name              = local.log_group_name
  retention_in_days = 7

  tags = {
    Name    = local.app_name
    Project = local.app_name
  }
}

resource "aws_security_group" "app" {
  name        = "${local.app_name}-sg"
  description = "Odoo demo access"
  vpc_id      = data.aws_vpc.default.id

  ingress {
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

  tags = {
    Name    = local.app_name
    Project = local.app_name
  }
}

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
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.app_name}-ec2-profile"
  role = aws_iam_role.ec2.name
}

resource "aws_instance" "odoo" {
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.app.id]
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
    http_tokens   = "required"
  }

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    dnf update -y
    dnf install -y docker docker-compose-plugin
    systemctl enable --now docker

    mkdir -p /opt/odoo/postgres /opt/odoo/odoo /opt/odoo/custom_addons

    cat >/opt/odoo/docker-compose.yml <<'YAML'
    services:
      db:
        image: postgres:15
        container_name: odoo-db
        restart: unless-stopped
        environment:
          POSTGRES_USER: odoo
          POSTGRES_PASSWORD: odoo
          POSTGRES_DB: postgres
        volumes:
          - /opt/odoo/postgres:/var/lib/postgresql/data
        logging:
          driver: awslogs
          options:
            awslogs-group: ${aws_cloudwatch_log_group.app.name}
            awslogs-region: ${var.aws_region}
            awslogs-stream-prefix: postgres

      web:
        image: odoo:16.0
        container_name: odoo-web
        restart: unless-stopped
        depends_on:
          - db
        ports:
          - "8069:8069"
        environment:
          HOST: odoo-db
          USER: odoo
          PASSWORD: odoo
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

  tags = {
    Name    = local.app_name
    Project = local.app_name
  }

  depends_on = [
    aws_iam_role_policy_attachment.ssm,
    aws_iam_role_policy.cloudwatch_logs,
    aws_cloudwatch_log_group.app
  ]
}

output "instance_id" {
  value = aws_instance.odoo.id
}

output "public_ip" {
  value = aws_instance.odoo.public_ip
}

output "app_url" {
  value = "http://${aws_instance.odoo.public_ip}:8069"
}

output "ssm_session_command" {
  value = "aws ssm start-session --target ${aws_instance.odoo.id}"
}