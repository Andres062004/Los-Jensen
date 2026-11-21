data "aws_caller_identity" "actual" {}

# ---------------------------------------------------------------------------
# AWS Secrets Manager: credenciales de la base (fuente única de verdad).
# scripts/desplegar.ps1 las lee de aquí para crear el Secret de Kubernetes.
# Mejora asignada: sincronizarlas con External Secrets Operator.
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.proyecto}/db"
  description             = "Credenciales de PostgreSQL de Nodo Ruta"
  recovery_window_in_days = 0 # laboratorio: permite destruir y recrear con el mismo nombre
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    DB_HOST     = aws_db_instance.postgres.address
    DB_PORT     = "5432"
    DB_NAME     = aws_db_instance.postgres.db_name
    DB_USER     = aws_db_instance.postgres.username
    DB_PASSWORD = random_password.db.result
  })
}

# ---------------------------------------------------------------------------
# GitHub Actions -> AWS por OIDC: el pipeline asume este rol con un token
# temporal; no se guardan llaves de AWS en GitHub Secrets.
# Solo puede desplegar desde la rama main del repositorio indicado y solo
# tiene permisos de edición en el namespace nodoruta.
# ---------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

resource "aws_iam_role" "github_deploy" {
  name = "${var.proyecto}-github-deploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/main" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_deploy" {
  name = "describe-eks"
  role = aws_iam_role.github_deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster"]
      Resource = "arn:aws:eks:${var.region}:${data.aws_caller_identity.actual.account_id}:cluster/${var.proyecto}-eks"
    }]
  })
}
