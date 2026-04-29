# Odoo en AWS

Este stack crea una instancia EC2 barata para Odoo + PostgreSQL y manda los logs de los contenedores a CloudWatch Logs.

## Coste objetivo

- Instancia `t3.micro`
- Un volumen gp3 de 20 GB
- CloudWatch Logs con retención de 7 días
- Sin load balancer, sin NAT, sin EKS, sin RDS

En una cuenta con Free Tier puede quedar muy cerca de cero si estás dentro de la capa gratuita; fuera de eso, sigue siendo un montaje barato para demos.

## Uso

Ejecuta Terraform desde esta carpeta para mantener el stack separado del Docker local que ya tenías.

```powershell
terraform -chdir=aws init
terraform -chdir=aws plan
terraform -chdir=aws apply
```

## Variables

- `aws_region`: región de AWS, por defecto `us-east-1`
- `instance_type`: por defecto `t3.micro`
- `allowed_cidr`: CIDR que puede entrar al puerto `8069`

Ejemplo con una IP concreta:

```powershell
terraform -chdir=aws apply -var="allowed_cidr=203.0.113.10/32"
```

## Acceso

- App: el output `app_url`
- SSM: el output `ssm_session_command`
- Logs: CloudWatch Logs en `/ec2/odoo-s21`

## Apagar la demo

```powershell
terraform -chdir=aws destroy
```
