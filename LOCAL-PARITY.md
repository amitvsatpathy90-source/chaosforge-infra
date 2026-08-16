# Local parity — what this AWS work did and did NOT change in the app repos

The hard requirement: **the AWS deployment must not break local `docker compose`
/ `bootRun`, and must not burn out an 8GB M1.** This file is the ledger proving it — every change
made to the two application repos during this repo's development , and why each is non-breaking. Everything else lives
in the separate `chaosforge-infra` repo and touches the app repos not at all.

## The one guarantee that matters most: no `application*.yml` was modified

Local runtime behavior is driven by the Spring profiles (`dev`, default, `mtls`) in each service's
`application*.yml`. **Not one of those files was touched.** The AWS deployment changes behavior only
through environment variables injected by ECS task definitions (which live in `chaosforge-infra`,
not the app repos) — the exact override mechanism Spring is designed for. Run `./gradlew bootRun` or
`docker compose up` and you get byte-identical behavior to before this work started.

## chaosforge repo — every change, and why it's safe

| File | Change | Why local is unaffected |
|---|---|---|
| `docker/mtls/generate-certs.sh` | Added `<svc>.chaosforge.internal` to each SAN list; added a `prometheus` client cert | **Additive.** `localhost` / `<svc>` / `127.0.0.1` SANs still present, so local + compose mTLS validate exactly as before. The extra SAN and the extra cert are simply ignored by anything not using the Cloud Map DNS name. |
| `chaosforge-avro-schemas/build.gradle.kts` | New `avroSchemaRegister` JavaExec task | **Not a `check` dependency.** `./gradlew check` never invokes it. It runs only when explicitly called with `-PapicurioRegistryUrl`. |
| `.../schema/tooling/AvroSchemaRegistrar.java` | New file (main source set) | Compiles against JDK `java.net.http` + `org.apache.avro.Schema` (already `api(libs.avro)` in the module). Adds one class to the jar; nothing references it at runtime. **Confirm with a local `./gradlew :chaosforge-avro-schemas:check` — this is the one change I could not compile here.** |
| `Architecture Audit` | Corrected the serializer/deserializer claim (was describing a class the code never uses) | Documentation only. |
| `docker/Dockerfile.{edge-gateway,control-plane,execution-service}` | New files | The repo had no Dockerfiles; local dev is `bootRun`. These are used only by CI/AWS. Local flow never invokes them. |
| `.github/workflows/ci.yml` | New file | Runs only in GitHub Actions. No effect on a local checkout. |

## rpe repo — every change

| File | Change | Why local is unaffected |
|---|---|---|
| `.github/workflows/ci.yml` | New file | GitHub Actions only. Local `mvn -f <svc>/pom.xml verify` and `docker compose` are untouched. |

RPE's application code, `application.yml`s, Dockerfiles, and compose files were **not modified at
all** — the AWS deployment consumes RPE's existing artifacts as-is.

## The M1 8GB guarantee

Nothing in this work runs the AWS stack locally. The AWS containers execute on Fargate, not the
laptop. Local footprint is exactly what it was: the existing `docker compose` stacks (each already
budgeted under 2GB by their own compose files) plus `bootRun`. The one new local-capable command —
`avroSchemaRegister` against the compose Apicurio — is a lightweight HTTP POST, not a new service.

## One-time steps that are NOT breakage (they're deployment setup)

These are documented in `README.md` and are AWS-only; they do not alter local behavior:
- Regenerating certs with the new SANs (the old certs still work locally; regen is for AWS).
- Pushing ECR mirror images (only the AWS tasks pull from ECR; local pulls from Docker Hub).
- Bootstrapping / filling blank secrets (SSM params) — local uses compose env / `.env`.

## Known deployment-specific overrides (drift points, tracked)

These are places where the AWS env-var value intentionally differs from the local default. They are
config, not code changes, but they're the exact kind of thing that drifts silently — so they're
enumerated:

| Setting | Local default | AWS value | Why |
|---|---|---|---|
| `chaosforge.steady-state.health-path` | `/health` | `/actuator/health/readiness` | RPE (the target) exposes readiness there; ADR-19 leaves only that path unauthenticated |
| `SPRING_PROFILES_ACTIVE` (cf gateway/CP/exec) | `dev`/unset | `mtls` | AWS runs the real mTLS posture; `application-mtls.yml` exists for all three |
| `JWK_SET_URI` (cf), `RPE_OAUTH_JWKS_URI` (rpe) | each repo's own local stub | `http://jwks-stub.observability.internal/.well-known/jwks.json` | One shared stub serves both (ADR-0404); decoders pick their key by `kid`. The **only** drifting value — `RPE_OAUTH_ISSUER`/`AUDIENCE` and cf's `JWT_ISSUER`/`JWT_AUDIENCE` stay byte-identical to local, because an issuer is an opaque exact-match string that is never dereferenced |
