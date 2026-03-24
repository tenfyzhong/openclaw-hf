# syntax=docker/dockerfile:1.7

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG OPENCLAW_VERSION=latest

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      cron \
      curl \
      git \
      gnupg \
      gosu \
      hostname \
      jq \
      openssl \
      procps \
      python3 \
      python3-pip \
      sudo \
      tar && \
    rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard --version "${OPENCLAW_VERSION}"

RUN /bin/bash -lc 'set -euo pipefail; \
    OPENCLAW_BIN="$(command -v openclaw || true)"; \
    if [[ -z "$OPENCLAW_BIN" && -x /root/.npm-global/bin/openclaw ]]; then \
      OPENCLAW_BIN=/root/.npm-global/bin/openclaw; \
    fi; \
    if [[ -z "$OPENCLAW_BIN" && -x /root/.local/bin/openclaw ]]; then \
      OPENCLAW_BIN=/root/.local/bin/openclaw; \
    fi; \
    if [[ -z "$OPENCLAW_BIN" ]]; then \
      echo "openclaw command not found after installer" >&2; \
      exit 1; \
    fi; \
    ln -sf "$OPENCLAW_BIN" /usr/local/bin/openclaw; \
    openclaw --help >/dev/null'

RUN python3 -m pip install --no-cache-dir --break-system-packages "huggingface_hub[cli]>=0.31.1"

RUN curl -sSf https://sshx.io/get | sh && \
    if [ -x /root/.local/bin/sshx ]; then ln -sf /root/.local/bin/sshx /usr/local/bin/sshx; fi && \
    sshx --help >/dev/null

RUN if ! getent group ubuntu >/dev/null; then \
      groupadd --system ubuntu || groupadd ubuntu; \
    fi && \
    if ! id -u ubuntu >/dev/null 2>&1; then \
      useradd --system --create-home --gid ubuntu --shell /bin/bash ubuntu || \
      useradd --create-home --gid ubuntu --shell /bin/bash ubuntu; \
    fi && \
    mkdir -p /etc/sudoers.d && \
    printf '%s\n' 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-ubuntu-nopasswd && \
    chmod 0440 /etc/sudoers.d/90-ubuntu-nopasswd

WORKDIR /opt/openclaw-hf

COPY openclaw_hf /opt/openclaw-hf/openclaw_hf
COPY scripts/openclaw-entrypoint.sh /usr/local/bin/openclaw-entrypoint.sh
COPY scripts/openclaw-backup-cron.sh /usr/local/bin/openclaw-backup-cron.sh
COPY scripts/openclaw-restore.sh /usr/local/bin/openclaw-restore.sh

RUN chmod 755 /usr/local/bin/openclaw-entrypoint.sh /usr/local/bin/openclaw-backup-cron.sh /usr/local/bin/openclaw-restore.sh && \
    mkdir -p /home/ubuntu/.openclaw/workspace /var/log/openclaw && \
    chown -R ubuntu:ubuntu /var/log/openclaw /home/ubuntu

ENV NODE_ENV=production
ENV PYTHONUNBUFFERED=1
ENV HOME=/home/ubuntu
ENV OPENCLAW_HOME=/home/ubuntu
ENV OPENCLAW_USER=ubuntu
ENV OPENCLAW_GROUP=ubuntu
ENV OPENCLAW_STATE_DIR=/home/ubuntu/.openclaw
ENV OPENCLAW_WORKSPACE_DIR=/home/ubuntu/.openclaw/workspace
ENV OPENCLAW_CONFIG_PATH=/home/ubuntu/.openclaw/openclaw.json
ENV OPENCLAW_GATEWAY_BIND=lan
ENV OPENCLAW_GATEWAY_PORT=7860
ENV OPENCLAW_INIT_GATEWAY_MODE=local
ENV OPENCLAW_GATEWAY_AUTH_MODE=token
ENV OPENCLAW_GATEWAY_CONTROLUI_DANGEROUSLY_ALLOW_HOST_HEADER_ORIGIN_FALLBACK=true
ENV OPENCLAW_GATEWAY_CONTROLUI_ALLOW_INSECURE_AUTH=false
ENV OPENCLAW_GATEWAY_CONTROLUI_DANGEROUSLY_DISABLE_DEVICE_AUTH=false
ENV OPENCLAW_LLM_PROVIDER=thirdparty
ENV OPENCLAW_LLM_MODEL=gpt-4o-mini
ENV OPENCLAW_LLM_API=openai-completions
ENV OPENCLAW_LLM_BASE_URL=https://api.openai.com/v1
ENV OPENCLAW_BACKUP_ENABLED=true
ENV OPENCLAW_BACKUP_CRON="*/30 * * * *"
ENV OPENCLAW_BACKUP_SOURCE_DIR=/home/ubuntu
ENV OPENCLAW_BACKUP_PRIVATE=true
ENV OPENCLAW_BACKUP_PATH_PREFIX=backups
ENV OPENCLAW_BACKUP_LATEST_NAME=latest-backup.tar.gz

EXPOSE 7860

HEALTHCHECK --interval=30s --timeout=5s --start-period=25s --retries=5 \
  CMD node -e "const p=process.env.OPENCLAW_GATEWAY_PORT||'7860';fetch('http://127.0.0.1:'+p+'/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

ENTRYPOINT ["/usr/local/bin/openclaw-entrypoint.sh"]
CMD ["gateway"]
