output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "edge_gateway_security_group_id" {
  value = aws_security_group.edge_gateway.id
}

output "control_plane_security_group_id" {
  value = aws_security_group.control_plane.id
}

output "execution_service_security_group_id" {
  description = "Informational. NOT read by rpe/ — that reverse remote-state read created a bootstrap cycle and was removed; both halves of the cross-system probe rule live in this root."
  value       = aws_security_group.execution_service.id
}

output "postgres_security_group_id" {
  value = aws_security_group.postgres.id
}

output "redis_security_group_id" {
  value = aws_security_group.redis.id
}

output "redpanda_security_group_id" {
  value = aws_security_group.redpanda.id
}

output "efs_file_system_ids" {
  description = "Keyed by service name (postgres/redpanda) — the task definitions mount these. Redis is cache-only and has no volume; see data-layer.tf"
  value       = { for k, v in aws_efs_file_system.data : k => v.id }
}

output "efs_access_point_ids" {
  description = "Keyed by service name — use the access point, not the raw file system, in Module 4's volume config (enforces the POSIX root-directory scoping)"
  value       = { for k, v in aws_efs_access_point.data : k => v.id }
}
