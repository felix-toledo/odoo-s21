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
