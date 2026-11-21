"""Operaciones sobre los datos de Nodo Ruta en PostgreSQL.

Equivale a scripts/datos.py del paquete, pero contra la base de datos:
  cargar          crea las tablas y carga el JSON semilla (los 6 pedidos)
  estado          muestra versión, número de pedidos y huella SHA-256
  alterar         cambia la versión y el estado de un pedido (prueba de restauración)
  simular-error   borra la versión de datos: /health debe devolver 503

Usa las mismas variables que la app: DB_HOST, DB_PORT, DB_NAME, DB_USER,
DB_PASSWORD y DB_SSLMODE.
"""
import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

import psycopg

ESQUEMA = """
CREATE TABLE IF NOT EXISTS metadatos (
    clave          text PRIMARY KEY,
    valor          text NOT NULL,
    actualizado_en timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS pedidos (
    id     text PRIMARY KEY,
    zona   text NOT NULL,
    estado text NOT NULL
);
"""


def conectar():
    return psycopg.connect(
        host=os.environ["DB_HOST"],
        port=int(os.environ.get("DB_PORT", "5432")),
        dbname=os.environ.get("DB_NAME", "nodoruta"),
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        sslmode=os.environ.get("DB_SSLMODE", "prefer"),
        connect_timeout=5,
    )


def huella(version, pedidos):
    canon = json.dumps({"version": version, "pedidos": pedidos}, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(canon.encode("utf-8")).hexdigest()


def leer(cur):
    cur.execute("SELECT valor FROM metadatos WHERE clave = 'version'")
    fila = cur.fetchone()
    cur.execute("SELECT id, zona, estado FROM pedidos ORDER BY id")
    pedidos = [{"id": i, "zona": z, "estado": e} for i, z, e in cur.fetchall()]
    return (fila[0] if fila else None), pedidos


def cargar(args):
    data = json.loads(Path(args.archivo).read_text(encoding="utf-8"))
    if not isinstance(data, dict) or not data.get("version") or not isinstance(data.get("pedidos"), list):
        raise ValueError("Se requiere un objeto JSON con version y lista pedidos")
    with conectar() as conn, conn.cursor() as cur:
        cur.execute(ESQUEMA)
        cur.execute("SELECT count(*) FROM pedidos")
        if args.si_vacia and cur.fetchone()[0] > 0:
            print("La base ya tiene pedidos; no se cargan de nuevo (--si-vacia).")
            return
        cur.execute("DELETE FROM pedidos")
        cur.executemany(
            "INSERT INTO pedidos (id, zona, estado) VALUES (%s, %s, %s)",
            [(p["id"], p["zona"], p["estado"]) for p in data["pedidos"]],
        )
        cur.execute(
            "INSERT INTO metadatos (clave, valor) VALUES ('version', %s) "
            "ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor, actualizado_en = now()",
            (data["version"],),
        )
    print(f"Cargados {len(data['pedidos'])} pedidos, versión {data['version']}.")


def estado(args):
    with conectar() as conn, conn.cursor() as cur:
        version, pedidos = leer(cur)
    print(json.dumps({"version": version, "total_pedidos": len(pedidos),
                      "sha256": huella(version, pedidos), "pedidos": pedidos},
                     ensure_ascii=False, indent=2))


def alterar(args):
    with conectar() as conn, conn.cursor() as cur:
        cur.execute("UPDATE pedidos SET estado = %s WHERE id = %s", (args.estado, args.pedido))
        if cur.rowcount != 1:
            raise ValueError(f"No existe el pedido {args.pedido}")
        cur.execute("UPDATE metadatos SET valor = %s, actualizado_en = now() WHERE clave = 'version'",
                    (args.version,))
    print(f"Pedido {args.pedido} -> '{args.estado}', versión -> {args.version}.")


def simular_error(args):
    with conectar() as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM metadatos WHERE clave = 'version'")
    print("Se borró la versión de datos. /health debe devolver 503 en todas las instancias.")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="accion", required=True)
    c = sub.add_parser("cargar")
    c.add_argument("--archivo", default=os.environ.get("SEMILLA", "/app/semilla/pedidos.json"))
    c.add_argument("--si-vacia", action="store_true", help="No cargar si ya hay pedidos")
    c.set_defaults(func=cargar)
    sub.add_parser("estado").set_defaults(func=estado)
    a = sub.add_parser("alterar")
    a.add_argument("--pedido", default="PED-003")
    a.add_argument("--estado", default="Cancelado")
    a.add_argument("--version", default="datos-alterado")
    a.set_defaults(func=alterar)
    sub.add_parser("simular-error").set_defaults(func=simular_error)
    args = p.parse_args()
    try:
        args.func(args)
    except (ValueError, OSError, KeyError, psycopg.Error) as e:
        sys.exit(f"No se realizó la operación: {e}")


if __name__ == "__main__":
    main()
