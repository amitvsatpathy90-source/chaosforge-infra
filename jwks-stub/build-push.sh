#!/usr/bin/env bash
# Builds + pushes the lab IdP stub image (foundation/jwks-stub.tf). Same shape and same discipline
# as observability/build-push.sh: assemble the context from the sibling repos' canonical files at
# build time, never fork them, delete the copies afterwards.
#
# Run AFTER `terraform apply` in foundation/ (the ECR repo must exist) and AFTER both repos'
# generate-jwks.sh have been run at least once. Assumes the standard sibling layout:
#   ~/work/repos/{chaosforge, revenue-protection-engine, chaosforge-infra}
#
# Usage: ./build-push.sh <aws-account-id> [region]
set -euo pipefail

ACCOUNT="${1:?usage: build-push.sh <aws-account-id> [region]}"
REGION="${2:-us-east-1}"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
TAG="1.27-alpine-idp1"

HERE="$(cd "$(dirname "$0")" && pwd)"
CHAOSFORGE="${HERE}/../../chaosforge"
RPE="${HERE}/../../revenue-protection-engine"

command -v jq >/dev/null || { echo "jq is required to merge the two JWK Sets" >&2; exit 1; }

RPE_JWKS="${RPE}/deploy/oauth/public/jwks.json"
CF_JWKS="${CHAOSFORGE}/docker/jwks/public/jwks.json"

[ -f "${RPE_JWKS}" ] || { echo "missing ${RPE_JWKS} — run ${RPE}/deploy/oauth/generate-jwks.sh first" >&2; exit 1; }
[ -f "${CF_JWKS}" ]  || { echo "missing ${CF_JWKS} — run ${CHAOSFORGE}/docker/jwks/generate-jwks.sh first" >&2; exit 1; }

# Merge both PUBLIC JWK Sets into one endpoint. A JWK Set holds many keys and each system's
# decoder selects its own by `kid` (rpe-lab-1 / chaosforge-lab-1 — distinct, set in each repo's
# generate-jwks.sh), so one file serves both. public/ only — keys/ is never touched.
jq -s '{keys: (map(.keys) | add)}' "${RPE_JWKS}" "${CF_JWKS}" > "${HERE}/jwks.json"

# Fail loudly on a half-merged or kid-colliding set. Left unchecked this is invisible until
# runtime, where it looks like "one whole system 401s for no reason" — the exact class of silent
# failure this stub exists to remove.
KEY_COUNT="$(jq '.keys | length' "${HERE}/jwks.json")"
KIDS="$(jq -r '[.keys[].kid] | sort | join(",")' "${HERE}/jwks.json")"
UNIQUE_KIDS="$(jq -r '[.keys[].kid] | unique | length' "${HERE}/jwks.json")"
if [ "${KEY_COUNT}" -ne 2 ] || [ "${UNIQUE_KIDS}" -ne 2 ]; then
  echo "merged JWK Set is wrong: ${KEY_COUNT} keys, ${UNIQUE_KIDS} unique kids (${KIDS}); expected 2 and 2" >&2
  echo "if the kids collide, re-run one repo's generate-jwks.sh with JWKS_KID set to something distinct" >&2
  rm -f "${HERE}/jwks.json"
  exit 1
fi

# Belt and braces: refuse to ship anything with a private component. A JWK Set is public by
# definition; "d" (RSA private exponent) appearing here would mean someone pointed this at keys/.
if jq -e '[.keys[] | has("d")] | any' "${HERE}/jwks.json" >/dev/null; then
  echo "REFUSING TO BUILD: merged JWK Set contains a private key component" >&2
  rm -f "${HERE}/jwks.json"
  exit 1
fi

aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

# Ensure a docker-container builder exists — the default 'docker' driver silently
# ignores --platform for non-native targets on this host (no error, wrong arch).
docker buildx inspect amd64builder >/dev/null 2>&1 || \
  docker buildx create --name amd64builder --driver docker-container
docker buildx use amd64builder

docker buildx build --platform linux/amd64 -f "${HERE}/Dockerfile.jwks-stub" -t "${REGISTRY}/platform/jwks-stub:${TAG}" "${HERE}" --load
docker push "${REGISTRY}/platform/jwks-stub:${TAG}"

# Copied context file is a build artifact, not a source — clean up so it never gets committed.
rm -f "${HERE}/jwks.json"

echo "done: ${REGISTRY}/platform/jwks-stub:${TAG} (kids: ${KIDS})"
