# Engineering Timeline — chaosforge · revenue-protection-engine · chaosforge-infra

**Provenance.** Public git history in these repos was flattened during a repo-sanitization pass;
each repo's baseline commit (2026-07-25) is where tracked history restarts. This document is the
reconstructed engineering record, derived **exclusively from dated artifacts that survived the
squash**: per-repo `CHANGELOG.md` entries and the per-decision ADR corpus (36 chaosforge,
29 RPE, 4 infra). No date below is inferred or invented — undated events are listed with their
recorded *ordering* and the evidence that bounds them, and every row cites its source. Dates are
documentation dates (when the record was written), not commit timestamps.

Repo keys: **CF** = chaosforge · **RPE** = revenue-protection-engine · **INF** = chaosforge-infra.
Evidence keys: `CF 1.14.0` = chaosforge `CHANGELOG.md` entry · `RPE v1.5` = RPE `CHANGELOG.md`
entry · `ADR-NNNN` = `docs/adrs/` in the named repo.

---

## Phase 1 — ChaosForge founding design (2026-05-20)

Thirteen ADRs land as a single founding batch — the platform's shape before a line of the current
codebase's history begins.

| Date | Repo | Event | Evidence |
|---|---|---|---|
| 2026-05-20 | CF | Founding ADR batch **ADR-0500…0512**: WebFlux gateway (0500); three-service split (0501); replay engine v1 — Postgres advisory lock + monotonic `replay_version` (0502, later superseded); append-only rule sets (0503); L1-only gateway cache (0504); `x-replay-*` outbox header namespace (0506); DLQ failure-class taxonomy (0508); three-layer tenant isolation (0509); cross-tenant 404-not-403 (0510); $0/month cost ceiling (0511); lab benchmarks must disclose full rig (0512) | CF ADR-0500…0512 |

## Phase 2 — RPE core detection design (undated; bounded ≤ 2026-06-12)

RPE's fourteen core ADRs are undated (pre-changelog era). Their ordering is recorded by ADR number
and cross-reference; the upper bound is RPE v1.1 (2026-06-12) and ADR-15's earliest edit-log entry
(2026-06-12), both of which already cite them.

| Order | Repo | Event | Evidence |
|---|---|---|---|
| ADR-01…14 | RPE | Detection core designed: dual runtime surface (01); Redis CB fallback, DLT rejected for transients (02); throttle-not-drop rate limiting (03); LISTEN/NOTIFY + adaptive-poll relay trigger (05); env-injected relay `transactional.id` (06); bounded VT lane queue + Caffeine lane map (07); Welford sample cap (08); partition-scoped lane drain on rebalance (09); `volatile-lru` (10); JSONB additive evolution via opaque relay (11); `synchronous_commit=off` vs UNLOGGED outbox trade (12); conscious non-durable dedup (13); Lua gate returns raw state, Java applies thresholds (14) | RPE ADR-01…14 |

## Phase 3 — Spring Boot 4 platform baseline, both systems (2026-06-12 → 2026-06-14)

| Date | Repo | Event | Evidence |
|---|---|---|---|
| 2026-06-12 | CF | Changelog era opens (1.0.0) | CF 1.0.0 |
| 2026-06-12 | RPE | Changelog era opens (v1.1); AI triage agent design begins | RPE v1.1; ADR-15 edit-log |
| 2026-06-13 | CF | Boot 4.1.x + Spring AI 2.0 adopted (1.2.0). ADR-0517 (Spring AI 1.1 on Boot 3) superseded same cycle by ADR-0520/0521; AI determinism boundary (0518) and PII egress controls for LLM prompts (0519) fixed before any AI code ships | CF 1.1.0–1.2.0; ADR-0517…0521 |
| 2026-06-13 | RPE | ADR-16 accepted: migrate to Boot 4.1.x baseline | RPE v1.2; ADR-16 |
| 2026-06-14 | CF | Consistency + hardening pass: durable fencing `inbox_fence`, outbox SENT gating (1.4.0); Avro binary confirmed as wire format (1.5.0, ADR-0525); ETag/If-Match CAS precondition (1.6.0). Replay mutex reversal begins: **ADR-0522 CAS optimistic lock supersedes the advisory lock**; tx decomposition (0523); JWT re-verification at CP/Exec (0524); partition key `scenario_id`, tenant-key rejected for HOL-blocking (0526); `FULL_TRANSITIVE` compatibility, `BACKWARD` argued insufficient (0527); OTel stretch outcomes + collector topology recorded (0513/0514); Week-12 game-day findings (0515); RPE-deviation register (0516) | CF 1.3.0–1.6.0; ADR-0513…0516, 0522…0527 |
| 2026-06-14 | RPE | ADR-16 implemented — core on Boot 4.1.0 + Spring Kafka 4.0, triage on Spring AI 2.0.0 | RPE v1.3 |

## Phase 4 — RPE microservice decomposition; CF replay protocol finalized (2026-06-17 → 2026-06-27)

