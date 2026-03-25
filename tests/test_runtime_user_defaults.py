import unittest
from pathlib import Path


class RuntimeUserDefaultsTests(unittest.TestCase):
    @staticmethod
    def _repo_root() -> Path:
        return Path(__file__).resolve().parents[1]

    @classmethod
    def _dockerfile_path(cls) -> Path:
        return cls._repo_root() / "Dockerfile"

    @classmethod
    def _entrypoint_path(cls) -> Path:
        return cls._repo_root() / "scripts" / "openclaw-entrypoint.sh"

    def test_dockerfile_defaults_to_root_runtime_home(self):
        dockerfile = self._dockerfile_path().read_text(encoding="utf-8")
        self.assertIn("ARG OPENCLAW_VERSION", dockerfile)
        self.assertIn("ENV OPENCLAW_VERSION=$OPENCLAW_VERSION", dockerfile)
        self.assertIn('OPENCLAW_VERSION_VALUE="${OPENCLAW_VERSION:-latest}"', dockerfile)
        self.assertIn("ENV HOME=/root", dockerfile)
        self.assertIn("ENV OPENCLAW_HOME=/root", dockerfile)
        self.assertIn("ENV OPENCLAW_USER=root", dockerfile)
        self.assertIn("ENV OPENCLAW_GROUP=root", dockerfile)
        self.assertIn('OPENCLAW_BIN="$(command -v openclaw || true)"', dockerfile)
        self.assertIn('if [[ -z "$OPENCLAW_BIN" ]] && [[ -x /root/.npm-global/bin/openclaw ]]; then', dockerfile)
        self.assertIn('elif [[ -z "$OPENCLAW_BIN" ]] && [[ -x /root/.local/bin/openclaw ]]; then', dockerfile)
        self.assertIn("if [ -x /root/.local/bin/sshx ]; then", dockerfile)
        self.assertNotIn("/home/ubuntu/.npm-global/bin/openclaw", dockerfile)
        self.assertNotIn("/home/ubuntu/.local/bin/sshx", dockerfile)

    def test_dockerfile_does_not_create_ubuntu_user_or_sudoer(self):
        dockerfile = self._dockerfile_path().read_text(encoding="utf-8")
        self.assertNotIn("useradd --system --create-home --gid ubuntu --shell /bin/bash ubuntu", dockerfile)
        self.assertNotIn("ubuntu ALL=(ALL) NOPASSWD:ALL", dockerfile)
        self.assertNotIn("/etc/sudoers.d/90-ubuntu-nopasswd", dockerfile)

    def test_entrypoint_defaults_to_root_runtime_user(self):
        entrypoint = self._entrypoint_path().read_text(encoding="utf-8")
        self.assertIn('OPENCLAW_USER="${OPENCLAW_USER:-root}"', entrypoint)
        self.assertIn('OPENCLAW_GROUP="${OPENCLAW_GROUP:-root}"', entrypoint)
        self.assertIn('OPENCLAW_HOME="${OPENCLAW_HOME:-/root}"', entrypoint)

    def test_backup_cron_uses_openclaw_user(self):
        entrypoint = self._entrypoint_path().read_text(encoding="utf-8")
        self.assertIn(
            '${OPENCLAW_BACKUP_CRON} ${OPENCLAW_USER} /usr/local/bin/openclaw-backup-cron.sh',
            entrypoint,
        )
        self.assertNotIn(
            "${OPENCLAW_BACKUP_CRON} root /usr/local/bin/openclaw-backup-cron.sh",
            entrypoint,
        )

    def test_entrypoint_does_not_rechown_entire_openclaw_home(self):
        entrypoint = self._entrypoint_path().read_text(encoding="utf-8")
        self.assertNotIn('find "$OPENCLAW_HOME" -xdev -exec chown "$OPENCLAW_USER:$OPENCLAW_GROUP" {} +', entrypoint)
        self.assertNotIn('chown -R "$OPENCLAW_USER:$OPENCLAW_GROUP" "$OPENCLAW_HOME"', entrypoint)
        self.assertNotIn('    "$OPENCLAW_HOME" \\', entrypoint)

    def test_backup_cron_setup_skips_when_not_root(self):
        entrypoint = self._entrypoint_path().read_text(encoding="utf-8")
        self.assertIn(
            'setup_backup_cron() {\n  if [[ "$(id -u)" -ne 0 ]]; then',
            entrypoint,
        )

    def test_backup_env_file_includes_keep_count(self):
        entrypoint = self._entrypoint_path().read_text(encoding="utf-8")
        self.assertIn("OPENCLAW_BACKUP_KEEP_COUNT", entrypoint)

    def test_sshx_auto_start_does_not_use_command_substitution(self):
        entrypoint = self._entrypoint_path().read_text(encoding="utf-8")
        self.assertNotIn('OPENCLAW_SSHX_PID="$(run_as_node_background_stdout sshx)"', entrypoint)

    def test_sshx_logs_directly_to_container_stdout_stderr(self):
        entrypoint = self._entrypoint_path().read_text(encoding="utf-8")
        self.assertIn('gosu "$OPENCLAW_USER:$OPENCLAW_GROUP" sshx >/proc/1/fd/1 2>/proc/1/fd/2 &', entrypoint)
        self.assertIn("sshx >/proc/1/fd/1 2>/proc/1/fd/2 &", entrypoint)
        self.assertNotIn('gosu "$OPENCLAW_USER:$OPENCLAW_GROUP" sshx >>"$OPENCLAW_STDOUT_LOG_PATH" 2>>"$OPENCLAW_STDERR_LOG_PATH" &', entrypoint)
        self.assertNotIn('sshx >>"$OPENCLAW_STDOUT_LOG_PATH" 2>>"$OPENCLAW_STDERR_LOG_PATH" &', entrypoint)


if __name__ == "__main__":
    unittest.main()
