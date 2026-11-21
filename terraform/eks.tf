module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.37"

  cluster_name    = "${var.proyecto}-eks"
  cluster_version = var.kubernetes_version

  # Sin registros del plano de control en CloudWatch (cobran por GB y por retención).
  # La observabilidad del servicio la dan Prometheus y Loki dentro del clúster.
  cluster_enabled_log_types   = []
  create_cloudwatch_log_group = false

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.admin_cidrs

  # Quien ejecuta terraform apply queda como administrador del clúster.
  enable_cluster_creator_admin_permissions = true

  # El pipeline de GitHub Actions solo puede editar recursos del namespace nodoruta.
  # Los demás integrantes (usuarios IAM en var.equipo_admin_arns) administran el clúster.
  access_entries = merge(
    {
      github_actions = {
        principal_arn = aws_iam_role.github_deploy.arn
        policy_associations = {
          editar_nodoruta = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
            access_scope = { type = "namespace", namespaces = ["nodoruta"] }
          }
        }
      }
    },
    {
      for i, arn in var.equipo_admin_arns : "equipo-${i}" => {
        principal_arn = arn
        policy_associations = {
          admin = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
    }
  )

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = { before_compute = true }
  }

  eks_managed_node_groups = {
    general = {
      instance_types = [var.node_instance_type]
      capacity_type  = "ON_DEMAND"
      min_size       = var.node_count
      max_size       = var.node_count + 1
      desired_size   = var.node_count
      subnet_ids     = module.vpc.public_subnets
      disk_size      = 20
    }
  }
}
