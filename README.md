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
- Store OpenClaw config/workspace under `/root/.openclaw`
- Restore state automatically from a Hugging Face Dataset on startup
- Run scheduled backups of OpenClaw data to a Hugging Face Dataset via `cron` (as `root` user)
- Preinstall `vim`, `opencode`, `codex`, `claude` (Claude Code CLI), and `sshx` in the image for interactive terminal use

## Repository Layout

- `Dockerfile`: Runtime image for the Space
- `scripts/openclaw-entrypoint.sh`: Main startup flow (restore, config generation, cron setup, gateway start)
- `openclaw_hf/backup.py`: Backup/restore implementation
- `scripts/openclaw-backup-cron.sh`: Cron entrypoint for backup jobs
- `scripts/openclaw-restore.sh`: Startup restore entrypoint
- `scripts/bootstrap-hf.sh`: Interactive bootstrap for Space/Dataset creation, upload, and Space variables/secrets setup (macOS/Linux)
- `scripts/bootstrap-hf.ps1`: Interactive bootstrap for Space/Dataset creation, upload, and Space variables/secrets setup (Windows PowerShell)
- `tests/test_backup.py`: Unit tests for the backup module
- `tests/test_entrypoint_config.py`: Unit tests for gateway config generation behavior

## Required Variables (Space Settings)

In your Hugging Face Space (`Settings -> Variables and secrets`), configure at least:

- Variable: `OPENCLAW_BACKUP_DATASET_REPO`: Backup target Dataset in `username/dataset-name` format
- Secret: `HF_TOKEN`: Used to write backups to the Dataset (must have write permission to that Dataset)
- Secret: `OPENCLAW_GATEWAY_TOKEN`: Gateway token (recommended; if omitted in deployment workflow, generate a random 32-character value)
- Secret: `OPENCLAW_GATEWAY_PASSWORD`: Gateway password (optional; if omitted in deployment workflow, generate a random 16-character value)

When using `./scripts/bootstrap-hf.sh` (macOS/Linux) or `./scripts/bootstrap-hf.ps1` (Windows PowerShell), these values are configured automatically on the target Space.

## Optional LLM Variables (All-Or-None)

Set all of these together only when you want OpenClaw to preconfigure a custom third-party model:

- Variable: `OPENCLAW_LLM_BASE_URL`: Third-party base URL (for example OpenAI-compatible `/v1`)
- Variable: `OPENCLAW_LLM_MODEL`: Third-party model ID
- Secret: `OPENCLAW_LLM_API_KEY`: Third-party API key

If any of the three is missing, entrypoint skips custom model generation.
In that case, you can still configure from inside the container (for example via `sshx`).

## Common Optional Variables

- `OPENCLAW_LLM_MODEL` (unset by default; used only when custom model preconfiguration is enabled)
- `OPENCLAW_LLM_PROVIDER` (default: `thirdparty`)
- `OPENCLAW_LLM_API` (default: `openai-completions`)
- `OPENCLAW_VERSION` (used by Docker install step; bootstrap prompts for it and defaults to the latest version detected from npm registry, fallback `latest`)
- `OPENCLAW_STATE_DIR` (default: `/root/.openclaw`)
- `OPENCLAW_USER` (default: `root`, runtime user for gateway and cron jobs)
- `OPENCLAW_GROUP` (default: `root`, runtime group for gateway and cron jobs)
- `OPENCLAW_CONFIG_PATH` (default: `/root/.openclaw/openclaw.json`)
- `OPENCLAW_WORKSPACE_DIR` (default: `/root/.openclaw/workspace`)
- `OPENCLAW_BACKUP_CRON` (default: `*/30 * * * *`, backup every 30 minutes)
- `OPENCLAW_BACKUP_SOURCE_DIR` (default: `/root/.openclaw`, backup/restore base directory for `openclaw-state`)
- `OPENCLAW_BACKUP_ROOT_CONFIG_DIR` (default: `/root/.config`, additional backup/restore directory for `root-config`)
- `OPENCLAW_BACKUP_PATH_PREFIX` (default: `backups`)
- `OPENCLAW_BACKUP_LATEST_NAME` (default: `latest-backup.tar.gz`)
- `OPENCLAW_BACKUP_KEEP_COUNT` (default: `48`, keep newest N timestamped backup archives; older ones are auto-deleted)
- `OPENCLAW_SSHX_AUTO_START` (default: `false`; set `true` to auto-run `sshx` in background on startup)
- `OPENCLAW_GATEWAY_AUTH_MODE` (default: `token`, optional: `password`)
- `OPENCLAW_GATEWAY_CONTROLUI_ALLOW_INSECURE_AUTH` (default: `false`)
- `OPENCLAW_GATEWAY_CONTROLUI_DANGEROUSLY_DISABLE_DEVICE_AUTH` (default: `false`; set `true` to bypass pairing, strongly discouraged on public networks)

