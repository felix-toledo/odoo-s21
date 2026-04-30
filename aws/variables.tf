# =============================================================================
# INFRAESTRUCTURA – Variables parametrizables
# Crea un archivo terraform.tfvars (NO lo commitees) para sobreescribir
# los defaults. El archivo ya está en .gitignore.
# =============================================================================

# ── AWS ──────────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "Region de AWS donde se despliegan los recursos"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Perfil opcional de AWS CLI a usar para esta infraestructura. Si queda vacio, usa las credenciales activas del entorno"
  type        = string
  default     = ""
}

variable "environment" {
  description = "Nombre del entorno: dev | staging | prod"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "El entorno debe ser dev, staging o prod."
  }
}

# ── EC2 ──────────────────────────────────────────────────────────────────────

variable "instance_type" {
  description = "Tipo de instancia EC2 para el servidor Odoo"
  type        = string
  default     = "t3.micro"
}

variable "ec2_root_volume_size" {
  description = "Tamaño en GB del disco raíz de la EC2. Amazon Linux 2023 actualmente requiere al menos 30 GB con esta AMI"
  type        = number
  default     = 30

  validation {
    condition     = var.ec2_root_volume_size >= 30
    error_message = "ec2_root_volume_size debe ser al menos 30 GB para esta AMI."
  }
}

variable "allowed_cidr" {
  description = "CIDR con acceso al puerto 8069. Restringir a la IP del equipo en produccion"
  type        = string
  default     = "0.0.0.0/0"
}

# ── RDS ──────────────────────────────────────────────────────────────────────

variable "db_instance_class" {
  description = "Clase de instancia RDS para PostgreSQL"
  type        = string
  default     = "db.t3.micro"
}

variable "db_backup_retention_period" {
  description = "Dias de retencion de backups automáticos en RDS. Algunas cuentas free tier solo permiten 1 o menos"
  type        = number
  default     = 1

  validation {
    condition     = var.db_backup_retention_period >= 0 && var.db_backup_retention_period <= 35
    error_message = "db_backup_retention_period debe estar entre 0 y 35."
  }
}

variable "db_name" {
  description = "Nombre de la base de datos PostgreSQL inicial"
  type        = string
  default     = "odoo"
}

variable "db_username" {
  description = "Usuario maestro de RDS PostgreSQL"
  type        = string
  default     = "odoo"
}

variable "db_password" {
  description = "Contrasena del usuario maestro de RDS. OBLIGATORIO – pasar via tfvars o variable de entorno TF_VAR_db_password"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.db_password) >= 12
    error_message = "La contrasena debe tener al menos 12 caracteres."
  }
}
