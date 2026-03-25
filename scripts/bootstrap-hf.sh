#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
HF_TOKEN_FILE="${HF_TOKEN_FILE:-$HOME/.cache/huggingface/token}"

trim() {
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

info() {
  printf '%s\n' "$*"
}

error() {
  printf 'error: %s\n' "$*" >&2
}

die() {
  error "$1"
  exit 1
}

prompt_line() {
  local prompt="$1"
  local default_value="${2:-}"
  local value=""

  if [[ -n "$default_value" ]]; then
    read -r -p "$prompt [$default_value]: " value || true
  else
    read -r -p "$prompt: " value || true
  fi

  value="$(trim "${value:-}")"
  if [[ -z "$value" ]]; then
    value="$default_value"
  fi
  printf '%s' "$value"
}

prompt_required() {
  local prompt="$1"
  local default_value="${2:-}"
  local value=""

  while [[ -z "$value" ]]; do
    value="$(prompt_line "$prompt" "$default_value")"
    value="$(trim "$value")"
    if [[ -z "$value" ]]; then
      printf 'This value is required.\n' >&2
    fi
  done
  printf '%s' "$value"
}

prompt_secret_optional() {
  local prompt="$1"
  local value=""

  if [[ -t 0 ]]; then
    read -r -s -p "$prompt: " value || true
    printf '\n' >&2
  else
    read -r -p "$prompt: " value || true
  fi
  printf '%s' "$(trim "${value:-}")"
}

prompt_yes_no() {
  local prompt="$1"
  local default_value="${2:-n}"
  local answer=""
  local hint="[y/N]"

  if [[ "$default_value" == "y" ]]; then
    hint="[Y/n]"
  fi

  while true; do
    read -r -p "$prompt $hint: " answer || true
    answer="$(trim "${answer:-}")"
    answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
    if [[ -z "$answer" ]]; then
      answer="$default_value"
    fi

    case "$answer" in
      y|yes)
        printf 'yes'
        return 0
        ;;
      n|no)
        printf 'no'
        return 0
        ;;
      *)
        printf 'Please enter y or n.\n' >&2
        ;;
    esac
  done
}

ensure_git() {
  command -v git >/dev/null 2>&1 || die "git is required. Please install git first."
}

ensure_hf_cli() {
  local os_name

  if command -v hf >/dev/null 2>&1; then
    return 0
  fi

  os_name="$(uname -s)"
  case "$os_name" in
    Darwin|Linux)
      info "hf CLI not found. Installing via https://hf.co/cli/install.sh ..."
      curl -LsSf https://hf.co/cli/install.sh | bash
      ;;
    *)
      die "hf CLI not found. For Windows use: powershell -ExecutionPolicy ByPass -c \"irm https://hf.co/cli/install.ps1 | iex\""
      ;;
  esac

  if [[ -d "$HOME/.local/bin" ]]; then
    PATH="$HOME/.local/bin:$PATH"
  fi

  command -v hf >/dev/null 2>&1 || die "hf CLI install failed. Please install manually and rerun."
}

ensure_huggingface_hub_py() {
  python3 -c "import huggingface_hub" >/dev/null 2>&1 || die "python3 package 'huggingface_hub' is required. Install with: python3 -m pip install --user 'huggingface_hub[cli]'"
}

resolve_latest_openclaw_version() {
  local version
  version="$(
    python3 - <<'PY' 2>/dev/null || true
import json
import urllib.request

url = "https://registry.npmjs.org/openclaw/latest"
try:
    with urllib.request.urlopen(url, timeout=8) as response:
        payload = response.read().decode("utf-8", errors="replace")
    data = json.loads(payload)
    version = str(data.get("version", "")).strip()
    if version:
        print(version)
except Exception:
    pass
PY
  )"
  version="$(trim "$version")"
  if [[ -z "$version" ]]; then
    version="latest"
  fi
  printf '%s' "$version"
}

read_current_hf_token() {
  if [[ -n "${HUGGINGFACE_HUB_TOKEN:-}" ]]; then
    printf '%s' "${HUGGINGFACE_HUB_TOKEN}" | tr -d '\r\n'
    return 0
  fi
  if [[ -n "${HF_TOKEN:-}" ]]; then
    printf '%s' "${HF_TOKEN}" | tr -d '\r\n'
    return 0
  fi
  if [[ -f "$HF_TOKEN_FILE" ]]; then
    head -n 1 "$HF_TOKEN_FILE" | tr -d '\r\n'
    return 0
  fi
  printf ''
}

