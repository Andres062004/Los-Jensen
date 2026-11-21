<#
.SYNOPSIS
  Consulta el servicio una vez por segundo y registra hora, código HTTP e instancia.
.DESCRIPTION
  Se deja corriendo mientras se provoca una falla (borrar un pod, drenar un nodo,
  restaurar la base) para ver el corte y medir el tiempo de recuperación (RTO).
  Al final resume: total, errores, primera y última falla, e instancias vistas.
.EXAMPLE
  ./scripts/sondear.ps1 -Url http://<ALB>/pedidos -Segundos 120 -Salida evidencias/nube_I02_pod.txt
#>
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [int]$Segundos = 120,
    [Parameter(Mandatory = $true)][string]$Salida
)
if (Test-Path $Salida) { throw "La salida $Salida ya existe; use otro nombre para conservar la evidencia anterior." }
New-Item -ItemType Directory -Force (Split-Path $Salida -Parent) | Out-Null

$filas = @()
for ($n = 1; $n -le $Segundos; $n++) {
    $t = Get-Date
    try {
        $r = Invoke-WebRequest $Url -TimeoutSec 3 -SkipHttpErrorCheck
        $codigo = [int]$r.StatusCode
        $inst = "$($r.Headers['X-Instancia'])"
        $version = try { ($r.Content | ConvertFrom-Json).version ?? ($r.Content | ConvertFrom-Json).version_datos } catch { "" }
    } catch {
        $codigo = "ERR"; $inst = "-"; $version = ""
    }
    $linea = "{0:HH:mm:ss} {1,4} {2} {3}" -f $t, $codigo, $inst, $version
    Write-Host $linea
    $linea | Add-Content -Encoding utf8 $Salida
    $filas += [pscustomobject]@{ Hora = $t; Codigo = $codigo; Instancia = $inst }
    $espera = 1000 - ((Get-Date) - $t).TotalMilliseconds
    if ($espera -gt 0) { Start-Sleep -Milliseconds $espera }
}

$fallas = $filas | Where-Object { $_.Codigo -ne 200 }
$resumen = @(
    "",
    "== Resumen",
    "Consultas: $($filas.Count)   OK: $($filas.Count - $fallas.Count)   Fallidas: $($fallas.Count)",
    "Instancias vistas: $((($filas | Where-Object Codigo -eq 200).Instancia | Sort-Object -Unique) -join ', ')"
)
if ($fallas) {
    $primera = $fallas[0].Hora; $ultima = $fallas[-1].Hora
    $resumen += "Primera falla: {0:HH:mm:ss}   Última falla: {1:HH:mm:ss}   Ventana de error: {2:N0} s" -f $primera, $ultima, (($ultima - $primera).TotalSeconds + 1)
}
$resumen | ForEach-Object { Write-Host $_ }
$resumen | Add-Content -Encoding utf8 $Salida
