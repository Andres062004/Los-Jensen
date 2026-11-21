# Imagen de Nodo Ruta para la nube. Se construye desde la raíz del paquete:
#   docker build -f app/Dockerfile -t nodoruta:v1 .
# A diferencia del Dockerfile original, los datos NO viven en la imagen:
# la app los lee de PostgreSQL. pedidos.json solo va como semilla para la carga inicial.

# --- Etapa 1: instalar dependencias (aquí sí se usa pip) ---
FROM python:3.13-slim AS dependencias
COPY app/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --prefix=/instaladas -r /tmp/requirements.txt

# --- Etapa 2: imagen final, sin pip ni herramientas de instalación ---
FROM python:3.13-slim
# Parches de seguridad de Debian y retiro de pip/ensurepip (traen paquetes
# empaquetados con vulnerabilidades y la app no los necesita en ejecución).
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && rm -rf /var/lib/apt/lists/* \
 && python -m pip uninstall -y pip \
 && rm -rf /usr/local/lib/python3.13/ensurepip /usr/local/bin/pip*

COPY --from=dependencias /instaladas /usr/local

WORKDIR /app
COPY app/app.py app/datos_db.py ./
COPY pedidos.json /app/semilla/pedidos.json

ENV PYTHONUNBUFFERED=1 PORT=8080
USER 10001
EXPOSE 8080
CMD ["python", "app.py"]
