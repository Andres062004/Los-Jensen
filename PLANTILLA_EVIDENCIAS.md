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

Fecha: sesiones en AWS del 21-nov-2026 (I01–I04), 27-nov (I05) y 28-nov (mala versión, I01 desde otra PC)
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
Resultado observado y códigos HTTP:
- Sesión del 21-nov (I1, rama `feat/infra-i1`): **CUMPLE**, todas 200, 3 instancias (`...-2czpm`, `...-wdcfp`, `...-xl76x`) en 2 nodos, `datos-v1`.
- Sesión del 28-nov desde otra PC (I5): **CUMPLE**, 20/20 respuestas 200, 3 instancias (`...-6gcq7`, `...-dbkls`, `...-fxdsp`) en nodos de `us-east-1a` y `us-east-1b`, `datos-v1`, 6 pedidos.
Inicio, fin y duración: no aplica (no hay falla).
Evidencia: `evidencias/nube_I01_inicio.json` (rama `feat/infra-i1`), `evidencias/nube_I01_otro_pc.json`, `evidencias/grafana_I01.png` [PENDIENTE captura]
¿Cumple? Sí
Error encontrado y ajuste: ninguno.
Resultado al repetir la prueba: repetida en otra sesión y desde otra PC con el mismo resultado.

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
Resultado observado y códigos HTTP (sesión del 21-nov, I4):
- Primer intento (`nube_I02_pod.txt`, 11:47:14–11:47:36): solo 200, pero el registro quedó corto (sin resumen), por eso se repitió.
- Repetición (`nube_I02_pod_r2.txt`, desde 11:52:07): **120 consultas, 120 OK, 0 fallidas**. Aparece una instancia nueva (`...-l8m6v`) que reemplaza a la borrada (`...-xl76x`).
Inicio, fin y duración: **RTO del servicio = 0 s** (el usuario no vio errores). Hora exacta del borrado y tiempo hasta 3 Ready: [PENDIENTE, I4]
Evidencia: `evidencias/nube_I02_pod.txt`, `evidencias/nube_I02_pod_r2.txt`. Sin captura de Grafana: la observabilidad aún no estaba instalada en esa sesión.
¿Cumple? Sí
Error encontrado y ajuste: el primer registro quedó incompleto; se repitió con `_r2`.
Resultado al repetir la prueba: 120/120 OK.

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
Resultado observado y códigos HTTP (sesión del 21-nov, I4): **300 consultas, 295 OK, 5 fallidas**. Primera falla 11:59:48, última falla 12:00:20. Los pods pasaron al otro nodo y el servicio siguió atendiendo con fallos aislados.
Inicio, fin y duración: **corte principal de ~12 s**: 4 timeouts seguidos (11:59:48, :51, :54 y :57; cada consulta espera 3 s) y primer 200 a las 12:00:00. Además, **1 fallo aislado** a las 12:00:20 (la última consulta). El resumen de `sondear.ps1` informa una "ventana de 32 s" porque mide del primer al último fallo y junta los dos eventos. Disponibilidad durante la prueba: 98,3 % (295/300).
Interpretación: al drenar el nodo, el ALB tarda en sacar del balanceo los pods que se están eliminando (health check cada 10 s, 2 fallos para marcarlos no sanos, y 15 s de deregistration delay), y algunas solicitudes caen en esa ventana.
Evidencia: `evidencias/nube_I02_nodo.txt`. Sin captura de Grafana ni alerta: la observabilidad aún no estaba instalada.
¿Cumple? Parcial: el servicio se recuperó solo en ~12 s y siguió atendiendo, pero el usuario sí vio errores.
Error encontrado y ajuste: propuesta: agregar un `preStop` con espera (sleep de 15–20 s) en el Deployment, para que el ALB saque el pod antes de que deje de responder, y repetir la prueba.
Resultado al repetir la prueba: no repetida.
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
Resultado observado y códigos HTTP (sesión del 21-nov, I4): `verificar_servicio.py` → **CUMPLE**, `datos-v1`. Tres pods nuevos `1/1 Running` (`...-2rqvb` en `ip-10-20-19-17` y `...-4wm2q` y `...-5hz5q` en `ip-10-20-6-223`), es decir, repartidos otra vez entre los 2 nodos.
Inicio, fin y duración: tiempo desde `uncordon` hasta 3 Ready [PENDIENTE, I4]. Verificación a las 17:05:35 UTC.
Evidencia: `evidencias/nube_I03.json`, `evidencias/nube_I03_recuperado.txt`
¿Cumple? Sí
Error encontrado y ajuste: ninguno.
Resultado al repetir la prueba: no fue necesario.

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
Resultado observado y códigos HTTP (sesión del 21-nov, I4): sondeo con **120 consultas, 120 OK, 0 fallidas**. Durante el rollout se ven las instancias viejas (`b796f4cd9-*`) y luego las nuevas (`56894db74f-*`), todas con `datos-v1`. `verificar_servicio.py` → **CUMPLE**.
Inicio, fin y duración: **RTO = 0 s** (sin errores durante el reemplazo de los 3 pods).
Evidencia: `evidencias/nube_I04.json`, `evidencias/nube_I04_sondeo.txt`, `evidencias/nube_I04_pods_antes.txt` y `evidencias/nube_I04_pods_despues.txt` (+ `_r2`)
¿Cumple? Sí
Error encontrado y ajuste: ninguno.
Resultado al repetir la prueba: repetida (`_r2`) con el mismo resultado.

