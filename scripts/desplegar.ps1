<#
.SYNOPSIS
  Despliegue manual de Nodo Ruta en EKS (el automático lo hace GitHub Actions).
.DESCRIPTION
  Requiere haber ejecutado "terraform apply" en la carpeta terraform y que la
  imagen exista en GHCR (la publica el pipeline al hacer push a main).
  1. Configura kubectl.
  2. Lee las credenciales de AWS Secrets Manager y crea el ConfigMap y el Secret
     de Kubernetes (la contraseña no se escribe en ningún archivo).
  3. Carga los datos semilla si la base está vacía.
  4. Aplica los manifiestos de k8s/ y espera el ALB.
.EXAMPLE
  ./scripts/desplegar.ps1 -Imagen ghcr.io/andres062004/los-jensen:main
#>
param(
    [string]$Imagen = "ghcr.io/andres062004/los-jensen:main",
    [string]$Region = "us-east-1",
    [string]$Cluster = "nodoruta-eks",
    [string]$Secreto = "nodoruta/db"
)
# No necesita el estado de Terraform: usa los nombres fijos que crea Terraform,
# así cualquier integrante con acceso al clúster puede ejecutarlo.
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
$raiz = Split-Path $PSScriptRoot -Parent
$k8s = Join-Path $raiz "k8s"
$region = $Region

Write-Host "== Configurando kubectl para $Cluster"
aws eks update-kubeconfig --region $region --name $Cluster | Out-Null

Write-Host "== Credenciales desde AWS Secrets Manager ($Secreto)"
$cred = aws secretsmanager get-secret-value --region $region --secret-id $Secreto `
    --query SecretString --output text | ConvertFrom-Json

kubectl apply -f (Join-Path $k8s "00-namespace.yaml")
kubectl -n nodoruta create configmap nodoruta-config `
    --from-literal=DB_HOST=$($cred.DB_HOST) `
    --from-literal=DB_PORT=$($cred.DB_PORT) `
    --from-literal=DB_NAME=$($cred.DB_NAME) `
    --from-literal=DB_SSLMODE=require `
    --dry-run=client -o yaml | kubectl apply -f -
kubectl -n nodoruta create secret generic nodoruta-db `
    --from-literal=DB_USER=$($cred.DB_USER) `
    --from-literal=DB_PASSWORD=$($cred.DB_PASSWORD) `
    --dry-run=client -o yaml | kubectl apply -f -

function Aplicar([string]$archivo) {
    (Get-Content (Join-Path $k8s $archivo) -Raw).Replace("__IMAGEN__", $Imagen) | kubectl apply -f -
}

Write-Host "== Carga inicial de datos (solo si la base está vacía)"
kubectl -n nodoruta delete job carga-datos --ignore-not-found
Aplicar "10-job-carga-datos.yaml"
kubectl -n nodoruta wait --for=condition=complete job/carga-datos --timeout=300s
kubectl -n nodoruta logs job/carga-datos

Write-Host "== Desplegando $Imagen"
Aplicar "20-deployment.yaml"
kubectl apply -f (Join-Path $k8s "30-service-ingress.yaml")
kubectl -n nodoruta rollout status deployment/nodoruta --timeout=300s
kubectl -n nodoruta get pods -o wide

Write-Host "== Esperando la dirección del ALB (puede tardar 2-4 minutos)"
$alb = ""
for ($i = 0; $i -lt 60 -and -not $alb; $i++) {
    $alb = kubectl -n nodoruta get ingress nodoruta -o jsonpath="{.status.loadBalancer.ingress[0].hostname}"
    if (-not $alb) { Start-Sleep -Seconds 5 }
}
if ($alb) {
    Write-Host "`nServicio publicado en: http://$alb/health"
    Write-Host "Evidencia: python scripts/verificar_servicio.py http://$alb/pedidos --peticiones 20 --salida evidencias/nube_inicio.json"
} else {
    Write-Warning "El ALB aún no tiene dirección. Revisar: kubectl -n nodoruta describe ingress nodoruta"
}
