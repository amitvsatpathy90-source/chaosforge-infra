#!/bin/sh
# Runtime entrypoint (arch-audit F-02). Writes the scrape token from an env var — injected by ECS
# from SSM SecureString, see foundation/observability.tf's PROM_SCRAPE_TOKEN secret — to the file
# path prometheus.yml's credentials_file already expects. Replaces the old build-time
# `COPY scrape_token` that baked a live 30-day bearer JWT into an ECR image that survives
# `terraform destroy`. /etc/prometheus is nobody-owned in the upstream image; no chmod needed.
set -eu
umask 077
printf '%s' "${PROM_SCRAPE_TOKEN:?PROM_SCRAPE_TOKEN not injected}" > /etc/prometheus/scrape_token
exec /bin/prometheus "$@"