## I05 · Daño de datos → 503 → restaurar RDS → hash igual
Dueño: I2 · Mide: I5
Qué queremos comprobar: que un daño de datos se detecta (503 y pods fuera del balanceo), que se restaura desde los backups de RDS y que el contenido vuelve a ser idéntico (mismo sha256).
Versión y estado inicial: `datos-v1`, sha256 en `evidencias/nube_estado_inicial.json`.
Pasos para repetirla: ver `docs/PLAN_EQUIPO.md` → I2 → paso 8 (`$t0`, `datos_db.py alterar`, `simular-error`, `restaurar_rds.ps1 -Hora $t0`).
Resultado esperado: tras `simular-error` los 3 pods responden 503 y quedan 0/1 Ready (fallo compartido: más réplicas no lo arreglan); tras restaurar, `datos-v1` y el sha256 coincide con el inicial.
Resultado observado y códigos HTTP (27-nov, hora de Colombia, I2; evidencias en la rama `feat/despliegue-aws`):
1. Estado inicial: `datos-v1`, 6 pedidos, sha256 `554cb0d7…16af771`.
2. 22:22:12: el sondeo empieza a ver `datos-alterado` (respuestas 200 con datos alterados).
3. 22:23:15: primer fallo (después de `simular-error`). Desde ahí, **994 respuestas 503** ("error_datos") y 10 sin respuesta (ERR). Los 3 pods quedan 0/1 Ready a la vez: el fallo es compartido.
4. 22:26:52: inicia `restaurar_rds.ps1` (PITR al punto 22:16:22) → copia `nodoruta-db-rest-11280326`.
5. 22:41:06: base restaurada disponible (854 s). 22:41:16: app conectada (rollout).
6. 22:43:05: primer 200 estable con `datos-v1`. `verificar_servicio.py` → **CUMPLE**. **sha256 idéntico** al inicial.
Inicio, fin y duración:
- **RTO percibido por el usuario: 19 min 50 s** (22:23:15 → 22:43:05), según el sondeo.
- **RTO del procedimiento de restauración: 865 s (14 min 25 s)**, según `restaurar_rds.ps1` (desde que se lanza hasta que la app queda conectada).
- La diferencia (~5 min) es el tiempo de detección y decisión antes de lanzar la restauración, más ~2 min hasta que los 3 pods quedaron listos tras conectar la app.
- **RPO ≈ 6 min**: punto de restauración 22:16:22 frente al daño a las ~22:22. Los cambios de esa ventana se perderían; en la prueba no hubo escrituras en ella, por eso el hash coincide.
Evidencia: `evidencias/nube_estado_inicial.json`, `nube_I05_alterado.json`, `nube_I05_error.json`, `nube_I05_sondeo.txt`, `nube_I05_restauracion.txt`, `nube_I05_restaurado.json`, `nube_rds.txt`, `nube_rds_privada.txt` (rama `feat/despliegue-aws`, pendiente de fusionar)
¿Cumple? Sí: se detectó el daño (503), se restauró y el contenido es idéntico (mismo sha256).
Error encontrado y ajuste:
- `nube_I05_error.json` marca "REVISAR", lo esperado porque todas las respuestas son 503.
- `restaurar_rds.ps1` imprime las horas locales con sufijo "Z" (formato `u`), aunque no son UTC. Ajuste propuesto: usar `ToUniversalTime()` antes de formatear.
- La copia restaurada no la gestiona Terraform: hay que borrarla a mano antes de `destroy` (ver la instrucción al final del registro).
Resultado al repetir la prueba: hubo un intento anterior (`nodoruta-db-rest-11280148`) que quedó sin conectar la app; el intento documentado es el de `-11280326`.

