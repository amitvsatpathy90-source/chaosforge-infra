#!/usr/bin/env bash
# Builds + pushes the two derived observability images. Run AFTER `terraform apply` in foundation/
# (the ECR repos must exist). Assumes the standard sibling layout:
#   ~/work/repos/{chaosforge, revenue-protection-engine, chaosforge-infra}
#
# Usage: ./build-push.sh <aws-account-id> [region]
set -euo pipefail

ACCOUNT="${1:?usage: build-push.sh <aws-account-id> [region]}"
REGION="${2:-us-east-1}"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

HERE="$(cd "$(dirname "$0")" && pwd)"
CHAOSFORGE="${HERE}/../../chaosforge"
RPE="${HERE}/../../revenue-protection-engine"

# Assemble build context from both repos' canonical files — these stay owned by their repos; this
# script copies at build time, never forks them.
cp "${CHAOSFORGE}/docker/prometheus/alerts.yml"                             "${HERE}/alerts.yml"
cp "${RPE}/monitoring/rules/dlt.rules.yml"                                  "${HERE}/dlt.rules.yml"
cp "${RPE}/monitoring/rules/redis.rules.yml"                                "${HERE}/redis.rules.yml"
cp "${CHAOSFORGE}/docker/grafana/provisioning/dashboards/dashboards.yml"   "${HERE}/dashboards.yml"
cp "${CHAOSFORGE}/docker/grafana/dashboards/chaosforge-slis.json"          "${HERE}/chaosforge-slis.json"
# Scrape token is no longer baked into the image (arch-audit F-02) — it's injected at container
# start from PROM_SCRAPE_TOKEN (SSM SecureString, foundation/observability.tf) via
# entrypoint-prometheus.sh. Set it with: terraform apply -var prometheus_scrape_token=<jwt>.

aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

docker build -f "${HERE}/Dockerfile.prometheus" -t "${REGISTRY}/observability/prometheus:v2.55.1-obs2" "${HERE}"
docker push "${REGISTRY}/observability/prometheus:v2.55.1-obs2"

docker build -f "${HERE}/Dockerfile.grafana" -t "${REGISTRY}/observability/grafana:11.3.0-obs1" "${HERE}"
docker push "${REGISTRY}/observability/grafana:11.3.0-obs1"

# Copied context files are build artifacts, not sources — clean up so they never get committed.
rm -f "${HERE}/alerts.yml" "${HERE}/dlt.rules.yml" "${HERE}/redis.rules.yml" "${HERE}/dashboards.yml" \
      "${HERE}/chaosforge-slis.json"

echo "done: ${REGISTRY}/observability/{prometheus:v2.55.1-obs2, grafana:11.3.0-obs1}"
