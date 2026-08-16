# ChaosForge-Infra

Terraform for the AWS deployment of [chaosforge](../chaosforge) (chaos engineering control plane)
and [revenue-protection-engine](../revenue-protection-engine) (its target system under test).

On-demand posture: this account is meant to sit near $0 between sessions. Bring the stack up for a
demo/benchmark run, tear it down after. See `foundation/budgets.tf` for the cost circuit breaker.

## Architecture Decision Records

The project's architectural decisions are maintained in [`docs/adrs/`](docs/adrs/).

**ADR index:** [`docs/adrs/README.md`](docs/adrs/README.md)

The index is the single source of truth for the ADR catalogue. Individual ADRs contain the decision
context, alternatives, consequences, and references.

## Layout

```
bootstrap/    one-time, local state — creates the S3 bucket everything else uses as a backend
foundation/   VPC-independent account baseline: IAM OIDC deploy role, budget/cost alarm
chaosforge/   chaosforge's AWS resources (own state file)
rpe/          revenue-protection-engine's AWS resources (own state file)
```

Each of `foundation/`, `chaosforge/`, `rpe/` is an independent Terraform root with its own state
file — a bad `apply` in one can't corrupt another. `chaosforge/` and `rpe/` read `foundation/`'s
outputs via `terraform_remote_state`, never write to it.

**Apply order is `foundation` → `rpe` → `chaosforge`, not alphabetical, and not arbitrary.** The
ChaosForge→RPE steady-state-probe security group rule is one relationship, and **both halves are
declared in `chaosforge/security-groups.tf`** — the egress on chaosforge's execution-service SG, and
the ingress on RPE's detection SG (attached by id). `chaosforge/` takes RPE's detection SG ID as a
**plain variable**; `rpe/` reads nothing from `chaosforge/`'s state. The dependency is therefore
strictly one-way (`chaosforge/` → `rpe/`), which is why `rpe/` must exist and have been applied at
least once before `chaosforge/` can apply.

An earlier design split the pair across the two states — `rpe/` read chaosforge's execution-service
SG ID via `terraform_remote_state`, while `chaosforge/` consumed rpe's output — which made the two
roots mutually dependent and left **no valid first-apply order from clean state**. Using a plain
variable on one side did not, by itself, break that cycle; removing the reverse remote-state read
did.

## Before you apply anything

Run the offline validation pass first: [`docs/VALIDATION.md`](docs/VALIDATION.md). It's credential-free,
resource-free, $0, and machine-checks the hand-written Terraform (which was never run through
`terraform validate` during the build) plus the one Java file that was never compiled. Do this before
the first-time setup below.

For a full session — pre-flight checks, apply order, mTLS/EFS provisioning, and the log signatures
that confirm the stack booted — follow [`docs/runbooks/apply-session.md`](docs/runbooks/apply-session.md).

## First-time setup

```bash
cd bootstrap
terraform init
terraform apply                       # creates the state bucket; state stays LOCAL, on purpose
terraform output state_bucket_name    # copy this value

cd ../foundation
terraform init -backend-config=<(echo "bucket = \"<state-bucket-name>\"") -backend-config=<(echo "region = \"us-east-1\"")
# or: cp backend.hcl.example backend.hcl, fill it in, then `terraform init -backend-config=backend.hcl`
cp terraform.tfvars.example terraform.tfvars   # fill in your email + GitHub repo(s)
terraform plan
terraform apply

cd ../rpe
cp backend.hcl.example backend.hcl             # fill in the same bucket name
cp terraform.tfvars.example terraform.tfvars   # fill in state_bucket_name
terraform init -backend-config=backend.hcl
terraform apply
terraform output detection_security_group_id   # copy this value

cd ../chaosforge
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars   # fill in state_bucket_name + rpe_detection_security_group_id
terraform init -backend-config=backend.hcl
terraform apply
```

### One-time image pushes (after first apply — the repos must exist first)

The task definitions pull ONLY from private ECR (through the VPC endpoints — there is no NAT by
default, so a task literally cannot reach Docker Hub). Populate the mirrors once per image-version
bump; app images are Module 7's CI job:

```bash
aws ecr get-login-password | docker login --username AWS --password-stdin <account>.dkr.ecr.us-east-1.amazonaws.com

# chaosforge postgres is a DERIVED image, not a plain mirror — it bakes in the same
# init-databases.sql that docker-compose mounts (creates chaosforge_cp + chaosforge_exec).
# Without it, CP/Exec crashloop on "database does not exist" (Module 5.5 audit fix).
cd ~/work/repos/chaosforge
printf 'FROM postgres:16.4-alpine\nCOPY docker/postgres/init-databases.sql /docker-entrypoint-initdb.d/\n' \
  | docker build -t <account>.dkr.ecr.us-east-1.amazonaws.com/chaosforge/mirror/postgres:16.4-alpine-cf1 -f - .
docker push <account>.dkr.ecr.us-east-1.amazonaws.com/chaosforge/mirror/postgres:16.4-alpine-cf1

# Plain mirrors (pull, tag, push) — versions match each repo's compose file exactly:
#   chaosforge: redis:7.4-alpine  redpandadata/redpanda:v24.2.7
#   rpe:        postgres:16.3     redis:7.2.5                    redpandadata/redpanda:v24.1.11
```

### mTLS material (chaosforge + observability)

Regenerate certs — the SAN list now includes `<svc>.chaosforge.internal` (fixed in
`generate-certs.sh` during Module 5.5; certs generated before that fix FAIL hostname verification
against Cloud Map DNS) — then copy the `.p12` files onto the `chaosforge-mtls-material` EFS volume
(one-time; e.g. a temporary Fargate task or an EC2 mount helper). Pass the same passwords to
terraform via `mtls_keystore_password`/`mtls_truststore_password`.

The same script now also emits a `prometheus` client identity as PEM (Module 6) — copy
`prometheus-cert.pem`, `prometheus-key.pem`, and `ca-cert.pem` onto the `observability-mtls` EFS
volume so Prometheus can scrape CP/Exec through their mandatory client-cert TLS.

### Lab JWKS stub (both systems — ADR-0404)

The shared IdP stub (`foundation/jwks-stub.tf`) serves one merged JWK Set so both systems' JWT
decoders can validate tokens. Generate each repo's key material once, then build + push the merged
image after the first foundation apply:

```bash
~/work/repos/revenue-protection-engine/deploy/oauth/generate-jwks.sh   # writes the rpe-lab-1 keypair
~/work/repos/chaosforge/docker/jwks/generate-jwks.sh                    # writes the chaosforge-lab-1 keypair
jwks-stub/build-push.sh <account-id>                                    # merges both PUBLIC sets, pushes to ECR
```

Only public key material is ever merged — each repo's signing key stays in its git-ignored `keys/`
directory, and the build refuses to ship a set containing a private component. A session that needs
tokens to actually validate raises `jwks_stub_desired_count=1` in `foundation/` alongside the app
tiers; at `0` the app services still boot and 401 every token (fail-closed) — the crashloop only
occurred with the old blank value, not with the stub down.

### Observability (Module 6)

One shared Prometheus + Grafana for both systems (`foundation/observability.tf`), running derived
images of **chaosforge's** pinned versions (prometheus v2.55.1, grafana 11.3.0 — see
`observability/build-push.sh`). rpe's compose pins differ (prometheus v2.52.0, grafana 10.4.3) and
are **not** what AWS runs; the scrape jobs, alert rules (chaosforge's C26/C27 gates + rpe's ADR-23
DLT rules), and the SLI dashboard carry over unmodified. Build the images with
`observability/build-push.sh <account-id>` after the first foundation apply.
Session use: `terraform apply -var observability_desired_count=1` in `foundation/`, then open
`http://<grafana-task-public-ip>:3000` (find the IP in the ECS console; admin password is in SSM
at `/observability/grafana-admin-password`). Anonymous access is off — unlike local — because
this Grafana has a public IP. Managed alternatives were rejected on cost: AMG alone bills
$9/user/month, more than this whole stack's idle total.

## Chaos experiments (Module 8)