get_hf_username() {
  local whoami_output
  local username
  local token_from_cache

  whoami_output="$(hf auth whoami 2>&1 || true)"
  username="$(printf '%s\n' "$whoami_output" | sed -nE 's/^[[:space:]]*user:[[:space:]]*([^[:space:]]+).*$/\1/p' | head -n 1)"
  if [[ -z "$username" ]]; then
    username="$(printf '%s\n' "$whoami_output" | sed -nE 's/.*[Ll]ogged in as[[:space:]]+([^[:space:]]+).*$/\1/p' | head -n 1)"
  fi
  if [[ -z "$username" ]]; then
    token_from_cache="$(read_current_hf_token)"
    if [[ -n "$token_from_cache" ]]; then
      username="$(
        HF_API_TOKEN="$token_from_cache" python3 - <<'PY' 2>/dev/null || true
from huggingface_hub import HfApi
import os

token = (os.environ.get("HF_API_TOKEN") or "").strip() or None
api = HfApi(token=token)
data = api.whoami(token=token)
name = data.get("name", "") if isinstance(data, dict) else ""
print((name or "").strip())
PY
      )"
    fi
  fi
  username="$(printf '%s' "$username" | tr -d '\r\n')"
  printf '%s' "$username"
}

set_space_variable() {
  local space_repo_id="$1"
  local key="$2"
  local value="$3"
  local api_token="$4"

  SPACE_REPO_ID="$space_repo_id" \
  SPACE_VARIABLE_KEY="$key" \
  SPACE_VARIABLE_VALUE="$value" \
  HF_API_TOKEN="$api_token" \
  python3 - <<'PY'
from huggingface_hub import HfApi
import os

token = (os.environ.get("HF_API_TOKEN") or "").strip() or None
api = HfApi(token=token)
try:
    api.add_space_variable(
        repo_id=os.environ["SPACE_REPO_ID"],
        key=os.environ["SPACE_VARIABLE_KEY"],
        value=os.environ["SPACE_VARIABLE_VALUE"],
    )
except Exception as exc:
    key = os.environ.get("SPACE_VARIABLE_KEY", "")
    repo_id = os.environ.get("SPACE_REPO_ID", "")
    raise SystemExit(f"failed to set space variable {key} on {repo_id}: {exc}")
PY
}

set_space_secret() {
  local space_repo_id="$1"
  local key="$2"
  local value="$3"
  local api_token="$4"

  SPACE_REPO_ID="$space_repo_id" \
  SPACE_SECRET_KEY="$key" \
  SPACE_SECRET_VALUE="$value" \
  HF_API_TOKEN="$api_token" \
  python3 - <<'PY'
from huggingface_hub import HfApi
import os

token = (os.environ.get("HF_API_TOKEN") or "").strip() or None
api = HfApi(token=token)
try:
    api.add_space_secret(
        repo_id=os.environ["SPACE_REPO_ID"],
        key=os.environ["SPACE_SECRET_KEY"],
        value=os.environ["SPACE_SECRET_VALUE"],
    )
except Exception as exc:
    key = os.environ.get("SPACE_SECRET_KEY", "")
    repo_id = os.environ.get("SPACE_REPO_ID", "")
    raise SystemExit(f"failed to set space secret {key} on {repo_id}: {exc}")
PY
}

restart_space() {
  local space_repo_id="$1"
  local api_token="$2"

  SPACE_RESTART_REPO_ID="$space_repo_id" \
  HF_API_TOKEN="$api_token" \
  python3 - <<'PY'
from huggingface_hub import HfApi
import os

token = (os.environ.get("HF_API_TOKEN") or "").strip() or None
api = HfApi(token=token)
try:
    api.restart_space(repo_id=os.environ["SPACE_RESTART_REPO_ID"])
except Exception as exc:
    repo_id = os.environ.get("SPACE_RESTART_REPO_ID", "")
    raise SystemExit(f"failed to restart space {repo_id}: {exc}")
PY
}

