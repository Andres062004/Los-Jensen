# 05 · Observabilidad, medición de RTO y evidencias

Responsable: I5 (Jensul Villalba Gaitán)

> Convención: **[PROBADO]** = verificado con evidencia en `evidencias/`. **[DISEÑO]** = configurado o propuesto pero sin evidencia todavía. **[PENDIENTE]** = dato por completar.

## 1. Qué se instaló y por qué

| Herramienta | Para qué la usamos | Archivo |
|---|---|---|
| **Prometheus** (kube-prometheus-stack) | Guarda las métricas de la app (`/metrics`), del clúster (kube-state-metrics) y del sondeo externo. Evalúa las alertas. | `k8s/monitoring/kps-values.yaml` |
| **Blackbox exporter** | Consulta `http://<ALB>/health` cada 5 s, igual que un usuario. Es la medida principal de disponibilidad y RTO. | `k8s/monitoring/probe-alb.yaml` |
| **Alertmanager** | Envía las alertas de Nodo Ruta (etiqueta `servicio=nodoruta`) al webhook del equipo. Las demás se descartan para no hacer ruido. | `kps-values.yaml`, `kps-values-discord.yaml` |
| **Loki** | Guarda los logs JSON que la app escribe por cada solicitud (instancia, ruta, status, ms, versión de datos). | `k8s/monitoring/loki-values.yaml` |
| **Grafana Alloy** | Lee los logs de los pods del namespace `nodoruta` por la API de Kubernetes y los envía a Loki. | `k8s/monitoring/alloy-values.yaml` |
| **Grafana** | Dashboard "Nodo Ruta · Continuidad" (8 paneles) y anotaciones de cada prueba. | `k8s/monitoring/dashboard-nodoruta.json` |

Por qué esta combinación: es el stack que pide el reto (`hackaton.md` §5), corre dentro del clúster sin costo extra de AWS (no se usa CloudWatch, que cobra por GB) y separa tres miradas:
- **Desde afuera** (Blackbox): ¿responde el servicio por el ALB?
- **Desde adentro** (métricas de la app y de Kubernetes): ¿cuántas réplicas hay?, ¿qué responden?
- **Detalle** (logs en Loki): ¿qué solicitud falló y en qué pod?

### Decisiones de configuración
- **Sin persistencia** (emptyDir): el clúster no tiene el driver EBS CSI y solo se necesitan los datos durante la sesión. Prometheus retiene 24 h.
- **Recursos pequeños**: comparte 2 nodos t3.medium con la app; agrega unos 10 pods.
- **Componentes de EKS desactivados** (scheduler, controller-manager, etcd, kube-proxy): AWS no los expone y sus alertas "Down" serían falsas.
- **Secretos fuera del repo**: la contraseña de Grafana (`grafana-admin`) y la URL del webhook (`alertmanager-webhook`) se crean en Kubernetes con el script; no se escriben en archivos.
- **URL del ALB automática**: `probe-alb.yaml` tiene el marcador `__ALB__`; el script lo reemplaza leyendo el Ingress.

## 2. Cómo se instala

```powershell
./scripts/monitoring-install.ps1                         # webhook genérico (webhook.site)
./scripts/monitoring-install.ps1 -Receptor discord       # webhook de Discord
./scripts/monitoring-install.ps1 -SoloSondeo             # si el ALB apareció después
kubectl -n monitoring port-forward svc/kps-grafana 3000:80   # http://localhost:3000
```

Verificación después de instalar:
- *Prometheus → Status → Targets*: `serviceMonitor/monitoring/nodoruta` con 3/3 UP y `probe/monitoring/alb` con 1/1 UP. [PENDIENTE captura `evidencias/prometheus_targets.png`]
- *Grafana → Connections → Data sources*: Prometheus y Loki. Dashboard "Nodo Ruta · Continuidad" con datos. [PENDIENTE captura `evidencias/grafana_I01.png`]

## 3. Dashboard "Nodo Ruta · Continuidad"

| Panel | Consulta | Qué muestra en las pruebas |
|---|---|---|
| Disponibilidad (15 min) | `avg_over_time(probe_success{job="probe/monitoring/alb"}[15m]) * 100` | % de sondeos OK; baja durante I05 |
| Pods Ready | `sum(kube_pod_status_ready{namespace="nodoruta",condition="true"})` | Baja a 2 en I02a; a 0 en I05 |
| Solicitudes por instancia | `sum by (pod) (rate(nodoruta_requests_total{ruta="/pedidos"}[1m]))` | Reparto entre pods; al caer uno, las otras líneas suben |
| % errores 5xx | `sum(rate(...{status=~"5.."}[2m])) / sum(rate(...[2m])) * 100` | Sube a ~100 % con datos dañados |
| Latencia p95 | `histogram_quantile(0.95, sum by (le) (rate(nodoruta_request_duration_seconds_bucket[5m])))` | Efecto de RDS lenta o caída |
| Versión de datos por pod | `max by (pod, version_datos) (nodoruta_datos_info)` | `datos-v1` → `datos-alterado` → vacío (503) → `datos-v1` en I05 |
| Sondeo externo | `probe_success{job="probe/monitoring/alb"}` | Línea verde/roja: de aquí se lee el RTO |
| Logs con error (Loki) | `{namespace="nodoruta"} \| json \| status >= 500` | Las líneas 503 con `"error": "Sin versión de datos"` |

Además muestra como anotaciones las alertas disparadas (`ALERTS{servicio="nodoruta"}`) y las anotaciones manuales de inicio de cada prueba (Ctrl+clic en un gráfico).

