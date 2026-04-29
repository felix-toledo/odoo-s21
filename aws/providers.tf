terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # ─────────────────────────────────────────────────────────────────────────
  # BACKEND REMOTO – State compartido + State Locking para el equipo
  #
  # ANTES de ejecutar `terraform init` por primera vez, cada integrante
  # del equipo debe crear (una sola vez) los recursos de bootstrap con:
  #
  #   aws s3api create-bucket \
  #     --bucket <ACCOUNT_ID>-s21-lubricentro-tfstate \
  #     --region us-east-1
  #
  #   aws s3api put-bucket-versioning \
  #     --bucket <ACCOUNT_ID>-s21-lubricentro-tfstate \
  #     --versioning-configuration Status=Enabled
  #
  #   aws s3api put-bucket-encryption \
  #     --bucket <ACCOUNT_ID>-s21-lubricentro-tfstate \
  #     --server-side-encryption-configuration \
  #       '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  #
  #   aws dynamodb create-table \
  #     --table-name s21-lubricentro-tfstate-lock \
  #     --attribute-definitions AttributeName=LockID,AttributeType=S \
  #     --key-schema AttributeName=LockID,KeyType=HASH \
  #     --billing-mode PAY_PER_REQUEST \
  #     --region us-east-1
  #
  # Reemplaza <ACCOUNT_ID> con tu AWS Account ID (aws sts get-caller-identity)
  # ─────────────────────────────────────────────────────────────────────────
  backend "s3" {
    bucket         = "<ACCOUNT_ID>-s21-lubricentro-tfstate"
    key            = "odoo/prod/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "s21-lubricentro-tfstate-lock"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "siglo-xxi-lubricentro"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
