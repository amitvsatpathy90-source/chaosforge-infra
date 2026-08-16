# Shared VPC for both systems — one VPC, segmented by subnet + security
# group, not two VPCs + peering. Both systems are yours, already isolate
# trust at the app layer (mTLS/JWT on chaosforge, OAuth2/NetworkPolicy-style
# defaults on RPE), and a single VPC means one route table set, one NAT/
# endpoint bill, one thing to tear down between on-demand sessions.
# Alternative considered: two VPCs + peering — more realistic for genuinely
# separate organizations, but doubles the always-there resources for no
# isolation benefit these two systems don't already have at the app layer.

variable "vpc_cidr" {
  description = "CIDR block for the shared platform VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "availability_zones" {
  description = "AZs to spread subnets across. The ALB requires at least 2."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

resource "aws_vpc" "platform" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "chaosforge-platform" }
}

resource "aws_internet_gateway" "platform" {
  vpc_id = aws_vpc.platform.id
}

# Public — the ALB only. ChaosForge's Edge Gateway is documented as the sole
# public ingress (mtls-rules.md); RPE has zero public HTTP surface by design
# (confirmed against source — no @RestController in rpe-detection-service),
# so RPE gets no public subnet presence at all.
resource "aws_subnet" "public" {
  for_each                = toset(var.availability_zones)
  vpc_id                  = aws_vpc.platform.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, index(var.availability_zones, each.value))
  availability_zone       = each.value
  map_public_ip_on_launch = true
  tags                    = { Name = "platform-public-${each.value}", Tier = "public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.platform.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.platform.id
  }
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Private — every ECS task and every stateful resource in both systems.
# Separate subnet sets per system (not per-system routing difference, just
# for readable tagging / future NACL scoping if that's ever needed).
resource "aws_subnet" "private_chaosforge" {
  for_each          = toset(var.availability_zones)
  vpc_id            = aws_vpc.platform.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 10 + index(var.availability_zones, each.value))
  availability_zone = each.value
  tags              = { Name = "platform-private-chaosforge-${each.value}", Tier = "private", System = "chaosforge" }
}

resource "aws_subnet" "private_rpe" {
  for_each          = toset(var.availability_zones)
  vpc_id            = aws_vpc.platform.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 20 + index(var.availability_zones, each.value))
  availability_zone = each.value
  tags              = { Name = "platform-private-rpe-${each.value}", Tier = "private", System = "rpe" }
}

# NAT Gateway — toggleable, DEFAULT OFF. ADR-0402.
variable "enable_nat_gateway" {
  description = "Default false: no idle NAT cost; rpe-triage runs in its documented degraded mode (ADR-15 §9). Set true only for a session that needs real OpenAI-backed triage verdicts."
  type        = bool
  default     = false
}

resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? 1 : 0
  domain = "vpc"
  tags   = { Name = "platform-nat" }
}

resource "aws_nat_gateway" "platform" {
  count         = var.enable_nat_gateway ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[var.availability_zones[0]].id
  tags          = { Name = "platform-nat" }
  depends_on    = [aws_internet_gateway.platform]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.platform.id
  tags   = { Name = "platform-private" }
}

# The default route exists only when the NAT does — a separate aws_route (not an inline route
# block) so it can be count-gated independently of the table itself.
resource "aws_route" "private_internet" {
  count                  = var.enable_nat_gateway ? 1 : 0
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.platform[0].id
}

resource "aws_route_table_association" "private_chaosforge" {
  for_each       = aws_subnet.private_chaosforge
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_rpe" {
  for_each       = aws_subnet.private_rpe
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
