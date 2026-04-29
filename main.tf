terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0.1"
    }
  }
}

provider "docker" {}

# Creamos una red para que los contenedores se comuniquen
resource "docker_network" "odoo_net" {
  name = "odoo_network"
}

# Imagen de PostgreSQL
resource "docker_image" "postgres" {
  name         = "postgres:15"
  keep_locally = true
}

# Contenedor de Base de Datos con persistencia
resource "docker_container" "db" {
  name  = "odoo-db"
  image = docker_image.postgres.image_id
  env   = [
    "POSTGRES_USER=odoo",
    "POSTGRES_PASSWORD=odoo",
    "POSTGRES_DB=postgres"
  ]
  # Guardamos la DB localmente
  volumes {
    host_path      = "${path.cwd}/data/postgres"
    container_path = "/var/lib/postgresql/data"
  }
  networks_advanced {
    name = docker_network.odoo_net.name
  }
}

# Imagen de Odoo 16
resource "docker_image" "odoo" {
  name         = "odoo:16.0"
  keep_locally = true
}

# Contenedor de Odoo con persistencia y addons
resource "docker_container" "web" {
  name  = "odoo-web"
  image = docker_image.odoo.image_id
  ports {
    internal = 8069
    external = 8069
  }
  env = [
    "HOST=odoo-db",
    "USER=odoo",
    "PASSWORD=odoo"
  ]
  # Guardamos archivos adjuntos/imágenes
  volumes {
    host_path      = "${path.cwd}/data/odoo"
    container_path = "/var/lib/odoo"
  }
  # Mapeamos nuestra carpeta de código para módulos custom
  volumes {
    host_path      = "${path.cwd}/custom_addons"
    container_path = "/mnt/extra-addons"
  }
  networks_advanced {
    name = docker_network.odoo_net.name
  }
  # Aseguramos que la DB levante primero
  depends_on = [docker_container.db] 
}