---
title: OpenClaw HF Space
emoji: 🦞
colorFrom: blue
colorTo: indigo
sdk: docker
app_port: 7860
pinned: false
---

# OpenClaw on Hugging Face Space (Docker)

This setup is designed to provide the following:

- Build the OpenClaw container on top of `ubuntu:24.04`
- Serve the OpenClaw dashboard directly on port `7860` (default Space access port)
- Use third-party OpenAI-compatible `base_url + api_key` by default (injected via environment variables)
- Store OpenClaw config/workspace under `/home/ubuntu/.openclaw`
- Restore state automatically from a Hugging Face Dataset on startup
- Run scheduled backups of OpenClaw data to a Hugging Face Dataset via `cron`
- Preinstall `sshx` in the image so you can open a shareable terminal session from inside the container

## Repository Layout

- `Dockerfile`: Runtime image for the Space
- `scripts/openclaw-entrypoint.sh`: Main startup flow (restore, config generation, cron setup, gateway start)
- `openclaw_hf/backup.py`: Backup/restore implementation
- `scripts/openclaw-backup-cron.sh`: Cron entrypoint for backup jobs
- `scripts/openclaw-restore.sh`: Startup restore entrypoint
- `scripts/bootstrap-hf.sh`: Helper script to create a Space + Dataset
- `tests/test_backup.py`: Unit tests for the backup module

## Required Variables (Space Settings)

In your Hugging Face Space (`Settings -> Variables and secrets`), configure at least:

- Secret: `OPENCLAW_LLM_API_KEY`: Third-party API key
- Variable: `OPENCLAW_LLM_BASE_URL`: Third-party base URL (for example OpenAI-compatible `/v1`)
- Variable: `OPENCLAW_BACKUP_DATASET_REPO`: Backup target Dataset in `username/dataset-name` format
- Secret: `HF_TOKEN`: Used to write backups to the Dataset (must have write permission to that Dataset)
- Secret: `OPENCLAW_GATEWAY_TOKEN`: Fixed gateway token
- Secret: `OPENCLAW_GATEWAY_PASSWORD`: Gateway password (optional)

## Common Optional Variables

- `OPENCLAW_LLM_MODEL` (default: `gpt-4o-mini`)
- `OPENCLAW_LLM_PROVIDER` (default: `thirdparty`)
- `OPENCLAW_LLM_API` (default: `openai-completions`)
- `OPENCLAW_STATE_DIR` (default: `/home/ubuntu/.openclaw`)
- `OPENCLAW_CONFIG_PATH` (default: `/home/ubuntu/.openclaw/openclaw.json`)
- `OPENCLAW_WORKSPACE_DIR` (default: `/home/ubuntu/.openclaw/workspace`)
- `OPENCLAW_BACKUP_CRON` (default: `*/30 * * * *`, backup every 30 minutes)
- `OPENCLAW_BACKUP_SOURCE_DIR` (default: `/home/ubuntu`, backup/restore root directory)
- `OPENCLAW_BACKUP_PATH_PREFIX` (default: `backups`)
- `OPENCLAW_BACKUP_LATEST_NAME` (default: `latest-backup.tar.gz`)
- `OPENCLAW_SSHX_AUTO_START` (default: `false`; set `true` to auto-run `sshx` in background on startup)
- `OPENCLAW_GATEWAY_AUTH_MODE` (default: `token`, optional: `password`)
- `OPENCLAW_GATEWAY_CONTROLUI_ALLOW_INSECURE_AUTH` (default: `false`)
- `OPENCLAW_GATEWAY_CONTROLUI_DANGEROUSLY_DISABLE_DEVICE_AUTH` (default: `false`; set `true` to bypass pairing, strongly discouraged on public networks)

## Quick Deployment

1. Create a private Space and a private Dataset

```bash
./scripts/bootstrap-hf.sh <space_repo_id> <dataset_repo_id>
# Example:
# ./scripts/bootstrap-hf.sh yourname/openclaw-hf yourname/openclaw-hf-backup
```

2. Upload this repository to the Space

```bash
hf upload <space_repo_id> . --repo-type space --exclude '.git/**' --exclude '.git' \
  --commit-message "feat: deploy openclaw on hf space"
```

3. Configure the variables/secrets above in Space settings, then restart the Space

## Agent Hand-off Prompt

Copy and send to your agent:

```
Please install and deploy OpenClaw to Hugging Face by following the "Agent Deployment SOP (Collapsed)" section in https://github.com/tenfyzhong/openclaw-hf/blob/main/README.md. Ask me for any missing required values before you continue.
```

## Agent Deployment SOP (Collapsed)

<details>
<summary>Click to expand agent installation workflow</summary>

This runbook is for agents that need to deploy this repo to Hugging Face.

### 1. Preflight check: ensure `git` and `hf` CLI are installed

Agent must check tools first:

