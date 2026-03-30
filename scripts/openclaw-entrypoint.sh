#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_USER="${OPENCLAW_USER:-root}"
OPENCLAW_GROUP="${OPENCLAW_GROUP:-root}"
OPENCLAW_HOME="${OPENCLAW_HOME:-/root}"
OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-/root/.openclaw}"
OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-${OPENCLAW_STATE_DIR}/openclaw.json}"
OPENCLAW_WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-${OPENCLAW_STATE_DIR}/workspace}"
OPENCLAW_GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND:-lan}"
OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-7860}"
OPENCLAW_INIT_GATEWAY_MODE="${OPENCLAW_INIT_GATEWAY_MODE:-local}"
OPENCLAW_GATEWAY_AUTH_MODE="${OPENCLAW_GATEWAY_AUTH_MODE:-token}"
OPENCLAW_LLM_PROVIDER="${OPENCLAW_LLM_PROVIDER:-thirdparty}"
OPENCLAW_LLM_MODEL="${OPENCLAW_LLM_MODEL:-}"
OPENCLAW_LLM_API="${OPENCLAW_LLM_API:-openai-completions}"
OPENCLAW_LLM_BASE_URL_ENV="${OPENCLAW_LLM_BASE_URL_ENV:-OPENCLAW_LLM_BASE_URL}"
OPENCLAW_LLM_API_KEY_ENV="${OPENCLAW_LLM_API_KEY_ENV:-OPENCLAW_LLM_API_KEY}"
OPENCLAW_BACKUP_ENABLED="${OPENCLAW_BACKUP_ENABLED:-true}"
OPENCLAW_BACKUP_CRON="${OPENCLAW_BACKUP_CRON:-*/30 * * * *}"
OPENCLAW_BACKUP_SOURCE_DIR="${OPENCLAW_BACKUP_SOURCE_DIR:-${OPENCLAW_STATE_DIR}}"
OPENCLAW_BACKUP_ROOT_CONFIG_DIR="${OPENCLAW_BACKUP_ROOT_CONFIG_DIR:-/root/.config}"
OPENCLAW_BACKUP_ROOT_CODEX_DIR="${OPENCLAW_BACKUP_ROOT_CODEX_DIR:-/root/.codex}"
OPENCLAW_BACKUP_ROOT_CLAUDE_DIR="${OPENCLAW_BACKUP_ROOT_CLAUDE_DIR:-/root/.claude}"
OPENCLAW_BACKUP_ROOT_AGENTS_DIR="${OPENCLAW_BACKUP_ROOT_AGENTS_DIR:-/root/.agents}"
OPENCLAW_BACKUP_ROOT_SSH_DIR="${OPENCLAW_BACKUP_ROOT_SSH_DIR:-/root/.ssh}"
OPENCLAW_BACKUP_ROOT_NPM_DIR="${OPENCLAW_BACKUP_ROOT_NPM_DIR:-/root/.npm}"
OPENCLAW_BACKUP_ROOT_LARK_CLI_DIR="${OPENCLAW_BACKUP_ROOT_LARK_CLI_DIR:-/root/.lark-cli}"
OPENCLAW_BACKUP_ENV_FILE_PATH="${OPENCLAW_BACKUP_ENV_FILE_PATH:-/etc/openclaw-backup.env}"
OPENCLAW_STDOUT_LOG_PATH="${OPENCLAW_STDOUT_LOG_PATH:-/var/log/openclaw/gateway.stdout.log}"
OPENCLAW_STDERR_LOG_PATH="${OPENCLAW_STDERR_LOG_PATH:-/var/log/openclaw/gateway.stderr.log}"
OPENCLAW_SSHX_AUTO_START="${OPENCLAW_SSHX_AUTO_START:-false}"
OPENCLAW_GATEWAY_CONTROLUI_ALLOW_INSECURE_AUTH="${OPENCLAW_GATEWAY_CONTROLUI_ALLOW_INSECURE_AUTH:-false}"
OPENCLAW_GATEWAY_CONTROLUI_DANGEROUSLY_DISABLE_DEVICE_AUTH="${OPENCLAW_GATEWAY_CONTROLUI_DANGEROUSLY_DISABLE_DEVICE_AUTH:-false}"
OPENCLAW_CHILD_PID=""
OPENCLAW_SSHX_PID=""
OPENCLAW_SHUTDOWN_BACKUP_DONE=0

