#Requires -Version 7
<#
.SYNOPSIS
  Mide el RTO de una prueba con los datos de Prometheus (sondeo externo y Pods Ready).
.DESCRIPTION
  Requiere el port-forward de Prometheus en otra terminal:
    kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090
  Analiza la ventana [-Desde, -Hasta] con paso de 5 s:
  - Servicio (probe_success del ALB): primer fallo, último fallo, primera recuperación, RTO.
  - Réplicas (Pods Ready < 3): inicio de la pérdida, vuelta a 3, tiempo de recuperación.
  RTO = desde el primer probe_success = 0 hasta el primer 1 después del último 0.
.EXAMPLE
  ./scripts/medir_rto.ps1 -Desde "10:32:00" -Hasta "10:36:00" -Prueba I02a -Salida evidencias/rto_I02a.txt
#>
param(
    [Parameter(Mandatory = $true)][datetime]$Desde,
    [datetime]$Hasta = (Get-Date),
    [string]$Prueba = "",
    [string]$Salida,
    [string]$Prometheus = "http://localhost:9090",
    [int]$Paso = 5
)
$ErrorActionPreference = "Stop"
if ($Salida -and (Test-Path $Salida)) { throw "La salida $Salida ya existe; use otro nombre (_r2) para conservar la evidencia anterior." }

function Serie([string]$consulta) {
    $ini = ([DateTimeOffset]$Desde).ToUnixTimeSeconds()
    $fin = ([DateTimeOffset]$Hasta).ToUnixTimeSeconds()
    $q = [uri]::EscapeDataString($consulta)
    $r = Invoke-RestMethod "$Prometheus/api/v1/query_range?query=$q&start=$ini&end=$fin&step=$Paso"
    if (-not $r.data.result) { return @() }
    $r.data.result[0].values | ForEach-Object {
        [pscustomobject]@{
            Hora  = [DateTimeOffset]::FromUnixTimeSeconds([long][double]$_[0]).LocalDateTime
            Valor = [double]$_[1]
        }
    }
}

function Analizar($puntos, [scriptblock]$esFallo, [string]$nombre) {
    if (-not $puntos) { return @("${nombre}: sin datos en la ventana (¿port-forward activo? ¿Probe aplicado?)") }
    $fallos = @($puntos | Where-Object { & $esFallo $_.Valor })
    if (-not $fallos) { return @("${nombre}: sin fallos en la ventana ($($puntos.Count) muestras, paso $Paso s)") }
    $primero = $fallos[0].Hora; $ultimo = $fallos[-1].Hora
    $recup = $puntos | Where-Object { $_.Hora -gt $ultimo -and -not (& $esFallo $_.Valor) } | Select-Object -First 1
    $lineas = @(
        "${nombre}:",
        ("  Primer fallo:      {0:HH:mm:ss}" -f $primero),
        ("  Último fallo:      {0:HH:mm:ss}" -f $ultimo),
        "  Muestras con fallo: $($fallos.Count) de $($puntos.Count) (paso $Paso s)"
    )
    if ($recup) {
        $lineas += ("  Recuperación:      {0:HH:mm:ss}" -f $recup.Hora)
        $lineas += ("  Duración (RTO):    {0:N0} s  (precisión ±{1} s)" -f ($recup.Hora - $primero).TotalSeconds, $Paso)
    } else {
        $lineas += "  Recuperación:      no se recuperó dentro de la ventana"
    }
    return $lineas
}

$sondeo = Serie 'min(probe_success{job="probe/monitoring/alb"})'
$ready = Serie 'sum(kube_pod_status_ready{namespace="nodoruta",condition="true"})'

$informe = @(
    "== RTO $Prueba",
    ("Ventana: {0:yyyy-MM-dd HH:mm:ss} -> {1:HH:mm:ss}" -f $Desde, $Hasta),
    ""
) + (Analizar $sondeo { param($v) $v -lt 1 } "Servicio (sondeo externo ALB /health)") `
  + @("") `
  + (Analizar $ready { param($v) $v -lt 3 } "Réplicas (Pods Ready < 3)")

if ($ready) {
    $min = ($ready | Measure-Object Valor -Minimum).Minimum
    $informe += "  Mínimo de pods Ready en la ventana: $min"
}

$informe | ForEach-Object { Write-Host $_ }
if ($Salida) {
    New-Item -ItemType Directory -Force (Split-Path $Salida -Parent) | Out-Null
    $informe | Set-Content -Encoding utf8 $Salida
}
