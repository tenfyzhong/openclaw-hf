#!/usr/bin/env bash
set -euo pipefail

SPACE_ID="${1:-${SPACE_ID:-}}"
if [[ -z "$SPACE_ID" ]]; then
  echo "usage: $0 <owner/space_name>" >&2
  echo "or set SPACE_ID=<owner/space_name>" >&2
  exit 1
fi

SPACE_HOST="${SPACE_ID/\//-}.hf.space"
HEALTH_URL="https://${SPACE_HOST}/healthz"
HF_BEARER_TOKEN="${HF_TOKEN:-${HUGGINGFACE_HUB_TOKEN:-}}"

if [[ -n "$HF_BEARER_TOKEN" ]]; then
  exec curl -fsS --max-time 20 --retry 3 --retry-delay 2 --retry-all-errors \
    -H "Authorization: Bearer ${HF_BEARER_TOKEN}" "$HEALTH_URL"
fi

exec curl -fsS --max-time 20 --retry 3 --retry-delay 2 --retry-all-errors "$HEALTH_URL"
