# Imagen de Nodo Ruta para la nube. Se construye desde la raíz del paquete:
#   docker build -f app/Dockerfile -t nodoruta:v1 .
# A diferencia del Dockerfile original, los datos NO viven en la imagen:
# la app los lee de PostgreSQL. pedidos.json solo va como semilla para la carga inicial.
FROM python:3.13-slim

WORKDIR /app
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/app.py app/datos_db.py ./
COPY pedidos.json /app/semilla/pedidos.json

ENV PYTHONUNBUFFERED=1 PORT=8080
USER 10001
EXPOSE 8080
CMD ["python", "app.py"]