export HOME="$OPENCLAW_HOME"
export OPENCLAW_HOME
export OPENCLAW_STATE_DIR
export OPENCLAW_CONFIG_PATH
export OPENCLAW_BACKUP_ENV_FILE_PATH
OPENCLAW_STEP_INDEX=0
OPENCLAW_ENTRYPOINT_TAG="openclaw-entrypoint"

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log_info() {
  printf '[%s] %s: %s\n' "$(timestamp_utc)" "$OPENCLAW_ENTRYPOINT_TAG" "$*"
}

log_warn() {
  printf '[%s] %s: %s\n' "$(timestamp_utc)" "$OPENCLAW_ENTRYPOINT_TAG" "$*" >&2
}

run_step() {
  local description="$1"
  shift
  OPENCLAW_STEP_INDEX=$((OPENCLAW_STEP_INDEX + 1))
  log_info "step ${OPENCLAW_STEP_INDEX} start: ${description}"
  "$@"
  log_info "step ${OPENCLAW_STEP_INDEX} done: ${description}"
}

is_true() {
  local value
  value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "$value" == "1" || "$value" == "true" || "$value" == "yes" || "$value" == "on" ]]
}

generate_gateway_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
  fi
}

mkdir_state_dirs() {
  mkdir -p "$OPENCLAW_STATE_DIR" "$OPENCLAW_WORKSPACE_DIR"
  mkdir -p "$OPENCLAW_STATE_DIR/identity"
  mkdir -p "$OPENCLAW_STATE_DIR/agents/main/agent"
  mkdir -p "$OPENCLAW_STATE_DIR/agents/main/sessions"
  mkdir -p "$OPENCLAW_STATE_DIR/logs"
  mkdir -p "$(dirname "$OPENCLAW_STDOUT_LOG_PATH")" "$(dirname "$OPENCLAW_STDERR_LOG_PATH")"
  touch "$OPENCLAW_STDOUT_LOG_PATH" "$OPENCLAW_STDERR_LOG_PATH"
}

fix_permissions() {
  local path

  if [[ "$(id -u)" -ne 0 ]]; then
    return 0
  fi

  if [[ -e "$OPENCLAW_HOME" ]]; then
    chown "$OPENCLAW_USER:$OPENCLAW_GROUP" "$OPENCLAW_HOME"
  fi

  for path in \
    "$OPENCLAW_STATE_DIR" \
    "$OPENCLAW_WORKSPACE_DIR" \
    "$OPENCLAW_STDOUT_LOG_PATH" \
    "$OPENCLAW_STDERR_LOG_PATH" \
    "$(dirname "$OPENCLAW_STDOUT_LOG_PATH")" \
    "$(dirname "$OPENCLAW_STDERR_LOG_PATH")"; do
    if [[ -e "$path" ]]; then
      chown -R "$OPENCLAW_USER:$OPENCLAW_GROUP" "$path"
    fi
  done
}