main() {
  local hf_username
  local space_name
  local dataset_name
  local space_repo_id
  local dataset_repo_id
  local default_openclaw_version
  local openclaw_version
  local gateway_token
  local gateway_password
  local generated_gateway_token=0
  local generated_gateway_password=0
  local current_hf_token
  local hf_token_for_backup
  local configure_llm
  local llm_base_url=""
  local llm_model=""
  local llm_api_key=""
  local enable_sshx="no"
  local restart_now
  local api_token
  local space_host
  local app_url
  local health_url

  cd "$REPO_ROOT"

  info "OpenClaw Hugging Face bootstrap (interactive)"
  ensure_git
  ensure_hf_cli
  ensure_huggingface_hub_py
  git --version
  hf version
  python3 --version

  if ! hf auth whoami >/dev/null 2>&1; then
    info "HF CLI is not logged in. Starting 'hf auth login'..."
    hf auth login
  fi

  hf_username="$(get_hf_username)"
  hf_username="$(trim "$hf_username")"
  if [[ -z "$hf_username" ]]; then
    hf_username="$(prompt_required "HF username (cannot parse from hf auth whoami)")"
  fi
  info "HF user: $hf_username"

  space_name="$(prompt_required "Space name (without username)" "openclaw-hf")"
  dataset_name="$(prompt_required "Dataset name (without username)" "${space_name}-backup")"
  default_openclaw_version="$(trim "${OPENCLAW_VERSION:-}")"
  if [[ -z "$default_openclaw_version" ]]; then
    default_openclaw_version="$(resolve_latest_openclaw_version)"
  fi
  openclaw_version="$(prompt_required "OPENCLAW_VERSION (press Enter to use detected latest)" "$default_openclaw_version")"
  space_repo_id="${hf_username}/${space_name}"
  dataset_repo_id="${hf_username}/${dataset_name}"

  gateway_token="$(prompt_secret_optional "OPENCLAW_GATEWAY_TOKEN (optional, leave empty to auto-generate 32 chars)")"
  if [[ -z "$gateway_token" ]]; then
    gateway_token="$(openssl rand -hex 16)"
    generated_gateway_token=1
  fi

  gateway_password="$(prompt_secret_optional "OPENCLAW_GATEWAY_PASSWORD (optional, leave empty to auto-generate 16 chars)")"
  if [[ -z "$gateway_password" ]]; then
    gateway_password="$(openssl rand -hex 8)"
    generated_gateway_password=1
  fi

  current_hf_token="$(read_current_hf_token)"
  hf_token_for_backup="$(prompt_secret_optional "HF_TOKEN for backup dataset (optional, leave empty to reuse current login token)")"
  if [[ -z "$hf_token_for_backup" ]]; then
    hf_token_for_backup="$current_hf_token"
  fi
  [[ -n "$hf_token_for_backup" ]] || die "HF_TOKEN is required to configure Space secret HF_TOKEN."

  configure_llm="$(prompt_yes_no "Configure custom LLM now?" "n")"
  if [[ "$configure_llm" == "yes" ]]; then
    llm_base_url="$(prompt_required "OPENCLAW_LLM_BASE_URL")"
    llm_model="$(prompt_required "OPENCLAW_LLM_MODEL")"
    llm_api_key="$(prompt_secret_optional "OPENCLAW_LLM_API_KEY")"
    [[ -n "$llm_api_key" ]] || die "OPENCLAW_LLM_API_KEY is required when enabling custom LLM config."
  else
    enable_sshx="$(prompt_yes_no "Set OPENCLAW_SSHX_AUTO_START=true for later sshx setup?" "y")"
  fi

  restart_now="$(prompt_yes_no "Restart Space at the end?" "y")"

  info "Creating private Space and Dataset..."
  hf repo create "$space_repo_id" --repo-type space --space-sdk docker --private --exist-ok
  hf repo create "$dataset_repo_id" --repo-type dataset --private --exist-ok

  info "Uploading repository to Space..."
  hf upload "$space_repo_id" . --repo-type space --exclude '.git/**' --exclude '.git' \
    --commit-message "feat: deploy openclaw to hf space"

  api_token="$(read_current_hf_token)"
  if [[ -z "$api_token" ]]; then
    api_token="$hf_token_for_backup"
  fi

  info "Configuring Space variables and secrets..."
  set_space_variable "$space_repo_id" "OPENCLAW_BACKUP_DATASET_REPO" "$dataset_repo_id" "$api_token"
  set_space_variable "$space_repo_id" "OPENCLAW_VERSION" "$openclaw_version" "$api_token"
  set_space_variable "$space_repo_id" "OPENCLAW_GATEWAY_CONTROLUI_ALLOW_INSECURE_AUTH" "true" "$api_token"
  set_space_variable "$space_repo_id" "OPENCLAW_GATEWAY_CONTROLUI_DANGEROUSLY_DISABLE_DEVICE_AUTH" "true" "$api_token"
  set_space_secret "$space_repo_id" "OPENCLAW_GATEWAY_TOKEN" "$gateway_token" "$api_token"
  set_space_secret "$space_repo_id" "OPENCLAW_GATEWAY_PASSWORD" "$gateway_password" "$api_token"
  set_space_secret "$space_repo_id" "HF_TOKEN" "$hf_token_for_backup" "$api_token"

  if [[ "$configure_llm" == "yes" ]]; then
    set_space_variable "$space_repo_id" "OPENCLAW_LLM_BASE_URL" "$llm_base_url" "$api_token"
    set_space_variable "$space_repo_id" "OPENCLAW_LLM_MODEL" "$llm_model" "$api_token"
    set_space_secret "$space_repo_id" "OPENCLAW_LLM_API_KEY" "$llm_api_key" "$api_token"
  elif [[ "$enable_sshx" == "yes" ]]; then
    set_space_variable "$space_repo_id" "OPENCLAW_SSHX_AUTO_START" "true" "$api_token"
  fi

  if [[ "$restart_now" == "yes" ]]; then
    info "Restarting Space..."
    if ! restart_space "$space_repo_id" "$api_token"; then
      error "Space restart failed. You can restart manually from Hugging Face Space Settings."
    fi
  fi

  space_host="${space_repo_id/\//-}.hf.space"
  app_url="https://${space_host}"
  health_url="${app_url}/healthz"

  info ""
  info "Deployment complete."
  info "Space repo: $space_repo_id"
  info "Dataset repo: $dataset_repo_id"
  info "OPENCLAW_VERSION: $openclaw_version"
  info "Space URL: $app_url"
  info "Health URL: $health_url"

  if [[ "$generated_gateway_token" -eq 1 ]]; then
    info "Generated OPENCLAW_GATEWAY_TOKEN=$gateway_token"
  fi
  if [[ "$generated_gateway_password" -eq 1 ]]; then
    info "Generated OPENCLAW_GATEWAY_PASSWORD=$gateway_password"
  fi
}

main "$@"
