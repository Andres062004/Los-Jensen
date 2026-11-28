# Registro del equipo
Equipo: Los Jensen

Integrantes y responsabilidades:
Andres Escobar Hincapie,
Jensul Villalba Gaitan, I5 · Observabilidad, medición de RTO y consolidación de evidencias
Juan Pablo Agudelo Arango,
Santiago Zapata Oquendo,
Yeison David Garcia Arismendy,
Danilo Andres Suarez Higuita,

> [PENDIENTE] Cada integrante agrega su rol (I1 infraestructura y costos · I2 datos y recuperación · I3 app y CI/CD · I4 Kubernetes y runbook) junto a su nombre.

Fecha: [PENDIENTE] fecha de la sesión 1 en AWS
Modalidad: nube (AWS, us-east-1). Ensayo previo en contenedores locales (`evidencias/local_*.json`).

Arquitectura elegida y motivo:
GitHub Actions → GHCR → Amazon EKS (3 pods en 2 zonas) detrás de un Application Load Balancer → Amazon RDS PostgreSQL en subred privada con backups automáticos. Credenciales en AWS Secrets Manager. Observabilidad dentro del clúster con Prometheus, Loki, Grafana, Alertmanager y Blackbox exporter.
Motivo: el reto pide alta disponibilidad, observabilidad y recuperación. Los datos viven fuera de los contenedores (RDS), así que recrear pods no los pierde. Las 3 réplicas repartidas en 2 zonas sobreviven a la caída de un pod o de un nodo. Ver `docs/PLAN_EQUIPO.md`.

Punto de acceso e instancias: `http://<ALB>/` (DNS del ALB de la sesión: [PENDIENTE]). Cada respuesta indica la instancia (`pod@nodo`) en el cuerpo y en la cabecera `X-Instancia`.
Ubicación de datos y respaldos: RDS `nodoruta-db` (Single-AZ, privada, cifrada). Backups automáticos + snapshot manual `nodoruta-antes-pruebas`. La restauración (PITR) crea una instancia nueva `nodoruta-db-rest-<MMddHHmm>`.

Ayudas utilizadas y cambios realizados:
Código base del reto (app, Compose local, `verificar_servicio.py`). Cambios propios: app con PostgreSQL y `/metrics`, Terraform, manifiestos de Kubernetes, pipeline CI/CD y observabilidad (`k8s/monitoring/`). Asistente de IA (Claude) para generar y revisar configuración; el equipo revisó y probó cada archivo.

Recursos, permisos y posibles costos:
EKS (plano de control), 2 nodos EC2 t3.medium, ALB, IPv4 públicas, RDS db.t4g.micro + almacenamiento + backups, Secrets Manager. Todo cobra por hora aunque no se use: se enciende al empezar y se destruye al terminar (`destruir.ps1`). Costos reales en `docs/costos.md` (I1). Usuarios IAM individuales con MFA; GitHub Actions entra por OIDC sin llaves.

Puntos únicos de fallo y mejora propuesta:
- RDS Single-AZ → Multi-AZ.
- Un solo ALB en una región: no cubre la caída de la región.
- Estado de Terraform local en la PC de I1 → backend S3 con bloqueo.
- HTTP sin TLS → ACM + HTTPS.
- Observabilidad sin persistencia: si se reinicia Prometheus o Loki se pierden métricas y logs → volumen EBS o servicios administrados.

---

# Fichas por prueba

Método de medición común (I5):
- `scripts/sondear.ps1`: una consulta por segundo desde la PC; resume la ventana de error.
- Sondeo externo de Prometheus (Blackbox) a `/health` del ALB cada 5 s; panel "Sondeo externo".
- **RTO** = desde el primer fallo (`probe_success = 0` o código ≠ 200) hasta el primer 200 estable. Se calcula con `scripts/medir_rto.ps1 -Desde <hora> -Hasta <hora> -Prueba <ID> -Salida evidencias/rto_<ID>.txt` y se compara con el resumen de `sondear.ps1`.
- Cada prueba tiene una anotación en Grafana al inicio y una captura `evidencias/grafana_<ID>.png`.

