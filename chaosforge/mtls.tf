# EFS-hosted keystore/truststore (.p12) mounted at the file: path Spring's SSL bundle config
# expects. Cert generation NOT automated in Terraform — manual, one-time, per mtls-rules.md.

resource "aws_efs_file_system" "mtls_material" {
  creation_token = "chaosforge-mtls-material"
  encrypted      = true
  tags           = { Name = "chaosforge-mtls-material" }
}

resource "aws_efs_access_point" "mtls_material" {
  file_system_id = aws_efs_file_system.mtls_material.id

  posix_user {
    uid = 1001 # verified against chaosforge/docker/Dockerfile.{control-plane,edge-gateway,execution-service}: groupadd/useradd --system --uid 1001 --gid 1001 chaosforge, USER chaosforge. Re-verify if any Dockerfile's uid/gid changes.
    gid = 1001
  }

  root_directory {
    path = "/mtls"
    creation_info {
      owner_uid   = 1001
      owner_gid   = 1001
      permissions = "0555" # read + execute only — nothing should ever write here except the manual provisioning step
    }
  }

  tags = { Name = "chaosforge-mtls-material" }
}

locals {
  mtls_mount_target_subnets = local.private_subnet_ids
}

resource "aws_efs_mount_target" "mtls_material" {
  for_each        = toset(local.mtls_mount_target_subnets)
  file_system_id  = aws_efs_file_system.mtls_material.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs_mount_targets.id]
}

# Reuses the same EFS mount-target SG from data-layer.tf — it already
# allows 2049 from every chaosforge task SG that needs it; gateway/CP/exec
# are exactly the SGs that need mTLS material, and they're already covered
# by data-layer.tf's ingress rule set being keyed on the SAME SG object.
# No new SG needed here — just an egress rule from the three consuming
# services (data-layer.tf only wired the four DATA-layer SGs' egress to
# EFS, not gateway/CP/exec, since they weren't EFS consumers until now).
resource "aws_vpc_security_group_ingress_rule" "efs_from_mtls_consumers" {
  for_each = {
    edge_gateway      = aws_security_group.edge_gateway.id
    control_plane     = aws_security_group.control_plane.id
    execution_service = aws_security_group.execution_service.id
  }
  security_group_id            = aws_security_group.efs_mount_targets.id
  referenced_security_group_id = each.value
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "mtls_consumers_to_efs" {
  for_each = {
    edge_gateway      = aws_security_group.edge_gateway.id
    control_plane     = aws_security_group.control_plane.id
    execution_service = aws_security_group.execution_service.id
  }
  security_group_id            = each.value
  referenced_security_group_id = aws_security_group.efs_mount_targets.id
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
}