## 4. Alertas

| Alerta | Condición | `for` | Prueba en la que debe dispararse |
|---|---|---|---|
| `InstanciaNoDisponible` | réplicas disponibles < 3 | 1m | I02b (y I02a si el reemplazo tarda > 1 min) |
| `ServicioCaido` | `probe_success == 0` | 30s | I05 |
| `TasaErrores5xx` | > 5 % de respuestas 5xx | 2m | I05 |
| `VersionDatosInconsistente` | más de una versión de datos a la vez | 1m | Ninguna (el daño afecta a todos los pods por igual); queda como protección |

Alertas recibidas: [PENDIENTE] alerta, hora de disparo, hora de resolución y captura (`evidencias/alerta_<nombre>.png`).

## 5. Cómo se mide el RTO

**RTO** = tiempo desde el primer fallo visto por el usuario hasta que el servicio vuelve a responder 200 de forma estable.

Se usan dos fuentes y se comparan:
1. `scripts/sondear.ps1`: una consulta por segundo desde la PC; precisión de ±1 s.
2. Prometheus: `scripts/medir_rto.ps1` calcula el primer `probe_success = 0`, el último, la recuperación y la duración, y también el tiempo con menos de 3 pods Ready; precisión de ±5 s.

```powershell
kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090
./scripts/medir_rto.ps1 -Desde "HH:mm:ss" -Hasta "HH:mm:ss" -Prueba I02a -Salida evidencias/rto_I02a.txt
```

Si las dos fuentes difieren, se informa la de `sondear.ps1` (más precisa) y se explica la diferencia (intervalo de 5 s, retraso del health check del ALB).

## 6. Resultados por prueba

| Prueba | Qué se observó | RTO servicio | Tiempo hasta 3 Ready | Alerta | Evidencia | Estado |
|---|---|---|---|---|---|---|
| I01 | [PENDIENTE] | — | — | — | `grafana_I01.png` | [PENDIENTE] |
| I02a | [PENDIENTE] | [PENDIENTE] | [PENDIENTE] | [PENDIENTE] | `grafana_I02a.png`, `rto_I02a.txt` | [PENDIENTE] |
| I02b | [PENDIENTE] | [PENDIENTE] | [PENDIENTE] | [PENDIENTE] | `grafana_I02b.png`, `rto_I02b.txt` | [PENDIENTE] |
| I03 | [PENDIENTE] | — | [PENDIENTE] | — | `grafana_I03.png` | [PENDIENTE] |
| I04 | [PENDIENTE] | [PENDIENTE] | — | — | `grafana_I04.png` | [PENDIENTE] |
| I05 | 3 pods 0/1 Ready con 503 "Sin versión de datos" (reportado en el grupo); resto [PENDIENTE] | [PENDIENTE] | [PENDIENTE] | [PENDIENTE] | `grafana_I05.png`, `nube_I05_*` | [PENDIENTE] |
| Mala versión | [PENDIENTE] | [PENDIENTE] | — | — | `nube_mala_version_*` | [PENDIENTE] |
| I06 | [PENDIENTE] | [PENDIENTE] | [PENDIENTE] | — | `nube_I06.txt` | [PENDIENTE] |

### Lectura de I05 (fallo compartido)
Cuando se dañan los datos en RDS, **los 3 pods fallan a la vez**: todos leen la misma base, el readiness (`/health`) responde 503 y Kubernetes saca los 3 del balanceo. El liveness (`/vivo`) sigue en 200, así que los pods **no** se reinician en bucle. Esto demuestra que más réplicas protegen contra fallos de instancia (I02), pero no contra fallos de datos: para eso se necesitan backups y restauración (I05) y, como mejora, RDS Multi-AZ.

## 7. Limitaciones del sistema de observabilidad actual
- **Sin persistencia**: si se reinicia el pod de Prometheus o de Loki (por ejemplo al drenar su nodo en I02b) se pierde la historia. Se mitiga con `sondear.ps1` como segunda fuente.
- **Corre en el mismo clúster que observa**: si cae el clúster, también cae la observabilidad. El sondeo externo real es solo `sondear.ps1` desde la PC.
- **Resolución de 5 s** en el sondeo de Prometheus: los cortes de menos de 5 s pueden no verse.
- **Sin TLS ni acceso externo a Grafana**: se entra por `port-forward`; solo lo ve quien tiene acceso al clúster.
- **No se observa RDS por dentro** (CPU, conexiones, lag): solo se ve su efecto en la app. Falta CloudWatch o `postgres_exporter`.
- **Versiones de los charts sin fijar**: un cambio de versión puede romper la instalación. Fijarlas después del ensayo.
- **Probado vs. diseño**: [PENDIENTE] marcar aquí lo que no se llegó a verificar en la sesión.

## 8. Propuesta para el encuentro 3
1. **Persistencia** de Prometheus y Loki: instalar el addon EBS CSI y usar PVC gp3 pequeños, o usar Amazon Managed Prometheus y Grafana para que sobrevivan a la caída del clúster.
2. **Sondeo desde fuera de AWS**: un chequeo sintético externo (CloudWatch Synthetics o un servicio gratuito de uptime) para medir la disponibilidad real aunque caiga el clúster.
3. **Métricas de RDS**: `postgres_exporter` o métricas de CloudWatch en Grafana.
4. **SLO y alertas por presupuesto de error** (por ejemplo 99,5 % de disponibilidad mensual) en lugar de umbrales fijos.
5. **Grafana con HTTPS y SSO** detrás del ALB (junto con la mejora de ACM de I3).