## Quick Deployment

Run the interactive bootstrap script from repo root:

```bash
./scripts/bootstrap-hf.sh
```

```powershell
powershell -ExecutionPolicy ByPass -File .\scripts\bootstrap-hf.ps1
```

`bootstrap-hf.sh` / `bootstrap-hf.ps1` will:

- Check/install `hf` CLI:
  - macOS/Linux: `curl -LsSf https://hf.co/cli/install.sh | bash`
  - Windows PowerShell: `powershell -ExecutionPolicy ByPass -c "irm https://hf.co/cli/install.ps1 | iex"`
- Ensure HF login (`hf auth whoami` / `hf auth login`)
- Ask for `space_name`, `dataset_name`, `OPENCLAW_VERSION`, gateway token/password, and optional LLM settings
- Default `OPENCLAW_VERSION` to latest detected from npm registry (`openclaw`), fallback `latest` when detection fails
- Auto-generate `OPENCLAW_GATEWAY_TOKEN` (32 chars) and `OPENCLAW_GATEWAY_PASSWORD` (16 chars) if left empty
- Create private Space + Dataset and upload this repository
- Configure Space `Variables and secrets` automatically, including:
  - `OPENCLAW_BACKUP_DATASET_REPO`
  - `OPENCLAW_VERSION`
  - `HF_TOKEN`
  - `OPENCLAW_GATEWAY_TOKEN`
  - `OPENCLAW_GATEWAY_PASSWORD`
  - `OPENCLAW_GATEWAY_CONTROLUI_ALLOW_INSECURE_AUTH=false`
  - `OPENCLAW_GATEWAY_CONTROLUI_DANGEROUSLY_DISABLE_DEVICE_AUTH=false`
- Optionally configure LLM triplet and set `OPENCLAW_SSHX_AUTO_START` from prompt choice (`true`/`false`)
- Print planned deployment settings and require a final confirmation before creating/updating Space/Dataset resources
- Print Hugging Face Space page URL, app URL, and `/healthz`

If gateway token/password were auto-generated, the script prints them at the end.

## Agent Hand-off Prompt

Copy and send to your agent:

```
Please deploy OpenClaw to Hugging Face by strictly following the "Agent Deployment SOP (Collapsed)" section in https://github.com/tenfyzhong/openclaw-hf/blob/main/README.md
```

## Agent Deployment SOP (Collapsed)

<details>
<summary>Click to expand agent installation workflow</summary>

This runbook is for agents that need to deploy this repo to Hugging Face.

Deployment must reuse:

- `./scripts/bootstrap-hf.sh` on macOS/Linux
- `powershell -ExecutionPolicy ByPass -File .\scripts\bootstrap-hf.ps1` on Windows PowerShell

Do not hand-roll a separate deployment flow unless the user explicitly asks for a manual fallback.

### 1. Preflight check before collecting inputs

Agent must check these dependencies first:

```bash
command -v git >/dev/null 2>&1 || MISSING_GIT=1
command -v hf >/dev/null 2>&1 || MISSING_HF=1
command -v python3 >/dev/null 2>&1 || MISSING_PYTHON3=1
```

If missing:

- `git`: install with the OS package manager.
- `hf`:
  - macOS/Linux: `curl -LsSf https://hf.co/cli/install.sh | bash`
  - Windows PowerShell: `powershell -ExecutionPolicy ByPass -c "irm https://hf.co/cli/install.ps1 | iex"`
- `python3`: install with the OS package manager or official installer.

Then verify:

```bash
git --version
hf version
python3 --version
```

Both bootstrap scripts also depend on Python package `huggingface_hub`:

```bash
python3 -c "import huggingface_hub" >/dev/null 2>&1 || \
  python3 -m pip install --user 'huggingface_hub[cli]'
```

### 2. Ask user for inputs in the same order as the bootstrap script prompts (with explanations)

Agent should ask in one consolidated message, in this order:

