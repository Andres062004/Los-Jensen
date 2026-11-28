# 01 · Infraestructura y costos (I1)

Responsable: I1 (`i1-infra`). Cuenta AWS `811815656853`, región `us-east-1`.

## Cuenta y accesos

- Usuario raíz con MFA, sin uso diario. Se trabaja con IAM.
- Grupos: `nodoruta-admin` (AdministratorAccess, solo I1: Terraform crea roles IAM) y
  `nodoruta-equipo` (PowerUserAccess + política `nodoruta-autogestion`, que deja a cada persona
  gestionar su propia MFA y sus llaves).
- Usuarios: `i1-infra`, `i2-datos`, `i3-cicd`, `i4-k8s`, `i5-obs`. Cada uno activa su MFA y crea su
  propia llave; nadie envía llaves por chat.
- Acceso a Kubernetes: lo dan las *access entries* de EKS (`equipo_admin_arns` en
  `terraform.tfvars`), no IAM. El rol del pipeline de GitHub solo edita el namespace `nodoruta`.
- Presupuesto mensual de 140 USD con alertas al 10 %, 35 % y 70 %.

## Plan de la cuenta

Plan gratuito con créditos (156,41 USD y 115 días al 21/11/2026).
**Resultado observado (21/11/2026):** el plan gratuito permitió crear VPC, EKS y RDS, pero **rechazó
`t3.medium`** para los nodos (`InvalidParameterCombination - The specified instance type is not eligible
for Free Tier`). Terraform no muestra ese error: se queda esperando; se ve en
`aws autoscaling describe-scaling-activities`. Tipos aceptados (`describe-instance-types` con
`free-tier-eligible=true`): `c7i-flex.large`, `m7i-flex.large`, `t3.micro/small`, `t4g.*`, `t8i.*`, `t9g.*`.
**Decisión:** `c7i-flex.large` (2 vCPU, 4 GiB, x86, ~29 pods por nodo). Los `t4g/t9g` son ARM y la imagen
es x86; `t3.small` (11 pods por nodo) no deja espacio para la observabilidad.

## Decisiones

| Decisión | Motivo | Riesgo declarado |
|---|---|---|
| Nodos en subredes públicas, sin NAT Gateway | El NAT cobra por hora; los grupos de seguridad impiden el acceso directo desde Internet | Mayor superficie que con subredes privadas |
| RDS en subredes privadas, tabla de rutas propia sin salida a Internet, `publicly_accessible=false` | La base solo debe ser alcanzable desde los nodos | — |
| RDS Single-AZ | Ahorro de créditos | Punto único de fallo; mejora: `multi_az = true` |
| `admin_cidrs = 0.0.0.0/0` | El despliegue desde GitHub Actions entra desde IP que cambian | La API exige autenticación IAM y solo admite a los ARN autorizados |
| Estado de Terraform local | Simplicidad | Vive en la máquina de I1; mejora: backend S3 con bloqueo |
| HTTP sin TLS | No hay dominio | Mejora: ACM + HTTPS |

## Cambio al código de Terraform

`terraform/vpc.tf`: se agregó `create_database_subnet_route_table = true`. Sin subredes privadas el
módulo de VPC no tenía una tabla de rutas que asociar a las subredes de la base y el `plan` fallaba
(`coalescelist: no non-null arguments`).

## Evidencias

- `evidencias/terraform_plan.txt`: plan de 77 recursos, sin errores.
- `evidencias/nube_infra.txt`: 2 nodos `Ready` en zonas distintas y controlador del ALB 1/1.
- `evidencias/nube_I01_inicio.json`: prueba I01, 20/20 respuestas 200, 3 instancias, `datos-v1`.
- `evidencias/nube_I01_pods.txt`: reparto de los pods en los nodos.
- `evidencias/nube_destroy.txt`: **no existe**; el 21/11 se pausó el entorno, no se destruyó.

## Operación

- Encender: `cd terraform; terraform plan -out plan.tfplan; terraform apply plan.tfplan` (~20 min),
  y luego `./scripts/desplegar.ps1` (crea los pods y un ALB nuevo con otra URL).
- Apagar del todo: `./scripts/destruir.ps1`, y revisar en la consola EC2 (Load Balancers, Instances),
  RDS (Databases, Snapshots), EKS y VPC.
- Solo I1 ejecuta `apply` y `destroy`, desde una sola máquina.

## Pausa (sin destruir)

Se usó el 21/11/2026 para conservar el entorno hasta la presentación. Se detiene lo que más cuesta,
pero el plano de control de EKS **sigue cobrando por hora** (0,10 USD/h; pasa a 0,50 USD/h desde el
1/12/2026, cuando Kubernetes 1.34 sale de soporte estándar).

1. Bajar la app: `kubectl -n nodoruta scale deployment/nodoruta --replicas=0` (el PDB `minAvailable: 2`
   impide drenar los nodos si no).
2. Nodos a 0: `aws eks update-nodegroup-config --cluster-name nodoruta-eks --nodegroup-name <grupo> --region us-east-1 --scaling-config minSize=0,maxSize=3,desiredSize=0`
   (el último nodo tarda ~3 min por el PDB de `coredns`).
3. Detener la base: `aws rds stop-db-instance --db-instance-identifier nodoruta-db --region us-east-1`
   (RDS la enciende sola a los 7 días).
4. Reanudar: revertir en orden inverso y ejecutar `./scripts/desplegar.ps1`. No ejecutar
   `terraform apply` mientras esté en pausa: volvería a subir `min_size`.
