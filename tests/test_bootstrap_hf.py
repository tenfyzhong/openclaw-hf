import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


class BootstrapHfScriptTests(unittest.TestCase):
    @staticmethod
    def _repo_root() -> Path:
        return Path(__file__).resolve().parents[1]

    @classmethod
    def _script_path(cls) -> Path:
        return cls._repo_root() / "scripts" / "bootstrap-hf.sh"

    @staticmethod
    def _write_executable(path: Path, content: str) -> None:
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)

    def _prepare_fake_tools(self, bin_dir: Path) -> None:
        self._write_executable(
            bin_dir / "hf",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                set -euo pipefail
                echo "hf $*" >>"${TRACE_FILE}"
                if [[ "${1:-}" == "auth" && "${2:-}" == "whoami" ]]; then
                  if [[ -n "${HF_WHOAMI_OUTPUT:-}" ]]; then
                    echo "${HF_WHOAMI_OUTPUT}"
                  else
                    echo "user:  demo-user"
                  fi
                  exit 0
                fi
                if [[ "${1:-}" == "auth" && "${2:-}" == "login" ]]; then
                  exit 0
                fi
                if [[ "${1:-}" == "version" ]]; then
                  echo "hf 9.9.9"
                  exit 0
                fi
                if [[ "${1:-}" == "repo" && "${2:-}" == "create" ]]; then
                  exit 0
                fi
                if [[ "${1:-}" == "upload" ]]; then
                  exit 0
                fi
                echo "unexpected hf command: $*" >&2
                exit 1
                """
            ),
        )
        self._write_executable(
            bin_dir / "python3",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                set -euo pipefail
                echo "python3 $*" >>"${TRACE_FILE}"
                if [[ "${1:-}" == "--version" ]]; then
                  echo "Python 3.12.0"
                  exit 0
                fi
                if [[ -n "${SPACE_VARIABLE_KEY:-}" ]]; then
                  echo "space-variable ${SPACE_VARIABLE_KEY}=${SPACE_VARIABLE_VALUE}" >>"${TRACE_FILE}"
                fi
                if [[ -n "${SPACE_SECRET_KEY:-}" ]]; then
                  echo "space-secret ${SPACE_SECRET_KEY}=${SPACE_SECRET_VALUE}" >>"${TRACE_FILE}"
                fi
                if [[ -n "${SPACE_RESTART_REPO_ID:-}" ]]; then
                  echo "space-restart ${SPACE_RESTART_REPO_ID}" >>"${TRACE_FILE}"
                  if [[ "${FAIL_SPACE_RESTART:-0}" == "1" ]]; then
                    echo "restart failed" >&2
                    exit 1
                  fi
                fi
                exit 0
                """
            ),
        )
        self._write_executable(
            bin_dir / "openssl",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                set -euo pipefail
                if [[ "${1:-}" == "rand" && "${2:-}" == "-hex" && "${3:-}" == "16" ]]; then
                  echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                  exit 0
                fi
                if [[ "${1:-}" == "rand" && "${2:-}" == "-hex" && "${3:-}" == "8" ]]; then
                  echo "bbbbbbbbbbbbbbbb"
                  exit 0
                fi
                echo "unexpected openssl call: $*" >&2
                exit 1
                """
            ),
        )
        self._write_executable(
            bin_dir / "git",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                set -euo pipefail
                if [[ "${1:-}" == "--version" ]]; then
                  echo "git version 2.47.0"
                  exit 0
                fi
                echo "unexpected git call: $*" >&2
                exit 1
                """
            ),
        )

    def test_interactive_bootstrap_configures_space_secrets_and_variables(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            home_dir = tmp_path / "home"
            token_file = home_dir / ".cache" / "huggingface" / "token"
            bin_dir = tmp_path / "bin"
            trace_file = tmp_path / "trace.log"

            bin_dir.mkdir(parents=True)
            token_file.parent.mkdir(parents=True)
            token_file.write_text("hf-current-token\n", encoding="utf-8")
            trace_file.write_text("", encoding="utf-8")
            self._prepare_fake_tools(bin_dir)

            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(home_dir),
                    "TRACE_FILE": str(trace_file),
                    "PATH": f"{bin_dir}:{env.get('PATH', '')}",
                }
            )

            # space_name, dataset_name, openclaw_version(blank -> default latest),
            # gateway_token(blank), gateway_password(blank), HF_TOKEN(blank -> reuse current token),
            # configure_llm(no), sshx_auto_start(yes)
            user_input = "demo-space\ndemo-backup\n\n\n\n\nn\ny\n"

            result = subprocess.run(
                [str(self._script_path())],
                cwd=self._repo_root(),
                env=env,
                input=user_input,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(
                result.returncode,
                0,
                msg=f"stdout:\n{result.stdout}\n\nstderr:\n{result.stderr}",
            )

            trace = trace_file.read_text(encoding="utf-8")
            self.assertIn("hf repo create demo-user/demo-space --repo-type space --space-sdk docker --private --exist-ok", trace)
            self.assertIn("hf repo create demo-user/demo-backup --repo-type dataset --private --exist-ok", trace)
            self.assertIn("hf upload demo-user/demo-space . --repo-type space --exclude .git/** --exclude .git --commit-message feat: deploy openclaw to hf space", trace)

            self.assertIn("space-variable OPENCLAW_BACKUP_DATASET_REPO=demo-user/demo-backup", trace)
            self.assertIn("space-variable OPENCLAW_VERSION=latest", trace)
            self.assertIn("space-variable OPENCLAW_GATEWAY_CONTROLUI_ALLOW_INSECURE_AUTH=false", trace)
            self.assertIn("space-variable OPENCLAW_GATEWAY_CONTROLUI_DANGEROUSLY_DISABLE_DEVICE_AUTH=false", trace)
            self.assertIn("space-variable OPENCLAW_SSHX_AUTO_START=true", trace)
            self.assertIn("space-secret HF_TOKEN=hf-current-token", trace)
            self.assertIn("space-secret OPENCLAW_GATEWAY_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", trace)
            self.assertIn("space-secret OPENCLAW_GATEWAY_PASSWORD=bbbbbbbbbbbbbbbb", trace)
            self.assertNotIn("space-restart demo-user/demo-space", trace)

            self.assertIn("Generated OPENCLAW_GATEWAY_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", result.stdout)
            self.assertIn("Generated OPENCLAW_GATEWAY_PASSWORD=bbbbbbbbbbbbbbbb", result.stdout)
            self.assertIn("Hugging Face Space: https://huggingface.co/spaces/demo-user/demo-space", result.stdout)

    def test_prompts_for_hf_username_when_whoami_output_is_unparseable(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            home_dir = tmp_path / "home"
            token_file = home_dir / ".cache" / "huggingface" / "token"
            bin_dir = tmp_path / "bin"
            trace_file = tmp_path / "trace.log"

            bin_dir.mkdir(parents=True)
            token_file.parent.mkdir(parents=True)
            token_file.write_text("hf-current-token\n", encoding="utf-8")
            trace_file.write_text("", encoding="utf-8")
            self._prepare_fake_tools(bin_dir)

            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(home_dir),
                    "TRACE_FILE": str(trace_file),
                    "HF_WHOAMI_OUTPUT": "whoami output without username",
                    "PATH": f"{bin_dir}:{env.get('PATH', '')}",
                }
            )

            # hf_username (fallback prompt), space_name, dataset_name, openclaw_version(blank),
            # gateway token/password/HF token(empty),
            # configure_llm(no), sshx_auto_start(yes)
            user_input = "manual-user\ndemo-space\ndemo-backup\n\n\n\n\nn\ny\n"

            result = subprocess.run(
                [str(self._script_path())],
                cwd=self._repo_root(),
                env=env,
                input=user_input,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(
                result.returncode,
                0,
                msg=f"stdout:\n{result.stdout}\n\nstderr:\n{result.stderr}",
            )

            trace = trace_file.read_text(encoding="utf-8")
            self.assertIn("hf repo create manual-user/demo-space --repo-type space --space-sdk docker --private --exist-ok", trace)
            self.assertIn("hf repo create manual-user/demo-backup --repo-type dataset --private --exist-ok", trace)
            self.assertIn("HF user: manual-user", result.stdout)

    def test_does_not_restart_space(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            home_dir = tmp_path / "home"
            token_file = home_dir / ".cache" / "huggingface" / "token"
            bin_dir = tmp_path / "bin"
            trace_file = tmp_path / "trace.log"

            bin_dir.mkdir(parents=True)
            token_file.parent.mkdir(parents=True)
            token_file.write_text("hf-current-token\n", encoding="utf-8")
            trace_file.write_text("", encoding="utf-8")
            self._prepare_fake_tools(bin_dir)

            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(home_dir),
                    "TRACE_FILE": str(trace_file),
                    "FAIL_SPACE_RESTART": "1",
                    "PATH": f"{bin_dir}:{env.get('PATH', '')}",
                }
            )

            user_input = "demo-space\ndemo-backup\n\n\n\n\nn\nn\n"

            result = subprocess.run(
                [str(self._script_path())],
                cwd=self._repo_root(),
                env=env,
                input=user_input,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(
                result.returncode,
                0,
                msg=f"stdout:\n{result.stdout}\n\nstderr:\n{result.stderr}",
            )
            trace = trace_file.read_text(encoding="utf-8")
            self.assertIn("space-variable OPENCLAW_SSHX_AUTO_START=false", trace)
            self.assertNotIn("space-restart demo-user/demo-space", trace)
            self.assertNotIn(
                "Space restart failed. You can restart manually from Hugging Face Space Settings.",
                result.stderr,
            )

    def test_prefers_user_configured_openclaw_version_from_env(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            home_dir = tmp_path / "home"
            token_file = home_dir / ".cache" / "huggingface" / "token"
            bin_dir = tmp_path / "bin"
            trace_file = tmp_path / "trace.log"

            bin_dir.mkdir(parents=True)
            token_file.parent.mkdir(parents=True)
            token_file.write_text("hf-current-token\n", encoding="utf-8")
            trace_file.write_text("", encoding="utf-8")
            self._prepare_fake_tools(bin_dir)

            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(home_dir),
                    "TRACE_FILE": str(trace_file),
                    "OPENCLAW_VERSION": "2026.3.23-2",
                    "PATH": f"{bin_dir}:{env.get('PATH', '')}",
                }
            )

            # space_name, dataset_name, openclaw_version(blank -> use env default),
            # gateway token/password/HF token(blank), configure_llm(no),
            # sshx_auto_start(yes)
            user_input = "demo-space\ndemo-backup\n\n\n\n\nn\ny\n"

            result = subprocess.run(
                [str(self._script_path())],
                cwd=self._repo_root(),
                env=env,
                input=user_input,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(
                result.returncode,
                0,
                msg=f"stdout:\n{result.stdout}\n\nstderr:\n{result.stderr}",
            )

            trace = trace_file.read_text(encoding="utf-8")
            self.assertIn("space-variable OPENCLAW_VERSION=2026.3.23-2", trace)
            self.assertIn("OPENCLAW_VERSION: 2026.3.23-2", result.stdout)


if __name__ == "__main__":
    unittest.main()
