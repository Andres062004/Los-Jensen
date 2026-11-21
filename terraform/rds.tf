resource "random_password" "db" {
  length           = 24
  special          = true
  override_special = "-_~"
}

resource "aws_security_group" "rds" {
  name        = "${var.proyecto}-rds"
  description = "PostgreSQL solo desde los nodos de EKS"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "PostgreSQL desde los nodos (pods)"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }
}

# Una sola zona (Single-AZ) para cuidar los créditos: es un punto único de falla
# declarado. Mejora para producción: multi_az = true.
resource "aws_db_instance" "postgres" {
  identifier     = "${var.proyecto}-db"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "nodoruta"
  username = "nodoruta_admin"
  password = random_password.db.result
  port     = 5432

  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = var.db_backup_retention_days
  backup_window           = "07:00-08:00"
  copy_tags_to_snapshot   = true

  # Laboratorio: permite destruir sin snapshot final. En producción: false + deletion_protection.
  skip_final_snapshot = true
  deletion_protection = false
  apply_immediately   = true
}