1. `space_name` (default `openclaw-hf`): Space repo suffix, final ID is `<hf_username>/<space_name>`.
2. `dataset_name` (default `<space_name>-backup`): backup Dataset suffix, final ID is `<hf_username>/<dataset_name>`.
3. `OPENCLAW_VERSION` (default: latest version detected from npm, fallback `latest`): controls OpenClaw version installed in the container.
4. `OPENCLAW_GATEWAY_TOKEN` (optional secret): if empty, script auto-generates 32 random characters and prints it at the end.
5. `OPENCLAW_GATEWAY_PASSWORD` (optional secret): if empty, script auto-generates 16 random characters and prints it at the end.
6. `HF_TOKEN for backup dataset` (optional secret): if empty, script reuses current local HF login token; token must have write access to the backup Dataset.
7. `Configure custom LLM now?` (`y/N`):
   - if `yes`, collect all 3: `OPENCLAW_LLM_BASE_URL`, `OPENCLAW_LLM_MODEL`, `OPENCLAW_LLM_API_KEY`.
   - if `no`, ask whether to set `OPENCLAW_SSHX_AUTO_START=true` (`Y/n`) for later sshx-based setup. When answer is `no`, script sets `OPENCLAW_SSHX_AUTO_START=false`.
8. `Proceed with these settings?` (`Y/n`):
   - if `no`, script exits before creating Space/Dataset or applying any Space variable/secret changes.

If `hf auth whoami` is not logged in, explain that the script will run `hf auth login` before deployment.

### 3. Execute deployment via script

From repo root:

```bash
./scripts/bootstrap-hf.sh
```

Or on Windows PowerShell:

```powershell
powershell -ExecutionPolicy ByPass -File .\scripts\bootstrap-hf.ps1
```

Agent should follow the script prompts step by step using the user-provided values in the same order.
If the final confirmation prompt is `no`, stop and do not execute repository creation/upload/variable updates.

The script will complete all deployment actions:

- create private Space and private Dataset
- upload repository to the Space
- configure Space variables and secrets (including `OPENCLAW_BACKUP_DATASET_REPO`, `OPENCLAW_VERSION`, `HF_TOKEN`, gateway credentials, and optional LLM/SSHX settings)
- set:
  - `OPENCLAW_GATEWAY_CONTROLUI_ALLOW_INSECURE_AUTH=false`
  - `OPENCLAW_GATEWAY_CONTROLUI_DANGEROUSLY_DISABLE_DEVICE_AUTH=false`
- set `OPENCLAW_SSHX_AUTO_START=true` only when chosen; otherwise set `OPENCLAW_SSHX_AUTO_START=false`

### 4. Final hand-off to user (required)

Agent final message must include:

- Space repo ID: `<owner>/<space_name>`
- Space page URL: `https://huggingface.co/spaces/<owner>/<space_name>`
- Dataset repo ID: `<owner>/<dataset_name>`
- `OPENCLAW_VERSION` used
- App URL: `https://<owner>-<space_name>.hf.space`
- Health URL: `https://<owner>-<space_name>.hf.space/healthz`
- If auto-generated, include `OPENCLAW_GATEWAY_TOKEN`
- If auto-generated, include `OPENCLAW_GATEWAY_PASSWORD`
- Keep-alive reminder:
  - paid hardware + `Sleep time=Never` for strict 24/7 uptime
  - free tier may sleep after inactivity

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

- Startup restore: on container startup, it tries to fetch `latest-backup.tar.gz` from the Dataset and restore:
  - `openclaw-state` -> `OPENCLAW_BACKUP_SOURCE_DIR` (default `/root/.openclaw`)
  - `root-config` -> `OPENCLAW_BACKUP_ROOT_CONFIG_DIR` (default `/root/.config`, restored only when present in archive)
- Scheduled backup: cron runs based on `OPENCLAW_BACKUP_CRON`
- Shutdown backup: when the container receives a stop signal, one final backup is uploaded before exit
- Each backup upload includes:
  - `backups/openclaw-backup-<timestamp>.tar.gz`
    - archive root `openclaw-state/`
    - archive root `root-config/` (included when `OPENCLAW_BACKUP_ROOT_CONFIG_DIR` exists)
  - `latest-backup.tar.gz`
  - `latest-backup.json`
- Retention: after upload, only the newest `OPENCLAW_BACKUP_KEEP_COUNT` timestamped archives are kept (default `48`); older timestamped archives are deleted automatically

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
