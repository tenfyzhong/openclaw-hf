---
name: openclaw-hf-deploy
description: Agent SOP for deploying this repository to Hugging Face Space with the project bootstrap scripts.
---

# OpenClaw HF Deployment Skill

Use this skill when a user asks an agent to deploy `openclaw-hf` to Hugging Face.

## Hard rules

- Always reuse project bootstrap scripts:
  - macOS/Linux: `./scripts/bootstrap-hf.sh`
  - Windows PowerShell: `powershell -ExecutionPolicy ByPass -File .\scripts\bootstrap-hf.ps1`
- Do not hand-roll a separate deployment flow unless the user explicitly asks for manual fallback.
- Keep secrets masked in agent logs and summaries.

## 1. Preflight checks

Run and verify:

```bash
command -v git >/dev/null 2>&1 || MISSING_GIT=1
command -v hf >/dev/null 2>&1 || MISSING_HF=1
command -v python3 >/dev/null 2>&1 || MISSING_PYTHON3=1
git --version
hf version
python3 --version
python3 -c "import huggingface_hub" >/dev/null 2>&1 || python3 -m pip install --user 'huggingface_hub[cli]'
```

Install missing tools before continuing.

## 2. HF auth flow must run first (before any other variables)

1. If user already provided `HF_TOKEN` in the conversation:
   - use this `HF_TOKEN` directly: `hf auth login --token <HF_TOKEN>`
   - if a different user is currently logged in, backup current token first and restore it after deployment
   - do not ask whether to keep current logged-in user
2. Otherwise, check login: `hf auth whoami`.
3. If not logged in:
   - ask user for `HF_TOKEN` (required)
   - run: `hf auth login --token <HF_TOKEN>`
4. If already logged in:
   - ask whether to use current logged-in user
   - if `yes`: continue
   - if `no`:
     - backup current token
     - ask for new `HF_TOKEN`
     - run: `hf auth login --token <HF_TOKEN>`
     - continue deployment with new account
     - after deployment, restore previous token

## 3. Collect remaining inputs in prompt order

After step 2 is completed, collect:

1. `space_name` (default `openclaw-hf`)
2. `dataset_name` (default `<space_name>-backup`)
3. `OPENCLAW_VERSION` (default latest detected from npm, fallback `latest`)
4. `OPENCLAW_GATEWAY_TOKEN` (optional, auto-generated if empty)
5. `OPENCLAW_GATEWAY_PASSWORD` (optional, auto-generated if empty)
6. `Configure custom LLM now?` (`y/N`)
   - if `yes`: `OPENCLAW_LLM_BASE_URL`, `OPENCLAW_LLM_MODEL`, `OPENCLAW_LLM_API_KEY`
   - if `no`: `OPENCLAW_SSHX_AUTO_START` (`Y/n`)
7. `Proceed with these settings?` defaults to `Y`; agent should press Enter directly and not collect this input from user.

If user explicitly asks to cancel before execution, answer `n` at final confirmation and stop without creating/updating remote resources.

## 4. Execute deployment

From repo root, run the platform-specific bootstrap script and follow prompts in order.

The script will:

- create private Space and Dataset
- upload repository to Space
- configure Space variables and secrets, including `OPENCLAW_BACKUP_DATASET_REPO`, `OPENCLAW_VERSION`, `HF_TOKEN`, gateway secrets, and optional LLM/SSHX settings

## 5. Required final hand-off

Agent final message must include:

- Space repo ID: `<owner>/<space_name>`
- Space page URL: `https://huggingface.co/spaces/<owner>/<space_name>`
- Dataset repo ID: `<owner>/<dataset_name>`
- `OPENCLAW_VERSION` used
- App URL: `https://<owner>-<space_name>.hf.space`
- Health URL: `https://<owner>-<space_name>.hf.space/healthz`
- auto-generated gateway token/password if generated
- keep-alive note: free tier may sleep; paid hardware + `Sleep time=Never` for strict 24/7 uptime