| Date | Repo | Event | Evidence |
|---|---|---|---|
| 2026-06-17 | RPE | **ADR-17 accepted**: decompose into 4 independently deployable services along correctness contexts; Stage 1 — relay extracted to `rpe-relay-service` | RPE v1.4–v1.5; ADR-17 |
| 2026-06-17 | CF | **ADR-0528**: replay critical section finalized — ownership-first CAS + fencing token (supersedes 0502, narrows 0522); the Redlock rejection argument | CF ADR-0528 |
| 2026-06-18 | RPE | Stages 2–5 in one push: alert-actioning extracted (`rpe-alert-service`), detection core moved into `rpe-detection-service`, per-consumer additive-evolution contract tests + ArchUnit cross-import bans, canonical multi-service compose. ADR-18: one DLT per consumer group | RPE v1.6–v1.10; ADR-18 |
| 2026-06-27 | RPE | Stage 6: CNPG HA Postgres, per-service schemas + login roles + least-privilege GRANTs (the k8s topology INF later deliberately does **not** replicate — INF ADR-0403) | RPE v1.11 |

## Phase 5 — Hardening + acceptance-gate closure sprint (2026-06-28 → 2026-06-30)

| Date | Repo | Event | Evidence |
|---|---|---|---|
| 2026-06-28 | CF | L2-cache fail-open instrumented (1.7.0); ADR-0529 DLQ retry consumer — fresh-`message_id` republish | CF 1.7.0; ADR-0529 |
| 2026-06-28 | RPE | ADR-19 zero-trust actuator surface (`SCOPE_metrics:scrape`); ADR-20 Kafka SASL_SSL/SCRAM + per-service principal ACLs | RPE ADR-19/20 |
| 2026-06-29 | CF | Flyway startup migration P0 fixed (1.8.0, ADR-0530); intra-service mTLS wired via SSL bundles (1.9.0, ADR-0531); **VT/JDBC pinning measured, not assumed** — Option-1 harness, pinning == 0 (1.10.0) | CF 1.8.0–1.10.0 |
| 2026-06-29 | RPE | ADR-21 exception-boundary discipline; ADR-22 coordinated graceful shutdown; ADR-23 operator-gated DLT re-drive; ADR-24 global atomic Lua token bucket, degrade-to-local | RPE ADR-21…24 |
| 2026-06-30 | CF | Five acceptance gates closed in one day: C10/C14/C16/C26/C27 cluster (1.11.0); C29 `FULL_TRANSITIVE` CI schema gate (1.12.0); C28 partition-drop purge — UUIDv7-derived `msg_ts` so dedup survives partitioning (1.13.0); C19 kill switch proven under PG-down/Kafka-partition (1.14.0); C20 steady-state auto-abort (1.15.0). All engineering gates closed; only C31 (game day) remains | CF 1.11.0–1.15.0 |
| 2026-06-30 | RPE | ADR-25 distributed tracing: Micrometer Observation → OTel, `traceparent` persisted through the outbox, fail-open | RPE v1.12; ADR-25 |

## Phase 6 — Audit season: arch-audits, EADIE, doc-drift reconciliation (2026-07-02 → 2026-07-19)

| Date | Repo | Event | Evidence |
|---|---|---|---|
| 2026-07-02 | CF | ADR-0532 `/internal` tenant is peer-asserted, not JWT-bound; ADR-0533 steady-state cadence time-based, not per-step | CF ADR-0532/0533 |
| 2026-07-02 | RPE | Arch-audit fixes land, all four services full-verify green | RPE v1.13 |
| 2026-07-03 | CF | ADR-0534 blast-radius containment: one SSRF guard at authoring | CF ADR-0534 |
| 2026-07-04 | CF | Doc-pair drift audit — two shipped-but-undocumented hardenings reconciled, one live regression fixed | CF 1.16.0 |
| 2026-07-06 | CF | Outbox relay hardening (EADIE G1/G2): partition-pruned claim, pipelined publish, outage-proof DEAD gating, mirrored across both relays (1.17.0); results-topic wire contract + sweeper terminal events + DLQ-header PII sweep (1.18.0) | CF 1.17.0–1.18.0 |
| 2026-07-06 | RPE | ADR-26 detection ordering-and-recovery correctness — the durability-gated ack + `ALERT_UNDURABLE` DLT contract | RPE v1.14; ADR-26 |
| 2026-07-12 | RPE | ADR-27 stats-key lifecycle: sliding idle TTL + memory watermark | RPE ADR-27 |
| 2026-07-13 | CF | Arch-audit reconciliation — 6 findings fixed, 5 verified already-resolved (1.19.0); ADR batch 0535…0539: exactly-one-terminal-event under DLQ retry, authn ≠ authz on operator surfaces, every silent-failure mode observable, isolated short-timeout probe client, partition-window mint-time rejection | CF 1.19.0; ADR-0535…0539 |
| 2026-07-14 | CF | Lab JWKS stub, local half (the ADR-0404 follow-up) + iss/aud claim-validation hardening | CF 1.20.0 |
| 2026-07-15 | CF/RPE | Decision backfills: CF ADR-0540 (gateway Redis Lua sliding-window, globally consistent); RPE ADR-28 (dedup-guard horizon outlives redelivery), ADR-29 (no global Resilience4j defaults) | CF ADR-0540; RPE ADR-28/29 |
| 2026-07-16 | CF | Config-sync/coverage audit closure — two doc-asserted capabilities implemented (trace_id/MDC, DLQ triage tier) | CF 1.21.0 |
| 2026-07-17 | CF | ADR-0541 startup assertion of security controls; ADR-0542 DLQ human-triage watermark | CF ADR-0541/0542 |
| 2026-07-19 | CF | Standing DLQ-depth signal implemented (ADR-0542 closure) | CF 1.22.0 |

