variable "name" {
  type    = string
  default = "eks-shared-subnets"
}
variable "vpc_cidr" {
  type    = string
  default = "10.1.0.0/24"
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
variable "tg_1_arn" {
  type = string
}
variable "tg_2_arn" {
  type = string
}

data "aws_availability_zones" "available" {
  # Do not include local zones
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name        = "${var.name}-workload"
  azs         = slice(data.aws_availability_zones.available.names, 0, 3)
  pod_subnets = ["100.64.0.0/18", "100.64.64.0/18", "100.64.128.0/18"]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.21.0"

  name                  = local.name
  cidr                  = var.vpc_cidr
  secondary_cidr_blocks = ["100.64.0.0/16"]
  azs                   = local.azs

  private_subnets = [
    "10.1.0.0/27", "10.1.0.32/27", "10.1.0.64/27",
    "10.1.0.192/28", "10.1.0.208/28", "10.1.0.224/28",
  ]
  create_database_subnet_route_table = true
  database_subnets                   = ["10.1.0.96/27", "10.1.0.128/27", "10.1.0.160/27"]

  public_subnets     = ["10.1.0.240/28"]
  enable_nat_gateway = true
  single_nat_gateway = true

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"     = 1
    "kubernetes.io/role/node"             = 1
    "kubernetes.io/cluster/${var.name}-1" = "shared"
    "kubernetes.io/cluster/${var.name}-2" = "shared"
  }
  private_route_table_tags = {
    "role" = "node"
  }
}

resource "aws_subnet" "pods" {
  count             = length(local.pod_subnets)
  vpc_id            = module.vpc.vpc_id
  cidr_block        = local.pod_subnets[count.index]
  availability_zone = local.azs[count.index]
  tags = {
    Name                                  = "${var.name}-workload-pod-${local.azs[count.index]}"
    "kubernetes.io/role/pod"              = 1
    "kubernetes.io/cluster/${var.name}-1" = "shared"
    "kubernetes.io/cluster/${var.name}-2" = "shared"
  }
}

resource "aws_route_table" "pods" {
  count  = length(local.pod_subnets)
  vpc_id = module.vpc.vpc_id
  tags = {
    Name   = "${var.name}-workload-pod-${local.azs[count.index]}"
    "role" = "pod"
  }

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = module.vpc.natgw_ids[0]
  }
}

resource "aws_route_table_association" "pods" {
  count          = length(local.pod_subnets)
  subnet_id      = aws_subnet.pods[count.index].id
  route_table_id = aws_route_table.pods[count.index].id
}

output "vpc_id" {
  value = module.vpc.vpc_id
}
output "pod_route_table_ids" {
  value = aws_route_table.pods.*.id
}

module "eks_1" {
  source = "./eks"

  vpc_id                  = module.vpc.vpc_id
  cluster_name            = "${var.name}-1"
  cluster_version         = "1.32"
  network_assume_role_arn = var.network_assume_role_arn
  network_vpc_id          = var.network_vpc_id
  network_vpc_cidr        = var.network_vpc_cidr
  target_group_arn        = var.tg_1_arn
  app_color               = "blue"
}

module "eks_2" {
  source = "./eks"

  vpc_id                  = module.vpc.vpc_id
  cluster_name            = "${var.name}-2"
  cluster_version         = "1.33"
  network_assume_role_arn = var.network_assume_role_arn
  network_vpc_id          = var.network_vpc_id
  network_vpc_cidr        = var.network_vpc_cidr
  target_group_arn        = var.tg_2_arn
  app_color               = "green"
}