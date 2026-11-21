data "aws_availability_zones" "disponibles" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.disponibles.names, 0, 2)
}

# VPC en 2 zonas de disponibilidad.
# - Subredes públicas: ALB y nodos de EKS (con IP pública para llegar a ECR/EKS
#   sin NAT Gateway, que cobra por hora). Los grupos de seguridad no abren los
#   nodos a Internet: solo el ALB llega a los pods.
# - Subredes de base de datos: privadas, sin salida a Internet, solo para RDS.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.21"

  name = "${var.proyecto}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  public_subnets   = [cidrsubnet(var.vpc_cidr, 4, 0), cidrsubnet(var.vpc_cidr, 4, 1)]
  database_subnets = [cidrsubnet(var.vpc_cidr, 8, 200), cidrsubnet(var.vpc_cidr, 8, 201)]

  create_database_subnet_group = true
  map_public_ip_on_launch      = true
  enable_nat_gateway           = false
  enable_dns_hostnames         = true
  enable_dns_support           = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
}
