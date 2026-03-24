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

    def test_dockerfile_does_not_reference_root_home(self):
        dockerfile = self._dockerfile_path().read_text(encoding="utf-8")
        self.assertNotIn("/root/", dockerfile)

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


if __name__ == "__main__":
    unittest.main()
