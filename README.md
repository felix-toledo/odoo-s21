# Odoo 16 – Siglo XXI Lubricentro

Sistema de gestión ERP basado en Odoo 16, desplegado en AWS con infraestructura gestionada por Terraform. Incluye entorno local con Docker Compose y addons personalizados.

---

## Índice

1. [Arquitectura general](#arquitectura-general)
2. [Servicios AWS](#servicios-aws)
3. [Terraform (IaC)](#terraform-iac)
4. [Docker](#docker)
5. [Custom Addons](#custom-addons)
6. [Entorno local](#entorno-local)
7. [Despliegue en AWS](#despliegue-en-aws)
8. [Sincronizar cambios al servidor](#sincronizar-cambios-al-servidor)
9. [Acceso remoto (SSM)](#acceso-remoto-ssm)
10. [Monitoreo (CloudWatch)](#monitoreo-cloudwatch)
11. [Estado actual del sistema](#estado-actual-del-sistema)

---

## Arquitectura general

```
┌─────────────────────────────────────────────────────────┐
│                        AWS (us-east-1)                  │
│                                                         │
│  Internet ──(8069)──► EC2 t3.micro                      │
│                       Amazon Linux 2023                 │
│                       Docker                            │
│                       └─ odoo-custom:16.0               │
│                             │                           │
│                             │ (5432, privado)           │
│                             ▼                           │
│                       RDS PostgreSQL 15                 │
│                       db.t3.micro, 20GB gp3             │
│                       cifrado, sin acceso público       │
│                             │                           │
│  SSM Agent ◄────────────────┘                           │
│  CloudWatch Logs ◄──────────┘                           │
└─────────────────────────────────────────────────────────┘
```

- La EC2 es el único punto de entrada público (puerto 8069).
- RDS no tiene IP pública. Solo acepta conexiones desde el Security Group de la EC2.
- No hay clave SSH. El acceso a la EC2 se hace exclusivamente por AWS SSM.

---

## Servicios AWS

| Servicio | Recurso | Detalle |
|---|---|---|
| **EC2** | `aws_instance` | `t3.micro`, Amazon Linux 2023, 30 GB gp3 cifrado, IMDSv2 |
| **RDS** | `aws_db_instance` | PostgreSQL 15, `db.t3.micro`, 20 GB gp3 cifrado, privado |
| **Security Group EC2** | `aws_security_group.ec2` | Entrada: TCP 8069 desde `allowed_cidr`. Salida: todo |
| **Security Group RDS** | `aws_security_group.rds` | Entrada: TCP 5432 solo desde SG de EC2 |
| **IAM Role** | `aws_iam_role.ec2` | Permite a la EC2 usar SSM y escribir a CloudWatch |
| **IAM Policy SSM** | `AmazonSSMManagedInstanceCore` | Acceso shell seguro sin SSH |
| **IAM Policy Logs** | `aws_iam_role_policy.cloudwatch_logs` | `PutLogEvents`, `CreateLogStream` |
| **CloudWatch Logs** | `aws_cloudwatch_log_group` | Grupo `/ec2/odoo-s21/dev`, retención 7 días |
| **S3** | bucket tfstate | `070980587585-s21-lubricentro-tfstate`, versionado + cifrado AES256 |
| **DynamoDB** | tabla locking | `s21-lubricentro-tfstate-lock`, evita conflictos de estado en equipo |
| **VPC** | default | Usa la VPC por defecto de la cuenta |

### Datos de la infraestructura actual (dev)

| Recurso | Valor |
|---|---|
| EC2 Instance ID | `i-0cf2c1b14a7fd4722` |
| EC2 IP pública | `100.24.61.90` |
| URL Odoo | http://100.24.61.90:8069 |
| RDS Endpoint | `odoo-s21-dev-db.c6dkuuk2gxtg.us-east-1.rds.amazonaws.com` |
| CloudWatch Log Group | `/ec2/odoo-s21/dev` |
| AWS Account ID | `070980587585` |
| Región | `us-east-1` |

---

## Terraform (IaC)

### Estructura de archivos

```
aws/
├── providers.tf          # Backend S3 + proveedor AWS con default_tags
├── variables.tf          # Todas las variables con validaciones
├── main.tf               # Todos los recursos (EC2, RDS, SGs, IAM, CloudWatch)
├── outputs.tf            # Valores post-apply (IP, URL, endpoints)
├── terraform.tfvars      # ⛔ NO en git — tus valores reales (contraseña, perfil)
└── terraform.tfvars.example  # ✅ Plantilla para el equipo
```

### Backend remoto (compartido en equipo)

El estado de Terraform se guarda en S3 con bloqueo en DynamoDB. Esto permite que el equipo trabaje sin pisarse:

```
S3 bucket: 070980587585-s21-lubricentro-tfstate
  └── odoo/prod/terraform.tfstate   ← estado actual
DynamoDB: s21-lubricentro-tfstate-lock ← evita dos apply simultáneos
```

### Comandos habituales

```powershell
# Activar perfil AWS (hacer una vez por terminal)
$env:AWS_PROFILE = "universidad"

# Ir al directorio del proyecto
cd C:\...\siglo-xxi-lubricentro

# Inicializar Terraform (primera vez o cuando cambia el backend)
terraform -chdir=aws init

# Ver qué cambios se van a hacer
terraform -chdir=aws plan

# Aplicar cambios
terraform -chdir=aws apply

# Ver outputs
terraform -chdir=aws output

# Destruir toda la infraestructura (¡CUIDADO!)
terraform -chdir=aws destroy
```

### Variables principales

| Variable | Default | Descripción |
|---|---|---|
| `aws_region` | `us-east-1` | Región |
| `aws_profile` | `""` | Perfil AWS CLI |
| `environment` | `dev` | `dev` / `staging` / `prod` |
| `instance_type` | `t3.micro` | Tipo EC2 |
| `ec2_root_volume_size` | `30` | GB disco EC2 (mínimo 30) |
| `allowed_cidr` | `0.0.0.0/0` | IPs con acceso al puerto 8069 |
| `db_instance_class` | `db.t3.micro` | Tipo RDS |
| `db_backup_retention_period` | `1` | Días de backup RDS (0-35) |
| `db_name` | `odoo` | Nombre de la DB |
| `db_username` | `odoo` | Usuario RDS |
| `db_password` | — | **Obligatorio, nunca en git** |

### Configurar terraform.tfvars

Copiá el ejemplo y completá con tus datos:

```powershell
Copy-Item aws\terraform.tfvars.example aws\terraform.tfvars
# Editá aws\terraform.tfvars con tu contraseña real
```

---

## Docker

### Imagen usada en AWS

En producción se usa una imagen custom construida directamente en la EC2:

```dockerfile
FROM odoo:16.0
USER root
COPY ./requirements.txt /etc/odoo/requirements.txt
RUN pip3 install --no-cache-dir -r /etc/odoo/requirements.txt
USER odoo
```

**Dependencias Python adicionales:** `cssselect` (requerida por algunos addons de scraping/HTML).

La imagen se llama `odoo-custom:16.0` y fue construida en la EC2 con:
```bash
cd /opt/odoo && docker build -t odoo-custom:16.0 .
```

### Contenedor en producción (EC2)

```bash
docker run -d \
  --name odoo-web \
  --restart unless-stopped \
  -p 8069:8069 \
  -e HOST=<rds-endpoint> \
  -e USER=odoo \
  -e PASSWORD=<password> \
  -v /opt/odoo/odoo:/var/lib/odoo \
  -v /opt/odoo/custom_addons:/mnt/extra-addons \
  --log-driver=awslogs \
  --log-opt awslogs-group=/ec2/odoo-s21/dev \
  --log-opt awslogs-region=us-east-1 \
  --log-opt awslogs-stream=odoo-web \
  odoo-custom:16.0
```

**Notas importantes:**
- El volumen `/opt/odoo/odoo` debe tener permisos del usuario `odoo` (uid 101 dentro del contenedor): `chown -R 101:101 /opt/odoo/odoo`
- Los logs van directo a CloudWatch mediante el driver `awslogs`
- `--restart unless-stopped` hace que el contenedor se levante automáticamente si la EC2 se reinicia

---

## Custom Addons

Los módulos personalizados están en `custom_addons/` y se montan en `/mnt/extra-addons` dentro del contenedor.

| Módulo | Descripción |
|---|---|
| `helpdesk_mgmt` | Gestión de tickets de soporte |
| `l10n_ar_afipws_fe` | Facturación electrónica AFIP (Argentina) |
| `resource_booking` | Reserva de recursos y turnos |
| `web_calendar_slot_duration` | Configuración de duración de slots en el calendario |

Para activar un módulo después de instalarlo en el servidor:
1. Ir a `http://100.24.61.90:8069`
2. **Settings → Activate developer mode** (o agregar `?debug=1` a la URL)
3. **Apps → Update Apps List → Confirm**
4. Buscar el módulo e instalarlo

---

## Entorno local

### Requisitos

- Docker Desktop instalado y corriendo
- Puerto 8069 libre en tu máquina

### Levantar el entorno

```powershell
docker compose up -d
```

Esto levanta:
- `odoo-db`: PostgreSQL 15 en `localhost:5432`
- `odoo-web`: Odoo 16 en `http://localhost:8069`

La imagen local se construye desde el `Dockerfile` local (incluye `cssselect`).

### Detener el entorno

```powershell
docker compose down
```

### Datos locales

Los datos persisten en `./data/` (ignorado en git):
- `./data/postgres/` → base de datos PostgreSQL
- `./data/odoo/` → archivos de Odoo (sesiones, adjuntos, etc.)

### Credenciales locales

| Campo | Valor |
|---|---|
| Host DB | `db` (nombre del servicio) |
| Usuario DB | `odoo` |
| Password DB | `odoo` |
| URL Odoo | http://localhost:8069 |

> Las credenciales locales `odoo`/`odoo` son solo para desarrollo. No tienen ningún impacto en producción.

---

## Despliegue en AWS

### Primera vez (setup completo)

**1. Configurar credenciales AWS**
```powershell
aws configure --profile universidad
# Access Key, Secret Key, region: us-east-1, output: json
```

**2. Bootstrap del backend remoto** (solo una vez por equipo)
```powershell
$env:AWS_PROFILE = "universidad"
$ACCOUNT_ID = (aws sts get-caller-identity --query Account --output text)

aws s3api create-bucket --bucket "$ACCOUNT_ID-s21-lubricentro-tfstate" --region us-east-1
aws s3api put-bucket-versioning --bucket "$ACCOUNT_ID-s21-lubricentro-tfstate" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$ACCOUNT_ID-s21-lubricentro-tfstate" --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws dynamodb create-table --table-name s21-lubricentro-tfstate-lock --attribute-definitions AttributeName=LockID,AttributeType=S --key-schema AttributeName=LockID,KeyType=HASH --billing-mode PAY_PER_REQUEST --region us-east-1
```

**3. Crear terraform.tfvars**
```powershell
Copy-Item aws\terraform.tfvars.example aws\terraform.tfvars
# Editá con tu contraseña real
```

**4. Inicializar y aplicar**
```powershell
$env:AWS_PROFILE = "universidad"
terraform -chdir=aws init
terraform -chdir=aws plan
terraform -chdir=aws apply
```

**5. Inicializar la base de datos Odoo** (solo la primera vez)
```powershell
$env:AWS_PROFILE = "universidad"
$INSTANCE_ID = (terraform -chdir=aws output -raw instance_id)

aws ssm send-command `
  --instance-ids $INSTANCE_ID `
  --document-name AWS-RunShellScript `
  --parameters 'commands=["sudo docker exec odoo-web bash -c '\''odoo -i base -d odoo --db_host=$HOST --db_user=$USER --db_password=$PASSWORD --without-demo=all --stop-after-init --no-http'\''"]' `
  --timeout-seconds 720 `
  --region us-east-1 `
  --query "Command.CommandId" --output text
```

---

## Sincronizar cambios al servidor

Cuando actualizás `custom_addons` o el `Dockerfile` localmente y hacés push, seguí estos pasos para aplicarlos en la EC2:

### 1. Clonar/actualizar el repo en la EC2

```powershell
$env:AWS_PROFILE = "universidad"

aws ssm send-command `
  --instance-ids i-0cf2c1b14a7fd4722 `
  --document-name AWS-RunShellScript `
  --parameters 'commands=["sudo dnf install -y git", "rm -rf /tmp/odoo-repo", "git clone https://github.com/felix-toledo/odoo-s21.git /tmp/odoo-repo", "sudo cp -r /tmp/odoo-repo/custom_addons/. /opt/odoo/custom_addons/", "sudo chown -R 101:101 /opt/odoo/custom_addons", "echo SYNC_DONE"]' `
  --timeout-seconds 300 --region us-east-1 `
  --query "Command.CommandId" --output text
```

### 2. Reconstruir la imagen (solo si cambió el Dockerfile o requirements.txt)

```powershell
aws ssm send-command `
  --instance-ids i-0cf2c1b14a7fd4722 `
  --document-name AWS-RunShellScript `
  --parameters 'commands=["sudo cp /tmp/odoo-repo/Dockerfile /opt/odoo/", "sudo cp /tmp/odoo-repo/requirements.txt /opt/odoo/", "cd /opt/odoo && sudo docker build -t odoo-custom:16.0 .", "echo BUILD_DONE"]' `
  --timeout-seconds 600 --region us-east-1 `
  --query "Command.CommandId" --output text
```

### 3. Verificar el estado de un comando SSM

```powershell
aws ssm list-command-invocations `
  --command-id "<ID_DEL_COMANDO>" `
  --region us-east-1 --details `
  --query "CommandInvocations[0].CommandPlugins[0].{Status:Status,Output:Output}" `
  --output json
```

---

## Acceso remoto (SSM)

No hay claves SSH. El acceso a la EC2 es exclusivamente por AWS Systems Manager.

### Abrir una shell en la EC2

```powershell
$env:AWS_PROFILE = "universidad"
aws ssm start-session --target i-0cf2c1b14a7fd4722 --region us-east-1
```

### Comandos útiles dentro de la EC2

```bash
# Ver logs del contenedor Odoo en tiempo real
sudo docker logs -f odoo-web

# Ver estado del contenedor
sudo docker ps

# Reiniciar Odoo
sudo docker restart odoo-web

# Ver el log de bootstrap inicial
cat /var/log/odoo-bootstrap.log

# Entrar al contenedor
sudo docker exec -it odoo-web bash
```

---

## Monitoreo (CloudWatch)

Los logs del contenedor Odoo se envían automáticamente a CloudWatch.

- **Log Group:** `/ec2/odoo-s21/dev`
- **Log Stream:** `odoo-web`
- **Retención:** 7 días

Para ver los logs desde la consola de AWS:
> CloudWatch → Log groups → `/ec2/odoo-s21/dev` → `odoo-web`

O desde la terminal:
```powershell
$env:AWS_PROFILE = "universidad"
aws logs tail /ec2/odoo-s21/dev --follow --region us-east-1
```

---

## Estado actual del sistema

| Componente | Estado |
|---|---|
| EC2 | ✅ Corriendo (`i-0cf2c1b14a7fd4722`) |
| RDS PostgreSQL | ✅ Corriendo |
| Odoo 16 | ✅ Corriendo en http://100.24.61.90:8069 |
| Imagen Docker | ✅ `odoo-custom:16.0` (con cssselect) |
| Custom Addons | ✅ Sincronizados en `/opt/odoo/custom_addons/` |
| Base de datos | ✅ Inicializada (99 módulos cargados) |
| CloudWatch Logs | ✅ Activo |
| Backend Terraform (S3) | ✅ Configurado y con versionado |
| Estado en git | ✅ Pusheado a `main` |

### Pendientes / mejoras para producción real

- [ ] Cambiar `allowed_cidr` de `0.0.0.0/0` a las IPs del equipo
- [ ] Cambiar la contraseña de la DB a una sin caracteres especiales (evita problemas de escaping en bash)
- [ ] Cambiar credenciales `admin`/`admin` de Odoo en el primer login
- [ ] Poner `deletion_protection = true` en RDS
- [ ] Poner `skip_final_snapshot = false` en RDS
- [ ] Considerar `multi_az = true` en RDS para alta disponibilidad
- [ ] Instalar y activar los custom addons desde la UI de Odoo

---

## Estructura del repositorio

```
siglo-xxi-lubricentro/
├── aws/
│   ├── main.tf                   # Recursos AWS (EC2, RDS, SGs, IAM, CloudWatch)
│   ├── providers.tf              # Backend S3 + proveedor AWS
│   ├── variables.tf              # Variables con validaciones
│   ├── outputs.tf                # Outputs post-apply
│   ├── terraform.tfvars          # ⛔ Ignorado en git (credenciales reales)
│   └── terraform.tfvars.example  # ✅ Plantilla para el equipo
├── custom_addons/
│   ├── helpdesk_mgmt/
│   ├── l10n_ar_afipws_fe/
│   ├── resource_booking/
│   └── web_calendar_slot_duration/
├── data/                         # ⛔ Ignorado en git (datos locales Docker)
├── Dockerfile                    # Imagen custom Odoo con cssselect
├── docker-compose.yml            # Stack local (PostgreSQL + Odoo)
├── requirements.txt              # Dependencias Python extra (cssselect)
├── .gitignore
└── README.md                     # Este archivo
```