## I01 · Acceso común, 3 instancias, datos-v1
Dueño: I1 · Mide: I5
Qué queremos comprobar: que por el ALB responden las 3 instancias y todas sirven `datos-v1`, también desde otra PC.
Versión y estado inicial: imagen [PENDIENTE: tag], 3 pods Ready, `datos-v1`.
Pasos para repetirla:
```powershell
python scripts/verificar_servicio.py http://<ALB>/pedidos --peticiones 20 --salida evidencias/nube_I01_inicio.json
# desde otra PC:
python scripts/verificar_servicio.py http://<ALB>/pedidos --peticiones 20 --salida evidencias/nube_I01_otro_pc.json
```
Resultado esperado: 20/20 respuestas 200, 3 instancias distintas, versión `datos-v1`.
Resultado observado y códigos HTTP: [PENDIENTE]
Inicio, fin y duración: no aplica (no hay falla).
Evidencia: `evidencias/nube_I01_inicio.json`, `evidencias/nube_I01_otro_pc.json`, `evidencias/grafana_I01.png`
¿Cumple? [PENDIENTE]
Error encontrado y ajuste: [PENDIENTE]
Resultado al repetir la prueba: [PENDIENTE]

## I02a · Cae un pod, el servicio sigue
Dueño: I4 · Mide: I5
Qué queremos comprobar: que al borrar un pod el ALB deja de enviarle tráfico, las otras 2 réplicas siguen respondiendo y Kubernetes crea un reemplazo.
Versión y estado inicial: 3 pods Ready, `datos-v1`.
Pasos para repetirla:
```powershell
./scripts/sondear.ps1 -Url http://<ALB>/pedidos -Segundos 120 -Salida evidencias/nube_I02_pod.txt   # terminal 1
kubectl -n nodoruta delete pod <pod>                                                                # terminal 2, ~10 s después
kubectl -n nodoruta get pods -w
```
Resultado esperado: 0 errores o errores muy breves (segundos); Pods Ready baja a 2 y vuelve a 3; se dispara `InstanciaNoDisponible` solo si la recuperación tarda más de 1 min.
Resultado observado y códigos HTTP: [PENDIENTE]
Inicio, fin y duración: hora del borrado [PENDIENTE] · RTO del servicio [PENDIENTE] s · tiempo hasta 3 Ready [PENDIENTE] s
Evidencia: `evidencias/nube_I02_pod.txt`, `evidencias/grafana_I02a.png`, `evidencias/rto_I02a.txt`
¿Cumple? [PENDIENTE]
Error encontrado y ajuste: [PENDIENTE]
Resultado al repetir la prueba: [PENDIENTE]

## I02b · Cae un nodo (o zona), el servicio sigue
Dueño: I4 · Mide: I5
Qué queremos comprobar: que al drenar un nodo los pods pasan al otro y el servicio no se interrumpe (el PDB `minAvailable: 2` impide quedarse sin réplicas).
Versión y estado inicial: 3 pods repartidos en 2 nodos y 2 zonas.
Pasos para repetirla:
```powershell
./scripts/sondear.ps1 -Url http://<ALB>/pedidos -Segundos 300 -Salida evidencias/nube_I02_nodo.txt
kubectl drain <nodo> --ignore-daemonsets --delete-emptydir-data
kubectl -n nodoruta get pods -o wide
```
Resultado esperado: el servicio sigue respondiendo 200; los pods quedan en el nodo restante.
Resultado observado y códigos HTTP: [PENDIENTE]
Inicio, fin y duración: [PENDIENTE]
Evidencia: `evidencias/nube_I02_nodo.txt`, `evidencias/grafana_I02b.png`, `evidencias/rto_I02b.txt`, captura de la alerta recibida `evidencias/alerta_InstanciaNoDisponible.png`
¿Cumple? [PENDIENTE]
Error encontrado y ajuste: [PENDIENTE]
Resultado al repetir la prueba: [PENDIENTE]
Nota: la observabilidad corre en los mismos nodos; al drenar uno, Prometheus o Grafana pueden reiniciarse y perder datos (no tienen persistencia). Si pasa, se anota aquí y se usa `sondear.ps1` como fuente principal.