write_or_update_config() {
  local existing_token
  existing_token=""

  if [[ -f "$OPENCLAW_CONFIG_PATH" ]]; then
    existing_token="$(python3 - <<'PY'
import json
import os

config_path = os.environ["OPENCLAW_CONFIG_PATH"]
try:
    with open(config_path, "r", encoding="utf-8") as fh:
        cfg = json.load(fh)
    token = cfg.get("gateway", {}).get("auth", {}).get("token", "")
    if isinstance(token, str):
        print(token.strip())
except Exception:
    pass
PY
)"
  fi

  if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
    if [[ -n "$existing_token" ]]; then
      OPENCLAW_GATEWAY_TOKEN="$existing_token"
    else
      OPENCLAW_GATEWAY_TOKEN="$(generate_gateway_token)"
    fi
  fi
  export OPENCLAW_GATEWAY_TOKEN

  OPENCLAW_GATEWAY_PORT="$OPENCLAW_GATEWAY_PORT" \
  OPENCLAW_GATEWAY_BIND="$OPENCLAW_GATEWAY_BIND" \
  OPENCLAW_INIT_GATEWAY_MODE="$OPENCLAW_INIT_GATEWAY_MODE" \
  OPENCLAW_CONFIG_PATH="$OPENCLAW_CONFIG_PATH" \
  OPENCLAW_GATEWAY_TOKEN="$OPENCLAW_GATEWAY_TOKEN" \
  OPENCLAW_GATEWAY_PASSWORD="${OPENCLAW_GATEWAY_PASSWORD:-}" \
  OPENCLAW_GATEWAY_AUTH_MODE="$OPENCLAW_GATEWAY_AUTH_MODE" \
  OPENCLAW_LLM_PROVIDER="$OPENCLAW_LLM_PROVIDER" \
  OPENCLAW_LLM_MODEL="$OPENCLAW_LLM_MODEL" \
  OPENCLAW_LLM_API="$OPENCLAW_LLM_API" \
  OPENCLAW_LLM_BASE_URL_ENV="$OPENCLAW_LLM_BASE_URL_ENV" \
  OPENCLAW_LLM_API_KEY_ENV="$OPENCLAW_LLM_API_KEY_ENV" \
  OPENCLAW_GATEWAY_CONTROLUI_DANGEROUSLY_ALLOW_HOST_HEADER_ORIGIN_FALLBACK="${OPENCLAW_GATEWAY_CONTROLUI_DANGEROUSLY_ALLOW_HOST_HEADER_ORIGIN_FALLBACK:-true}" \
  OPENCLAW_GATEWAY_CONTROLUI_ALLOW_INSECURE_AUTH="$OPENCLAW_GATEWAY_CONTROLUI_ALLOW_INSECURE_AUTH" \
  OPENCLAW_GATEWAY_CONTROLUI_DANGEROUSLY_DISABLE_DEVICE_AUTH="$OPENCLAW_GATEWAY_CONTROLUI_DANGEROUSLY_DISABLE_DEVICE_AUTH" \
  OPENCLAW_INIT_CONTROL_UI_ALLOWED_ORIGINS="${OPENCLAW_INIT_CONTROL_UI_ALLOWED_ORIGINS:-}" \
  python3 - <<'PY'
import json
import os
import sys
from pathlib import Path

config_path = Path(os.environ["OPENCLAW_CONFIG_PATH"])
config = {}
if config_path.exists():
    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
    except Exception:
        config = {}

provider = os.environ.get("OPENCLAW_LLM_PROVIDER", "thirdparty").strip() or "thirdparty"
model = (os.environ.get("OPENCLAW_LLM_MODEL") or "").strip()
api = os.environ.get("OPENCLAW_LLM_API", "openai-completions").strip() or "openai-completions"
base_env_name = os.environ.get("OPENCLAW_LLM_BASE_URL_ENV", "OPENCLAW_LLM_BASE_URL").strip() or "OPENCLAW_LLM_BASE_URL"
key_env_name = os.environ.get("OPENCLAW_LLM_API_KEY_ENV", "OPENCLAW_LLM_API_KEY").strip() or "OPENCLAW_LLM_API_KEY"
base_url_value = (os.environ.get(base_env_name) or "").strip()
api_key_value = (os.environ.get(key_env_name) or "").strip()

missing_llm_env = []
if not model:
    missing_llm_env.append("OPENCLAW_LLM_MODEL")
if not base_url_value:
    missing_llm_env.append(base_env_name)
if not api_key_value:
    missing_llm_env.append(key_env_name)
custom_llm_ready = not missing_llm_env
model_ref = f"{provider}/{model}" if custom_llm_ready else ""

