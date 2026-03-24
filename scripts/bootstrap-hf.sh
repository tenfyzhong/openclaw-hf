#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <space_repo_id> <dataset_repo_id>"
  echo "example: $0 yourname/openclaw-hf yourname/openclaw-hf-backup"
  exit 1
fi

SPACE_REPO_ID="$1"
DATASET_REPO_ID="$2"

hf repo create "$SPACE_REPO_ID" --repo-type space --space-sdk docker --private --exist-ok
hf repo create "$DATASET_REPO_ID" --repo-type dataset --private --exist-ok

echo "space:   https://huggingface.co/spaces/$SPACE_REPO_ID"
echo "dataset: https://huggingface.co/datasets/$DATASET_REPO_ID"
echo "visibility: private/private"

echo
echo "Set these Space variables/secrets:"
echo "  OPENCLAW_BACKUP_DATASET_REPO=$DATASET_REPO_ID"
echo "  OPENCLAW_LLM_BASE_URL=<your third-party base url>"
echo "  OPENCLAW_LLM_API_KEY=<your third-party api key>"
echo "  OPENCLAW_GATEWAY_TOKEN=<gateway token>"
echo "  OPENCLAW_GATEWAY_PASSWORD=<gateway password>"
echo "  OPENCLAW_GATEWAY_AUTH_MODE=token|password (default token)"
echo "  OPENCLAW_GATEWAY_CONTROLUI_DANGEROUSLY_DISABLE_DEVICE_AUTH=true|false (default false)"
echo "  OPENCLAW_SSHX_AUTO_START=true|false (default false)"
echo "  HF_TOKEN=<token with write access to dataset>"

echo
echo "To upload current directory to Space:"
echo "  hf upload $SPACE_REPO_ID . --repo-type space --exclude '.git/**' --exclude '.git' \\"
echo "    --commit-message 'feat: deploy openclaw on hf space'"
