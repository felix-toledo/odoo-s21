# Dockerfile
FROM odoo:16.0

# Cambiamos a root para poder instalar paquetes del sistema y de Python
USER root

# Copiamos el archivo de requerimientos al contenedor
COPY ./requirements.txt /etc/odoo/requirements.txt

# Instalamos la dependencia
RUN pip3 install --no-cache-dir -r /etc/odoo/requirements.txt

# Volvemos al usuario odoo por seguridad y buenas prácticas
USER odoo