## Phase 7 — AWS deployment build: chaosforge-infra Modules 1–9 (ordered; not individually dated)

INF's `CHANGELOG.md` records the build as a module sequence, not dated entries. Bounds from the
record: the build postdates both app repos' CI workflows (Module 7 wires them); the ADR-0404
crashloop finding predates CF 1.20.0 (2026-07-14), which is explicitly its local-half follow-up;
everything is complete by the 2026-07-25 baseline commit.

| Order | Event | Evidence |
|---|---|---|
| Module 1 | Foundation: state backend, budget backstop, deploy role starts Budgets-only | INF CHANGELOG |
| Module 2 | Networking: VPC + endpoints, deliberately no NAT | INF CHANGELOG; ADR-0402 |
| Module 3 | Data layer: EFS-backed self-hosted Postgres/Redpanda/Redis (RDS/MSK rejected on cost); original `rds:*` IAM guess superseded | INF CHANGELOG |
| Module 4 | Compute: ECS Fargate, Cloud Map, NAT added as opt-in (ADR-0402 reversal arc) | INF CHANGELOG; ADR-0402 |
| Module 5 | Secrets & IAM: SSM SecureString over Secrets Manager; mid-module catch — deploy role couldn't write the secrets it provisions | INF CHANGELOG |
| Module 6 | Observability: derived prometheus/grafana images on CF's pins; AMG rejected on cost | INF CHANGELOG |
| Module 7 | CI/CD: OIDC deploy role, image push on main, deliberately no plan/apply in CI | INF CHANGELOG |
| Module 8 | Chaos wiring: FIS templates, CloudWatch stop conditions (`treat_missing_data = breaching`) | INF CHANGELOG |
| Module 9 | Local-parity + cost guardrails; `image_tag` made required after the `:latest`-vs-IMMUTABLE bug | INF CHANGELOG |
| ADRs | ADR-0401 one-way dependency + apply order; ADR-0402 NAT opt-in reversal; ADR-0403 compose-parity DB credentials; **ADR-0404 the `" "` JWKS crashloop finding → shared lab IdP stub** (≤ 2026-07-14 per CF 1.20.0) | INF ADR-0401…0404 |
| Late corrections | Deploy-role IAM ledger records two caught-late fixes: missing S3 state-bucket grant (Module 1 first pass); SNS topic-create for the budget topic — foundation was never appliable by the role until then | INF CHANGELOG (IAM ledger) |

## Phase 8 — Three-repo over-engineering audit closure + sanitization baseline (2026-07-25)

| Date | Repo | Event | Evidence |
|---|---|---|---|
| 2026-07-25 | CF | Audit closure: `resilience4j-spring-boot4` alignment with RPE, vestigial seam collapsed, repo git-tracked (1.23.0); verification debt cleared — full suite, 248 tests green (1.23.1) | CF 1.23.0–1.23.1 |
| 2026-07-25 | RPE | Audit closure + v1.15 verification debt cleared — full `mvn clean verify` ×4, Testcontainers ITs live | RPE v1.15–v1.16 |
| 2026-07-25 | INF | Baseline commit (`15a3a24`) + executed offline validation pass recorded (`c09af30`, `docs/VALIDATION.md`) — tracked history restarts here | INF git log |

---

## What this record does and does not claim

- **Dated rows** carry the date their CHANGELOG/ADR source records — a documentation date, not a
  commit timestamp.
- **Undated material** (RPE ADR-01…14, INF Modules 1–9) is presented as ordered sequence with
  explicit bounds, never with reconstructed dates.
- **No AWS apply has occurred** as of the baseline: INF's validation is the offline
  `docs/VALIDATION.md` pass; runtime claims remain gated on the first
  `docs/runbooks/apply-session.md` run.
- Reversals and corrections are part of the record on purpose: ADR-0502 → 0522 → 0528 (replay
  mutex), ADR-0517 → 0521 (Spring AI baseline), NAT add-then-default-off (ADR-0402), the JWKS
  crashloop (ADR-0404), and the caught-late IAM gaps. The trail of being wrong and fixing it is
  the evidence of process — that is what this timeline exists to preserve.
