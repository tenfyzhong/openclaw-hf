import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


class EntrypointConfigTests(unittest.TestCase):
    @staticmethod
    def _repo_root() -> Path:
        return Path(__file__).resolve().parents[1]

    @classmethod
    def _entrypoint_path(cls) -> Path:
        return cls._repo_root() / "scripts" / "openclaw-entrypoint.sh"

    @staticmethod
    def _write_fake_openclaw(bin_dir: Path) -> None:
        fake_openclaw = bin_dir / "openclaw"
        fake_openclaw.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        fake_openclaw.chmod(0o755)

    def _run_gateway(self, extra_env=None):
        if extra_env is None:
            extra_env = {}

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            state_dir = tmp_path / "state"
            home_dir = tmp_path / "home"
            workspace_dir = state_dir / "workspace"
            logs_dir = tmp_path / "logs"
            bin_dir = tmp_path / "bin"
            config_path = state_dir / "openclaw.json"

            state_dir.mkdir(parents=True)
            home_dir.mkdir(parents=True)
            workspace_dir.mkdir(parents=True)
            logs_dir.mkdir(parents=True)
            bin_dir.mkdir(parents=True)
            self._write_fake_openclaw(bin_dir)

            env = os.environ.copy()
            for key in ("OPENCLAW_LLM_BASE_URL", "OPENCLAW_LLM_MODEL", "OPENCLAW_LLM_API_KEY"):
                env.pop(key, None)
            env.update(
                {
                    "PATH": f"{bin_dir}:{env.get('PATH', '')}",
                    "OPENCLAW_HOME": str(home_dir),
                    "OPENCLAW_STATE_DIR": str(state_dir),
                    "OPENCLAW_CONFIG_PATH": str(config_path),
                    "OPENCLAW_WORKSPACE_DIR": str(workspace_dir),
                    "OPENCLAW_STDOUT_LOG_PATH": str(logs_dir / "gateway.stdout.log"),
                    "OPENCLAW_STDERR_LOG_PATH": str(logs_dir / "gateway.stderr.log"),
                    "OPENCLAW_BACKUP_ENABLED": "false",
                    "OPENCLAW_SSHX_AUTO_START": "false",
                }
            )
            env.update(extra_env)

            result = subprocess.run(
                [str(self._entrypoint_path()), "gateway"],
                cwd=self._repo_root(),
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )

            with config_path.open("r", encoding="utf-8") as fh:
                config = json.load(fh)

            return config, result

    def test_gateway_configures_custom_model_when_llm_env_present(self):
        config, _ = self._run_gateway(
            {
                "OPENCLAW_LLM_BASE_URL": "https://example.com/v1",
                "OPENCLAW_LLM_MODEL": "demo-model",
                "OPENCLAW_LLM_API_KEY": "demo-key",
            }
        )

        self.assertEqual(config["agents"]["defaults"]["model"]["primary"], "thirdparty/demo-model")
        self.assertEqual(
            config["agents"]["defaults"]["models"]["thirdparty/demo-model"]["alias"],
            "Default",
        )
        self.assertEqual(config["models"]["mode"], "merge")
        self.assertEqual(config["models"]["providers"]["thirdparty"]["baseUrl"], "${OPENCLAW_LLM_BASE_URL}")
        self.assertEqual(config["models"]["providers"]["thirdparty"]["apiKey"], "${OPENCLAW_LLM_API_KEY}")
        self.assertEqual(config["models"]["providers"]["thirdparty"]["api"], "openai-completions")
        self.assertEqual(
            config["models"]["providers"]["thirdparty"]["models"],
            [{"id": "demo-model", "name": "demo-model"}],
        )

    def test_gateway_skips_custom_model_when_llm_env_missing(self):
        config, result = self._run_gateway()

        defaults = config.get("agents", {}).get("defaults", {})
        providers = config.get("models", {}).get("providers", {})
        self.assertNotIn("model", defaults)
        self.assertNotIn("models", defaults)
        self.assertNotIn("thirdparty", providers)
        self.assertIn("OPENCLAW_SSHX_AUTO_START=true", result.stderr)


if __name__ == "__main__":
    unittest.main()