## I03 · Vuelven las 3 réplicas
Dueño: I4 · Mide: I5
Qué queremos comprobar: que tras recuperar el nodo vuelven 3 instancias distintas repartidas entre zonas.
Pasos para repetirla:
```powershell
kubectl uncordon <nodo>
kubectl -n nodoruta rollout restart deployment/nodoruta
kubectl -n nodoruta get pods -o wide > evidencias/nube_I03_recuperado.txt
python scripts/verificar_servicio.py http://<ALB>/pedidos --peticiones 20 --salida evidencias/nube_I03.json
```
Resultado esperado: 3 instancias distintas, `datos-v1`, sin errores durante el rollout (`maxUnavailable: 0`).
Resultado observado y códigos HTTP: [PENDIENTE]
Inicio, fin y duración: desde `uncordon` hasta 3 Ready [PENDIENTE] s
Evidencia: `evidencias/nube_I03.json`, `evidencias/nube_I03_recuperado.txt`, `evidencias/grafana_I03.png`
¿Cumple? [PENDIENTE]
Error encontrado y ajuste: [PENDIENTE]
Resultado al repetir la prueba: [PENDIENTE]

## I04 · Recrear los pods conserva los datos
Dueño: I4 · Mide: I5
Qué queremos comprobar: que los datos no viven en el contenedor: pods nuevos siguen sirviendo `datos-v1` y los 6 pedidos desde RDS.
Pasos para repetirla:
```powershell
./scripts/sondear.ps1 -Url http://<ALB>/pedidos -Segundos 120 -Salida evidencias/nube_I04_sondeo.txt
kubectl -n nodoruta rollout restart deployment/nodoruta
python scripts/verificar_servicio.py http://<ALB>/pedidos --salida evidencias/nube_I04.json
```
Resultado esperado: nombres de pod nuevos, misma versión y mismos 6 pedidos, 0 errores en el sondeo.
Resultado observado y códigos HTTP: [PENDIENTE]
Inicio, fin y duración: [PENDIENTE]
Evidencia: `evidencias/nube_I04.json`, `evidencias/nube_I04_sondeo.txt`, `evidencias/grafana_I04.png`
¿Cumple? [PENDIENTE]
Error encontrado y ajuste: [PENDIENTE]
Resultado al repetir la prueba: [PENDIENTE]

## I05 · Daño de datos → 503 → restaurar RDS → hash igual
Dueño: I2 · Mide: I5
Qué queremos comprobar: que un daño de datos se detecta (503 y pods fuera del balanceo), que se restaura desde los backups de RDS y que el contenido vuelve a ser idéntico (mismo sha256).
Versión y estado inicial: `datos-v1`, sha256 en `evidencias/nube_estado_inicial.json`.
Pasos para repetirla: ver `docs/PLAN_EQUIPO.md` → I2 → paso 8 (`$t0`, `datos_db.py alterar`, `simular-error`, `restaurar_rds.ps1 -Hora $t0`).
Resultado esperado: tras `simular-error` los 3 pods responden 503 y quedan 0/1 Ready (fallo compartido: más réplicas no lo arreglan); tras restaurar, `datos-v1` y el sha256 coincide con el inicial.
Resultado observado y códigos HTTP:
- Observación reportada en el grupo del equipo (sin hora exacta): con el clúster encendido, los 3 pods estaban `0/1 Running` (READY 0/3) y respondían **503 "Sin versión de datos"**, el error que produce `datos_db.py simular-error`. El ConfigMap `nodoruta-config` aún apuntaba a `nodoruta-db` y existía la copia restaurada `nodoruta-db-rest-11280148` (el nombre indica que la restauración empezó el 2026-11-28 a las 01:48 UTC). Es decir, en ese momento la base restaurada existía pero la app todavía no estaba conectada a ella.
- [PENDIENTE] Confirmar con I2: ¿`restaurar_rds.ps1` terminó y cambió el ConfigMap, o se interrumpió? Resultado final de version y sha256.
Inicio, fin y duración: `$t0` (punto de recuperación) [PENDIENTE] · hora del daño [PENDIENTE] · RTO que imprime `restaurar_rds.ps1` [PENDIENTE] s · RPO = hora del daño − `$t0` [PENDIENTE]
Evidencia: `evidencias/nube_estado_inicial.json`, `nube_I05_alterado.json`, `nube_I05_error.json`, `nube_I05_sondeo.txt`, `nube_I05_restauracion.txt`, `nube_I05_restaurado.json`, `grafana_I05.png`
¿Cumple? [PENDIENTE]
Error encontrado y ajuste: [PENDIENTE]
Resultado al repetir la prueba: [PENDIENTE]

