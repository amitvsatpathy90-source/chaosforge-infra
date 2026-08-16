# ALB — toggleable, DEFAULT OFF. ~$16-20/mo + public IPv4 the instant it exists; default posture
# is a session-scoped public IP on the gateway task instead (~$0 idle). See cost-model.md.
variable "enable_alb" {
  description = "Default false: gateway task gets a session-scoped public IP instead (~$0 idle). Set true to front it with a real ALB (production-shaped ingress, ~$20+/mo while it exists)."
  type        = bool
  default     = false
}

resource "aws_lb" "edge_gateway" {
  count              = var.enable_alb ? 1 : 0
  name               = "chaosforge-edge-gateway"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.public_subnet_ids
}

resource "aws_lb_target_group" "edge_gateway" {
  count       = var.enable_alb ? 1 : 0
  name        = "chaosforge-edge-gateway"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
  target_type = "ip" # required for awsvpc-networked Fargate tasks

  health_check {
    path                = "/actuator/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
  }
}

# Public TLS mandatory whenever ALB is on — enforced as a variable validation (fails at plan,
# not a silent HTTP fallback). Bearer JWT must not cross the internet in cleartext.
variable "acm_certificate_arn" {
  description = "ACM certificate ARN for the ALB's HTTPS listener. Required when enable_alb = true. Public ACM certificates are free; they need a domain you control."
  type        = string
  default     = null

  validation {
    condition     = !var.enable_alb || (var.acm_certificate_arn != null && var.acm_certificate_arn != "")
    error_message = "enable_alb = true requires acm_certificate_arn. Request a free public certificate in ACM for a domain you control, then re-apply. Serving the edge gateway over plain HTTP would expose bearer JWTs in transit."
  }
}

resource "aws_lb_listener" "edge_gateway_https" {
  count             = var.enable_alb ? 1 : 0
  load_balancer_arn = aws_lb.edge_gateway[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.edge_gateway[0].arn
  }
}

# :80 exists only to bounce clients to TLS. It never forwards to the target group, so a client that
# forgets the scheme is redirected rather than served over cleartext.
resource "aws_lb_listener" "edge_gateway_http_redirect" {
  count             = var.enable_alb ? 1 : 0
  load_balancer_arn = aws_lb.edge_gateway[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
