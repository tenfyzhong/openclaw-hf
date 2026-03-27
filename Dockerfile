# syntax=docker/dockerfile:1.7

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG OPENCLAW_VERSION
ENV OPENCLAW_VERSION=$OPENCLAW_VERSION

RUN printf 'Acquire::Retries "5";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' \
      > /etc/apt/apt.conf.d/80-openclaw-retries && \
    set -eux; \
    for attempt in 1 2 3 4 5; do \
      if apt-get update && apt-get install -y --no-install-recommends \
          ca-certificates \
          cmake \
          cron \
          curl \
          g++ \
          gh \
          git \
          gnupg \
          gosu \
          hostname \
          jq \
          libasound2t64 \
          libatk-bridge2.0-0 \
          libatk1.0-0 \
          libatspi2.0-0 \
          libdbus-1-3 \
          libgbm1 \
          libglib2.0-0 \
          libnspr4 \
          libnss3 \
          libx11-6 \
          libxcb1 \
          libxcomposite1 \
          libxdamage1 \
          libxext6 \
          libxfixes3 \
          libxkbcommon0 \
          libxrandr2 \
          make \
          neovim \
          openssl \
          procps \
          python3 \
          python3-pip \
          tar \
          unzip \
          vim; then \
        break; \
      fi; \
      if [ "$attempt" -eq 5 ]; then \
        exit 1; \
      fi; \
      echo "apt bootstrap failed on attempt $attempt, retrying..." >&2; \
      rm -rf /var/lib/apt/lists/*; \
      sleep $((attempt * 5)); \
    done; \
    rm -rf /var/lib/apt/lists/*

RUN /bin/bash -lc 'set -euo pipefail; \
    CFT_VERSION="$(curl -fsSL https://googlechromelabs.github.io/chrome-for-testing/LATEST_RELEASE_STABLE)"; \
    DEB_ARCH="$(dpkg --print-architecture)"; \
    case "$DEB_ARCH" in \
      amd64) CFT_ARCH=linux64 ;; \
      arm64) CFT_ARCH=linux-arm64 ;; \
      *) echo "unsupported architecture for chrome-headless-shell: $DEB_ARCH" >&2; exit 1 ;; \
    esac; \
    CFT_ZIP="chrome-headless-shell-${CFT_ARCH}.zip"; \
    CFT_DIR="chrome-headless-shell-${CFT_ARCH}"; \
    CFT_URL="https://storage.googleapis.com/chrome-for-testing-public/${CFT_VERSION}/${CFT_ARCH}/${CFT_ZIP}"; \
    curl -fsSL "$CFT_URL" -o "/tmp/${CFT_ZIP}"; \
    rm -rf "/opt/${CFT_DIR}"; \
    unzip -q "/tmp/${CFT_ZIP}" -d /opt; \
    rm -f "/tmp/${CFT_ZIP}"; \
    ln -sf "/opt/${CFT_DIR}/chrome-headless-shell" /usr/local/bin/chromium-headless-shell; \
    chromium-headless-shell --version >/dev/null'

RUN /bin/bash -lc 'set -euo pipefail; \
    OPENCLAW_VERSION_VALUE="${OPENCLAW_VERSION:-latest}"; \
    HOME=/root curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard --version "$OPENCLAW_VERSION_VALUE"'

RUN /bin/bash -lc 'set -euo pipefail; \
    OPENCLAW_BIN="$(command -v openclaw || true)"; \
    if [[ -z "$OPENCLAW_BIN" ]] && [[ -x /root/.npm-global/bin/openclaw ]]; then \
      OPENCLAW_BIN=/root/.npm-global/bin/openclaw; \
    elif [[ -z "$OPENCLAW_BIN" ]] && [[ -x /root/.local/bin/openclaw ]]; then \
      OPENCLAW_BIN=/root/.local/bin/openclaw; \
    fi; \
    if [[ -z "$OPENCLAW_BIN" ]]; then \
      echo "openclaw command not found after installer" >&2; \
      exit 1; \
    fi; \
    ln -sf "$OPENCLAW_BIN" /usr/local/bin/openclaw; \
    /usr/local/bin/openclaw --help >/dev/null'

RUN /bin/bash -lc 'set -euo pipefail; \
    if ! command -v npm >/dev/null; then \
      echo "npm command not found; cannot install developer CLIs" >&2; \
      exit 1; \
    fi; \
    npm install -g --no-audit --no-fund opencode-ai @openai/codex @anthropic-ai/claude-code; \
    NPM_PREFIX="$(npm config get prefix)"; \
    NPM_BIN="${NPM_PREFIX%/}/bin"; \
    for cmd in opencode codex claude; do \
      CLI_BIN="$(command -v "$cmd" || true)"; \
      if [[ -z "$CLI_BIN" ]] && [[ -x "$NPM_BIN/$cmd" ]]; then \
        CLI_BIN="$NPM_BIN/$cmd"; \
      elif [[ -z "$CLI_BIN" ]] && [[ -x /root/.npm-global/bin/"$cmd" ]]; then \
        CLI_BIN=/root/.npm-global/bin/"$cmd"; \
      elif [[ -z "$CLI_BIN" ]] && [[ -x /root/.local/bin/"$cmd" ]]; then \
        CLI_BIN=/root/.local/bin/"$cmd"; \
      fi; \
      if [[ -z "$CLI_BIN" ]]; then \
        echo "$cmd command not found after npm install" >&2; \
        exit 1; \
      fi; \
      ln -sf "$CLI_BIN" "/usr/local/bin/$cmd"; \
      "/usr/local/bin/$cmd" --help >/dev/null; \
    done'

RUN python3 -m pip install --no-cache-dir --break-system-packages "huggingface_hub[cli]>=0.31.1" "uv>=0.6.0" && \
    hf --help >/dev/null && \
    uv --version >/dev/null

RUN python3 --version >/dev/null && \
    gh --version >/dev/null && \
    nvim --version >/dev/null && \
    command -v chromium-headless-shell >/dev/null

RUN HOME=/root /bin/bash -lc "curl -sSf https://sshx.io/get | sh" && \
    if [ -x /root/.local/bin/sshx ]; then ln -sf /root/.local/bin/sshx /usr/local/bin/sshx; fi && \
    sshx --help >/dev/null

WORKDIR /opt/openclaw-hf

COPY openclaw_hf /opt/openclaw-hf/openclaw_hf
COPY scripts/openclaw-entrypoint.sh /usr/local/bin/openclaw-entrypoint.sh
COPY scripts/openclaw-backup-cron.sh /usr/local/bin/openclaw-backup-cron.sh
COPY scripts/openclaw-restore.sh /usr/local/bin/openclaw-restore.sh

RUN chmod 755 /usr/local/bin/openclaw-entrypoint.sh /usr/local/bin/openclaw-backup-cron.sh /usr/local/bin/openclaw-restore.sh && \
    mkdir -p /root/.openclaw/workspace /var/log/openclaw

ENV NODE_ENV=production
ENV PYTHONUNBUFFERED=1
ENV HOME=/root
ENV OPENCLAW_HOME=/root
ENV OPENCLAW_USER=root
ENV OPENCLAW_GROUP=root
ENV OPENCLAW_STATE_DIR=/root/.openclaw
ENV OPENCLAW_WORKSPACE_DIR=/root/.openclaw/workspace
ENV OPENCLAW_CONFIG_PATH=/root/.openclaw/openclaw.json
ENV OPENCLAW_GATEWAY_BIND=lan
ENV OPENCLAW_GATEWAY_PORT=7860
ENV OPENCLAW_INIT_GATEWAY_MODE=local
ENV OPENCLAW_GATEWAY_AUTH_MODE=token
ENV OPENCLAW_GATEWAY_CONTROLUI_DANGEROUSLY_ALLOW_HOST_HEADER_ORIGIN_FALLBACK=true
ENV OPENCLAW_GATEWAY_CONTROLUI_ALLOW_INSECURE_AUTH=false
ENV OPENCLAW_GATEWAY_CONTROLUI_DANGEROUSLY_DISABLE_DEVICE_AUTH=false
ENV OPENCLAW_LLM_PROVIDER=thirdparty
ENV OPENCLAW_LLM_API=openai-completions
ENV OPENCLAW_BACKUP_ENABLED=true
ENV OPENCLAW_BACKUP_CRON="*/30 * * * *"
ENV OPENCLAW_BACKUP_SOURCE_DIR=/root/.openclaw
ENV OPENCLAW_BACKUP_ROOT_CONFIG_DIR=/root/.config
ENV OPENCLAW_BACKUP_ROOT_CODEX_DIR=/root/.codex
ENV OPENCLAW_BACKUP_ROOT_CLAUDE_DIR=/root/.claude
ENV OPENCLAW_BACKUP_ROOT_AGENTS_DIR=/root/.agents
ENV OPENCLAW_BACKUP_ROOT_SSH_DIR=/root/.ssh
ENV OPENCLAW_BACKUP_ROOT_NPM_DIR=/root/.npm
ENV OPENCLAW_SSHX_AUTO_START=false
ENV OPENCLAW_BACKUP_PRIVATE=true
ENV OPENCLAW_BACKUP_PATH_PREFIX=backups
ENV OPENCLAW_BACKUP_LATEST_NAME=latest-backup.tar.gz

EXPOSE 7860

HEALTHCHECK --interval=30s --timeout=5s --start-period=25s --retries=5 \
  CMD /bin/bash -lc 'set -euo pipefail; URL="http://127.0.0.1:${OPENCLAW_GATEWAY_PORT:-7860}/healthz"; curl -fsS --max-time 3 "$URL" >/dev/null'

ENTRYPOINT ["/usr/local/bin/openclaw-entrypoint.sh"]
CMD ["gateway"]
