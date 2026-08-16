# # ADR Index

Single source of truth for ChaosForge-Infra's Architectural Decision Records. Root `README.md` links
here instead of duplicating this table.

| ADR | Decision | File |
|---|---|---|
| ADR-0401 | One-way `chaosforge → rpe` dependency via plain security-group variable; apply order `foundation → rpe → chaosforge` | [ADR-0401](ADR-0401.md) |
| ADR-0402 | NAT Gateway as opt-in, triage-scoped egress; default-off to preserve the on-demand cost posture | [ADR-0402](ADR-0402.md) |
| ADR-0403 | RPE database credentials follow compose parity: all four services use the single `rpe` login rather than k8s-only per-service roles | [ADR-0403](ADR-0403.md) |
| ADR-0404 | One shared lab JWKS stub in `foundation/` serves both systems | [ADR-0404](ADR-0404.md) |

---

## Changelog

| Date | Change |
|---|---|
| 2026-08-09 | Index compiled from the full ADR corpus (ADR-0401–0404) |