if missing_llm_env:
    print(
        "openclaw: skip custom LLM model configuration because missing: "
        + ", ".join(missing_llm_env),
        file=sys.stderr,
    )
    sshx_auto_start = (os.environ.get("OPENCLAW_SSHX_AUTO_START") or "false").strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
    }
    if not sshx_auto_start:
        print(
            "openclaw: if you want to configure LLM via sshx, consider setting OPENCLAW_SSHX_AUTO_START=true",
            file=sys.stderr,
        )

fallback_allowed_origins = [f"http://127.0.0.1:{os.environ.get('OPENCLAW_GATEWAY_PORT', '7860')}"]
allowed_origins = fallback_allowed_origins
raw_allowed_origins = (os.environ.get("OPENCLAW_INIT_CONTROL_UI_ALLOWED_ORIGINS") or "").strip()
if raw_allowed_origins:
    try:
        parsed = json.loads(raw_allowed_origins)
        if isinstance(parsed, list):
            normalized = []
            for value in parsed:
                if isinstance(value, str):
                    item = value.strip()
                    if item:
                        normalized.append(item)
            if normalized:
                allowed_origins = normalized
    except Exception:
        pass

fallback_origin = (os.environ.get("OPENCLAW_GATEWAY_CONTROLUI_DANGEROUSLY_ALLOW_HOST_HEADER_ORIGIN_FALLBACK") or "true").lower() in {
    "1",
    "true",
    "yes",
    "on",
}
allow_insecure_auth = (os.environ.get("OPENCLAW_GATEWAY_CONTROLUI_ALLOW_INSECURE_AUTH") or "false").lower() in {
    "1",
    "true",
    "yes",
    "on",
}
disable_device_auth = (os.environ.get("OPENCLAW_GATEWAY_CONTROLUI_DANGEROUSLY_DISABLE_DEVICE_AUTH") or "false").lower() in {
    "1",
    "true",
    "yes",
    "on",
}

gateway = config.get("gateway")
if not isinstance(gateway, dict):
    gateway = {}
gateway["mode"] = os.environ.get("OPENCLAW_INIT_GATEWAY_MODE", "local")
gateway["bind"] = os.environ.get("OPENCLAW_GATEWAY_BIND", "lan")
auth = gateway.get("auth")
if not isinstance(auth, dict):
    auth = {}

token_value = (os.environ.get("OPENCLAW_GATEWAY_TOKEN") or "").strip()
password_value = (os.environ.get("OPENCLAW_GATEWAY_PASSWORD") or "").strip()
if token_value:
    auth["token"] = token_value
if password_value:
    auth["password"] = password_value

valid_auth_modes = {"none", "token", "password", "trusted-proxy"}
mode_env = (os.environ.get("OPENCLAW_GATEWAY_AUTH_MODE") or "").strip().lower()
existing_mode = auth.get("mode")
if mode_env in valid_auth_modes:
    auth["mode"] = mode_env
elif password_value and not token_value:
    auth["mode"] = "password"
elif token_value and not password_value:
    auth["mode"] = "token"
elif token_value and password_value:
    auth["mode"] = "token"
elif isinstance(existing_mode, str) and existing_mode.strip().lower() in valid_auth_modes:
    auth["mode"] = existing_mode.strip().lower()
else:
    auth["mode"] = "token"

gateway["auth"] = auth
gateway.setdefault("controlUi", {})
gateway["controlUi"]["allowedOrigins"] = allowed_origins
gateway["controlUi"]["dangerouslyAllowHostHeaderOriginFallback"] = fallback_origin
gateway["controlUi"]["allowInsecureAuth"] = allow_insecure_auth
gateway["controlUi"]["dangerouslyDisableDeviceAuth"] = disable_device_auth
config["gateway"] = gateway

agents = config.get("agents")
if not isinstance(agents, dict):
    agents = {}
defaults = agents.get("defaults")
if not isinstance(defaults, dict):
    defaults = {}