```bash
command -v git >/dev/null 2>&1 || MISSING_GIT=1
command -v hf >/dev/null 2>&1 || MISSING_HF=1
```

If any tool is missing, agent should install automatically (based on OS/package manager):

```bash
# macOS (Homebrew)
if command -v brew >/dev/null 2>&1; then
  [ "${MISSING_GIT:-0}" = "1" ] && brew install git
  [ "${MISSING_HF:-0}" = "1" ] && brew install huggingface-cli
fi

# Ubuntu/Debian
if command -v apt-get >/dev/null 2>&1; then
  [ "${MISSING_GIT:-0}" = "1" ] && sudo apt-get update && sudo apt-get install -y git
  if [ "${MISSING_HF:-0}" = "1" ]; then
    sudo apt-get update
    sudo apt-get install -y python3-pip
    python3 -m pip install --user --break-system-packages "huggingface_hub[cli]"
  fi
fi
```

Then verify:

```bash
git --version
hf version
```

### 2. Collect required inputs from user first

Agent must require user inputs for:

- `OPENCLAW_LLM_BASE_URL`
- `OPENCLAW_LLM_MODEL`
- `OPENCLAW_LLM_API_KEY`
- `OPENCLAW_GATEWAY_TOKEN`
- `OPENCLAW_GATEWAY_PASSWORD`
- `space_name`
- `dataset_name`

`HF_TOKEN` is not required from user input. It is derived from current HF CLI login session automatically.

Before asking for values, agent must pick explanation language from runtime context:

- If user explicitly asks for a language, use that language.
- Else infer from agent environment language (`LC_ALL`, `LC_MESSAGES`, `LANG`).
- Fallback to English when language cannot be inferred.

Reference detection command:

```bash
USER_LANG="${LC_ALL:-${LC_MESSAGES:-${LANG:-en_US.UTF-8}}}"
```

Agent must explain what each variable is used for in the selected language when asking user to provide values:

- `OPENCLAW_LLM_BASE_URL`: LLM API base URL endpoint.
- `OPENCLAW_LLM_MODEL`: LLM model ID used by OpenClaw.
- `OPENCLAW_LLM_API_KEY`: LLM provider API key (secret).
- `OPENCLAW_GATEWAY_TOKEN`: gateway token for token auth mode (secret).
- `OPENCLAW_GATEWAY_PASSWORD`: gateway password for password auth mode (secret).
- `space_name`: Hugging Face Space name; final repo ID becomes `<hf_username>/<space_name>`.
- `dataset_name`: Hugging Face Dataset name for backup; final repo ID becomes `<hf_username>/<dataset_name>`.

If any required value is missing, agent must ask user for only the missing keys, then wait for user input before continuing.

### 3. Ensure `hf` CLI is authenticated, derive `HF_TOKEN`, and clone repo

Before deployment, agent must verify HF CLI auth:

```bash
hf auth whoami
```

If not logged in, guide user to create a write token at `https://huggingface.co/settings/tokens`, then login:

```bash
hf auth login --token <HF_WRITE_TOKEN>
hf auth whoami
```

After login, derive `HF_TOKEN` automatically from local HF CLI credentials (do not ask user to provide `HF_TOKEN` separately):

```bash
HF_TOKEN="$(cat "$HOME/.cache/huggingface/token")"
```

Derive `hf_username`, `space_repo_id`, and `dataset_repo_id` from HF CLI login + user-provided names (do not ask user for full repo IDs):

```bash
HF_USERNAME="$(hf auth whoami | awk '{print $2}')"
space_repo_id="${HF_USERNAME}/${space_name}"
dataset_repo_id="${HF_USERNAME}/${dataset_name}"
```

Then clone this repo:

```bash
git clone https://github.com/tenfyzhong/openclaw-hf openclaw-hf
cd openclaw-hf
```

Use values to set:

- Secrets: `OPENCLAW_LLM_API_KEY`, `OPENCLAW_GATEWAY_TOKEN`, `OPENCLAW_GATEWAY_PASSWORD`, `HF_TOKEN` (auto-derived)
- Variables: `OPENCLAW_LLM_BASE_URL`, `OPENCLAW_LLM_MODEL`, `OPENCLAW_BACKUP_DATASET_REPO`

Agent must also set these additional variables:

- `OPENCLAW_GATEWAY_CONTROLUI_ALLOW_INSECURE_AUTH=true`
- `OPENCLAW_GATEWAY_CONTROLUI_DANGEROUSLY_DISABLE_DEVICE_AUTH=true`

When guiding user to configure these values, agent must explain the purpose of each key in the user's language:

- `HF_TOKEN`: Hugging Face token with write permission to the backup dataset.
- `OPENCLAW_BACKUP_DATASET_REPO`: backup dataset repo ID (`<hf_username>/<dataset_name>`).
- `OPENCLAW_GATEWAY_CONTROLUI_ALLOW_INSECURE_AUTH`: allows insecure auth behavior in Control UI (development/testing usage only).
- `OPENCLAW_GATEWAY_CONTROLUI_DANGEROUSLY_DISABLE_DEVICE_AUTH`: disables device auth flow in Control UI (high risk; use only when explicitly intended).

