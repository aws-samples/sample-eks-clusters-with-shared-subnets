variable "name" {
  type    = string
  default = "eks-shared-subnets"
}
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/24"
}
variable "target_group_1_weight" {
  description = "Weight for target group 1"
  type        = number
  default     = 100
}
variable "target_group_2_weight" {
  description = "Weight for target group 2"
  type        = number
  default     = 0
}
variable "workload_account_id" {
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
  name = "${var.name}-network"
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)
}

# VPC
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.21.0"

  name = local.name
  cidr = var.vpc_cidr
  azs  = local.azs

  public_subnets  = ["10.0.0.0/27", "10.0.0.32/27", "10.0.0.64/27"]
  private_subnets = ["10.0.0.96/27", "10.0.0.128/27", "10.0.0.160/27"]

  enable_nat_gateway = true
  single_nat_gateway = true
}

output "vpc_id" {
  value = module.vpc.vpc_id
}
output "vpc_cidr" {
  value = module.vpc.vpc_cidr_block
}
# ALB
resource "aws_security_group" "alb" {
  name   = local.name
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "this" {
  name               = local.name
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = module.vpc.public_subnets
}

resource "aws_lb_target_group" "tg_1" {
  name        = "${local.name}-tg-1"
  port        = 3000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = module.vpc.vpc_id
}

output "tg_1_arn" {
  value = aws_lb_target_group.tg_1.arn
}

resource "aws_lb_target_group" "tg_2" {
  name        = "${local.name}-tg-2"
  port        = 3000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = module.vpc.vpc_id
}

output "tg_2_arn" {
  value = aws_lb_target_group.tg_2.arn
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "forward"
    forward {
      target_group {
        arn    = aws_lb_target_group.tg_1.arn
        weight = var.target_group_1_weight
      }
      target_group {
        arn    = aws_lb_target_group.tg_2.arn
        weight = var.target_group_2_weight
      }
    }
  }
}

resource "aws_lb_listener_rule" "internal_test_query" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_2.arn
  }

  condition {
    query_string {
      key   = "internal"
      value = "true"
    }
  }
}

resource "aws_iam_role" "targetgroupbinding" {
  name = "${var.name}-network-targetgroupbinding"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.workload_account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "sts:ExternalId" = "very-secret-string"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "targetgroupbinding" {
  name = "targetgroupbinding"
  role = aws_iam_role.targetgroupbinding.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"

        Action = [
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets"
        ]
        Resource = [
          aws_lb_target_group.tg_1.arn,
          aws_lb_target_group.tg_2.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetHealth"
        ]
        Resource = "*"
      },
    ]
  })
}

output "assume_role_arn" {
  value = aws_iam_role.targetgroupbinding.arn
}