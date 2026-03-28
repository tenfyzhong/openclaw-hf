import unittest
from pathlib import Path


class BootstrapHfWindowsScriptTests(unittest.TestCase):
    @staticmethod
    def _repo_root() -> Path:
        return Path(__file__).resolve().parents[1]

    @classmethod
    def _script_text(cls) -> str:
        script_path = cls._repo_root() / "scripts" / "bootstrap-hf.ps1"
        return script_path.read_text(encoding="utf-8")

    def test_uses_windows_hf_cli_install_command(self):
        content = self._script_text()
        self.assertIn('powershell -ExecutionPolicy ByPass -c "irm https://hf.co/cli/install.ps1 | iex"', content)

    def test_generates_gateway_token_and_password_when_empty(self):
        content = self._script_text()
        self.assertIn("$gateway_token = New-RandomHex -Length 32", content)
        self.assertIn("$gateway_password = New-RandomHex -Length 16", content)
        self.assertIn('Write-Info "Generated OPENCLAW_GATEWAY_TOKEN=$gateway_token"', content)
        self.assertIn('Write-Info "Generated OPENCLAW_GATEWAY_PASSWORD=$gateway_password"', content)

    def test_openclaw_version_prefers_env_and_fallbacks_to_latest(self):
        content = self._script_text()
        self.assertIn("$default_openclaw_version = Trim-Value $env:OPENCLAW_VERSION", content)
        self.assertIn("$default_openclaw_version = Resolve-LatestOpenclawVersion", content)
        self.assertIn('return "latest"', content)

    def test_configures_space_variables_and_secrets(self):
        content = self._script_text()
        self.assertIn('Set-SpaceVariableLogged -SpaceRepoId $space_repo_id -Key "OPENCLAW_BACKUP_DATASET_REPO" -Value $dataset_repo_id -ApiToken $api_token', content)
        self.assertIn('Set-SpaceVariableLogged -SpaceRepoId $space_repo_id -Key "OPENCLAW_VERSION" -Value $openclaw_version -ApiToken $api_token', content)
        self.assertIn('Set-SpaceVariableLogged -SpaceRepoId $space_repo_id -Key "OPENCLAW_GATEWAY_CONTROLUI_ALLOW_INSECURE_AUTH" -Value "false" -ApiToken $api_token', content)
        self.assertIn('Set-SpaceVariableLogged -SpaceRepoId $space_repo_id -Key "OPENCLAW_GATEWAY_CONTROLUI_DANGEROUSLY_DISABLE_DEVICE_AUTH" -Value "false" -ApiToken $api_token', content)
        self.assertIn('Set-SpaceVariableLogged -SpaceRepoId $space_repo_id -Key "OPENCLAW_SSHX_AUTO_START" -Value $sshx_auto_start_value -ApiToken $api_token', content)
        self.assertIn('Set-SpaceSecretLogged -SpaceRepoId $space_repo_id -Key "HF_TOKEN" -Value $hf_token_for_backup -ApiToken $api_token', content)
        self.assertIn('Set-SpaceSecretLogged -SpaceRepoId $space_repo_id -Key "OPENCLAW_GATEWAY_TOKEN" -Value $gateway_token -ApiToken $api_token', content)
        self.assertIn('Set-SpaceSecretLogged -SpaceRepoId $space_repo_id -Key "OPENCLAW_GATEWAY_PASSWORD" -Value $gateway_password -ApiToken $api_token', content)

    def test_hf_login_flow_supports_switch_and_restore(self):
        content = self._script_text()
        self.assertIn('Prompt-YesNo -Prompt "HF CLI is already logged in as \'$current_hf_username\'. Use this user?" -DefaultValue "y"', content)
        self.assertIn('$switch_hf_token = Prompt-SecretRequired -Prompt "HF_TOKEN for switching HF user"', content)
        self.assertIn('Login-WithHfToken -Token $switch_hf_token', content)
        self.assertIn('Restore-PreviousHfLoginIfNeeded', content)
        self.assertIn('& hf auth login --token $script:RestoreHfLoginToken *> $null', content)

    def test_hf_token_prompt_happens_before_other_bootstrap_inputs(self):
        content = self._script_text()
        self.assertLess(
            content.index('Invoke-Step -Message "Resolve HF login and HF_TOKEN" -Action {'),
            content.index('Invoke-Step -Message "Collect Space and Dataset names" -Action {'),
        )
        self.assertNotIn('Prompt-SecretOptional -Prompt "HF_TOKEN for backup dataset (optional, leave empty to reuse current login token)"', content)

    def test_does_not_prompt_or_restart_space(self):
        content = self._script_text()
        self.assertNotIn('Prompt-YesNo -Prompt "Restart Space at the end?"', content)
        self.assertNotIn('Invoke-Step -Message "Restart Space $space_repo_id"', content)

    def test_requires_confirmation_before_remote_execution(self):
        content = self._script_text()
        self.assertIn('Prompt-YesNo -Prompt "Proceed with these settings?" -DefaultValue "y"', content)
        self.assertIn('Write-Info "Cancelled by user before creating/updating Space or Dataset."', content)


if __name__ == "__main__":
    unittest.main()
