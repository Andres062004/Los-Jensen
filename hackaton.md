# Nodo Ruta - Servicio de Consultas y Despliegue Continuo

Servicio de consulta de estado de entregas para distribución urbana, diseñado con una arquitectura orientada a la alta disponibilidad, automatización y observabilidad.

**Versión del README:** 1.0 · **Autoría:** Santiago Zapata · **Última revisión:** 21/11/2026

---

## 1. Qué es y para quién

Un servicio para consultar el estado de una entrega y ver los pedidos del día. El sistema está diseñado no solo para funcionar, sino para **mantenerse disponible durante cambios y fallos**.

- **Ámbito:** logística y distribución urbana.
- **Quién lo usa:** el equipo de operaciones (consulta entregas) y el responsable técnico (publica versiones y atiende incidentes).
- **Quién no lo usa:** los clientes finales. Ellos reciben la información por el equipo de operaciones.
- **Qué necesita poder hacer quien lo usa:** consultar el estado de un pedido con certeza, y que el servicio siga disponible durante cambios y fallos.

## 2. Qué puede fallar y cómo lo resolvemos

| Cuando cambia… | Qué deja de funcionar | Quién lo nota | Cómo lo resolvemos en este proyecto |
|---|---|---|---|
| El servicio se actualiza con un error | Las consultas dejan de responder | El equipo de operaciones | **CI/CD con GitHub Actions** que valida antes de desplegar y permite rollback rápido. |
| La instancia que atiende se detiene | El servicio queda sin respuesta | El equipo de operaciones | **Nginx con Failover** y Health Checks que redirigen el tráfico a la instancia sana. |
| Se pierde o se modifica el archivo de datos | Las consultas devuelven datos vacíos o incorrectos | El equipo de operaciones y la coordinación logística | **Volumen persistente** (separado del contenedor) y **Script de backups** con retención. |

## 3. El servicio pequeño

El más chico que representa el problema: **consultar el estado de un pedido** y **ver los pedidos del día**.

- **Qué entra:** 6 pedidos ficticios con un identificador de versión de los datos.
- **Operación que muestra su valor:** consultar un pedido.
- **Respuesta observable:** la consulta devuelve el estado, el listado del día y el `instance_id` de la instancia que atendió.
- **Si el servicio no responde:** el proxy Nginx detecta la falla y la otra instancia atiende la consulta (continuidad).
- **Por qué es una muestra válida:** contiene lo que más afecta si falla (consultar) y lo que permite verificarlo (listar y reconocer qué instancia atendió).

## 4. Recorrido mínimo

1. **Un cambio:** se actualiza el código y se hace push a la rama `main`.
2. **Una operación:** GitHub Actions construye la imagen, la publica y el entorno local la descarga.
3. **Una respuesta observable:** la consulta responde y el listado muestra el pedido, con el `instance_id` de la instancia que atendió.

```mermaid
flowchart LR
    A["Un cambio<br/>Git Push a main"] --> B["Pipeline CI/CD<br/>GitHub Actions"]
    B --> C["Una operación<br/>consultar un pedido vía Nginx"]
    C --> D["Una respuesta observable<br/>responde y aparece en el listado<br/>con instance_id"]
```

## 5. Arquitectura y Decisiones Técnicas

Para garantizar la reproducibilidad y la continuidad, el proyecto se divide en dos capas: **la visión de producción (AWS)** y el **MVP funcional (Local)**.

### 5.1. Visión de Producción (Diseño Cloud)

Diseñado para escalar y resistir fallos de infraestructura. Utiliza **Terraform** para aprovisionar la VPC, el clúster de **Amazon EKS** (Kubernetes) y **Amazon RDS** (PostgreSQL).

El tráfico se gestiona mediante un **Application Load Balancer (ALB)**, mientras que la observabilidad se delega a **Prometheus, Loki y Grafana**.

Los secretos se gestionan de forma segura mediante **AWS Secrets Manager**.

