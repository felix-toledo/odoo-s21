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

# Imagen y contenedor de PostgreSQL
resource "docker_image" "postgres" {
  name         = "postgres:15"
  keep_locally = true
}

resource "docker_container" "db" {
  name  = "odoo-db"
  image = docker_image.postgres.image_id
  env   = [
    "POSTGRES_USER=odoo",
    "POSTGRES_PASSWORD=odoo",
    "POSTGRES_DB=postgres"
  ]
  networks_advanced {
    name = docker_network.odoo_net.name
  }
}

# Imagen y contenedor de Odoo 16
resource "docker_image" "odoo" {
  name         = "odoo:16.0"
  keep_locally = true
}

resource "docker_container" "web" {
  name  = "odoo-web"
  image = docker_image.odoo.image_id
  ports {
    internal = 8069
    external = 8069
  }
  # Acá estaba el error, la 's' de más ya fue eliminada
  env = [
    "HOST=odoo-db",
    "USER=odoo",
    "PASSWORD=odoo"
  ]
  networks_advanced {
    name = docker_network.odoo_net.name
  }
  # Aseguramos que la DB levante primero
  depends_on = [docker_container.db] 
}