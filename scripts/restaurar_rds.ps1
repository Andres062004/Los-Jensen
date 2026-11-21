<#
.SYNOPSIS
  Restaura la base RDS a un punto en el tiempo y conecta la app a la copia restaurada.
.DESCRIPTION
  Prueba I05 en la nube. Pasos:
    1. Crea una instancia nueva desde los backups automáticos (point-in-time restore),
       con la misma subred y grupo de seguridad.
    2. Espera a que esté disponible.
    3. Cambia DB_HOST en el ConfigMap y reinicia los pods (rollout).
    4. Mide el tiempo total (RTO) y muestra el estado de los datos.
  RDS no restaura "encima" de la instancia original: siempre crea otra.
  La instancia restaurada NO la gestiona Terraform: bórrela antes de terraform destroy
  (el script imprime el comando).
.PARAMETER Hora
  Momento a restaurar, en UTC (ej. "2026-11-21T15:30:00Z"). Debe ser ANTES de alterar los datos.
.EXAMPLE
  ./scripts/restaurar_rds.ps1 -Hora "2026-11-21T15:30:00Z"
#>
param(
    [Parameter(Mandatory = $true)][string]$Hora,
    [string]$Region = "us-east-1",
    [string]$Origen = "nodoruta-db",
    [string]$Secreto = "nodoruta/db"
)
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$region = $Region
$origen = $Origen
$destino = "$origen-rest-$((Get-Date).ToUniversalTime().ToString('MMddHHmm'))"

$info = aws rds describe-db-instances --region $region --db-instance-identifier $origen | ConvertFrom-Json
$db = $info.DBInstances[0]
$sg = $db.VpcSecurityGroups[0].VpcSecurityGroupId
$subredes = $db.DBSubnetGroup.DBSubnetGroupName
Write-Host "Última hora restaurable: $($db.LatestRestorableTime)"

$inicio = Get-Date
Write-Host "== [$($inicio.ToString('HH:mm:ss'))] Restaurando $origen a $Hora como $destino"
aws rds restore-db-instance-to-point-in-time --region $region `
    --source-db-instance-identifier $origen `
    --target-db-instance-identifier $destino `
    --restore-time $Hora `
    --db-instance-class $db.DBInstanceClass `
    --db-subnet-group-name $subredes `
    --vpc-security-group-ids $sg `
    --no-publicly-accessible `
    --no-multi-az | Out-Null

Write-Host "== Esperando a que la instancia esté disponible (suele tardar 10-20 minutos)"
aws rds wait db-instance-available --region $region --db-instance-identifier $destino
$nuevoHost = (aws rds describe-db-instances --region $region --db-instance-identifier $destino --query "DBInstances[0].Endpoint.Address" --output text).Trim()
$listaDb = Get-Date

Write-Host "== [$($listaDb.ToString('HH:mm:ss'))] Conectando la app a $nuevoHost"
kubectl -n nodoruta patch configmap nodoruta-config --type merge -p "{`"data`":{`"DB_HOST`":`"$nuevoHost`"}}"
# Mantener Secrets Manager al día para que un nuevo despliegue use la base restaurada.
$valorSecreto = aws secretsmanager get-secret-value --region $region --secret-id $Secreto --query SecretString --output text | ConvertFrom-Json
$valorSecreto.DB_HOST = $nuevoHost
$archivoTmp = New-TemporaryFile
($valorSecreto | ConvertTo-Json -Compress) | Set-Content -NoNewline -Encoding utf8NoBOM $archivoTmp
aws secretsmanager put-secret-value --region $region --secret-id $Secreto --secret-string "file://$archivoTmp" | Out-Null
Remove-Item $archivoTmp
kubectl -n nodoruta rollout restart deployment/nodoruta
kubectl -n nodoruta rollout status deployment/nodoruta --timeout=300s
$fin = Get-Date

$pod = kubectl -n nodoruta get pods -l app=nodoruta -o jsonpath="{.items[0].metadata.name}"
kubectl -n nodoruta exec $pod -- python datos_db.py estado

Write-Host ""
Write-Host "Inicio:                 $($inicio.ToString('u'))"
Write-Host "Base restaurada lista:  $($listaDb.ToString('u'))  ($([int]($listaDb - $inicio).TotalSeconds) s)"
Write-Host "App conectada (fin):    $($fin.ToString('u'))"
Write-Host "RTO total medido:       $([int]($fin - $inicio).TotalSeconds) s"
Write-Host ""
Write-Host "Compare version y sha256 con el estado previo a la alteración."
Write-Host "Antes de terraform destroy, borre la copia restaurada:"
Write-Host "  aws rds delete-db-instance --region $region --db-instance-identifier $destino --skip-final-snapshot"
