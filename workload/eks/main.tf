variable "vpc_id" {
  type = string
}
variable "cluster_name" {
  type = string
}
variable "cluster_version" {
  type = string
}
variable "network_assume_role_arn" {
  type = string
}
variable "network_vpc_id" {
  type = string
}
variable "network_vpc_cidr" {
  type = string
}
variable "target_group_arn" {
  type = string
}
variable "app_color" {
  type = string
}

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.37.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1.3"
    }
  }
}

data "aws_region" "current" {}
locals {
  region = data.aws_region.current.name
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}
resource "aws_iam_role_policy_attachment" "worker_node" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy"
  role       = aws_iam_role.node.name
}
resource "aws_iam_role_policy_attachment" "ecr" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
  role       = aws_iam_role.node.name
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.37.1"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  enable_cluster_creator_admin_permissions = true
  cluster_endpoint_public_access           = true

  vpc_id     = var.vpc_id
  subnet_ids = data.aws_subnets.private.ids

  cluster_compute_config = {
    enabled    = true
    node_pools = []
  }

  access_entries = {
    custom_nodeclass_access = {
      principal_arn = aws_iam_role.node.arn
      type          = "EC2"
      policy_associations = {
        auto = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAutoNodePolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  node_security_group_additional_rules = {
    network = {
      description = "Allow all traffic from Network VPC"
      type        = "ingress"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = [var.network_vpc_cidr]
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "--region", local.region, "get-token", "--cluster-name", module.eks.cluster_name]
  }
}
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "--region", local.region, "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}
provider "kubectl" {
  apply_retry_count      = 5
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "--region", local.region, "get-token", "--cluster-name", module.eks.cluster_name]
  }
}
module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "1.21.1"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  enable_aws_load_balancer_controller = true
  aws_load_balancer_controller = {
    chart_version = "1.13.3"
    values = [
      <<-EOT
          vpcId: ${var.vpc_id}
          region: ${local.region}
        EOT
    ]
    policy_statements = [{
      sid       = ""
      actions   = ["sts:AssumeRole"]
      resources = ["*"]
    }]
  }

  depends_on = [module.eks]
}

resource "kubectl_manifest" "nodeclass" {
  yaml_body = templatefile("${path.module}/manifests/nodeclass.yaml", {
    cluster_name = var.cluster_name
    node_role    = aws_iam_role.node.name
  })
  depends_on = [module.eks]
}

resource "kubectl_manifest" "nodepool" {
  yaml_body  = file("${path.module}/manifests/nodepool.yaml")
  depends_on = [kubectl_manifest.nodeclass]
}

resource "kubectl_manifest" "namespace" {
  yaml_body  = file("${path.module}/manifests/namespace.yaml")
  depends_on = [kubectl_manifest.nodepool]
}

resource "kubectl_manifest" "deployment" {
  wait_for_rollout = false
  yaml_body = templatefile("${path.module}/manifests/deployment.yaml", {
    app_color = var.app_color
  })
  depends_on = [kubectl_manifest.namespace]
}

resource "kubectl_manifest" "service" {
  yaml_body  = file("${path.module}/manifests/service.yaml")
  depends_on = [kubectl_manifest.namespace]
}

resource "kubectl_manifest" "targetgroupbinding" {
  yaml_body = templatefile("${path.module}/manifests/targetgroupbinding.yaml", {
    assume_role_arn  = var.network_assume_role_arn
    vpc_id           = var.network_vpc_id
    target_group_arn = var.target_group_arn
  })
  depends_on = [
    kubectl_manifest.nodepool,
    module.eks_blueprints_addons
  ]
}
