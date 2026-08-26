# -----------------------------------------------------------------------------
# NAT Gateway — Fargate tasks in private subnets need outbound internet access
# to reach AWS China region APIs (ec2.cn-northwest-1.amazonaws.com.cn, etc.)
# and GCR for MCP image pulls.
#
# Architecture: IGW → public subnet → NAT → private subnet route table
# Single NAT to save cost; for HA flip to one per AZ.
#
# Created ONLY when this stack also creates the VPC (var.vpc_id == "").
# When an existing VPC is supplied, no network resources are created — the
# subnets keep their own route tables. The private subnets must already have
# a 0.0.0.0/0 route via a NAT Gateway, and the VPC an attached IGW.
# -----------------------------------------------------------------------------

resource "aws_internet_gateway" "this" {
  count  = local.create_vpc ? 1 : 0
  vpc_id = local.vpc_id
  tags   = { Name = "${var.name_prefix}-igw" }
}

resource "aws_eip" "nat" {
  count  = local.create_vpc ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${var.name_prefix}-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  count         = local.create_vpc ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = local.public_subnet_ids[0]
  tags          = { Name = "${var.name_prefix}-nat" }

  depends_on = [aws_internet_gateway.this]
}

# Public subnet route table (IGW for NAT Gateway's own internet access)
resource "aws_route_table" "public" {
  count  = local.create_vpc ? 1 : 0
  vpc_id = local.vpc_id
  tags   = { Name = "${var.name_prefix}-public" }

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }
}

resource "aws_route_table_association" "public" {
  count          = local.create_vpc ? length(local.public_subnet_ids) : 0
  subnet_id      = local.public_subnet_ids[count.index]
  route_table_id = aws_route_table.public[0].id
}

# Private subnet route table (NAT for Fargate outbound)
resource "aws_route_table" "private" {
  count  = local.create_vpc ? 1 : 0
  vpc_id = local.vpc_id
  tags   = { Name = "${var.name_prefix}-private" }

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[0].id
  }
}

resource "aws_route_table_association" "private" {
  count          = local.create_vpc ? length(local.private_subnet_ids) : 0
  subnet_id      = local.private_subnet_ids[count.index]
  route_table_id = aws_route_table.private[0].id
}
