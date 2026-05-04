# Infraestructura AWS – Odoo 16 (Siglo XXI Lubricentro)

Stack de Terraform para desplegar Odoo 16 en AWS con base de datos administrada RDS PostgreSQL, acceso seguro vía SSM, logs centralizados en CloudWatch y alarmas básicas de monitoreo.

---

## Arquitectura

```
Internet
   │  (puerto 8069)
   ▼
EC2 t3.micro  ──────────────────►  RDS PostgreSQL db.t3.micro
(Odoo 16 en Docker)               (privado, sin acceso a internet)
   │
   ▼
CloudWatch Logs  /ec2/odoo-s21/<env>
```

| Recurso            | Descripción                                              |
|--------------------|----------------------------------------------------------|
| `aws_instance`     | EC2 con Amazon Linux 2023, Docker + Odoo 16              |
| `aws_db_instance`  | RDS PostgreSQL 15, cifrado, 20 GB gp3                    |
| `aws_security_group` ec2 | Solo puerto 8069 entrante                         |
| `aws_security_group` rds | Solo acepta conexiones desde el SG de la EC2      |
| `aws_iam_role`     | Rol EC2 con SSM + permisos CloudWatch Logs               |
| `aws_cloudwatch_log_group` | Retención 7 días                               |
| `aws_cloudwatch_metric_alarm` | Alarmas de CPU/health para EC2 y RDS        |
| `aws_cloudwatch_dashboard` | Dashboard operativo con métricas y logs        |

---

## Pre-requisitos

### 1. AWS CLI configurado

Cada integrante del equipo debe configurar sus credenciales locales:

```powershell
aws configure
# AWS Access Key ID: <tu_access_key>
# AWS Secret Access Key: <tu_secret_key>
# Default region name: us-east-1
# Default output format: json
```

Verifica que funciona:

```powershell
aws sts get-caller-identity
```

Si ya tenés otra cuenta configurada en AWS CLI, no hace falta tocarla. Tenés dos opciones seguras:

```powershell
# Ver perfiles disponibles
aws configure list-profiles

# Probar un perfil especifico
aws sts get-caller-identity --profile universidad
```

- Opción 1: exportar el perfil solo para esta terminal:

```powershell
$env:AWS_PROFILE = "universidad"
aws sts get-caller-identity
```

- Opción 2: definir `aws_profile` dentro de `terraform.tfvars`.

Recomendación: usar `AWS_PROFILE` al bootstrap del backend y dejar `aws_profile` también en `terraform.tfvars` para que el provider de Terraform apunte siempre a la cuenta correcta.

### 2. Terraform >= 1.5.0

```powershell
terraform version
```

Si no está instalado: https://developer.hashicorp.com/terraform/install

---

## Bootstrap del Backend Remoto (hacer UNA sola vez por equipo)

El estado de Terraform se guarda en S3 con bloqueo en DynamoDB para evitar que varios desarrolladores modifiquen la infraestructura al mismo tiempo.

**Ejecuta estos comandos una sola vez** (el responsable DevOps del equipo):

Primero activá el perfil correcto si no querés usar la cuenta por default:

```powershell
$env:AWS_PROFILE = "universidad"
aws sts get-caller-identity
```

```powershell
# 1. Obtener tu Account ID
$ACCOUNT_ID = (aws sts get-caller-identity --query Account --output text)

# 2. Crear el bucket S3 con versionado y cifrado
aws s3api create-bucket `
  --bucket "$ACCOUNT_ID-s21-lubricentro-tfstate" `
  --region us-east-1

aws s3api put-bucket-versioning `
  --bucket "$ACCOUNT_ID-s21-lubricentro-tfstate" `
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption `
  --bucket "$ACCOUNT_ID-s21-lubricentro-tfstate" `
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block `
  --bucket "$ACCOUNT_ID-s21-lubricentro-tfstate" `
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# 3. Crear la tabla DynamoDB para State Locking
aws dynamodb create-table `
  --table-name s21-lubricentro-tfstate-lock `
  --attribute-definitions AttributeName=LockID,AttributeType=S `
  --key-schema AttributeName=LockID,KeyType=HASH `
  --billing-mode PAY_PER_REQUEST `
  --region us-east-1
