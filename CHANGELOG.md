# Changelog — chaosforge-infra

Release history (newest first), then the module-by-module build history. Neither is current state:
for what the stack does and its live constraints, read the [`README.md`](README.md); for what each
root actually declares, read the `.tf` files. Tags are `vX.Y.Z-lab`: lab only, no production claims.

## Releases

### v1.1.0-lab — 2026-11-10

Cumulative since `v1.0.0-lab`.
Diff: https://github.com/amitvsatpathy90-source/chaosforge-infra/compare/v1.0.0-lab...v1.1.0-lab

#### Added

- Mocked-input Rego regression tests for both S3 egress policies; `policy-tests` CI job gating the per-root `validate`
  matrix (#13).
- `enable_fis` gating of FIS resources (default `true`); `github_immutable_subs` for immutable GitHub OIDC subjects
  (#8).
- Revision history in the apply-session and validation runbooks; Changelog tables on ADR-0401…0404.

#### Changed

- Terraform `1.15.8` and Conftest `0.69.0` aligned across local and CI (#5).
- Fargate scratch volume replaced with `linuxParameters.tmpfs` (#11).
- `SERVER_FORWARD_HEADERS_STRATEGY` applied only when `enable_alb=true` (#15).

#### Fixed

- RPE DB `currentSchema`; edge-gateway actuator scrape on `9080`; Redpanda settings for EFS/NFS; build platform for JWKS
  and observability images (#11).
- Runbook EFS ownership for `chaosforge-mtls-material` corrected to UID 1001 (#13); remaining uid 1000 reference in
  sharp edge #1 fixed.

#### Documentation

- Apply-session runbook records the first live AWS session (#11, #13, #17); ADR-0404 amended with runtime evidence.

#### Known limitations

- Per-service CPU/memory sizing unverified; ALB-enabled runtime not live-verified.
- Terraform plan/apply not run in CI; plan-based S3 egress policy covered by mocked input only.
- No backup, PITR or replication; destroy wipes EFS session data.

### v1.0.0-lab — 2026-08-16

Baseline: unified AWS infrastructure for the 3-service chaos engine and 4-service fraud-detection
engine (tag annotation). Offline-validated (`docs/VALIDATION.md`); no AWS apply executed.

## Build history (pre-`v1.0.0-lab`)

The modules below are the build sequence, not runtime components. Every one is complete.

| # | Module                         | Status |
|---|--------------------------------|--------|
| 1 | Foundation                     | Done   |
| 2 | Networking                     | Done   |
| 3 | Data layer                     | Done   |
| 4 | Compute                        | Done   |
| 5 | Secrets & IAM                  | Done   |
| 6 | Observability                  | Done   |
| 7 | CI/CD pipeline                 | Done   |
| 8 | Chaos wiring                   | Done   |
| 9 | Local-parity & cost guardrails | Done   |

## Deploy-role IAM growth, by module

`foundation/iam-deploy-policy.tf` started deliberately narrow (Budgets/Cost Explorer only) and each
module extended it. This ledger keeps the policy's shape reviewable in one place; the authoritative
grants are in the `.tf` file itself.

| Module                                 | Added to the deploy role                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
|----------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1 Foundation                           | `s3:*` on the state bucket only (correction — missing in the first pass), `budgets:*`, `ce:Get*`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| 2 Networking                           | `ec2:*Vpc*`, `ec2:*Subnet*`, `ec2:*SecurityGroup*`, `ec2:*RouteTable*`, `ec2:*InternetGateway*`, `ec2:*VpcEndpoint*`                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| 3 Data layer                           | `elasticfilesystem:*` (scoped actions — see iam-deploy-policy.tf). Originally guessed `rds:*`/`elasticache:*`; superseded once the real design (self-hosted-on-Fargate + EFS) landed                                                                                                                                                                                                                                                                                                                                                                                                     |
| 4 Compute                              | `ecs:*`, `ecr:*`, `servicediscovery:*`, `elasticloadbalancing:*`, scoped `logs:*`/`iam:*Role*` for task roles, plus NAT/EIP actions (`ec2:*NatGateway*`, `ec2:AllocateAddress`) that Module 2's original grant didn't anticipate — the NAT Gateway itself was added in Module 4, not 2                                                                                                                                                                                                                                                                                                   |
| 5 Secrets                              | `secretsmanager:*`/`ssm:*` (scoped actions) on the deploy role — caught mid-module: the deploy role had no create/write permission for the very secrets it needed to provision, only the execution roles had read access. `iam:PassRole` for the ECS task roles was already added in Module 4                                                                                                                                                                                                                                                                                            |
| 6 Observability                        | Nothing new — self-hosted-on-Fargate reuses Module 4/5's grants (`ecs`/`ecr`/`logs`/`servicediscovery`/`efs`/`ssm`). One fix: `observability-*` role names added to the `PassEcsRolesOnly` patterns (would have failed `iam:PassRole` at apply)                                                                                                                                                                                                                                                                                                                                          |
| 8 Chaos                                | `fis:` template CRUD (scoped actions — see iam-deploy-policy.tf); `platform-fis` added to the `PassEcsRolesOnly` ARNs (templates reference it via `role_arn`). The FIS experiment role's OWN ecs:StopTask grant is in `foundation/fis.tf`, not the deploy role. **Stop conditions:** `cloudwatch:PutMetricAlarm`/`DeleteAlarms` (scoped to `*-fis-steady-state-breach`) + unscopeable `DescribeAlarms`/`ListTagsForResource` on the deploy role; the FIS experiment role separately gets `cloudwatch:DescribeAlarms` in `foundation/fis.tf` so it can evaluate the condition at run time |
| 1 Foundation (correction, caught late) | `sns:CreateTopic`/`DeleteTopic`/`SetTopicAttributes`/tagging, scoped to the budget topic. The role could `sns:Subscribe` but never create the topic it subscribes to, nor set the access policy that lets AWS Budgets publish to it — so `foundation` was never appliable by this role                                                                                                                                                                                                                                                                                                   |
