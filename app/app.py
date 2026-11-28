"""Nodo Ruta - servicio de consulta de pedidos (caso ficticio de EstudIA).

Versión para la nube del app.py original del paquete:
- Lee los pedidos desde PostgreSQL (Amazon RDS) cuando existe DB_HOST.
  Sin DB_HOST conserva el comportamiento original y lee DATA_PATH (JSON).
- Cada respuesta indica qué instancia la atendió (cuerpo y cabecera X-Instancia).
- /health comprueba los datos (503 si la base o el archivo fallan).
- /vivo solo comprueba que el proceso responde (liveness de Kubernetes).
- /metrics expone métricas para Prometheus.
- Registra una línea JSON por solicitud en stdout (la recoge Loki).
"""
import json
import os
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest

POD = os.environ.get("POD_NAME")
NODE = os.environ.get("NODE_NAME")
INSTANCE = os.environ.get("INSTANCE_ID") or (f"{POD}@{NODE}" if POD and NODE else POD) or "instancia-ejemplo"
DATA = Path(os.environ.get("DATA_PATH", "pedidos.json"))
DB_HOST = os.environ.get("DB_HOST")

RUTAS = ("/", "/health", "/pedidos")

SOLICITUDES = Counter("nodoruta_requests_total", "Solicitudes atendidas", ["ruta", "status"])
LATENCIA = Histogram("nodoruta_request_duration_seconds", "Duración de las solicitudes", ["ruta"])
DATOS_INFO = Gauge("nodoruta_datos_info", "Versión de datos que sirve esta instancia", ["version_datos"])
PEDIDOS = Gauge("nodoruta_pedidos_cargados", "Pedidos leídos en la última consulta")


class ErrorDatos(Exception):
    """Los datos no se pudieron leer o no tienen el formato esperado."""


def leer_postgres():
    import psycopg  # solo se necesita en modo base de datos

    try:
        with psycopg.connect(
            host=DB_HOST,
            port=int(os.environ.get("DB_PORT", "5432")),
            dbname=os.environ.get("DB_NAME", "nodoruta"),
            user=os.environ["DB_USER"],
            password=os.environ["DB_PASSWORD"],
            sslmode=os.environ.get("DB_SSLMODE", "prefer"),
            connect_timeout=2,
        ) as conn, conn.cursor() as cur:
            cur.execute("SELECT valor FROM metadatos WHERE clave = 'version'")
            fila = cur.fetchone()
            cur.execute("SELECT id, zona, estado FROM pedidos ORDER BY id")
            pedidos = [{"id": i, "zona": z, "estado": e} for i, z, e in cur.fetchall()]
    except (psycopg.Error, KeyError) as e:
        raise ErrorDatos(type(e).__name__) from e
    if fila is None or not fila[0]:
        raise ErrorDatos("Sin versión de datos")
    return {"version": fila[0], "pedidos": pedidos}


def leer_json():
    try:
        data = json.loads(DATA.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise ErrorDatos(type(e).__name__) from e
    if not isinstance(data, dict) or not isinstance(data.get("pedidos"), list):
        raise ErrorDatos("Formato de datos inválido")
    return data


def leer_datos():
    try:
        data = leer_postgres() if DB_HOST else leer_json()
    except ErrorDatos:
        DATOS_INFO.clear()  # sin datos válidos no se reporta ninguna versión
        PEDIDOS.set(0)
        raise
    DATOS_INFO.clear()
    DATOS_INFO.labels(version_datos=str(data.get("version"))).set(1)
    PEDIDOS.set(len(data["pedidos"]))
    return data


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        inicio = time.monotonic()
        ruta = self.path.split("?", 1)[0]
        version = None

        if ruta == "/metrics":
            self._enviar(200, generate_latest(), CONTENT_TYPE_LATEST)
            return
        if ruta == "/vivo":
            status, response = 200, {"estado": "vivo", "instancia": INSTANCE}
        elif ruta not in RUTAS:
            status, response = 404, {"error": "Ruta no disponible", "instancia": INSTANCE}
        else:
            try:
                data = leer_datos()
                version = data.get("version")
                status = 200
                if ruta == "/pedidos":
                    response = {"instancia": INSTANCE, **data}
                elif ruta == "/health":
                    response = {"estado": "ok", "instancia": INSTANCE, "version_datos": version}
                else:
                    response = {"servicio": "Nodo Ruta - caso ficticio", "version_app": "1.1",
                                "instancia": INSTANCE, "rutas": ["/health", "/pedidos"]}
            except ErrorDatos as e:
                status, response = 503, {"estado": "error_datos", "instancia": INSTANCE}
                self._error = str(e)

        payload = json.dumps(response, ensure_ascii=False).encode("utf-8")
        self._enviar(status, payload, "application/json; charset=utf-8")

        duracion = time.monotonic() - inicio
        etiqueta = ruta if ruta in RUTAS + ("/vivo",) else "otra"
        SOLICITUDES.labels(ruta=etiqueta, status=str(status)).inc()
        LATENCIA.labels(ruta=etiqueta).observe(duracion)
        if ruta != "/vivo":  # las sondas de liveness no ensucian los registros
            registro = {
                "ts": datetime.now(timezone.utc).isoformat(),
                "request_id": self.headers.get("X-Amzn-Trace-Id") or uuid.uuid4().hex,
                "instancia": INSTANCE,
                "ruta": ruta,
                "status": status,
                "ms": round(duracion * 1000, 2),
                "version_datos": version,
                "cliente": self.headers.get("X-Forwarded-For", self.client_address[0]),
            }
            if getattr(self, "_error", None):
                registro["error"] = self._error
            print(json.dumps(registro, ensure_ascii=False), flush=True)

    def _enviar(self, status, payload, tipo):
        self.send_response(status)
        self.send_header("Content-Type", tipo)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Instancia", INSTANCE)
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format, *args):
        pass  # se reemplaza por el registro JSON de do_GET


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    origen = f"PostgreSQL {DB_HOST}" if DB_HOST else f"archivo {DATA}"
    print(json.dumps({"evento": "inicio", "instancia": INSTANCE, "puerto": port, "datos": origen}), flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
