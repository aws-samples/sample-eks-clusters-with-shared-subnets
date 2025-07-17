variable "region" {
  type    = string
  default = "ap-southeast-1"
}
variable "name" {
  type    = string
  default = "eks-shared-subnets"
}

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.95.0, < 6.0.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

module "network" {
  source = "./network"

  name                  = var.name
  vpc_cidr              = "10.0.0.0/24"
  target_group_1_weight = 100
  target_group_2_weight = 0
  workload_account_id   = local.account_id
}

module "workload" {
  source = "./workload"

  name                    = var.name
  network_assume_role_arn = module.network.assume_role_arn
  network_vpc_id          = module.network.vpc_id
  network_vpc_cidr        = module.network.vpc_cidr
  tg_1_arn                = module.network.tg_1_arn
  tg_2_arn                = module.network.tg_2_arn
}

module "vpc-peering" {
  source = "./vpc-peering"

  vpc_id      = module.network.vpc_id
  peer_vpc_id = module.workload.vpc_id
}