```mermaid
flowchart TD
    classDef dev fill:#24292e,stroke:#fff,stroke-width:2px,color:white;
    classDef secret fill:#E74C3C,stroke:#C0392B,stroke-width:2px,color:white;
    classDef aws fill:#FF9900,stroke:#232F3E,stroke-width:2px,color:black;
    classDef k8s fill:#326CE5,stroke:#fff,stroke-width:2px,color:white;
    classDef obs fill:#F46800,stroke:#232F3E,stroke-width:2px,color:white;
    classDef client fill:#85C1E9,stroke:#2E86C1,stroke-width:2px;
    classDef iaC fill:#844FBA,stroke:#4A235A,stroke-width:2px,color:white;
    classDef registry fill:#2088FF,stroke:#0052CC,stroke-width:2px,color:white;
    classDef db fill:#336791,stroke:#fff,stroke-width:2px,color:white;
    classDef proxy fill:#2ECC71,stroke:#27AE60,stroke-width:2px,color:white;

    subgraph Repositorio_Git [GitHub - CI/CD y Secretos]
        Dev[Desarrollador]:::dev --> GHA[GitHub Actions\nBuild, Test & Scan]:::dev
        Secrets[GitHub Secrets]:::secret -.->|Inyección| GHA
        GHA -->|Push Image| Registry[(GHCR)]:::registry
    end

    TF[Terraform - IaC]:::iaC -.-> |Aprovisiona Toda la Infra| AWS_VPC
    
    subgraph AWS_VPC [AWS Cloud - VPC]
        U[Usuarios]:::client -->|HTTPS| ALB[ALB / Nginx\nFailover & Health Checks]:::proxy
        Secrets -.->|AWS Secrets Manager| EKS
        
        subgraph EKS [Amazon EKS]
            ALB --> Pod1[Pod 1]:::k8s
            ALB --> Pod2[Pod 2]:::k8s
            ALB -.->|Failover| Pod3[Pod 3]:::k8s
        end
        
        Registry -.->|Canary / Rollback| EKS
        
        Pod1 & Pod2 & Pod3 --> RDS[(Amazon RDS)]:::db
        RDS -->|Snapshots| BK_BD[(Backups)]:::db
    end

    subgraph Observabilidad [Observabilidad]
        Pod1 & Pod2 & Pod3 -.->|/metrics| Prom[Prometheus]:::obs
        Pod1 & Pod2 & Pod3 -.->|Logs| Loki[Loki]:::obs
        Prom --> AM[AlertManager]:::obs
        Prom & Loki & AM --> Grafana[Grafana]:::obs
    end
```
### 5.2. MVP de la Hackatón (Implementación Local)

Es la misma topología lógica que la visión de producción, pero adaptada a las restricciones del reto (sin costos y con almacenamiento en archivo JSON).

1. **Proxy Inverso:** Nginx distribuye la carga y maneja el failover (si una instancia falla, redirige a la otra).

2. **Aplicación:** Dos contenedores Docker (Python) que exponen los endpoints:
   - `/pedidos`
   - `/health`
   - `/metrics`

3. **Almacenamiento:** Volumen persistente en el host que guarda el archivo `pedidos.json`, separado del ciclo de vida de los contenedores.

4. **CI/CD:** GitHub Actions construye la imagen y la publica en GHCR.

5. **Secretos:** Uso de GitHub Secrets para el pipeline y un archivo `.env` local (ignorado en Git) para las variables de entorno.

6. **Observabilidad:** Logs en `stdout` y endpoint de métricas mediante `prometheus_client`.

### 5.2. MVP de la Hackatón (Implementación Local)

Es la misma topología lógica que la visión de producción, pero adaptada a las restricciones del reto (sin costos y con almacenamiento en archivo JSON).

1. **Proxy Inverso:** Nginx distribuye la carga y maneja el failover (si una instancia falla, redirige a la otra).

2. **Aplicación:** Dos contenedores Docker (Python) que exponen los endpoints:
   - `/pedidos`
   - `/health`
   - `/metrics`

3. **Almacenamiento:** Volumen persistente en el host que guarda el archivo `pedidos.json`, separado del ciclo de vida de los contenedores.

4. **CI/CD:** GitHub Actions construye la imagen y la publica en GHCR.

5. **Secretos:** Uso de GitHub Secrets para el pipeline y un archivo `.env` local (ignorado en Git) para las variables de entorno.

6. **Observabilidad:** Logs en `stdout` y endpoint de métricas mediante `prometheus_client`.

```mermaid
flowchart TD
    classDef dev fill:#24292e,stroke:#fff,stroke-width:2px,color:white;
    classDef secret fill:#E74C3C,stroke:#C0392B,stroke-width:2px,color:white;
    classDef client fill:#85C1E9,stroke:#2E86C1,stroke-width:2px;
    classDef proxy fill:#2ECC71,stroke:#27AE60,stroke-width:2px,color:white;
    classDef container fill:#34495E,stroke:#2C3E50,stroke-width:2px,color:white;
    classDef storage fill:#E67E22,stroke:#D35400,stroke-width:2px,color:white;
    classDef obs fill:#9B59B6,stroke:#8E44AD,stroke-width:2px,color:white;
    classDef registry fill:#2088FF,stroke:#0052CC,stroke-width:2px,color:white;
    classDef script fill:#D35400,stroke:#fff,stroke-width:2px,color:white;
    classDef iaC fill:#844FBA,stroke:#4A235A,stroke-width:2px,color:white;

    subgraph GitHub [GitHub]
        Dev[Desarrollador]:::dev --> GHA[GitHub Actions]:::dev
        Secrets[GitHub Secrets]:::secret -.->|Inyección| GHA
        GHA -->|Build & Push| Registry[(GHCR)]:::registry
    end

    TF_Local[Terraform Local]:::iaC -.->|Orquesta| Docker_Host
    
    U[Usuario]:::client -->|HTTP| Nginx[Nginx]:::proxy
    
    subgraph Docker_Host [Host Local]
        Registry -.->|Pull Image| Compose[Docker Compose]
        EnvFile[.env Local]:::secret -.->|Variables| Compose
        
        Nginx --> App1[App Instancia A]:::container
        Nginx --> App2[App Instancia B]:::container
        Nginx -.->|Failover si falla /health| App1
        
        App1 & App2 --> Vol_Datos[(Volumen Persistente)]:::storage
        Vol_Datos -.-> JSON[pedidos.json]:::storage
        JSON -.->|Cron / Manual| ScriptBK[Script backup.sh]:::script
        ScriptBK -->|Copia Segura| Backup[(Backups)]:::storage
    end

    subgraph Logs_y_Salud [Observabilidad Básica]
        App1 & App2 -.->|Logs| Logs[Logs de Docker]:::obs
        App1 & App2 -.->|Endpoint| Health["/health y /metrics"]:::obs
    end
```
### 5.3. Tabla de Componentes y Responsabilidades

