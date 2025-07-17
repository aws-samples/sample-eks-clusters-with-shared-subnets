variable "vpc_id" {
  type = string
}
variable "peer_vpc_id" {
  type = string
}
variable "name" {
  type    = string
  default = "eks-shared-subnets"
}

data "aws_vpc" "vpc" {
  id = var.vpc_id
}

data "aws_vpc" "peer" {
  id = var.peer_vpc_id
}

resource "aws_vpc_peering_connection" "this" {
  vpc_id      = data.aws_vpc.vpc.id
  peer_vpc_id = data.aws_vpc.peer.id
  auto_accept = true
  tags = {
    Name = var.name
  }
}

data "aws_route_tables" "vpc" {
  vpc_id = data.aws_vpc.vpc.id
  filter {
    name   = "tag:Name"
    values = ["${var.name}-network-public"]
  }
}

data "aws_route_tables" "peer" {
  vpc_id = data.aws_vpc.peer.id

  filter {
    name   = "tag:role"
    values = ["pod"]
  }
}

resource "aws_route" "vpc" {
  count                     = length(data.aws_route_tables.vpc.ids)
  route_table_id            = tolist(data.aws_route_tables.vpc.ids)[count.index]
  destination_cidr_block    = data.aws_vpc.peer.cidr_block_associations[1].cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}

resource "aws_route" "peer" {
  count                     = length(data.aws_route_tables.peer.ids)
  route_table_id            = tolist(data.aws_route_tables.peer.ids)[count.index]
  destination_cidr_block    = data.aws_vpc.vpc.cidr_block_associations[0].cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}

