<#
.SYNOPSIS
  Elimina todo lo creado en AWS para no consumir créditos.
.DESCRIPTION
  Orden necesario:
    1. Borrar el Ingress para que el controlador elimine el ALB (si no, la VPC queda
       ocupada y terraform destroy falla).
    2. Borrar las instancias RDS restauradas por restaurar_rds.ps1 (no las gestiona Terraform).
    3. terraform destroy.
#>
$ErrorActionPreference = "Stop"
$raiz = Split-Path $PSScriptRoot -Parent
$tfDir = Join-Path $raiz "terraform"
$tf = terraform "-chdir=$tfDir" output -json | ConvertFrom-Json
$region = $tf.region.value

Write-Host "== 1. Eliminando el Ingress (y con él el ALB)"
kubectl -n nodoruta delete ingress nodoruta --ignore-not-found --wait=true
Start-Sleep -Seconds 60   # margen para que el controlador borre el ALB y sus grupos de seguridad

Write-Host "== 2. Buscando copias restauradas de RDS"
$copias = aws rds describe-db-instances --region $region `
    --query "DBInstances[?starts_with(DBInstanceIdentifier, '$($tf.db_instance_id.value)-rest-')].DBInstanceIdentifier" `
    --output text
foreach ($c in ($copias -split "\s+" | Where-Object { $_ })) {
    Write-Host "   Borrando $c"
    aws rds delete-db-instance --region $region --db-instance-identifier $c --skip-final-snapshot | Out-Null
    aws rds wait db-instance-deleted --region $region --db-instance-identifier $c
}

Write-Host "== 3. Snapshots manuales (sobreviven a terraform destroy y cobran almacenamiento)"
$snaps = aws rds describe-db-snapshots --region $region --snapshot-type manual `
    --query "DBSnapshots[?starts_with(DBSnapshotIdentifier, 'nodoruta-')].DBSnapshotIdentifier" --output text
foreach ($s in ($snaps -split "\s+" | Where-Object { $_ })) {
    Write-Host "   Borrando snapshot $s"
    aws rds delete-db-snapshot --region $region --db-snapshot-identifier $s | Out-Null
}

Write-Host "== 4. terraform destroy"
terraform "-chdir=$tfDir" destroy
Write-Host "Revise en la consola de AWS (EC2 > Load Balancers, RDS, EKS) que no quede nada."
