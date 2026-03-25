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
        self.assertIn('Set-SpaceVariable -SpaceRepoId $space_repo_id -Key "OPENCLAW_BACKUP_DATASET_REPO" -Value $dataset_repo_id -ApiToken $api_token', content)
        self.assertIn('Set-SpaceVariable -SpaceRepoId $space_repo_id -Key "OPENCLAW_VERSION" -Value $openclaw_version -ApiToken $api_token', content)
        self.assertIn('Set-SpaceSecret -SpaceRepoId $space_repo_id -Key "HF_TOKEN" -Value $hf_token_for_backup -ApiToken $api_token', content)
        self.assertIn('Set-SpaceSecret -SpaceRepoId $space_repo_id -Key "OPENCLAW_GATEWAY_TOKEN" -Value $gateway_token -ApiToken $api_token', content)
        self.assertIn('Set-SpaceSecret -SpaceRepoId $space_repo_id -Key "OPENCLAW_GATEWAY_PASSWORD" -Value $gateway_password -ApiToken $api_token', content)


if __name__ == "__main__":
    unittest.main()
