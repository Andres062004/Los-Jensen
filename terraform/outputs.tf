output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "db_host" {
  value = aws_db_instance.postgres.address
}

output "db_instance_id" {
  value = aws_db_instance.postgres.identifier
}

output "db_secret_name" {
  description = "Secreto de Secrets Manager con las credenciales de la base"
  value       = aws_secretsmanager_secret.db.name
}

output "github_deploy_role_arn" {
  description = "Poner en GitHub > Settings > Secrets and variables > Actions > Variables como AWS_DEPLOY_ROLE_ARN"
  value       = aws_iam_role.github_deploy.arn
}

output "configurar_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