```

Luego edita `providers.tf` y reemplaza `<ACCOUNT_ID>` con el valor real.

Si preferís no exportar `AWS_PROFILE`, podés agregar `--profile universidad` a cada comando `aws` del bootstrap.

---

## Variables de entorno obligatorias

La contraseña de la base de datos es `sensitive` y **nunca debe estar en el repositorio**.

**Opción A – Variable de entorno (recomendada para CI/CD):**

```powershell
$env:TF_VAR_db_password = "MiPasswordSegura2024!"
```

**Opción B – Archivo `terraform.tfvars` (local, ya en `.gitignore`):**

```hcl
# aws/terraform.tfvars  ← NO commitear
aws_profile  = "universidad"
db_password  = "MiPasswordSegura2024!"
allowed_cidr = "203.0.113.10/32"   # tu IP pública
environment  = "dev"
```

---

## Flujo de trabajo del equipo

### Primera vez (o tras clonar el repo)

```powershell
# Desde la raíz del repositorio
$env:AWS_PROFILE = "universidad"   # opcional si ya definiste aws_profile en terraform.tfvars
terraform -chdir=aws init
```

### Antes de aplicar cambios

```powershell
# Ver qué va a cambiar sin tocar nada
$env:AWS_PROFILE = "universidad"
terraform -chdir=aws plan
```

> Si otro integrante está aplicando en ese momento, Terraform mostrará:
> `Error: Error acquiring the state lock` — espera a que termine.

### Aplicar cambios

```powershell
$env:AWS_PROFILE = "universidad"
terraform -chdir=aws apply
```

Confirma escribiendo `yes` cuando se solicite.

Al terminar, los outputs muestran:

```
app_url               = "http://x.x.x.x:8069"
ssm_session_command   = "aws ssm start-session --target i-xxxxxxxxxx --region us-east-1"
db_endpoint           = "odoo-s21-dev-db.xxxx.us-east-1.rds.amazonaws.com"
```

### Acceso seguro a la EC2 (sin clave SSH)

```powershell
$env:AWS_PROFILE = "universidad"
aws ssm start-session --target <instance_id> --region us-east-1
```

### Ver logs de Odoo en tiempo real

```powershell
$env:AWS_PROFILE = "universidad"
aws logs tail /ec2/odoo-s21/dev --follow --region us-east-1
```

### Monitoreo en CloudWatch

Terraform ahora deja configurado:

- alarmas por CPU alta en EC2 y RDS
- alarma por `StatusCheckFailed` en la EC2
- alarma por bajo espacio libre en RDS
- dashboard con métricas de EC2, RDS y últimos logs de Odoo

Después del `apply`, podés ver el nombre del dashboard con:

```powershell
terraform -chdir=aws output cloudwatch_dashboard_name
```

### Destruir la infraestructura (apagar la demo)

```powershell
$env:AWS_PROFILE = "universidad"
terraform -chdir=aws destroy
```

---

## Variables disponibles

| Variable           | Default        | Descripción                                        |
|--------------------|----------------|----------------------------------------------------|
| `aws_region`       | `us-east-1`    | Región AWS                                         |
| `aws_profile`      | `""`          | Perfil AWS CLI opcional para este proyecto         |
| `environment`      | `dev`          | Entorno: dev / staging / prod                      |
| `instance_type`    | `t3.micro`     | Tipo de instancia EC2                              |
| `ec2_root_volume_size` | `30`       | Tamaño del disco raíz EC2 en GB                    |
| `allowed_cidr`     | `0.0.0.0/0`    | CIDR con acceso al puerto 8069 (restringir en prod)|
| `db_instance_class`| `db.t3.micro`  | Clase de instancia RDS                             |
| `db_backup_retention_period` | `1`      | Días de backups automáticos RDS                   |
| `db_name`          | `odoo`         | Nombre de la base de datos                         |
| `db_username`      | `odoo`         | Usuario maestro RDS                                |
| `db_password`      | **requerida**  | Contraseña RDS — nunca en el repo                  |

---

## Notas para producción real

- Cambiar `deletion_protection = true` y `skip_final_snapshot = false` en RDS
- Cambiar `multi_az = true` en RDS para alta disponibilidad real
- Si tu cuenta AWS tiene restricciones de plan/free tier en RDS, dejar `db_backup_retention_period = 1` o bajar a `0`
- Restringir `allowed_cidr` a las IPs del equipo o usar un ALB
- Considerar AWS Secrets Manager para rotar la contraseña de BD automáticamente