if custom_llm_ready:
    defaults["model"] = {"primary": model_ref}
    allow_models = defaults.get("models")
    if not isinstance(allow_models, dict):
        allow_models = {}
    allow_models.setdefault(model_ref, {"alias": "Default"})
    defaults["models"] = allow_models
agents["defaults"] = defaults
config["agents"] = agents

if custom_llm_ready:
    models_cfg = config.get("models")
    if not isinstance(models_cfg, dict):
        models_cfg = {}
    models_cfg["mode"] = "merge"
    providers = models_cfg.get("providers")
    if not isinstance(providers, dict):
        providers = {}
    provider_cfg = providers.get(provider)
    if not isinstance(provider_cfg, dict):
        provider_cfg = {}
    provider_cfg["baseUrl"] = f"${{{base_env_name}}}"
    provider_cfg["apiKey"] = f"${{{key_env_name}}}"
    provider_cfg["api"] = api
    provider_cfg["models"] = [{"id": model, "name": model}]
    providers[provider] = provider_cfg
    models_cfg["providers"] = providers
    config["models"] = models_cfg

config_path.parent.mkdir(parents=True, exist_ok=True)
config_path.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
os.chmod(config_path, 0o600)
PY
}

write_backup_env_file() {
  local backup_env_file
  local keys=(
    HF_TOKEN
    HUGGINGFACE_HUB_TOKEN
    OPENCLAW_BACKUP_DATASET_REPO
    OPENCLAW_BACKUP_REPO_TYPE
    OPENCLAW_BACKUP_PATH_PREFIX
    OPENCLAW_BACKUP_LATEST_NAME
    OPENCLAW_BACKUP_KEEP_COUNT
    OPENCLAW_BACKUP_PRIVATE
    OPENCLAW_BACKUP_WORK_DIR
    OPENCLAW_BACKUP_SOURCE_DIR
    OPENCLAW_BACKUP_ROOT_CONFIG_DIR
    OPENCLAW_BACKUP_ROOT_CODEX_DIR
    OPENCLAW_BACKUP_ROOT_CLAUDE_DIR
    OPENCLAW_BACKUP_ROOT_AGENTS_DIR
    OPENCLAW_BACKUP_ROOT_SSH_DIR
    OPENCLAW_BACKUP_ROOT_NPM_DIR
    OPENCLAW_BACKUP_ROOT_LARK_CLI_DIR
    OPENCLAW_STATE_DIR
  )

  backup_env_file="${OPENCLAW_BACKUP_ENV_FILE_PATH:-/etc/openclaw-backup.env}"
  if [[ "$(id -u)" -ne 0 && "$backup_env_file" == "/etc/openclaw-backup.env" ]]; then
    backup_env_file="${OPENCLAW_STATE_DIR}/openclaw-backup.env"
  fi

  mkdir -p "$(dirname "$backup_env_file")"
  if ! : > "$backup_env_file"; then
    echo "openclaw: cannot write backup env file at $backup_env_file" >&2
    return 1
  fi

  for key in "${keys[@]}"; do
    printf '%s=%q\n' "$key" "${!key:-}" >> "$backup_env_file"
  done
  OPENCLAW_BACKUP_ENV_FILE_PATH="$backup_env_file"
  export OPENCLAW_BACKUP_ENV_FILE_PATH

  if [[ "$(id -u)" -eq 0 ]]; then
    chown "$OPENCLAW_USER:$OPENCLAW_GROUP" "$backup_env_file"
    chmod 640 "$backup_env_file"
  else
    chmod 600 "$backup_env_file"
  fi
}

