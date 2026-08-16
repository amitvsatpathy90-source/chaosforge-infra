# Self-hosted-on-Fargate + EFS, not RDS/ElastiCache/MSK (Dev/Cost topology).
# One Postgres server, two databases (chaosforge_cp, chaosforge_exec) — compose parity.

locals {
  # All three — used for network (SG) rules. Every stateful service needs
  # its port reachable regardless of whether it persists to disk.
  chaosforge_stateful_services = {
    postgres = { port = 5432, sg_id = aws_security_group.postgres.id }
    redis    = { port = 6379, sg_id = aws_security_group.redis.id }
    redpanda = { port = 9092, sg_id = aws_security_group.redpanda.id }
  }

  # Apicurio not deployed not deployed in this stack.
  # Redis not EFS-backed (--save "", L2 cache, loss expected); opposite of rpe's Redis which keeps its volume.
  # This map drives all downstream EFS/SG/IAM resources — removing a service here removes it everywhere.
  chaosforge_efs_backed_services = {
    postgres = local.chaosforge_stateful_services.postgres
    redpanda = local.chaosforge_stateful_services.redpanda
  }
}

# Verified against real images: postgres:16.4-alpine uid 70:70 (Alpine, not Debian's 999);
# redpanda:v24.2.7 uid 101:101. Re-verify if either image tag changes.
variable "efs_posix_ids" {
  description = "POSIX uid/gid each EFS access point's root directory is created and chowned with — MUST match what the container image actually runs as. Verified against the images pinned above; re-verify on tag bump."
  type = map(object({
    uid = number
    gid = number
  }))
  default = {
    postgres = { uid = 70, gid = 70 }
    redpanda = { uid = 101, gid = 101 }
  }
}

resource "aws_efs_file_system" "data" {
  for_each       = local.chaosforge_efs_backed_services
  creation_token = "chaosforge-${each.key}"
  encrypted      = true # AWS-managed key (aws/elasticfilesystem) — a customer-managed CMK is the real-production upgrade, not needed at this scale
  tags           = { Name = "chaosforge-${each.key}" }
}

resource "aws_efs_access_point" "data" {
  for_each       = local.chaosforge_efs_backed_services
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

  tags = { Name = "chaosforge-${each.key}" }
}

locals {
  efs_mount_targets = {
    for pair in setproduct(keys(local.chaosforge_efs_backed_services), local.private_subnet_ids) :
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
  name_prefix = "chaosforge-efs-"
  vpc_id      = local.vpc_id
  description = "EFS mount targets for chaosforge's stateful containers' data directories (NFS, port 2049)."
}

# Keyed on the EFS-backed map, not the stateful map. Only a service that actually mounts a
# filesystem needs NFS reachability to it; keying these on `chaosforge_stateful_services` granted
# port 2049 to services with no volume at all (Apicurio, when it existed; Redis, until now).
resource "aws_vpc_security_group_ingress_rule" "efs_from_stateful_services" {
  for_each                     = local.chaosforge_efs_backed_services
  security_group_id            = aws_security_group.efs_mount_targets.id
  referenced_security_group_id = each.value.sg_id
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "stateful_services_to_efs" {
  for_each                     = local.chaosforge_efs_backed_services
  security_group_id            = each.value.sg_id
  referenced_security_group_id = aws_security_group.efs_mount_targets.id
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
}
