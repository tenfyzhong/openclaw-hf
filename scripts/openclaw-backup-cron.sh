#!/usr/bin/env bash
set -euo pipefail

if [[ -f /etc/openclaw-backup.env ]]; then
  # shellcheck disable=SC1091
  source /etc/openclaw-backup.env
fi

python3 /opt/openclaw-hf/openclaw_hf/backup.py backup