This is a brief overview of the chaos experiment this project was built for. ChaosForge's execution 
engine is an HTTP fault injector, but RPE has no business HTTP surface — its real failure modes are
infrastructure-level. So the two layers run together in a game day:

- **AWS FIS** (`rpe/fis.tf`, `chaosforge/fis.tf`) injects the infra fault — `aws:ecs:stop-task` on
  Redis / Postgres / Redpanda / relay / a mid-run service. Each template's description names the
  exact ADR/acceptance-gate claim it tests (e.g. kill-redpanda ⇒ ADR-26 asyncAcks watermark +
  UUIDv5 dedup absorb the redelivery).
- **Every template has a CloudWatch-alarm stop condition** — the abort path. Each stack alarms on the
  one service its experiments assert must stay healthy (`rpe-detection`, `chaosforge-control-plane`);
  `treat_missing_data = "breaching"` means the alarm also fires if that service stops reporting
  entirely, i.e. the blast radius escaped. It is a coarse guard, not an SLO guard: the real SLIs live
  in Prometheus, which CloudWatch cannot see. **Consequence: bring the stack up before starting an
  experiment** — FIS refuses to start when the stop-condition alarm is already in `ALARM`, which it is
  whenever `desired_count = 0`.
- **A ChaosForge scenario** simultaneously probes RPE's `/actuator/health/readiness` as the
  steady-state hypothesis (C20) — the network path Module 2 opened.
- **The Module 6 Grafana** is where you watch the documented degradation and recovery happen live.

Run one: `aws fis start-experiment --experiment-template-id <id>` (ids in `terraform output
fis_experiment_template_ids`). Cost: templates free, ~$0.10/action-minute while running — a
10-experiment game day ≈ $1.

This makes chaosforge's **C31 game day executable**: its runbook (`docs/runbooks/game-day-c31.md`)
was "procedure ready, run pending" for lack of a target environment. These templates + the deployed
stack are that environment. Closing C31 still requires *running* the runbook and attesting "no
manual data-repair writes" — an operational exercise, which this can't do for you; it removes the
missing-environment blocker, nothing more.

## CI/CD (Module 7)

Three workflows, one per repo, each owning what that repo owns:

- **chaosforge `ci.yml`** — `./gradlew check` on every push/PR (this carries C29's
  `avroSchemaCompatibilityCheck`, so a FULL_TRANSITIVE schema break fails CI); on main, builds the
  three service images (new `docker/Dockerfile.<service>` files — the repo had none; local dev is
  `bootRun`) and pushes `:<12-char-sha>` to ECR via OIDC.
