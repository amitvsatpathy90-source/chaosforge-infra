# Runbook — apply a session and prove the stack boots

**Status: derived from reading the code + README, NOT from a run.** No `terraform apply` has been
executed against this repo. Treat this as the plan to execute and the things to verify, not a
transcript. The two items most likely to bite on the first real run are called out inline
(`nfsvers`, AL2023 package presence, EFS ownership uids).

This runbook exists because the finding that produced ADR-0404 came from reading code, and reading
code is exactly what cannot prove a stack boots. The proof is here, at apply time.

Apply order is a hard invariant: **foundation → rpe → chaosforge** (ADR-0401). Destroy is always a
human action (cost-model.md rule 4).

---

## Phase 0 — Pre-flight (cheap checks that pre-empt the known crashloops)

Each is the concrete verification for a finding the arch-audit left GATED. ~1 minute each; each
saves a failed session.

**0a. Verify the 5 EFS POSIX uids** — wrong uid = `Permission denied` on the data dir → crashloop,
with no Terraform-time error (`rpe/data-layer.tf`, `chaosforge/data-layer.tf` both flag these as
unverified placeholders):

```bash
docker run --rm --entrypoint id postgres:16.3                 # rpe claims 999
docker run --rm --entrypoint id redis:7.2.5                   # rpe claims 999
docker run --rm --entrypoint id redpandadata/redpanda:v24.1.11 # rpe claims 101
docker run --rm --entrypoint id postgres:16.4-alpine          # chaosforge claims 999
docker run --rm --entrypoint id redpandadata/redpanda:v24.2.7  # chaosforge claims 101
```

Any mismatch → override that key via `-var 'efs_posix_ids={...}'` at apply. (chaosforge's *app*
tier is immune: it forces `user=1000:1000`; only the data tier trusts the image default.)

**0b. Confirm chaosforge's health-path auth** — RPE's `/actuator/health/readiness` is verified
`permitAll`; chaosforge's was not. If it isn't, the ALB target health check (ALB mode) fails:

```bash
grep -rn "permitAll\|/actuator/health" \
  ~/work/repos/chaosforge/edge-gateway/src/main/java/io/chaosforge/gateway/config/SecurityConfig.java
```