setup_backup_cron() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "openclaw: backup cron requires root; skip cron setup" >&2
    return 0
  fi

  if ! is_true "$OPENCLAW_BACKUP_ENABLED"; then
    return 0
  fi

  if [[ -z "${OPENCLAW_BACKUP_DATASET_REPO:-}" ]]; then
    echo "openclaw: backup enabled but OPENCLAW_BACKUP_DATASET_REPO is empty; skip cron" >&2
    return 0
  fi

  if ! write_backup_env_file; then
    echo "openclaw: backup env file unavailable; skip cron setup" >&2
    return 0
  fi

  cat > /etc/cron.d/openclaw-backup <<EOFCRON
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
OPENCLAW_BACKUP_ENV_FILE_PATH=${OPENCLAW_BACKUP_ENV_FILE_PATH}
${OPENCLAW_BACKUP_CRON} ${OPENCLAW_USER} /usr/local/bin/openclaw-backup-cron.sh >> /var/log/openclaw/backup.log 2>&1
EOFCRON
  chmod 0644 /etc/cron.d/openclaw-backup
  touch /var/log/openclaw/backup.log
  chown "$OPENCLAW_USER:$OPENCLAW_GROUP" /var/log/openclaw/backup.log

  if pgrep -x cron >/dev/null 2>&1; then
    return 0
  fi

  cron
}

restore_from_backup_on_startup() {
  if [[ -z "${OPENCLAW_BACKUP_DATASET_REPO:-}" ]]; then
    echo "openclaw: startup restore skipped (OPENCLAW_BACKUP_DATASET_REPO is empty)" >&2
    return 0
  fi

  if ! write_backup_env_file; then
    echo "openclaw: backup env file unavailable; skip startup restore" >&2
    return 0
  fi
  if /usr/local/bin/openclaw-restore.sh; then
    echo "openclaw: restore finished"
  else
    echo "openclaw: restore skipped or failed, continue startup" >&2
  fi
}

run_as_node() {
  local cmd=("$@")
  if [[ "$(id -u)" -eq 0 ]]; then
    exec gosu "$OPENCLAW_USER:$OPENCLAW_GROUP" "${cmd[@]}" >>"$OPENCLAW_STDOUT_LOG_PATH" 2>>"$OPENCLAW_STDERR_LOG_PATH"
  fi
  exec "${cmd[@]}" >>"$OPENCLAW_STDOUT_LOG_PATH" 2>>"$OPENCLAW_STDERR_LOG_PATH"
}

run_as_node_background() {
  local cmd=("$@")
  if [[ "$(id -u)" -eq 0 ]]; then
    gosu "$OPENCLAW_USER:$OPENCLAW_GROUP" "${cmd[@]}" >>"$OPENCLAW_STDOUT_LOG_PATH" 2>>"$OPENCLAW_STDERR_LOG_PATH" &
  else
    "${cmd[@]}" >>"$OPENCLAW_STDOUT_LOG_PATH" 2>>"$OPENCLAW_STDERR_LOG_PATH" &
  fi
  OPENCLAW_CHILD_PID="$!"
}

start_sshx_background() {
  if ! is_true "$OPENCLAW_SSHX_AUTO_START"; then
    return 0
  fi

  if ! command -v sshx >/dev/null 2>&1; then
    echo "openclaw: OPENCLAW_SSHX_AUTO_START=true but sshx not found; skip auto start" >&2
    return 0
  fi

  if [[ "$(id -u)" -eq 0 ]]; then
    gosu "$OPENCLAW_USER:$OPENCLAW_GROUP" sshx >/proc/1/fd/1 2>/proc/1/fd/2 &
  else
    sshx >/proc/1/fd/1 2>/proc/1/fd/2 &
  fi
  OPENCLAW_SSHX_PID="$!"
  echo "openclaw: sshx started in background (pid=$OPENCLAW_SSHX_PID)"
}

stop_sshx_background() {
  if [[ -n "$OPENCLAW_SSHX_PID" ]] && kill -0 "$OPENCLAW_SSHX_PID" >/dev/null 2>&1; then
    echo "openclaw: stopping sshx background process (pid=$OPENCLAW_SSHX_PID)"
    kill "$OPENCLAW_SSHX_PID" >/dev/null 2>&1 || true
    wait "$OPENCLAW_SSHX_PID" >/dev/null 2>&1 || true
  fi
}

