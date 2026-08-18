# Same decision as chaosforge/data-layer.tf: self-hosted on Fargate, EFS-backed, RPE's compose
# images — not RDS/ElastiCache/MSK. No CNPG HA (k8s-only) (Single-instance dev topology).

locals {
  rpe_stateful_services = {
    postgres = { port = 5432, sg_id = aws_security_group.postgres.id }
    redis    = { port = 6379, sg_id = aws_security_group.redis.id }
    redpanda = { port = 9092, sg_id = aws_security_group.redpanda.id }
  }
}

# Verified against real images: postgres:16.3 uid 999:999, redis:7.2.5 uid 999:999,
# redpanda:v24.1.11 uid 101:101. Re-verify on tag bump. NOT shared with chaosforge's map
# (its Alpine postgres runs as uid 70, not 999).
variable "efs_posix_ids" {
  description = "POSIX uid/gid each EFS access point's root directory is created and chowned with — MUST match what the container image actually runs as. Verified against the images pinned above; re-verify on tag bump."
  type = map(object({
    uid = number
    gid = number
  }))
  default = {
    postgres = { uid = 999, gid = 999 }
    redis    = { uid = 999, gid = 999 }
    redpanda = { uid = 101, gid = 101 }
  }
}

resource "aws_efs_file_system" "data" {
  for_each       = local.rpe_stateful_services
  creation_token = "rpe-${each.key}"
  encrypted      = true
  tags           = { Name = "rpe-${each.key}" }
}

resource "aws_efs_access_point" "data" {
  for_each       = local.rpe_stateful_services
  file_system_id = aws_efs_file_system.data[each.key].id

  posix_user {
    uid = var.efs_posix_ids[each.key].uid
    gid = var.efs_posix_ids[each.key].gid
  }

  root_directory {
    path = "/${each.key}"
    creation_info {
      owner_uid   = var.efs_posix_ids[each.key].uid
      owner_gid   = var.efs_posix_ids[each.key].gid
      permissions = "0755"
    }
  }

  tags = { Name = "rpe-${each.key}" }
}

locals {
  efs_mount_targets = {
    for pair in setproduct(keys(local.rpe_stateful_services), local.private_subnet_ids) :
    "${pair[0]}-${pair[1]}" => { svc = pair[0], subnet_id = pair[1] }
  }
}

resource "aws_efs_mount_target" "data" {
  for_each        = local.efs_mount_targets
  file_system_id  = aws_efs_file_system.data[each.value.svc].id
  subnet_id       = each.value.subnet_id
  security_groups = [aws_security_group.efs_mount_targets.id]
}

resource "aws_security_group" "efs_mount_targets" {
  name_prefix = "rpe-efs-"
  vpc_id      = local.vpc_id
  description = "EFS mount targets for RPE stateful containers data directories (NFS, port 2049)."
}

resource "aws_vpc_security_group_ingress_rule" "efs_from_stateful_services" {
  for_each                     = local.rpe_stateful_services
  security_group_id            = aws_security_group.efs_mount_targets.id
  referenced_security_group_id = each.value.sg_id
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "stateful_services_to_efs" {
  for_each                     = local.rpe_stateful_services
  security_group_id            = each.value.sg_id
  referenced_security_group_id = aws_security_group.efs_mount_targets.id
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
}
