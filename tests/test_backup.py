import tarfile
import tempfile
import unittest
from unittest import mock
from pathlib import Path

from openclaw_hf.backup import BackupConfig, OpenClawBackup


class FakeApi:
    def __init__(self):
        self.create_repo_calls = []
        self.upload_file_calls = []
        self.list_repo_files_calls = []
        self.delete_file_calls = []
        self.repo_files_to_list = []

    def create_repo(self, **kwargs):
        self.create_repo_calls.append(kwargs)

    def upload_file(self, **kwargs):
        self.upload_file_calls.append(kwargs)

    def list_repo_files(self, **kwargs):
        self.list_repo_files_calls.append(kwargs)
        return list(self.repo_files_to_list)

    def delete_file(self, **kwargs):
        self.delete_file_calls.append(kwargs)


class BackupTests(unittest.TestCase):
    def test_from_env_defaults_backup_source_to_state_dir(self):
        env = {
            "OPENCLAW_BACKUP_DATASET_REPO": "user/demo-backup",
        }
        with mock.patch.dict("os.environ", env, clear=True):
            config = BackupConfig.from_env()

        self.assertEqual(config.state_dir, Path("/root/.openclaw").resolve())
        self.assertEqual(config.backup_source_dir, config.state_dir)
        self.assertEqual(config.keep_count, 48)

    def test_from_env_defaults_backup_source_to_explicit_state_dir_when_unset(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            state_dir = tmp_path / "state"
            state_dir.mkdir(parents=True)

            env = {
                "OPENCLAW_BACKUP_DATASET_REPO": "user/demo-backup",
                "OPENCLAW_STATE_DIR": str(state_dir),
            }
            with mock.patch.dict("os.environ", env, clear=True):
                config = BackupConfig.from_env()

            self.assertEqual(config.state_dir, state_dir.resolve())
            self.assertEqual(config.backup_source_dir, state_dir.resolve())

    def test_from_env_uses_explicit_backup_source_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            backup_source = tmp_path / "home-node"
            backup_source.mkdir()

            env = {
                "OPENCLAW_BACKUP_DATASET_REPO": "user/demo-backup",
                "OPENCLAW_STATE_DIR": str(tmp_path / "state"),
                "OPENCLAW_BACKUP_SOURCE_DIR": str(backup_source),
            }
            with mock.patch.dict("os.environ", env, clear=True):
                config = BackupConfig.from_env()

            self.assertEqual(config.backup_source_dir, backup_source.resolve())

    def test_from_env_uses_explicit_backup_keep_count(self):
        env = {
            "OPENCLAW_BACKUP_DATASET_REPO": "user/demo-backup",
            "OPENCLAW_BACKUP_KEEP_COUNT": "72",
        }
        with mock.patch.dict("os.environ", env, clear=True):
            config = BackupConfig.from_env()

        self.assertEqual(config.keep_count, 72)

    def test_create_archive_contains_state_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            state_dir = tmp_path / "state"
            state_dir.mkdir(parents=True)
            (state_dir / "openclaw.json").write_text('{"ok":true}\n', encoding="utf-8")

            config = BackupConfig(
                dataset_repo="user/demo-backup",
                state_dir=state_dir,
                backup_source_dir=state_dir,
                work_dir=tmp_path / "work",
                repo_type="dataset",
                path_prefix="backups",
                latest_name="latest-backup.tar.gz",
                private=True,
            )
            runner = OpenClawBackup(config=config, api=FakeApi(), token="hf_test")

            archive = runner.create_archive(timestamp="20260324-120000")
            self.assertTrue(archive.exists())

            with tarfile.open(archive, "r:gz") as tar:
                members = tar.getnames()

            self.assertIn("openclaw-state/openclaw.json", members)

    def test_create_archive_uses_backup_source_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            state_dir = tmp_path / "state"
            source_dir = tmp_path / "home-node"
            state_dir.mkdir(parents=True)
            source_dir.mkdir(parents=True)
            (state_dir / "state.txt").write_text("state\n", encoding="utf-8")
            (source_dir / "from-home-node.txt").write_text("home\n", encoding="utf-8")

            config = BackupConfig(
                dataset_repo="user/demo-backup",
                state_dir=state_dir,
                backup_source_dir=source_dir,
                work_dir=tmp_path / "work",
                repo_type="dataset",
                path_prefix="backups",
                latest_name="latest-backup.tar.gz",
                private=True,
            )
            runner = OpenClawBackup(config=config, api=FakeApi(), token="hf_test")

            archive = runner.create_archive(timestamp="20260324-120000")
            self.assertTrue(archive.exists())

            with tarfile.open(archive, "r:gz") as tar:
                members = tar.getnames()

            self.assertIn("openclaw-state/from-home-node.txt", members)

    def test_upload_backup_writes_timestamp_and_latest(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            archive = tmp_path / "openclaw-backup-20260324-120000.tar.gz"
            archive.write_bytes(b"dummy")

            fake_api = FakeApi()
            config = BackupConfig(
                dataset_repo="user/demo-backup",
                state_dir=tmp_path / "state",
                backup_source_dir=tmp_path / "state",
                work_dir=tmp_path / "work",
                repo_type="dataset",
                path_prefix="backups",
                latest_name="latest-backup.tar.gz",
                private=True,
            )
            runner = OpenClawBackup(config=config, api=fake_api, token="hf_test")

            remote_path = runner.upload_backup(archive)
            self.assertEqual(remote_path, "backups/openclaw-backup-20260324-120000.tar.gz")
            self.assertEqual(len(fake_api.upload_file_calls), 3)

            uploaded_paths = [call["path_in_repo"] for call in fake_api.upload_file_calls]
            self.assertIn("backups/openclaw-backup-20260324-120000.tar.gz", uploaded_paths)
            self.assertIn("latest-backup.tar.gz", uploaded_paths)
            self.assertIn("latest-backup.json", uploaded_paths)
            self.assertEqual(fake_api.delete_file_calls, [])

    def test_upload_backup_prunes_old_archives_by_keep_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            archive = tmp_path / "openclaw-backup-20260324-120000.tar.gz"
            archive.write_bytes(b"dummy")

            fake_api = FakeApi()
            fake_api.repo_files_to_list = [
                "backups/openclaw-backup-20260324-120000.tar.gz",
                "backups/openclaw-backup-20260324-110000.tar.gz",
                "backups/openclaw-backup-20260324-100000.tar.gz",
                "backups/openclaw-backup-20260324-090000.tar.gz",
                "backups/readme.txt",
                "latest-backup.tar.gz",
                "latest-backup.json",
            ]
            config = BackupConfig(
                dataset_repo="user/demo-backup",
                state_dir=tmp_path / "state",
                backup_source_dir=tmp_path / "state",
                work_dir=tmp_path / "work",
                repo_type="dataset",
                path_prefix="backups",
                latest_name="latest-backup.tar.gz",
                private=True,
                keep_count=2,
            )
            runner = OpenClawBackup(config=config, api=fake_api, token="hf_test")

            runner.upload_backup(archive)

            deleted_paths = [call["path_in_repo"] for call in fake_api.delete_file_calls]
            self.assertEqual(
                deleted_paths,
                [
                    "backups/openclaw-backup-20260324-100000.tar.gz",
                    "backups/openclaw-backup-20260324-090000.tar.gz",
                ],
            )

    def test_replace_dir_contents_clears_old_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            source = tmp_path / "source"
            target = tmp_path / "target"
            source.mkdir()
            target.mkdir()

            (source / "new.txt").write_text("new\n", encoding="utf-8")
            (target / "old.txt").write_text("old\n", encoding="utf-8")

            OpenClawBackup.replace_dir_contents(source, target)

            self.assertTrue((target / "new.txt").exists())
            self.assertFalse((target / "old.txt").exists())


if __name__ == "__main__":
    unittest.main()
