#Requires -Version 7
<#
.SYNOPSIS
  Instala la observabilidad de Nodo Ruta en el namespace monitoring:
  Prometheus + Alertmanager + Grafana (kube-prometheus-stack), Loki, Alloy y Blackbox exporter.
.DESCRIPTION
  1. Agrega los repositorios de Helm.
  2. Crea el namespace y los Secrets (contraseña de Grafana y URL del webhook de alertas).
     Ningún secreto se escribe en archivos del repositorio.
  3. Instala los charts con los values de k8s/monitoring/.
  4. Aplica el ServiceMonitor, las alertas, el dashboard y el Probe del ALB.
  Se puede ejecutar varias veces (es idempotente).

  La URL del ALB se lee del Ingress nodoruta/nodoruta. Si la app aún no está desplegada,
  el Probe se omite; después se aplica con:  ./scripts/monitoring-install.ps1 -SoloSondeo
.PARAMETER Alb
  Nombre DNS del ALB (sin http://). Si se omite, se lee del Ingress.
.PARAMETER Receptor
  webhook (genérico, p. ej. https://webhook.site) o discord.
.PARAMETER SoloSondeo
  Solo (re)aplica el Probe del ALB. Útil cuando I4 comparte la URL después de instalar.
.PARAMETER CambiarWebhook
  Vuelve a pedir la URL del webhook aunque el Secret ya exista.
.EXAMPLE
  ./scripts/monitoring-install.ps1
.EXAMPLE
  ./scripts/monitoring-install.ps1 -Receptor discord -CambiarWebhook
.EXAMPLE
  ./scripts/monitoring-install.ps1 -SoloSondeo -Alb nodoruta-alb-123456.us-east-1.elb.amazonaws.com
#>
param(
    [string]$Alb,
    [ValidateSet("webhook", "discord")][string]$Receptor = "webhook",
    [switch]$SoloSondeo,
    [switch]$CambiarWebhook
)
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
$raiz = Split-Path $PSScriptRoot -Parent
$mon = Join-Path $raiz "k8s/monitoring"
$ns = "monitoring"
# Helm 4 y kubectl recientes esperan por "watch-list"; con conexiones lentas el watch se
# queda sin eventos y --wait falla aunque los recursos estén listos. Se usa el modo clásico.
$env:KUBE_FEATURE_WatchListClient = "false"

function Aplicar-Sondeo {
    $dns = $Alb
    if (-not $dns) {
        $dns = kubectl -n nodoruta get ingress nodoruta --ignore-not-found -o jsonpath="{.status.loadBalancer.ingress[0].hostname}"
    }
    # Acepta también "http://xxx/health" pegado desde el chat.
    $dns = "$dns" -replace '^https?://', '' -replace '/.*$', ''
    if (-not $dns) {
        Write-Warning "No hay URL del ALB todavía. Cuando I4 la comparta: ./scripts/monitoring-install.ps1 -SoloSondeo [-Alb <dns>]"
        return
    }
    Write-Host "== Sondeo externo: http://$dns/health cada 5 s"
    (Get-Content (Join-Path $mon "probe-alb.yaml") -Raw).Replace("__ALB__", $dns) | kubectl apply -f -
}

if ($SoloSondeo) { Aplicar-Sondeo; return }

Write-Host "== Repositorios de Helm"
# Los charts de prometheus-community se toman del registro OCI (ghcr.io): así no se
# descarga su índice (>6 MB), que con conexiones lentas supera el tiempo de espera.
$promCharts = "oci://ghcr.io/prometheus-community/charts"
helm repo add grafana https://grafana.github.io/helm-charts --force-update

Write-Host "== Namespace $ns"
kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f -

Write-Host "== Secret grafana-admin"
if (-not (kubectl -n $ns get secret grafana-admin --ignore-not-found -o name)) {
    $bytes = [Security.Cryptography.RandomNumberGenerator]::GetBytes(18)
    $clave = [Convert]::ToBase64String($bytes) -replace '[+/=]', ''
    kubectl -n $ns create secret generic grafana-admin `
        --from-literal=admin-user=admin `
        --from-literal=admin-password=$clave | Out-Null
    Write-Host "   Usuario: admin   Contraseña: $clave"
    Write-Host "   (Guárdela en su gestor de contraseñas. No la pegue en el chat del equipo.)"
} else {
    Write-Host "   Ya existe. Para verla:"
    Write-Host '   kubectl -n monitoring get secret grafana-admin -o jsonpath="{.data.admin-password}" | %{ [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }'
}

Write-Host "== Secret alertmanager-webhook (receptor: $Receptor)"
$existe = kubectl -n $ns get secret alertmanager-webhook --ignore-not-found -o name
if (-not $existe -or $CambiarWebhook) {
    $url = Read-Host -MaskInput "URL del webhook ($Receptor). Enter para dejarlo sin configurar"
    if (-not $url) {
        $url = "http://127.0.0.1:9/sin-configurar"
        Write-Warning "Webhook sin configurar: las alertas se verán en Alertmanager pero no llegarán al equipo. Repetir con -CambiarWebhook."
    }
    kubectl -n $ns create secret generic alertmanager-webhook --from-literal=url=$url `
        --dry-run=client -o yaml | kubectl apply -f - | Out-Null
    Remove-Variable url
    # Alertmanager lee url_file en cada envío; el Secret montado se actualiza solo (~1 min).
} else {
    Write-Host "   Ya existe (use -CambiarWebhook para reemplazarlo)."
}

Write-Host "== kube-prometheus-stack (Prometheus, Alertmanager, Grafana)"
$kpsValores = @("-f", (Join-Path $mon "kps-values.yaml"))
if ($Receptor -eq "discord") { $kpsValores += @("-f", (Join-Path $mon "kps-values-discord.yaml")) }
helm upgrade --install kps "$promCharts/kube-prometheus-stack" -n $ns @kpsValores --wait --timeout 10m

Write-Host "== Loki"
helm upgrade --install loki grafana/loki -n $ns -f (Join-Path $mon "loki-values.yaml") --wait --timeout 10m

Write-Host "== Alloy (recolector de logs)"
helm upgrade --install alloy grafana/alloy -n $ns -f (Join-Path $mon "alloy-values.yaml") --wait --timeout 5m

Write-Host "== Blackbox exporter"
helm upgrade --install blackbox "$promCharts/prometheus-blackbox-exporter" -n $ns `
    --set resources.requests.cpu=10m --set resources.requests.memory=32Mi --set resources.limits.memory=64Mi `
    --wait --timeout 5m

Write-Host "== ServiceMonitor, alertas y dashboard"
kubectl apply -f (Join-Path $mon "servicemonitor-nodoruta.yaml") -f (Join-Path $mon "alertas-nodoruta.yaml")
$dashboard = Join-Path $mon "dashboard-nodoruta.json"
kubectl -n $ns create configmap dashboard-nodoruta "--from-file=dashboard-nodoruta.json=$dashboard" `
    --dry-run=client -o yaml | kubectl apply -f -
kubectl -n $ns label configmap dashboard-nodoruta grafana_dashboard=1 --overwrite | Out-Null

Aplicar-Sondeo

Write-Host "`n== Estado"
helm list -n $ns
kubectl -n $ns get pods -o wide

Write-Host @"

Siguientes pasos:
  Grafana:      kubectl -n monitoring port-forward svc/kps-grafana 3000:80                              -> http://localhost:3000
  Prometheus:   kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090      -> http://localhost:9090/targets
  Alertmanager: kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-alertmanager 9093    -> http://localhost:9093
  Comprobar en Targets: serviceMonitor/monitoring/nodoruta (3/3 UP) y probe/monitoring/alb (1/1 UP).
  Si hay pods en Pending por capacidad, avisar a I1 (node_count = 3).
"@