| Pieza | Qué es | Para qué sirve | Herramienta en MVP |
|--------|---------|----------------|--------------------|
| Punto de acceso común | Proxy Inverso | Recibe las consultas, distribuye la carga y realiza failover. | Nginx |
| Servicio de consultas | Aplicación | Responde los endpoints `/pedidos`, `/health` y `/metrics`, e informa el `instance_id`. | Python + Docker |
| Base de datos / archivo | Dependencia | Guarda los pedidos fuera del ciclo de vida del contenedor. | Volumen Docker + JSON |
| Respaldo | Copia externa | Permite recuperar los datos si se pierden o alteran. | `backup.sh` con timestamp |
| CI/CD | Automatización | Construye, prueba y publica la imagen para evitar errores manuales. | GitHub Actions |
| IaC | Infraestructura como Código | Permite recrear el entorno de forma reproducible. | Terraform |
| Secretos | Seguridad | Evita subir credenciales o claves al repositorio. | GitHub Secrets + `.env` |

---

### 5.4. Entornos y Flujo de Trabajo

1. **Desarrollo:** donde se realizan los cambios (rama local).

2. **Pruebas:** donde GitHub Actions verifica que la imagen se construye correctamente y que los health checks pasan.

3. **Producción:** donde el equipo de operaciones utiliza el sistema (entorno local simulado).

Una versión solo avanza si supera las pruebas automatizadas definidas en el pipeline.

```mermaid
flowchart LR
    subgraph DEV["Desarrollo · Local"]
        d1["Código + Docker"] --> d2[("Datos de ejemplo")]
    end
    subgraph TEST["Pruebas · CI/CD"]
        t1["GitHub Actions"] --> t2[("Build & Test")]
    end
    subgraph PROD["Producción · MVP"]
        p1["Contenedores Nginx + App"] --> p2[("Volumen + Backups")]
    end
    DEV -->|"Push a main"| TEST
    TEST -->|"Solo avanza si el build y test pasan"| PROD
```
## 6. Criterios de Aceptación y Pruebas

| # | Operación | Evidencia | Cómo lo resuelve la arquitectura |
|---|-----------|-----------|----------------------------------|
| 1 | Consultar un pedido a través del punto de acceso común | Otra persona obtiene el mismo resultado, con la versión y el `instance_id` anotados. | Nginx distribuye la carga entre las instancias. |
| 2 | Un cambio que deja el servicio sin poder consultar | La versión no avanza, o se vuelve a la anterior y la consulta funciona de nuevo. | El pipeline de CI/CD bloquea imágenes defectuosas y permite rollback. |
| 3 | Detener una instancia | La consulta sigue respondiendo. | Nginx detecta que `/health` falla y redirige a la instancia sana (failover). |
| 4 | Pérdida o alteración de datos | Se restaura el respaldo y el `version_id` vuelve a ser el esperado. | El volumen persiste fuera del contenedor y el script de backup permite la recuperación. |

### Pruebas de Aceptación Detalladas

#### Prueba A · Funcionamiento Normal

1. **Entrada:** consultar un pedido a través de Nginx.
2. **Se espera:** la consulta responde y el pedido aparece en el listado, junto con el `instance_id` de la instancia que atendió la solicitud.
3. **Cómo se comprueba:** se realiza un `curl` o se abre el navegador y se verifica la respuesta obtenida.

#### Prueba B · Fallo y Recuperación (Continuidad)

1. **Entrada:** detener una instancia (por ejemplo, `docker stop app1`) y volver a consultar.
2. **Se espera:** la consulta continúa respondiendo desde la instancia restante (failover de Nginx).
3. **Cómo se comprueba:** se detiene el contenedor, se realiza una nueva consulta y se verifica que el `instance_id` cambió al de la instancia activa.

#### Prueba C · Persistencia y Respaldo (Durabilidad)

1. **Entrada:** respaldar el archivo, alterar una copia de trabajo y restaurarla.
2. **Se espera:** tras restaurar, el `version_id` y el contenido vuelven a ser los esperados.
3. **Cómo se comprueba:** se ejecuta `backup.sh`, se modifica el JSON original, se restaura el respaldo y se compara el `version_id` y el hash del archivo.

---