## Extra · Mala versión: CI la bloquea y el clúster la revierte
Dueño: I3 · Mide: I5
Qué queremos comprobar: (A) un PR que rompe `/health` no se puede fusionar; (B) una imagen inexistente desplegada a mano no tumba el servicio y se revierte con `rollout undo`.
Pasos para repetirla: ver `docs/PLAN_EQUIPO.md` → I3 → paso 9.
Resultado esperado: (A) job `ci` en rojo y botón de merge bloqueado; (B) 0 errores en el sondeo gracias a `maxUnavailable: 0`.
Resultado observado (28-nov, I3):
- A. CI: PR con `/health` roto → job `ci` en rojo y merge bloqueado (`nube_mala_version_ci.png`, `nube_mala_version_ci_actions.png`).
- B. Clúster (13:50–13:51 UTC): se aplicó la imagen `:no-existe`. El pod nuevo quedó en `ErrImagePull` y `rollout status` falló por timeout a los 60 s. **Los 3 pods viejos siguieron `1/1 Running`** (`maxUnavailable: 0`). `rollout undo` volvió a `sha-aed07fc` en ~2 s.
- Sondeo: **120 consultas, 120 OK, 0 fallidas**.
Inicio, fin y duración: de 13:50:06 (imagen mala) a 13:51:13 (rollback completo) = 67 s con la versión mala aplicada; **RTO percibido = 0 s**.
Evidencia: `evidencias/github_proteccion_main.png`, `evidencias/github_proteccion_main_detalle.jpg`, `evidencias/github_environment_produccion.jpg`, `evidencias/nube_mala_version_ci.png`, `evidencias/nube_mala_version_ci_actions.png`, `evidencias/nube_mala_version_rollback.txt`, `evidencias/nube_mala_version_sondeo.txt`, `evidencias/nube_cd.txt`
¿Cumple? Sí (A y B).
Error encontrado y ajuste: `rollout undo` avisa que la anotación `last-applied-configuration` queda desactualizada. Después de un rollback hay que volver a aplicar el manifiesto o desplegar por el pipeline.
Resultado al repetir la prueba: no fue necesario.

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

| Prueba | Consultas (OK / fallidas) | Inicio del fallo | Recuperación | RTO percibido | Fuente |
|---|---|---|---|---|---|
| I02a · pod | 120 / 0 | — | — | **0 s** | `nube_I02_pod_r2.txt` |
| I02b · nodo | 295 / 5 | 11:59:48 | 12:00:00 | **~12 s** (+1 fallo aislado a las 12:00:20) | `nube_I02_nodo.txt` |
| I03 · recuperación | CUMPLE | — | 3 pods en 2 nodos | — | `nube_I03.json` |
| I04 · recrear pods | 120 / 0 | — | — | **0 s** | `nube_I04_sondeo.txt` |
| I05 · datos + RDS | 562 / 1004 | 22:23:15 | 22:43:05 | **19 min 50 s** (script: 865 s) | `nube_I05_sondeo.txt`, `nube_I05_restauracion.txt` |
| Mala versión B | 120 / 0 | — | — | **0 s** | `nube_mala_version_sondeo.txt` |
| I06 · runbook | [PENDIENTE] | [PENDIENTE] | [PENDIENTE] | [PENDIENTE] | registro I5 |

RPO (solo I05): **≈ 6 min** (punto de restauración 22:16:22 frente al daño a las ~22:22).

Lectura: las réplicas protegen contra fallos de **instancia** (I02a, I04 y mala versión con 0 s de corte; I02b con un corte de ~12 s). Contra un fallo de **datos** (I05) no sirven: las 3 réplicas fallan a la vez y la recuperación depende de restaurar RDS (~20 min).

---

# Cierre
Qué funciona realmente (probado con evidencia): acceso común por ALB con 3 instancias (I01); caída de un pod sin corte (I02a, 0 s); caída de un nodo con corte de ~12 s (I02b); recuperación de réplicas (I03); recrear pods conservando datos en RDS (I04, 0 s); daño de datos detectado con 503 y restaurado por PITR con el mismo sha256 (I05, RTO 19 min 50 s, RPO ≈ 6 min); mala versión bloqueada por CI y revertida sin corte.
Qué quedó como propuesta o pendiente: I06 (runbook con otro integrante) no realizada; observabilidad (Prometheus, Grafana, Loki, alertas) configurada pero sin instalación completa en EKS, por lo que no hay capturas ni alertas recibidas; RDS Multi-AZ, HTTPS y backend remoto de Terraform son diseño.
Procedimiento para recrear y recuperar: `docs/04-runbook.md` (I4), restauración de datos en `docs/02-datos-recuperacion.md` (I2), observabilidad en `docs/05-observabilidad.md` (I5).
Limitaciones y cambios para el encuentro 3: ver puntos únicos de fallo arriba y `docs/05-observabilidad.md` → Limitaciones.