- **rpe `ci.yml`** — matrix `mvn -f <svc>/pom.xml verify` (four independent builds, matching
  ADR-17 §3.5's no-reactor-aggregation rule); on main, builds/pushes the four images using each
  service's existing self-contained Dockerfile.
- **infra `terraform.yml`** — `fmt -check` + `terraform validate` on all four roots. **No plan or
  apply in CI, deliberately**: apply-on-merge would create billable infrastructure unprompted
  (anti-goal of the cost model), and plan would need tfvars secrets duplicated into GitHub for a
  one-operator lab whose applies happen locally. The upgrade path is documented in the workflow.

Setup: each app repo needs two Actions **variables** (not secrets — they aren't):
`AWS_DEPLOY_ROLE_ARN` (foundation's output) and `AWS_REGION`. No AWS keys anywhere.

`avroSchemaRegister` (the Apicurio registration task) runs only against the **local compose**
Apicurio. There is no Apicurio in this AWS deployment at all — nothing at runtime reads a registry
(CP/Exec frame Avro with local codecs), so deploying one bought a Fargate task per session and zero
function. See "Known deviations". The C29 compatibility gate — the control that matters — runs
registry-free in CI.

## Cost model (Module 5.5 — the "no idle cost" contract)

Running everything (all 13 services, both systems) costs **~$0.30/hour** of Fargate. Idle cost is
the enemy, and the defaults now hold it near zero:

| Lever | Default | Idle cost | Session cost |
|---|---|---|---|
| ECS services | `desired_count = 0` | $0 | ~$0.30/hr all-up |
| Observability (Prometheus + Grafana) | `observability_desired_count = 0` | $0 (+$0.50/mo Cloud Map zone while applied) | +~$0.03/hr |
| Lab JWKS stub (both systems' JWT decoders) | `jwks_stub_desired_count = 0` | $0 (reuses the observability Cloud Map zone) | +~$0.02/hr; raise to 1 so tokens validate (ADR-0404) |
| NAT Gateway | `enable_nat_gateway = false` | $0 | +~$0.05/hr if enabled (only for real OpenAI triage) |
| ALB | `enable_alb = false` (gateway gets a session public IP, scoped to `gateway_ingress_cidr`) | $0 | +~$0.03/hr if enabled; requires a free ACM cert |
| Secrets | SSM SecureString (was Secrets Manager) | $0 | $0 |
| VPC interface endpoints (4, single-AZ) | exist while applied | ~$29/mo if left standing | ~$0.03/hr |
| EFS, Cloud Map zones, ECR storage | exist while applied | ~$2-3/mo | same |
| AWS FIS experiments | templates free; 2 stop-condition alarms | ~$0.20/mo (the alarms) | $0.10/action-min while running (~$1/game day) |

**Automated backstop (Module 9):** the $25 budget's SNS topic drives a Lambda (`enable_budget_teardown`,
default on) that scales every ECS service to 0 on a threshold breach — the safe, bounded circuit
breaker Module 1 promised. It stops the Fargate burn (the only thing that climbs the bill post-5.5)
without touching Terraform state; `terraform destroy` stays a human action. Idempotent, ~$0 to keep
armed.

**Local parity (Module 9):** the whole AWS effort changed **zero `application*.yml` files** — see
[LOCAL-PARITY.md](LOCAL-PARITY.md) for the full ledger of what was touched in each app repo and why
every change is additive. Local `docker compose` / `bootRun` behavior is byte-identical to before.

**The workflow that makes it $0: session = `terraform apply` → demo → `terraform destroy`** (in
`chaosforge/` + `rpe/`; `foundation/` can stay — its residents are free-tier: IAM, budget, empty
cluster, the VPC itself. Destroy foundation too for true zero). What survives destroy and its cost:
S3 state (pennies), ECR images (~$1/mo past the free tier). Module 3's no-RDS/no-MSK decision is
what makes this viable — the whole stack re-creates in minutes, not tens of minutes. Note
`terraform destroy` of EFS wipes session data by design; every session starts with a fresh
Postgres first-init (which is also what makes DB bootstrap automatic).

## Known deviations from local/k8s topology

Findings from an arch analysis, kept here instead of buried in a module's file comments so
they're visible without reading every `.tf` file:

- **RPE's HA Postgres (CNPG, 2-instance cluster) does not exist in this AWS deployment.** CNPG is a
  Kubernetes operator; Module 2's kickoff session chose ECS Fargate over EKS specifically to avoid
  the ~$73/mo control-plane fee for an on-demand lab workload. `rpe/data-layer.tf` runs a single
  self-hosted Postgres instance instead — the per-service schema/role structure (ADR-17 §5.2/§5.3)
  carries over, the HA guarantee does not. Acceptable under "lab benchmarks only," called out
  explicitly so it's a decision, not a silent gap.
- **The database and broker data directories sit on EFS (NFS).** Both stacks mount an EFS access
  point as the container's *data directory*: Postgres `PGDATA` (`/var/lib/postgresql/data`),
  Redpanda's log dir (`/var/lib/redpanda/data`), and Redis `/data`. That is what makes a mid-session
  Fargate task restart non-destructive, and it is what makes Module 3's no-RDS/no-MSK decision
  viable. It was never disclosed, and it carries three consequences:
  - **Write throughput is not a property of this code.** Every Postgres commit fsyncs WAL, and every
    EFS operation is a network round trip (~ms) against sub-ms for EBS or local NVMe. Any write-path
    number measured here says more about NFS than about the system. `performance_mode` and
    `throughput_mode` are left at AWS's defaults. Benchmarks belong on the local compose stack.
  - **PostgreSQL on NFS is a documented caveat, not a supported configuration.** PG's own docs
    require the filesystem to honour write ordering and locking. EFS implements NFSv4.1 locking, so
    Postgres's `postmaster.pid` guard should hold — Redpanda's log directory offers no equivalent
    guarantee, and neither engine should be *relied* on to catch a second writer.
  - **The two-writer window is closed, deliberately.** ECS's service defaults (min 100% / max 200%)
    start a replacement task before draining the old one — which on a task-definition change would
    briefly run two processes against the same data directory. The stateful services now pin
    `deployment_minimum_healthy_percent = 0` / `deployment_maximum_percent = 100` (stop-then-start),
    trading seconds of downtime for the absence of that window. Correct precisely because every one
    of these services is single-instance by design.

  There are no backups, no PITR, and no replication; `terraform destroy` of EFS wipes session data
  by design. The production path is RDS Multi-AZ plus a real Kafka, which the cost model forbids.
  This is a decision, not an oversight — but the decision means **no data in this deployment is
  durable**, and nothing here should be pointed at data you care about.
- **Resolved: chaosforge's Redis has no EFS volume.** Its command is `--save ""` with no
  `--appendonly`, so it never persists a byte — the volume was a filesystem nothing wrote to, plus an
  access point, mount targets, NFS security-group rules, and IAM grants for zero bytes. Correct for
  what it is: the L2 cache (ADR-0504), whose loss on restart is the documented design. Removing it
  also corrected the NFS rules, which were keyed on *all* stateful services rather than only the
  EFS-backed ones. RPE's Redis is `--appendonly yes` and keeps its volume — the two are not symmetric.
- **Resolved: ChaosForge's steady-state probe path mismatch.** `chaosforge.steady-state.health-path`
  defaults to `/health`; RPE's real path is `/actuator/health/readiness`. The execution-service task
  definition sets `CHAOSFORGE_STEADYSTATE_HEALTHPATH` to the latter (deployment-wide — the `@Value` is
  a single global, and RPE is the sole target here). No `application.yml` was modified.
- **Blast-radius ceiling for the fault injector.** Under the `mtls` profile the executor blocks
  private-network targets by default while its allowlist is empty, which would reject RPE itself
  (`STEP_FAILED`). The execution-service task definition pins `TARGET_ALLOWED_HOSTS` to
  `detection.rpe.internal` — a non-empty allowlist is the guard's sole ceiling, so that host is the
  complete set of things this deployment may inject faults into.
- **Resolved, Module 4: Ollama is deliberately NOT deployed to AWS.** Ollama is already opt-in even
  in local dev (`docker-compose_chaosforge.yml`: "INTENTIONALLY excluded from the 2 GB budget... Run
  it host-local, or opt in with `--profile ai`") and needs real GPU/multi-GB sizing Fargate doesn't
  offer cleanly. CP's AI-authoring feature is unavailable in this AWS deployment as a result — not a
  gap, a scope decision. Revisit only if AI authoring needs to work in AWS: the realistic path is
  pointing CP at a hosted LLM API (config change, mirroring how RPE's triage agent already does this),
  not standing up Ollama on Fargate.
- **Resolved, Module 4: RPE triage-agent's LLM egress.** Verified against `application.yml`, not
  assumed — it calls OpenAI's hosted API (`spring.ai.openai`, model `gpt-4o-mini`), not a self-hosted
  model. NAT Gateway (added this module, see below) plus a `triage`-only egress rule to 443/0.0.0.0/0
  in `rpe/security-groups.tf` resolves it — no other RPE service gets general internet egress.
- **NAT Gateway added in Module 4, reversing Module 2's "no NAT" call.** The data-layer containers
  pull public Docker Hub/Quay images; there's no PrivateLink endpoint for that, so a NAT Gateway turned
  out to be required, not optional. Single-AZ. VPC endpoints stay (they keep ECR/logs/secrets traffic
  off the NAT's per-GB charge).
- **Bug caught and fixed, Module 4: RPE's Redis security group was wrong.** The architecture doc's
  "Redis owns ALL hot-path logic" framing was read as detection-only in Module 2. Verified against
  source before wiring the ECS network config: `rpe-triage-agent` also uses Redis (`TriageTools.java`,
  `TriagedVerdictPublisher.java` — agent tool lookups). Fixed in `rpe/security-groups.tf` before it
  became a runtime connectivity failure.
- **Resolved in the app repo since: CP's Kafka bootstrap-servers was hardcoded.**
  `control-plane/application.yml` originally set `spring.kafka.bootstrap-servers: localhost:9092` as
  a literal, with no `${VAR:default}` placeholder — flagged here, since fixed in chaosforge (now
  `${KAFKA_BOOTSTRAP:localhost:9092}`, the same var the exec service reads). The task definition's
  `SPRING_KAFKA_BOOTSTRAP_SERVERS` override predates the fix and still works (Spring Boot's
  environment property source outranks `application.yml` either way), so no Terraform change is
  needed.
- **Apicurio is NOT deployed to AWS.** `schema-rules.md`'s canonical table wrongly claimed the wire
  serde was `AvroKafkaSerializer`/`Deserializer`; the real code
  (`AvroCommandPayloadCodec`/`AvroResultPayloadCodec`) uses a local `SpecificDatumWriter`, correctly,
  because registry I/O can't run inside the CAS/finalize transactions that need it. So the running
  services never call a registry. What schema-rules.md's "register before send" language actually
  implied is `avroSchemaRegister` (`AvroSchemaRegistrar.java`, chaosforge repo) — a **build-time**
  Gradle task, matching Apicurio's own tooling convention (they ship a Maven plugin for exactly this).
  An Apicurio task was nevertheless provisioned here for compose parity: it ran
  `APICURIO_STORAGE_KIND=mem` (persisted nothing), its security group ended up with no ingress and no
  egress rules (nothing could reach it), and no code called it. It has been removed from this
  deployment — one Fargate task per session for zero function. It remains in
  `docker-compose_chaosforge.yml`, which is where `avroSchemaRegister` targets it. One caveat carried
  in `AvroSchemaRegistrar.java`: the exact request-body shape is corroborated by search, not confirmed
  against Apicurio's authoritative OpenAPI spec — verify against the local `docker-compose` instance
  (`$0` cost) before this runs in any real pipeline.

- **Module 5.5 reversal: RPE's DB credentials are compose-parity (single `rpe` login), not
  per-service roles.** Module 5 provisioned four per-service passwords mirroring the
  `application.yml` `DB_USER` defaults (`detection_role` etc.) — but those roles are a
  **k8s/CNPG-only construct** (created by `deploy/k8s/db/` manifests that don't exist outside
  Kubernetes). RPE's own canonical *container* topology (`deploy/docker-compose.services.yml`,
  Stage 5, e2e-verified by the project itself) runs all four services as `DB_USER: rpe` with the
  single `POSTGRES_PASSWORD` — verified in every service's environment block. This ECS deployment
  follows compose, which also dissolves Module 5's "manual CREATE ROLE bootstrap SQL" gap: there is
  nothing to bootstrap. The per-service-role hardening remains real — in the k8s topology, where it
  lives.
- **One shared lab JWKS stub serves both systems (ADR-0404).** Both systems' JWKS SSM parameters
  once held `" "` (a single space, since SSM rejects `""`), believed to mean "unset, fail closed."
  It didn't: every resource-server decoder is built via
  `NimbusJwtDecoder`/`NimbusReactiveJwtDecoder.withJwkSetUri(...)`, whose builder calls
  `Assert.hasText` — and `StringUtils.hasText(" ") == false` — so the space threw at bean
  construction and crashlooped all six app services (RPE ×4, chaosforge gateway + CP) rather than
  401-ing. No test caught it: the decoder is gated `@ConditionalOnWebApplication(REACTIVE)` and the
  suites boot `webEnvironment = NONE`. Now a single nginx Fargate task in `foundation/` serves a
  merged JWK Set (`rpe-lab-1` + `chaosforge-lab-1`, each decoder picking its own by `kid`) at
  `jwks-stub.observability.internal`, built from each repo's existing `generate-jwks.sh` output.
  Decoders fetch lazily, so with the stub up tokens validate, and with it scaled to 0 the services
  still boot and 401 — the fail-closed posture originally intended. Issuer/audience stay
  byte-identical to local (opaque exact-match strings, never dereferenced); only the JWKS URL
  drifts. A real IdP (Cognito/Keycloak) is a two-value change if the lab posture ever needs more.
- **Module 5.5 audit fixes (breakage class — each would have failed the first real session):**
  (1) chaosforge postgres now uses a derived image baking in `init-databases.sql` — Module 4's task
  definition mounted nothing, so `chaosforge_cp`/`chaosforge_exec` were never created and CP/Exec
  would crashloop; (2) `generate-certs.sh` (chaosforge repo) now adds `<svc>.chaosforge.internal`
  SANs — pre-fix certs fail mTLS hostname verification against Cloud Map DNS (mtls-design.md §8
  called this; the task defs used the Cloud Map names without the regen); (3) both systems' task
  roles now hold `elasticfilesystem:ClientMount/ClientWrite` — every EFS volume mounts with
  `iam = ENABLED` and no permission had been granted.
- **Module 5.5 cost hardening:** Secrets Manager → free SSM SecureString everywhere (also removes
  the deletion-recovery-window snag that fought destroy-per-session); NAT Gateway default-off
  (its Module 4 justification went stale the moment ECR mirrors existed — triage degrades per
  ADR-15 §9 without it); ALB default-off (gateway task carries a session-scoped public IP); VPC
  endpoints single-AZ. See "Cost model" above.
- **Public ingress is not world-open, and the ALB will not serve cleartext.** Both were true until
  recently, justified as "JWT at the gateway is the real gate." That reasoning is inverted: the
  gateway's JWT check authenticates the *caller*; it does nothing to protect the bearer token *in
  transit*. Now: `gateway_ingress_cidr` has **no default** and refuses `0.0.0.0/0` (ALB-less mode
  serves plain HTTP on a public IP, so it must be scoped to the operator's address), and
  `enable_alb = true` **requires** `acm_certificate_arn` — the ALB terminates TLS on :443 and :80
  only 301-redirects. ACM public certs are free; the ALB is not, so there was never a cost argument.
- **Module 6: RPE's tracing stack (OTel Collector + Tempo) is deliberately not deployed.** ADR-25
  makes tracing fail-open by design — with no OTLP collector, spans drop on a background thread and
  detection is untouched; RPE's own docs class tracing as "best-effort and lab-sampled, not a
  durability mechanism." Deploying Tempo would roughly double the observability footprint for that
  signal. ADOT/X-Ray is the path if AWS traces ever matter. Metrics + alert rules (the C26/C27 and
  ADR-23 gates) carry over fully.
- **Module 6 reversals, both with the same cause:** edge-gateway (chaosforge) and relay/alert/triage
  (rpe) are now Cloud Map-registered. Module 4 skipped them as "nothing queries them" — Prometheus
  now queries all of them. Registration serves the scraper only; RPE's Kafka-only inter-service
  constraint and the gateway's ALB/public-IP client path are untouched.
- **Module 7 fix: app task definitions referenced `:latest` against IMMUTABLE ECR repos — a tag
  that can never exist there.** Every app task launch would have failed at image pull. Both
  systems now take a required `image_tag` variable (the git SHA CI pushes); required with no
  default on purpose — defaulting to "latest" would re-hide the bug. Also new: chaosforge had no
  Dockerfiles at all (local dev is `bootRun`) — `docker/Dockerfile.{edge-gateway,control-plane,
  execution-service}` added to the chaosforge repo, following RPE's proven multi-stage pattern.
- **Asymmetry, flagged: chaosforge's Postgres credential is shared between CP and Exec.** That's
  what the app supports today (both `application.yml`s, same `DB_USERNAME` var). Post-5.5 this is
  symmetric with RPE's container topology rather than worse than it. Per-service logins for CP/Exec
  would be an app-repo improvement (roles + GRANTs in `init-databases.sql`) — flagged, not
  implemented.

## Build history

The module-by-module build log — the "all nine modules Done" status table and the per-module
deploy-role IAM growth ledger — lives in [`CHANGELOG.md`](CHANGELOG.md), so this README stays a
description of the current system rather than a record of how it was assembled.
