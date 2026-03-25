#!/usr/bin/env bash
set -euo pipefail

BACKUP_ENV_FILE_PATH="${OPENCLAW_BACKUP_ENV_FILE_PATH:-/etc/openclaw-backup.env}"
if [[ -f "$BACKUP_ENV_FILE_PATH" ]]; then
  # shellcheck disable=SC1091
  source "$BACKUP_ENV_FILE_PATH"
fi

python3 /opt/openclaw-hf/openclaw_hf/backup.py restore