## Extra · Mala versión: CI la bloquea y el clúster la revierte
Dueño: I3 · Mide: I5
Qué queremos comprobar: (A) un PR que rompe `/health` no se puede fusionar; (B) una imagen inexistente desplegada a mano no tumba el servicio y se revierte con `rollout undo`.
Pasos para repetirla: ver `docs/PLAN_EQUIPO.md` → I3 → paso 9.
Resultado esperado: (A) job `ci` en rojo y botón de merge bloqueado; (B) 0 errores en el sondeo gracias a `maxUnavailable: 0`.
Resultado observado: [PENDIENTE]
Inicio, fin y duración: [PENDIENTE]
Evidencia: `evidencias/github_proteccion_main.png` (protección de `main`, ya existe), `evidencias/github_environment_produccion.jpg` (ya existe), `evidencias/nube_mala_version_ci.png`, `evidencias/nube_mala_version_sondeo.txt`, `evidencias/nube_cd.txt`
¿Cumple? [PENDIENTE]
Error encontrado y ajuste: [PENDIENTE]
Resultado al repetir la prueba: [PENDIENTE]

## I06 · Otro integrante recrea el servicio con el runbook
Ejecuta: I3 · Registra: I5
Qué queremos comprobar: que alguien distinto a I4 recrea el servicio solo con `docs/04-runbook.md`, sin ayuda.
Pasos para repetirla:
```powershell
./scripts/sondear.ps1 -Url http://<ALB>/pedidos -Segundos 900 -Salida evidencias/nube_I06_sondeo.txt
kubectl -n nodoruta delete deploy nodoruta
# I3 sigue docs/04-runbook.md desde su PC (desplegar.ps1)
python scripts/verificar_servicio.py http://<ALB>/pedidos --peticiones 20 --salida evidencias/nube_I06.json
```
Resultado esperado: el servicio vuelve con 3 instancias y `datos-v1`; los pasos del runbook alcanzan sin preguntar a I4.
Registro de I5 (`evidencias/nube_I06.txt`): hora de inicio, cada paso ejecutado, dudas o pasos que fallaron, hora en que vuelve el primer 200 y hora con 3 Ready.
Resultado observado: [PENDIENTE]
Inicio, fin y duración: [PENDIENTE]
Evidencia: `evidencias/nube_I06.txt`, `evidencias/nube_I06.json`, `evidencias/nube_I06_sondeo.txt`
¿Cumple? [PENDIENTE]
Error encontrado y ajuste en el runbook: [PENDIENTE]
Resultado al repetir la prueba (`_r2`): [PENDIENTE]

---

# Resumen de RTO

| Prueba | Inicio del fallo | Recuperación | RTO servicio | Tiempo hasta 3 Ready | Fuente |
|---|---|---|---|---|---|
| I02a | [PENDIENTE] | [PENDIENTE] | [PENDIENTE] | [PENDIENTE] | sondear + Prometheus |
| I02b | [PENDIENTE] | [PENDIENTE] | [PENDIENTE] | [PENDIENTE] | sondear + Prometheus |
| I03 | — | [PENDIENTE] | — | [PENDIENTE] | kubectl + Prometheus |
| I04 | [PENDIENTE] | [PENDIENTE] | [PENDIENTE] | [PENDIENTE] | sondear |
| I05 | [PENDIENTE] | [PENDIENTE] | [PENDIENTE] | [PENDIENTE] | restaurar_rds.ps1 + sondear |
| Mala versión B | [PENDIENTE] | [PENDIENTE] | [PENDIENTE] | — | sondear |
| I06 | [PENDIENTE] | [PENDIENTE] | [PENDIENTE] | [PENDIENTE] | registro I5 |

RPO (solo I05): [PENDIENTE]

---

# Cierre
Qué funciona realmente: [PENDIENTE] solo lo que tenga evidencia en `evidencias/`.
Qué quedó como propuesta o pendiente: [PENDIENTE] (separar lo **probado** de lo que es **diseño**).
Procedimiento para recrear y recuperar: `docs/04-runbook.md` (I4), restauración de datos en `docs/02-datos-recuperacion.md` (I2), observabilidad en `docs/05-observabilidad.md` (I5).
Limitaciones y cambios para el encuentro 3: ver puntos únicos de fallo arriba y `docs/05-observabilidad.md` → Limitaciones.