**0c. Confirm the mTLS SANs** (deviation #11, unverifiable from infra) — each service cert needs
`<svc>.chaosforge.internal` in its SAN list or mTLS hostname verification fails against Cloud Map
DNS. `generate-certs.sh` already emits these; confirm before trusting a pre-existing cert set:

```bash
grep -n "chaosforge.internal" ~/work/repos/chaosforge/docker/mtls/generate-certs.sh
```

---

## Phase 1 — State backend + foundation

```bash
# bootstrap — only if the state bucket does not exist yet
cd bootstrap && terraform init && terraform apply
# → note state_bucket_name; put bucket + region in each root's backend.hcl

# foundation — apply with an ADMIN identity, NOT the CI deploy role.
# (Module 1 audit HIGH: the deploy role cannot create its own permissions-boundary policy or the
#  OIDC provider — a real, unfixed gap. Admin sidesteps it for the session.)
cd ../foundation
terraform init -backend-config=backend.hcl
terraform apply \
  -var 'budget_alert_email=<you@example.com>' \
  -var 'github_repositories=["<org>/chaosforge","<org>/revenue-protection-engine"]'
# desired counts stay 0 — creates infra + all foundation ECR repos, no compute spend.
```

---

## Phase 2 — Build + push the foundation-owned images

```bash
ACCOUNT=<your-account-id>

# JWKS stub (ADR-0404). Keys first, then merge + push.
~/work/repos/revenue-protection-engine/deploy/oauth/generate-jwks.sh   # rpe-lab-1 keypair
~/work/repos/chaosforge/docker/jwks/generate-jwks.sh                    # chaosforge-lab-1 keypair
jwks-stub/build-push.sh $ACCOUNT              # merges PUBLIC sets; refuses a private component

observability/build-push.sh $ACCOUNT          # prometheus + grafana derived images
```

---

## Phase 3 — rpe, then chaosforge

```bash
BUCKET=<state-bucket-name>

# rpe FIRST — chaosforge consumes its detection SG id.
cd ../rpe
terraform init -backend-config=backend.hcl
terraform apply -var "state_bucket_name=$BUCKET" -var 'image_tag=<12-char-sha>'
# → grab detection_security_group_id from the output.

# push rpe images: mirrors (README "One-time image pushes") + the 4 app images (rpe CI on main,
# or built+pushed manually to the IMMUTABLE repos at that SHA).

# chaosforge — needs rpe's SG id + the mTLS passwords the certs were generated with (Phase 4).
cd ../chaosforge
terraform init -backend-config=backend.hcl
terraform apply \
  -var "state_bucket_name=$BUCKET" \
  -var "rpe_detection_security_group_id=<from rpe output>" \
  -var 'image_tag=<12-char-sha>' \
  -var 'gateway_ingress_cidr=<your-ip>/32' \
  -var 'mtls_keystore_password=<KS>' -var 'mtls_truststore_password=<TS>'
# push chaosforge images: derived postgres (bakes init-databases.sql) + mirrors + 3 app images.
```

Images must exist in ECR before the desired-count bump (Phase 5), not before apply — the task defs
reference tags, but nothing pulls them until a task launches.

---

## Phase 4 — mTLS material onto EFS

EFS is VPC-only, and **ECS Exec is unavailable in this stack** — it needs an `ssmmessages` VPC
endpoint, and foundation provisions only `ecr.api`/`ecr.dkr`/`logs`/`ssm`. So population happens
from a throwaway EC2 mount helper inside the VPC.

### What goes where (disjoint sets — the CA signing key never leaves your host)

`generate-certs.sh` writes to `chaosforge/docker/mtls/certs/`.

| EFS (access-point path, forced uid) | Files | Consumed by |
|---|---|---|
| `chaosforge-mtls-material` (`/mtls`, uid 1000) | `edge-gateway-keystore.p12`, `control-plane-keystore.p12`, `execution-service-keystore.p12`, `truststore.p12` | gateway/CP/exec at `/mnt/mtls/…` |
| `observability-mtls` (`/obs-mtls`, uid 65534) | `prometheus-cert.pem`, `prometheus-key.pem`, `ca-cert.pem` | prometheus at `/mnt/mtls/…` |

**Never upload** `ca-key.pem` (CA private key — "never leaves this host") or the per-service
`*-key.pem` (already sealed in the `.p12`).

### Why no EFS rule change is needed

Attach to the helper the two SGs already permitted to mount each volume — `control_plane` SG
(`chaosforge-mtls` ingress) and `prometheus` SG (`observability-mtls` ingress) — plus one throwaway
SSH SG scoped to your IP. Direct NFS mount (not via the access point) needs no instance profile and
avoids the R2 task-role boundary, which blocks the `s3:GetObject` a Fargate-based helper would need.

### Steps

```bash
REGION=us-east-1
INFRA=~/work/repos/chaosforge-infra

# 0. Generate certs locally with the SAME passwords passed to chaosforge in Phase 3
cd ~/work/repos/chaosforge
MTLS_KEYSTORE_PASSWORD=<KS> MTLS_TRUSTSTORE_PASSWORD=<TS> ./docker/mtls/generate-certs.sh

# 1. Resolve ids
CF_FS=$(aws efs describe-file-systems --region $REGION \
  --query "FileSystems[?Tags[?Key=='Name'&&Value=='chaosforge-mtls-material']].FileSystemId" --output text)
OBS_FS=$(aws efs describe-file-systems --region $REGION \
  --query "FileSystems[?Tags[?Key=='Name'&&Value=='observability-mtls']].FileSystemId" --output text)
VPC=$(cd $INFRA/foundation && terraform output -raw vpc_id)
SUBNET=$(cd $INFRA/foundation && terraform output -json public_subnet_ids | jq -r '.[0]')
PROM_SG=$(cd $INFRA/foundation && terraform output -raw prometheus_security_group_id)
CP_SG=$(cd $INFRA/chaosforge && terraform output -raw control_plane_security_group_id)
AMI=$(aws ssm get-parameter --region $REGION \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)

# 2. Throwaway SSH SG + t3.micro in the public subnet with 3 SGs
SSH_SG=$(aws ec2 create-security-group --vpc-id $VPC --group-name mtls-helper --description tmp --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id $SSH_SG --protocol tcp --port 22 --cidr <your-ip>/32
EC2=$(aws ec2 run-instances --image-id $AMI --instance-type t3.micro --key-name <your-keypair> \
  --subnet-id $SUBNET --security-group-ids $CP_SG $PROM_SG $SSH_SG --associate-public-ip-address \
  --query 'Instances[0].InstanceId' --output text)
IP=$(aws ec2 describe-instances --instance-ids $EC2 --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

# 3. Copy the two disjoint sets up (never ca-key.pem)
cd docker/mtls/certs
scp edge-gateway-keystore.p12 control-plane-keystore.p12 execution-service-keystore.p12 truststore.p12 ec2-user@$IP:/tmp/
scp prometheus-cert.pem prometheus-key.pem ca-cert.pem ec2-user@$IP:/tmp/

# 4. Mount each fs ROOT, place files under the access-point path, stamp ownership
ssh ec2-user@$IP <<EOF
  sudo mkdir -p /mnt/cf /mnt/obs
  sudo mount -t nfs4 -o nfsvers=4.1 $CF_FS.efs.$REGION.amazonaws.com:/  /mnt/cf
  sudo mount -t nfs4 -o nfsvers=4.1 $OBS_FS.efs.$REGION.amazonaws.com:/ /mnt/obs
  sudo mkdir -p /mnt/cf/mtls /mnt/obs/obs-mtls
  sudo cp /tmp/*-keystore.p12 /tmp/truststore.p12 /mnt/cf/mtls/
  sudo cp /tmp/prometheus-*.pem /tmp/ca-cert.pem   /mnt/obs/obs-mtls/
  sudo chown -R 1000:1000  /mnt/cf/mtls
  sudo chown -R 65534:65534 /mnt/obs/obs-mtls
  sudo chmod 0555 /mnt/cf/mtls /mnt/obs/obs-mtls
  ls -ln /mnt/cf/mtls /mnt/obs/obs-mtls    # VERIFY: 4 files @1000, 3 files @65534
  sudo umount /mnt/cf /mnt/obs
  rm -f /tmp/*.p12 /tmp/*.pem
EOF

# 5. Tear down the helper (zero residue)
aws ec2 terminate-instances --instance-ids $EC2
aws ec2 delete-security-group --group-id $SSH_SG   # after the instance is fully terminated
```

### Sharp edges

1. **Ownership must be uid 1000 / 65534.** Files land on the fs root (not via the access point), so
   ownership isn't auto-stamped — hence the explicit `chown`. `ls -ln` is the checkpoint. Wrong uid
   surfaces later as `keystore … cannot be opened` (app) or a prometheus cert-read error.
2. **Passwords must match Phase 3.** `generate-certs.sh` bakes `MTLS_*_PASSWORD` into the `.p12`;
   they must be byte-identical to the `-var mtls_*_password` values or the keystore silently won't
   open (`chaosforge/secrets.tf` warns of this).
3. **Reasoned, not run:** `nfsvers=4.1` and AL2023 shipping `nfs-utils` are the two things to
   confirm live on the first attempt.

### Alternative (no EC2)

Add a temporary `ssmmessages` interface endpoint (attach to the `vpc_endpoints` SG), run a
throwaway Fargate task with `enableExecuteCommand`, the `chaosforge-app-task` role (already holds
`ClientMount/ClientWrite`), and the `control_plane` SG, mounting the access point at `/mnt/mtls`.
`aws ecs execute-command` in and `base64 -d` each small file — the access point auto-stamps uid
1000, so no chown. More moving parts; reach for it only if EC2 access is inconvenient.

---

## Phase 5 — Bring the session up

```bash
# Raise desired counts and re-apply. jwks_stub_desired_count=1 is what makes tokens VALIDATE
# (ADR-0404) — at 0 the app tiers still boot and 401 (fail-closed), not crashloop.
cd ../foundation && terraform apply -var 'jwks_stub_desired_count=1' -var 'observability_desired_count=1' <foundation vars…>
cd ../rpe        && terraform apply -var 'desired_count=1' <rpe vars…>
cd ../chaosforge && terraform apply -var 'desired_count=1' <chaosforge vars…>
```

---

## Phase 6 — Watch it settle (where ADR-0404's fix is proven)

```bash
aws logs tail /platform/jwks-stub --follow --since 5m
for s in detection relay alert triage; do aws logs tail /rpe/$s --since 5m & done
for s in edge-gateway control-plane execution-service; do aws logs tail /chaosforge/$s --since 5m & done
```

**Confirms the crashloop is gone:**
- **Absent:** `IllegalArgumentException` / `jwkSetUri cannot be empty` / any `hasText` failure at
  startup. Its presence means the SSM value didn't take.
- **Present:** Spring context refresh completes; `/actuator/health/readiness` returns UP.
- **Token validation working** = a Prometheus scrape of `/actuator/prometheus` returns 200 (needs
  the real scrape token baked, deviation #18) rather than 401.

| Log signature | Cause | Phase-0 check |
|---|---|---|
| `Permission denied` / `could not access directory ".../pgdata"` | wrong `efs_posix_ids` uid | 0a |
| `IllegalArgumentException: jwkSetUri cannot be empty` | SSM value still `" "` (fix didn't apply) | — (must be absent) |
| repeated 401 on inter-service calls | stub down, or issuer/aud mismatch | `jwks_stub_desired_count=1` |
| `keystore ... cannot be opened` | mTLS password mismatch, or wrong EFS uid | Phase 4 sharp edges |
| mTLS `No subject alternative DNS name matching …` | cert SANs missing | 0c |
| ALB target unhealthy (ALB mode only) | `/actuator/health` not `permitAll` | 0b |

---

## Phase 7 — Teardown (the cost contract)

```bash
# reverse order; destroy is always a human action (never automated — cost-model.md rule 4)
cd chaosforge  && terraform destroy <vars…>
cd ../rpe       && terraform destroy <vars…>
cd ../foundation && terraform destroy <vars…>
# survives by design: S3 state (pennies), ECR images (~$1/mo). EFS is wiped — no data is durable.
```

---

## Weakest links (verify live, first run)

- **Phase 3 app-image push** — the task defs need images at a real SHA in the IMMUTABLE repos; CI's
  job on main, or a manual build.
- **Phase 4 EFS population** — `nfsvers`, AL2023 packages, and the ownership uids are reasoned from
  the SG rules and `generate-certs.sh`, not run.
- **Task sizing** — every CPU/memory value in `{rpe,chaosforge}/ecs-task-definitions.tf` is reasoned,
  not load-verified (their own headers say so). During Phase 6, record per-service CloudWatch
  CPU/memory utilization and note the numbers against the task-def comments — that recording, not a
  checkbox, is what closes the "reasoned" caveat (verification.md rule 7).
- **Nothing here is proven until it runs.** That is the point of the runbook.
