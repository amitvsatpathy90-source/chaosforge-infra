# With NAT default-OFF, these are the only path to ECR/Logs/SSM from private subnets — mandatory.
# Single-AZ deliberately (4 endpoints x 2 AZ was ~$58/mo idle); risk is an AZ outage failing a session, not data loss.

resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "platform-vpce-"
  vpc_id      = aws_vpc.platform.id

  ingress {
    description = "HTTPS from anything in the platform VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.platform.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}

locals {
  # ECR (image pulls), CloudWatch Logs (task logging), SSM (secret resolution — Module 5.5 moved
  # all secrets from Secrets Manager to free SSM SecureString parameters, so the endpoint follows).
  # Add more here if a later module needs another AWS API reached from a private subnet — don't
  # reach for a NAT gateway first.
  interface_endpoints = ["ecr.api", "ecr.dkr", "logs", "ssm"]
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(local.interface_endpoints)
  vpc_id              = aws_vpc.platform.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_chaosforge[var.availability_zones[0]].id] # single-AZ — see header
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
}
