variable "region" {
  description = "Región de AWS"
  type        = string
  default     = "us-east-1"
}

variable "proyecto" {
  description = "Prefijo de nombres de los recursos"
  type        = string
  default     = "nodoruta"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "kubernetes_version" {
  description = "Versión de Kubernetes de EKS. Verificar que esté en soporte estándar (el soporte extendido cobra más)."
  type        = string
  default     = "1.34"
}

variable "node_instance_type" {
  description = "Tipo de instancia de los nodos. Si la cuenta del plan gratuito lo rechaza, probar m7i-flex.large o c7i-flex.large."
  type        = string
  default     = "t3.medium"
}

variable "node_count" {
  description = "Nodos del clúster (uno por zona como mínimo)"
  type        = number
  default     = 2
}

variable "admin_cidrs" {
  description = "IPs que pueden usar la API de Kubernetes. Restringir a la IP pública del equipo (ej. 181.x.x.x/32)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "equipo_admin_arns" {
  description = "ARN de los usuarios IAM del equipo que administran el clúster (sin incluir a quien ejecuta terraform apply)"
  type        = list(string)
  default     = []
}

variable "github_repo" {
  description = "Repositorio autorizado a desplegar por OIDC (propietario/nombre)"
  type        = string
  default     = "Andres062004/Los-Jensen"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_engine_version" {
  type    = string
  default = "17"
}

variable "db_backup_retention_days" {
  description = "Días de backups automáticos de RDS (habilita restauración a un punto en el tiempo)"
  type        = number
  default     = 1
}