backup_on_shutdown() {
  if [[ "$OPENCLAW_SHUTDOWN_BACKUP_DONE" -eq 1 ]]; then
    return 0
  fi
  OPENCLAW_SHUTDOWN_BACKUP_DONE=1

  if [[ -z "${OPENCLAW_BACKUP_DATASET_REPO:-}" ]]; then
    echo "openclaw: shutdown backup skipped (OPENCLAW_BACKUP_DATASET_REPO is empty)" >&2
    return 0
  fi

  if ! write_backup_env_file; then
    echo "openclaw: backup env file unavailable; skip shutdown backup" >&2
    return 0
  fi
  echo "openclaw: running shutdown backup"
  if /usr/local/bin/openclaw-backup-cron.sh; then
    echo "openclaw: shutdown backup completed"
  else
    echo "openclaw: shutdown backup failed, container will still exit" >&2
  fi
}

run_gateway_with_shutdown_backup() {
  local gateway_exit_code=0
  local shutting_down=0

  on_gateway_signal() {
    local signal="$1"
    if [[ "$shutting_down" -eq 1 ]]; then
      return 0
    fi
    shutting_down=1
    log_warn "received ${signal}, preparing graceful shutdown"

    if [[ -n "$OPENCLAW_CHILD_PID" ]] && kill -0 "$OPENCLAW_CHILD_PID" >/dev/null 2>&1; then
      kill -s "$signal" "$OPENCLAW_CHILD_PID" >/dev/null 2>&1 || kill "$OPENCLAW_CHILD_PID" >/dev/null 2>&1 || true
      if ! wait "$OPENCLAW_CHILD_PID"; then
        gateway_exit_code=$?
      fi
    fi

    log_info "gateway process stopped with code ${gateway_exit_code}"
    stop_sshx_background
    backup_on_shutdown
    trap - TERM INT QUIT
    exit "$gateway_exit_code"
  }

  trap 'on_gateway_signal TERM' TERM
  trap 'on_gateway_signal INT' INT
  trap 'on_gateway_signal QUIT' QUIT

  log_info "starting gateway process (bind=${OPENCLAW_GATEWAY_BIND}, port=${OPENCLAW_GATEWAY_PORT})"
  run_as_node_background openclaw gateway --allow-unconfigured --bind "$OPENCLAW_GATEWAY_BIND" --port "$OPENCLAW_GATEWAY_PORT" "$@"
  log_info "gateway process started (pid=${OPENCLAW_CHILD_PID})"
  if ! wait "$OPENCLAW_CHILD_PID"; then
    gateway_exit_code=$?
  fi
  log_info "gateway process exited (pid=${OPENCLAW_CHILD_PID}, code=${gateway_exit_code})"

  stop_sshx_background
  backup_on_shutdown
  trap - TERM INT QUIT
  return "$gateway_exit_code"
}

main() {
  if [[ "$#" -eq 0 ]]; then
    set -- gateway
  fi

  local subcommand="$1"
  shift || true

  if [[ "$subcommand" == "gateway" ]]; then
    log_info "starting gateway bootstrap sequence"
    run_step "prepare runtime directories" mkdir_state_dirs
    run_step "restore state from backup (if configured)" restore_from_backup_on_startup
    run_step "write or update gateway config" write_or_update_config
    run_step "fix file ownership and permissions" fix_permissions
    run_step "setup backup cron (if enabled)" setup_backup_cron
    run_step "start sshx background service (if enabled)" start_sshx_background
    OPENCLAW_STEP_INDEX=$((OPENCLAW_STEP_INDEX + 1))
    log_info "step ${OPENCLAW_STEP_INDEX} start: launch gateway"
    run_gateway_with_shutdown_backup "$@"
    local gateway_exit_code=$?
    if [[ "$gateway_exit_code" -ne 0 ]]; then
      log_warn "gateway exited with non-zero code ${gateway_exit_code}"
      return "$gateway_exit_code"
    fi
    log_info "step ${OPENCLAW_STEP_INDEX} done: launch gateway"
  else
    log_info "starting subcommand: openclaw ${subcommand}"
    run_as_node openclaw "$subcommand" "$@"
  fi
}

main "$@"
