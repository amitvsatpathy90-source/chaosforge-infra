# Validation Runbook

Offline verification for Terraform and policy changes before targeting AWS. No credentials, no
state, no resources created — $0. This catches errors a manual review cannot: undeclared
references, type mismatches, incorrect provider-schema arguments, malformed `for_each`/`dynamic`
blocks.

Run after any `.tf` or `policy/*.rego` change.

---

## 0. Prerequisites

All roots pin Terraform `~> 1.10`.

```bash
tfenv install
tfenv use
terraform version
```

No AWS credentials or backend config required for sections 1–5.

---

## 1. Formatting

```bash
terraform fmt -recursive -diff
```

Cosmetic only. Use `-check` instead of `-diff` to verify without modifying.

---

## 2. Validate every root

```bash
for root in bootstrap foundation chaosforge rpe; do
  terraform -chdir="$root" init -backend=false -input=false >/dev/null &&
  terraform -chdir="$root" validate
done
```

Expected: `Success! The configuration is valid.` for all four roots.

`validate` does not require variable values, does not resolve `terraform_remote_state`, and does
not execute `archive_file`. A failure names the file and line — fix and re-run that root only.

---

## 3. RPE build (optional)

No RPE application code changed in this pass — only CF-infra policy/CI/Terraform work. Run
this only to confirm RPE is unaffected, not because this pass requires it.

```bash
for s in rpe-detection-service rpe-relay-service rpe-alert-service rpe-triage-agent; do
  mvn -f "$s/pom.xml" -q verify
done
```

---

## 4. CF build (optional)

Compiles all Java changes and runs the full acceptance-gate suite, including
`avroSchemaCompatibilityCheck`.

```bash
./gradlew check
```

Optional — exercise the schema registrar against a local Apicurio instance:

```bash
docker compose -f docker-compose_cf.yml up -d apicurio
./gradlew :cf-avro-schemas:avroSchemaRegister \
  -PapicurioRegistryUrl=http://localhost:8086/apis/registry/v3
```

## 5. Rego policy tests

```bash
conftest verify --policy policy/
```

Expected: 4 tests, 4 passed, 0 failures.

Covers both R1 gates using mocked input:
- `s3_egress.rego` — presence check
- `s3_egress_plan.rego` — per-security-group coverage check

Neither test invokes a real Terraform plan. `s3_egress.rego` also runs separately in CI against
actual `.tf` source (`policy-tests` → `validate` in `terraform.yml`). `s3_egress_plan.rego`
requires resolved security-group IDs from a live plan and is not yet exercised against one.

---

## Scope

**Proves:** HCL is syntactically valid; all references resolve; provider arguments match schema;
Java/Gradle changes compile and pass their gates; Rego policy logic is correct against mocked
input.

**Does not prove:**
- Runtime correctness (e.g., a syntactically valid security-group rule on the wrong port)
- Cross-root wiring — `terraform_remote_state` only resolves at `plan`/`apply`, in order
  `foundation → rpe → chaosforge`
- AWS-side reality — IAM sufficiency, ECR image existence, EFS mounts, mTLS handshakes
- The Apicurio registration request shape, without a live instance (§4)

## Minimum pass

§1, §2, and §5 cover everything this repo owns. §3 and §4 are optional checks.
RPE's and CF's own CI already run these on every push to their respective repos.
Use them here only for local, uncommitted app-code changes we want to verify before pushing.

## Deeper check — `terraform plan`

Read-only, $0, but requires AWS credentials and existing `foundation` state — a post-first-apply
step, not part of this offline pass. See [README](../README.md#first-time-setup) for apply
ordering and backend configuration.
