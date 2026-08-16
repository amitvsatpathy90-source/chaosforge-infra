# Validation runbook

Machine-verify the Terraform + the app-repo changes **before** ever pointing this at AWS. Every step
here is **offline: no AWS credentials, no state, no resources created, $0.** It catches the class of
error a by-hand review (brace-counting) cannot — undeclared references, type mismatches, wrong
provider-schema arguments, malformed `for_each`/`dynamic` blocks.

> History: the repo was originally written without a local `terraform` binary — reviewed by hand
> (HCL brace/bracket balance + reference reconciliation), never by `terraform validate`. That gap is
> now closed: **2026-07-25, `terraform validate` passed in all four roots** (`bootstrap`,
> `foundation`, `chaosforge`, `rpe`) on Terraform v1.15.7 (init'd providers present in each root).
> This runbook remains the repeatable pass to run after any `.tf` change.

---

## 0. Prerequisites

Install the pinned Terraform version (all roots pin `~> 1.10`):

```bash
cd ~/work/repos/chaosforge-infra
tfenv install 1.10.5     # or any 1.10.x; tfenv respects the version constraint
tfenv use 1.10.5
terraform version         # confirm 1.10.x
```

No `~/.aws/credentials`, no `AWS_PROFILE`, no backend config needed for anything below.

---

## 1. Formatting — expect this to flag files, and that's fine

The HCL was hand-written without `terraform fmt`, so alignment nits (extra spaces around `=`) almost
certainly exist. This is **cosmetic only** — it never changes behavior.

```bash
cd ~/work/repos/chaosforge-infra
terraform fmt -recursive -diff     # auto-fixes AND prints what it changed
```

Review the diff (it'll be whitespace realignment). If it rewrote files, that's expected — commit it.
To instead just *check* without modifying (e.g. in review), use `terraform fmt -check -recursive`.

---

## 2. Validate every root — the real check

Each of the four roots is independent and needs its own provider install first. `init -backend=false`
installs providers **without** touching S3 or needing credentials; `validate` then does full static
analysis.

```bash
cd ~/work/repos/chaosforge-infra
for root in bootstrap foundation chaosforge rpe; do
  echo "=== $root ==="
  terraform -chdir="$root" init -backend=false -input=false >/dev/null &&
  terraform -chdir="$root" validate
done
```

**Expected result:** `Success! The configuration is valid.` for all four.

Notes on what's normal here:
- `validate` does **not** require variable values, does **not** read `terraform_remote_state` (those
  are plan-time data sources), and does **not** run the `archive_file` zip. Unknowns are fine.
- If a root fails, the error names the file + line. Fix, re-run just that root. The likely suspects
  are the hand-written files with the most moving parts: `chaosforge/security-groups.tf`,
  `chaosforge/ecs-task-definitions.tf`, `foundation/observability.tf`, `foundation/cost-guardrail.tf`.

---

## 3. chaosforge `./gradlew check` — the one thing I could not compile

`AvroSchemaRegistrar.java` (new, Module 5.5 Apicurio work) and the new `avroSchemaRegister` Gradle
task were written but **never compiled** in the session that produced them. `check` compiles them and
runs every acceptance gate — including C29 (`avroSchemaCompatibilityCheck` is a `check` dependency),
which is the control that actually matters for the schema work.

```bash
cd ~/work/repos/chaosforge
./gradlew check
```

**Expected:** BUILD SUCCESSFUL. If `AvroSchemaRegistrar.java` has a compile error, it surfaces here —
it imports only JDK `java.net.http` + `org.apache.avro.Schema` (already a module dependency), so it
*should* be clean, but this is the confirmation. This does not deploy or register anything; it's a
local build.

Optional, only if you want to actually exercise the registrar against the compose Apicurio ($0,
local):

```bash
docker compose -f docker-compose_chaosforge.yml up -d apicurio
./gradlew :chaosforge-avro-schemas:avroSchemaRegister \
  -PapicurioRegistryUrl=http://localhost:8086/apis/registry/v3
```

If this 400s, the Apicurio request-body shape needs correcting (it was corroborated by docs, not the
authoritative OpenAPI spec — flagged in `AvroSchemaRegistrar.java` and the infra README).

---

## 4. RPE build — baseline sanity (optional)

No RPE application code was changed (only a CI workflow was added), so this should be green exactly as
it was before. Run it only if you want the baseline confirmed:

```bash
cd ~/work/repos/revenue-protection-engine
for s in rpe-detection-service rpe-relay-service rpe-alert-service rpe-triage-agent; do
  mvn -f "$s/pom.xml" -q verify
done
```

---

## What this proves — and what it does NOT

**Proves:** the HCL is syntactically valid, every resource/variable/output reference resolves, every
provider argument matches its schema, and the chaosforge Java/Gradle changes compile and pass their
own gates.

**Does NOT prove (out of scope for an offline pass):**
- **Runtime correctness** — a security-group rule can be valid HCL and still point at the wrong port.
  Those were verified by reading the app configs during the build, not by `validate`.
- **Cross-root wiring** — `terraform_remote_state` outputs only resolve at `plan`/`apply` against real
  applied state, in the order `foundation → rpe → chaosforge`.
- **AWS-side reality** — IAM sufficiency, image existence in ECR, EFS mount success, mTLS handshakes.
  These surface only against a live account.
- **The Apicurio request shape** — needs the live compose instance (§3).

## Optional deeper check — `terraform plan` (needs credentials, still $0)

`plan` is read-only — it creates nothing and costs nothing — but it **does** need AWS credentials and
the `foundation` state to already exist, so it's a post-first-apply tool, not part of this offline
pass. When you get there, the apply order and the `-backend-config` / `tfvars` wiring are in the main
[README](../README.md#first-time-setup). `plan` is where cross-root wiring and IAM/image reality first
get exercised for real.
```

---

**One-liner if you just want the offline gate to pass:** run §1 then §2. Those two are the whole
"did the hand-written Terraform hold up" check. §3 is the "did the Java I couldn't compile hold up"
check. Everything else is optional depth.
