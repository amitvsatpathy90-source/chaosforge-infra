output "deploy_role_arn" {
  value = aws_iam_role.github_deploy.arn
}

output "budget_alerts_topic_arn" {
  value = aws_sns_topic.budget_alerts.arn
}

output "vpc_id" {
  value = aws_vpc.platform.id
}

output "vpc_cidr" {
  value = var.vpc_cidr
}

output "public_subnet_ids" {
  value = [for s in aws_subnet.public : s.id]
}

output "private_chaosforge_subnet_ids" {
  value = [for s in aws_subnet.private_chaosforge : s.id]
}

output "private_rpe_subnet_ids" {
  value = [for s in aws_subnet.private_rpe : s.id]
}

output "vpc_endpoints_security_group_id" {
  description = "Every app-layer SG needs an egress rule to this on 443 (ECR pull + log/secret delivery ride the task's own ENI in awsvpc mode)"
  value       = aws_security_group.vpc_endpoints.id
}

output "s3_prefix_list_id" {
  description = "S3 Gateway endpoint has no ENI/SG — reached via prefix list, not vpc_endpoints_security_group_id. Every task SG needs egress here on 443 too: ECR serves image layers from S3, ecr.dkr only handles manifest/auth (R1, policy/s3_egress.rego)."
  value       = aws_vpc_endpoint.s3.prefix_list_id
}

output "task_role_permissions_boundary_arn" {
  description = "Attach to every ECS/FIS/Lambda role's permissions_boundary argument. See iam-task-role-boundary.tf (R2 fix — the deploy role's CreateRole/PutRolePolicy grants require this boundary on every role they touch)."
  value       = aws_iam_policy.task_role_boundary.arn
}

output "ecs_cluster_id" {
  value = aws_ecs_cluster.platform.id
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.platform.name
}

output "fis_role_arn" {
  value = aws_iam_role.fis.arn
}

output "fis_log_group_arn" {
  value = aws_cloudwatch_log_group.fis.arn
}

output "prometheus_security_group_id" {
  description = "chaosforge/ and rpe/ each grant scrape ingress FROM this SG on their own services, in their own state (keeps the one-way foundation->child read direction)"
  value       = aws_security_group.prometheus.id
}

output "jwks_stub_security_group_id" {
  description = "rpe/ and chaosforge/ each add their OWN app-tier egress rule TO this SG on :80, in their own state (keeps the one-way foundation->child read direction, same as prometheus_security_group_id)"
  value       = aws_security_group.jwks_stub.id
}

output "jwks_stub_url" {
  description = "Value for rpe's /rpe/oauth/jwks-uri and chaosforge's /chaosforge/jwk-set-uri. Both systems keep their local-compose issuer and audience constants unchanged — only this URL drifts from local (LOCAL-PARITY.md). See foundation/jwks-stub.tf for why a single space in those parameters crashloops all six app services."
  value       = "http://jwks-stub.observability.internal/.well-known/jwks.json"
}

output "chaosforge_service_discovery_namespace_id" {
  value = aws_service_discovery_private_dns_namespace.chaosforge.id
}

output "rpe_service_discovery_namespace_id" {
  value = aws_service_discovery_private_dns_namespace.rpe.id
}
