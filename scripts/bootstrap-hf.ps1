Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script_dir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo_root = (Resolve-Path (Join-Path $script_dir "..")).Path
$hf_token_file = if ($env:HF_TOKEN_FILE) { $env:HF_TOKEN_FILE } else { Join-Path $HOME ".cache/huggingface/token" }

function Trim-Value {
  param([AllowNull()][string]$Value)

  if ($null -eq $Value) {
    return ""
  }
  return $Value.Trim()
}

function Write-Info {
  param([string]$Message)

  Write-Host $Message
}

$script:BootstrapStepIndex = 0

function Get-LogTimestamp {
  return (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
}

function Write-StepStart {
  param([string]$Message)

  $script:BootstrapStepIndex += 1
  Write-Info ("[{0}] [bootstrap step {1}] START {2}" -f (Get-LogTimestamp), $script:BootstrapStepIndex, $Message)
}

function Write-StepDone {
  param([string]$Message)

  Write-Info ("[{0}] [bootstrap step {1}] DONE  {2}" -f (Get-LogTimestamp), $script:BootstrapStepIndex, $Message)
}

function Invoke-Step {
  param(
    [string]$Message,
    [ScriptBlock]$Action
  )

  Write-StepStart -Message $Message
  & $Action
  Write-StepDone -Message $Message
}

function Fail {
  param([string]$Message)

  throw $Message
}

function Prompt-Line {
  param(
    [string]$Prompt,
    [string]$DefaultValue = ""
  )

  if ([string]::IsNullOrEmpty($DefaultValue)) {
    $raw = Read-Host -Prompt $Prompt
  } else {
    $raw = Read-Host -Prompt "$Prompt [$DefaultValue]"
  }

  $value = Trim-Value $raw
  if ([string]::IsNullOrEmpty($value)) {
    $value = $DefaultValue
  }
  return $value
}

function Prompt-Required {
  param(
    [string]$Prompt,
    [string]$DefaultValue = ""
  )

  while ($true) {
    $value = Trim-Value (Prompt-Line -Prompt $Prompt -DefaultValue $DefaultValue)
    if (-not [string]::IsNullOrEmpty($value)) {
      return $value
    }
    Write-Host "This value is required." -ForegroundColor Red
  }
}

function Convert-SecureStringToPlainText {
  param([System.Security.SecureString]$SecureValue)

  if ($null -eq $SecureValue) {
    return ""
  }

  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  }
  finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

function Prompt-SecretOptional {
  param([string]$Prompt)

  $secure_value = Read-Host -Prompt $Prompt -AsSecureString
  $plain_text = Convert-SecureStringToPlainText -SecureValue $secure_value
  return Trim-Value $plain_text
}

function Prompt-YesNo {
  param(
    [string]$Prompt,
    [ValidateSet("y", "n")][string]$DefaultValue = "n"
  )

  $hint = if ($DefaultValue -eq "y") { "[Y/n]" } else { "[y/N]" }

  while ($true) {
    $answer = Trim-Value (Read-Host -Prompt "$Prompt $hint")
    $answer = $answer.ToLowerInvariant()
    if ([string]::IsNullOrEmpty($answer)) {
      $answer = $DefaultValue
    }

    switch ($answer) {
      { $_ -in @("y", "yes") } { return "yes" }
      { $_ -in @("n", "no") } { return "no" }
      default {
        Write-Host "Please enter y or n." -ForegroundColor Red
      }
    }
  }
}

function New-RandomHex {
  param([int]$Length)

  if ($Length -le 0 -or ($Length % 2) -ne 0) {
    Fail "Length must be a positive even number."
  }

  $bytes = New-Object byte[] ($Length / 2)
  [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
  return ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
}

function Ensure-Git {
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Fail "git is required. Please install git first."
  }
}

function Ensure-HfCli {
  if (Get-Command hf -ErrorAction SilentlyContinue) {
    return
  }

  Write-Info "hf CLI not found. Installing via powershell -ExecutionPolicy ByPass -c `"irm https://hf.co/cli/install.ps1 | iex`" ..."
  & powershell -ExecutionPolicy ByPass -c "irm https://hf.co/cli/install.ps1 | iex"
  if ($LASTEXITCODE -ne 0) {
    Fail "hf CLI install failed. Please install manually and rerun."
  }

  $local_bin = Join-Path $HOME ".local/bin"
  if ((Test-Path $local_bin) -and -not (($env:PATH -split [IO.Path]::PathSeparator) -contains $local_bin)) {
    $env:PATH = "$local_bin$([IO.Path]::PathSeparator)$env:PATH"
  }

  if (-not (Get-Command hf -ErrorAction SilentlyContinue)) {
    Fail "hf CLI install failed. Please install manually and rerun."
  }
}

function Ensure-Python3 {
  if (-not (Get-Command python3 -ErrorAction SilentlyContinue)) {
    Fail "python3 is required. Please install python3 first."
  }
}

function Ensure-HuggingFaceHubPy {
  & python3 -c "import huggingface_hub" 2>$null
  if ($LASTEXITCODE -ne 0) {
    Fail "python3 package 'huggingface_hub' is required. Install with: python3 -m pip install --user 'huggingface_hub[cli]'"
  }
}

function Resolve-LatestOpenclawVersion {
  $python_code = @'
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
'@

  $version_output = & python3 -c $python_code 2>$null
  $version = Trim-Value (($version_output | Out-String))
  if ([string]::IsNullOrEmpty($version)) {
    return "latest"
  }
  return $version
}

function Read-CurrentHfToken {
  if (-not [string]::IsNullOrEmpty($env:HUGGINGFACE_HUB_TOKEN)) {
    return Trim-Value $env:HUGGINGFACE_HUB_TOKEN
  }
  if (-not [string]::IsNullOrEmpty($env:HF_TOKEN)) {
    return Trim-Value $env:HF_TOKEN
  }
  if (Test-Path $hf_token_file) {
    return Trim-Value (Get-Content -Path $hf_token_file -TotalCount 1)
  }
  return ""
}

function Test-HfLoggedIn {
  & hf auth whoami *> $null
  return ($LASTEXITCODE -eq 0)
}

function Get-HfUsername {
  $whoami_output = (& hf auth whoami 2>&1 | Out-String)

  $user_match = [regex]::Match($whoami_output, "(?im)^\s*user:\s*([^\s]+)")
  if ($user_match.Success) {
    return Trim-Value $user_match.Groups[1].Value
  }

  $login_match = [regex]::Match($whoami_output, "(?im)logged in as\s+([^\s]+)")
  if ($login_match.Success) {
    return Trim-Value $login_match.Groups[1].Value
  }

  $token_from_cache = Read-CurrentHfToken
  if (-not [string]::IsNullOrEmpty($token_from_cache)) {
    $env:HF_API_TOKEN = $token_from_cache
    $python_code = @'
from huggingface_hub import HfApi
import os

token = (os.environ.get("HF_API_TOKEN") or "").strip() or None
api = HfApi(token=token)
data = api.whoami(token=token)
name = data.get("name", "") if isinstance(data, dict) else ""
print((name or "").strip())
'@

    $name_output = & python3 -c $python_code 2>$null
    $name = Trim-Value (($name_output | Out-String))
    if (-not [string]::IsNullOrEmpty($name)) {
      return $name
    }
  }

  return ""
}

function Set-SpaceVariable {
  param(
    [string]$SpaceRepoId,
    [string]$Key,
    [string]$Value,
    [string]$ApiToken
  )

  $env:SPACE_REPO_ID = $SpaceRepoId
  $env:SPACE_VARIABLE_KEY = $Key
  $env:SPACE_VARIABLE_VALUE = $Value
  $env:HF_API_TOKEN = $ApiToken

  $python_code = @'
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
'@

  & python3 -c $python_code
  if ($LASTEXITCODE -ne 0) {
    Fail "failed to set space variable $Key"
  }
}

function Set-SpaceSecret {
  param(
    [string]$SpaceRepoId,
    [string]$Key,
    [string]$Value,
    [string]$ApiToken
  )

  $env:SPACE_REPO_ID = $SpaceRepoId
  $env:SPACE_SECRET_KEY = $Key
  $env:SPACE_SECRET_VALUE = $Value
  $env:HF_API_TOKEN = $ApiToken

  $python_code = @'
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
'@

  & python3 -c $python_code
  if ($LASTEXITCODE -ne 0) {
    Fail "failed to set space secret $Key"
  }
}

function Set-SpaceVariableLogged {
  param(
    [string]$SpaceRepoId,
    [string]$Key,
    [string]$Value,
    [string]$ApiToken
  )

  Invoke-Step -Message "Set Space variable $Key" -Action {
    Set-SpaceVariable -SpaceRepoId $SpaceRepoId -Key $Key -Value $Value -ApiToken $ApiToken
  }
}

function Set-SpaceSecretLogged {
  param(
    [string]$SpaceRepoId,
    [string]$Key,
    [string]$Value,
    [string]$ApiToken
  )

  Invoke-Step -Message "Set Space secret $Key" -Action {
    Set-SpaceSecret -SpaceRepoId $SpaceRepoId -Key $Key -Value $Value -ApiToken $ApiToken
  }
}

function Restart-Space {
  param(
    [string]$SpaceRepoId,
    [string]$ApiToken
  )

  $env:SPACE_RESTART_REPO_ID = $SpaceRepoId
  $env:HF_API_TOKEN = $ApiToken

  $python_code = @'
from huggingface_hub import HfApi
import os

token = (os.environ.get("HF_API_TOKEN") or "").strip() or None
api = HfApi(token=token)
try:
    api.restart_space(repo_id=os.environ["SPACE_RESTART_REPO_ID"])
except Exception as exc:
    repo_id = os.environ.get("SPACE_RESTART_REPO_ID", "")
    raise SystemExit(f"failed to restart space {repo_id}: {exc}")
'@

  & python3 -c $python_code
  if ($LASTEXITCODE -ne 0) {
    Fail "failed to restart space $SpaceRepoId"
  }
}

function Main {
  Invoke-Step -Message "Change directory to repository root" -Action {
    Set-Location $repo_root
  }

  Write-Info "OpenClaw Hugging Face bootstrap (interactive, Windows PowerShell)"
  Invoke-Step -Message "Check dependency git" -Action { Ensure-Git }
  Invoke-Step -Message "Check dependency hf CLI" -Action { Ensure-HfCli }
  Invoke-Step -Message "Check dependency python3" -Action { Ensure-Python3 }
  Invoke-Step -Message "Check dependency python package huggingface_hub" -Action { Ensure-HuggingFaceHubPy }
  Invoke-Step -Message "Print dependency versions" -Action {
    & git --version
    & hf version
    & python3 --version
  }
  Invoke-Step -Message "Ensure HF CLI login is active" -Action {
    if (-not (Test-HfLoggedIn)) {
      Write-Info "HF CLI is not logged in. Starting 'hf auth login'..."
      & hf auth login
      if ($LASTEXITCODE -ne 0) {
        Fail "hf auth login failed."
      }
    } else {
      Write-Info "HF CLI login already active."
    }
  }

  $hf_username = ""
  Invoke-Step -Message "Resolve HF username" -Action {
    $hf_username = Trim-Value (Get-HfUsername)
    if ([string]::IsNullOrEmpty($hf_username)) {
      $hf_username = Prompt-Required -Prompt "HF username (cannot parse from hf auth whoami)"
    }
    Write-Info "HF user: $hf_username"
  }

  $space_name = ""
  $dataset_name = ""
  Invoke-Step -Message "Collect Space and Dataset names" -Action {
    $space_name = Prompt-Required -Prompt "Space name (without username)" -DefaultValue "openclaw-hf"
    $dataset_name = Prompt-Required -Prompt "Dataset name (without username)" -DefaultValue "$space_name-backup"
  }

  $openclaw_version = ""
  Invoke-Step -Message "Resolve and confirm OPENCLAW_VERSION" -Action {
    $default_openclaw_version = Trim-Value $env:OPENCLAW_VERSION
    if ([string]::IsNullOrEmpty($default_openclaw_version)) {
      $default_openclaw_version = Resolve-LatestOpenclawVersion
    }
    $openclaw_version = Prompt-Required -Prompt "OPENCLAW_VERSION (press Enter to use detected latest)" -DefaultValue $default_openclaw_version
  }

  $space_repo_id = "$hf_username/$space_name"
  $dataset_repo_id = "$hf_username/$dataset_name"

  $gateway_token = ""
  $generated_gateway_token = $false
  Invoke-Step -Message "Collect OPENCLAW_GATEWAY_TOKEN" -Action {
    $gateway_token = Prompt-SecretOptional -Prompt "OPENCLAW_GATEWAY_TOKEN (optional, leave empty to auto-generate 32 chars)"
    if ([string]::IsNullOrEmpty($gateway_token)) {
      $gateway_token = New-RandomHex -Length 32
      $generated_gateway_token = $true
      Write-Info "OPENCLAW_GATEWAY_TOKEN generated automatically."
    }
  }

  $gateway_password = ""
  $generated_gateway_password = $false
  Invoke-Step -Message "Collect OPENCLAW_GATEWAY_PASSWORD" -Action {
    $gateway_password = Prompt-SecretOptional -Prompt "OPENCLAW_GATEWAY_PASSWORD (optional, leave empty to auto-generate 16 chars)"
    if ([string]::IsNullOrEmpty($gateway_password)) {
      $gateway_password = New-RandomHex -Length 16
      $generated_gateway_password = $true
      Write-Info "OPENCLAW_GATEWAY_PASSWORD generated automatically."
    }
  }

  $hf_token_for_backup = ""
  Invoke-Step -Message "Collect HF_TOKEN for backup dataset" -Action {
    $current_hf_token = Read-CurrentHfToken
    $hf_token_for_backup = Prompt-SecretOptional -Prompt "HF_TOKEN for backup dataset (optional, leave empty to reuse current login token)"
    if ([string]::IsNullOrEmpty($hf_token_for_backup)) {
      $hf_token_for_backup = $current_hf_token
    }
    if ([string]::IsNullOrEmpty($hf_token_for_backup)) {
      Fail "HF_TOKEN is required to configure Space secret HF_TOKEN."
    }
  }

  $configure_llm = "no"
  $llm_base_url = ""
  $llm_model = ""
  $llm_api_key = ""
  $enable_sshx = "no"
  Invoke-Step -Message "Collect custom LLM or sshx bootstrap options" -Action {
    $configure_llm = Prompt-YesNo -Prompt "Configure custom LLM now?" -DefaultValue "n"
    if ($configure_llm -eq "yes") {
      $llm_base_url = Prompt-Required -Prompt "OPENCLAW_LLM_BASE_URL"
      $llm_model = Prompt-Required -Prompt "OPENCLAW_LLM_MODEL"
      $llm_api_key = Prompt-SecretOptional -Prompt "OPENCLAW_LLM_API_KEY"
      if ([string]::IsNullOrEmpty($llm_api_key)) {
        Fail "OPENCLAW_LLM_API_KEY is required when enabling custom LLM config."
      }
    } else {
      $enable_sshx = Prompt-YesNo -Prompt "Set OPENCLAW_SSHX_AUTO_START=true for later sshx setup?" -DefaultValue "y"
    }
  }

  Invoke-Step -Message "Create Space repo $space_repo_id" -Action {
    & hf repo create $space_repo_id --repo-type space --space-sdk docker --private --exist-ok
    if ($LASTEXITCODE -ne 0) {
      Fail "failed to create Space repo"
    }
  }
  Invoke-Step -Message "Create Dataset repo $dataset_repo_id" -Action {
    & hf repo create $dataset_repo_id --repo-type dataset --private --exist-ok
    if ($LASTEXITCODE -ne 0) {
      Fail "failed to create Dataset repo"
    }
  }
  Invoke-Step -Message "Upload repository to Space $space_repo_id" -Action {
    & hf upload $space_repo_id . --repo-type space --exclude ".git/**" --exclude ".git" --commit-message "feat: deploy openclaw to hf space"
    if ($LASTEXITCODE -ne 0) {
      Fail "failed to upload repository to Space"
    }
  }

  $api_token = ""
  Invoke-Step -Message "Resolve API token for Space configuration" -Action {
    $api_token = Read-CurrentHfToken
    if ([string]::IsNullOrEmpty($api_token)) {
      $api_token = $hf_token_for_backup
    }
    if ([string]::IsNullOrEmpty($api_token)) {
      Fail "unable to resolve API token for Space configuration."
    }
  }

  Set-SpaceVariableLogged -SpaceRepoId $space_repo_id -Key "OPENCLAW_BACKUP_DATASET_REPO" -Value $dataset_repo_id -ApiToken $api_token
  Set-SpaceVariableLogged -SpaceRepoId $space_repo_id -Key "OPENCLAW_VERSION" -Value $openclaw_version -ApiToken $api_token
  Set-SpaceVariableLogged -SpaceRepoId $space_repo_id -Key "OPENCLAW_GATEWAY_CONTROLUI_ALLOW_INSECURE_AUTH" -Value "false" -ApiToken $api_token
  Set-SpaceVariableLogged -SpaceRepoId $space_repo_id -Key "OPENCLAW_GATEWAY_CONTROLUI_DANGEROUSLY_DISABLE_DEVICE_AUTH" -Value "false" -ApiToken $api_token
  Set-SpaceSecretLogged -SpaceRepoId $space_repo_id -Key "OPENCLAW_GATEWAY_TOKEN" -Value $gateway_token -ApiToken $api_token
  Set-SpaceSecretLogged -SpaceRepoId $space_repo_id -Key "OPENCLAW_GATEWAY_PASSWORD" -Value $gateway_password -ApiToken $api_token
  Set-SpaceSecretLogged -SpaceRepoId $space_repo_id -Key "HF_TOKEN" -Value $hf_token_for_backup -ApiToken $api_token

  if ($configure_llm -eq "yes") {
    Set-SpaceVariableLogged -SpaceRepoId $space_repo_id -Key "OPENCLAW_LLM_BASE_URL" -Value $llm_base_url -ApiToken $api_token
    Set-SpaceVariableLogged -SpaceRepoId $space_repo_id -Key "OPENCLAW_LLM_MODEL" -Value $llm_model -ApiToken $api_token
    Set-SpaceSecretLogged -SpaceRepoId $space_repo_id -Key "OPENCLAW_LLM_API_KEY" -Value $llm_api_key -ApiToken $api_token
  }

  if ($enable_sshx -eq "yes") {
    Set-SpaceVariableLogged -SpaceRepoId $space_repo_id -Key "OPENCLAW_SSHX_AUTO_START" -Value "true" -ApiToken $api_token
  } else {
    Set-SpaceVariableLogged -SpaceRepoId $space_repo_id -Key "OPENCLAW_SSHX_AUTO_START" -Value "false" -ApiToken $api_token
  }

  Invoke-Step -Message "Print deployment summary" -Action {
    $space_page_url = "https://huggingface.co/spaces/$space_repo_id"
    $space_host = "$($space_repo_id -replace '/', '-').hf.space"
    $app_url = "https://$space_host"
    $health_url = "$app_url/healthz"

    Write-Info ""
    Write-Info "Deployment complete."
    Write-Info "Space repo: $space_repo_id"
    Write-Info "Hugging Face Space: $space_page_url"
    Write-Info "Dataset repo: $dataset_repo_id"
    Write-Info "OPENCLAW_VERSION: $openclaw_version"
    Write-Info "Space URL: $app_url"
    Write-Info "Health URL: $health_url"

    if ($generated_gateway_token) {
      Write-Info "Generated OPENCLAW_GATEWAY_TOKEN=$gateway_token"
    }
    if ($generated_gateway_password) {
      Write-Info "Generated OPENCLAW_GATEWAY_PASSWORD=$gateway_password"
    }
  }
}

try {
  Main
}
catch {
  Write-Error $_.Exception.Message
  exit 1
}
