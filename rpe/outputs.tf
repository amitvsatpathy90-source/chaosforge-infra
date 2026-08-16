output "detection_security_group_id" {
  value = aws_security_group.detection.id
}

output "relay_security_group_id" {
  value = aws_security_group.relay.id
}

output "alert_security_group_id" {
  value = aws_security_group.alert.id
}

output "triage_security_group_id" {
  value = aws_security_group.triage.id
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
  description = "Keyed by service name (postgres/redis/redpanda) — Module 4's task definitions mount these"
  value       = { for k, v in aws_efs_file_system.data : k => v.id }
}

output "efs_access_point_ids" {
  description = "Keyed by service name — use the access point, not the raw file system, in Module 4's volume config"
  value       = { for k, v in aws_efs_access_point.data : k => v.id }
}