### 4. Create Space + Dataset and upload code to Hugging Face

```bash
hf repo create "$space_repo_id" --repo-type space --space-sdk docker --private --exist-ok
hf repo create "$dataset_repo_id" --repo-type dataset --private --exist-ok

hf upload "$space_repo_id" . --repo-type space --exclude '.git/**' --exclude '.git' \
  --commit-message "feat: deploy openclaw to hf space"
```

Then configure the Space Settings (`Variables and secrets`) using all values above, restart the Space, and verify `/healthz`.

</details>

## Hugging Face Keep-Alive

How to keep a Space available depends on hardware tier:

- Free `cpu-basic`: the Space sleeps after inactivity (currently around 48h). It cannot be configured to run forever on free hardware.
- Paid hardware: the Space runs continuously by default. In `Settings -> Hardware`, set `Sleep time` to `Never` (or use API with `sleep_time=-1`) for true 24/7 availability.
- Cost-saving mode on paid hardware: set a custom `Sleep time` (for example `3600` seconds) so it auto-sleeps and auto-wakes on the next visit.

Space URL composition:

- Space repo ID format: `<owner>/<space_name>` (example: `tenfyzhong/openclaw-hf`)
- Public runtime host format: `https://<owner>-<space_name>.hf.space`
- OpenClaw health check URL: `https://<owner>-<space_name>.hf.space/healthz`
- Inside the Space runtime, Hugging Face also provides `SPACE_HOST`, so health URL can be built as `https://${SPACE_HOST}/healthz`.

Example:

```bash
SPACE_ID="tenfyzhong/openclaw-hf"
SPACE_HOST="${SPACE_ID/\//-}.hf.space"
HEALTH_URL="https://${SPACE_HOST}/healthz"
echo "$HEALTH_URL"
```

Keep-alive by periodic health checks:

```bash
*/5 * * * * HF_TOKEN=hf_xxx /path/to/repo/scripts/check-space-health.sh tenfyzhong/openclaw-hf >/dev/null || true
```

Notes:

- For private Spaces, unauthenticated calls to `https://<owner>-<space_name>.hf.space/healthz` return a Hub 404 page. This is expected access control behavior.
- For private Spaces, include `Authorization: Bearer <HF_TOKEN>` (the helper script above does this automatically via `HF_TOKEN` or `HUGGINGFACE_HUB_TOKEN`).
- This ping strategy is a practical workaround for reducing idle sleep on free hardware, but it is not a guaranteed always-on method.
- If you need strict 24/7 uptime, use paid hardware and set sleep time to `Never`.

References:

- <https://huggingface.co/docs/hub/spaces-gpus#sleep-time>
- <https://huggingface.co/docs/huggingface_hub/package_reference/space_runtime>
- <https://huggingface.co/docs/hub/spaces-overview>

Programmatic options (owner token required):

```python
from huggingface_hub import HfApi

api = HfApi(token="hf_xxx")
repo_id = "your-username/your-space"

# Keep running (paid hardware)
api.set_space_sleep_time(repo_id=repo_id, sleep_time=-1)

# Or sleep after 1 hour of inactivity
api.set_space_sleep_time(repo_id=repo_id, sleep_time=3600)

# Manual control
api.pause_space(repo_id=repo_id)
api.restart_space(repo_id=repo_id)
```

For this project, if you need stable dashboard access without cold starts, use paid hardware and set sleep time to `Never`.

## Backup/Restore Flow

- Startup restore: on container startup, it tries to fetch `latest-backup.tar.gz` from the Dataset and restore it to `OPENCLAW_BACKUP_SOURCE_DIR` (default `/home/ubuntu`)
- Scheduled backup: cron runs based on `OPENCLAW_BACKUP_CRON`
- Shutdown backup: when the container receives a stop signal, one final backup is uploaded before exit
- Each backup upload includes:
  - `backups/openclaw-backup-<timestamp>.tar.gz`
  - `latest-backup.tar.gz`
  - `latest-backup.json`

## Use sshx Inside the Container

`sshx` is preinstalled in the image.

1. Auto-start `sshx` in background via environment variables:

```bash
OPENCLAW_SSHX_AUTO_START=true
```

When enabled, entrypoint starts `sshx` in background and sends `sshx` output directly to container stdout/stderr logs (no file logging).

2. Manual start inside container:

```bash
sshx
```

3. Let OpenClaw start a process itself (run in OpenClaw terminal/tool):

```bash
nohup sshx >/proc/1/fd/1 2>/proc/1/fd/2 &
```

4. After use, close `sshx` process promptly:

```bash
pgrep -fa sshx
pkill -TERM -f '(^|/)sshx($| )'
```

## Local Test

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
```

## License

MIT. See `LICENSE`.
