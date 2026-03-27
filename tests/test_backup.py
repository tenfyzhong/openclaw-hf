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
        self.assertEqual(config.root_config_dir, Path("/root/.config").resolve())
        self.assertEqual(config.root_codex_dir, Path("/root/.codex").resolve())
        self.assertEqual(config.root_claude_dir, Path("/root/.claude").resolve())
        self.assertEqual(config.root_agents_dir, Path("/root/.agents").resolve())
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

    def test_from_env_uses_explicit_root_config_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            root_config = tmp_path / "root-config"
            root_config.mkdir()

            env = {
                "OPENCLAW_BACKUP_DATASET_REPO": "user/demo-backup",
                "OPENCLAW_BACKUP_ROOT_CONFIG_DIR": str(root_config),
            }
            with mock.patch.dict("os.environ", env, clear=True):
                config = BackupConfig.from_env()

            self.assertEqual(config.root_config_dir, root_config.resolve())

    def test_from_env_uses_explicit_other_root_dirs(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            root_codex = tmp_path / "root-codex"
            root_claude = tmp_path / "root-claude"
            root_agents = tmp_path / "root-agents"
            root_codex.mkdir()
            root_claude.mkdir()
            root_agents.mkdir()

            env = {
                "OPENCLAW_BACKUP_DATASET_REPO": "user/demo-backup",
                "OPENCLAW_BACKUP_ROOT_CODEX_DIR": str(root_codex),
                "OPENCLAW_BACKUP_ROOT_CLAUDE_DIR": str(root_claude),
                "OPENCLAW_BACKUP_ROOT_AGENTS_DIR": str(root_agents),
            }
            with mock.patch.dict("os.environ", env, clear=True):
                config = BackupConfig.from_env()

            self.assertEqual(config.root_codex_dir, root_codex.resolve())
            self.assertEqual(config.root_claude_dir, root_claude.resolve())
            self.assertEqual(config.root_agents_dir, root_agents.resolve())

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
                root_config_dir=tmp_path / "root-config",
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
                root_config_dir=tmp_path / "root-config",
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

    def test_create_archive_contains_extra_root_trees_when_exist(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            state_dir = tmp_path / "state"
            root_config_dir = tmp_path / "root-config"
            root_codex_dir = tmp_path / "root-codex"
            root_claude_dir = tmp_path / "root-claude"
            root_agents_dir = tmp_path / "root-agents"
            state_dir.mkdir(parents=True)
            root_config_dir.mkdir(parents=True)
            root_codex_dir.mkdir(parents=True)
            root_claude_dir.mkdir(parents=True)
            root_agents_dir.mkdir(parents=True)
            (state_dir / "state.txt").write_text("state\n", encoding="utf-8")
            (root_config_dir / "settings.json").write_text('{"key":"value"}\n', encoding="utf-8")
            (root_codex_dir / "config.toml").write_text("theme = \"dark\"\n", encoding="utf-8")
            (root_claude_dir / "profile.json").write_text('{"provider":"claude"}\n', encoding="utf-8")
            (root_agents_dir / "agent.yaml").write_text("name: default\n", encoding="utf-8")

            config = BackupConfig(
                dataset_repo="user/demo-backup",
                state_dir=state_dir,
                backup_source_dir=state_dir,
                root_config_dir=root_config_dir,
                root_codex_dir=root_codex_dir,
                root_claude_dir=root_claude_dir,
                root_agents_dir=root_agents_dir,
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

            self.assertIn("openclaw-state/state.txt", members)
            self.assertIn("root-config/settings.json", members)
            self.assertIn("root-codex/config.toml", members)
            self.assertIn("root-claude/profile.json", members)
            self.assertIn("root-agents/agent.yaml", members)

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
                root_config_dir=tmp_path / "root-config",
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
                root_config_dir=tmp_path / "root-config",
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

    def test_restore_restores_extra_root_dirs_when_present_in_archive(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            state_target = tmp_path / "state-target"
            root_config_target = tmp_path / "root-config-target"
            root_codex_target = tmp_path / "root-codex-target"
            root_claude_target = tmp_path / "root-claude-target"
            root_agents_target = tmp_path / "root-agents-target"
            state_target.mkdir(parents=True)
            root_config_target.mkdir(parents=True)
            root_codex_target.mkdir(parents=True)
            root_claude_target.mkdir(parents=True)
            root_agents_target.mkdir(parents=True)
            (state_target / "old-state.txt").write_text("old-state\n", encoding="utf-8")
            (root_config_target / "old-config.json").write_text('{"old":true}\n', encoding="utf-8")
            (root_codex_target / "old-codex.toml").write_text("old = true\n", encoding="utf-8")
            (root_claude_target / "old-claude.json").write_text('{"old":true}\n', encoding="utf-8")
            (root_agents_target / "old-agent.yaml").write_text("old: true\n", encoding="utf-8")

            restore_payload = tmp_path / "restore-payload"
            restore_state = restore_payload / "openclaw-state"
            restore_root_config = restore_payload / "root-config"
            restore_root_codex = restore_payload / "root-codex"
            restore_root_claude = restore_payload / "root-claude"
            restore_root_agents = restore_payload / "root-agents"
            restore_state.mkdir(parents=True)
            restore_root_config.mkdir(parents=True)
            restore_root_codex.mkdir(parents=True)
            restore_root_claude.mkdir(parents=True)
            restore_root_agents.mkdir(parents=True)
            (restore_state / "new-state.txt").write_text("new-state\n", encoding="utf-8")
            (restore_root_config / "new-config.json").write_text('{"new":true}\n', encoding="utf-8")
            (restore_root_codex / "new-codex.toml").write_text("new = true\n", encoding="utf-8")
            (restore_root_claude / "new-claude.json").write_text('{"new":true}\n', encoding="utf-8")
            (restore_root_agents / "new-agent.yaml").write_text("new: true\n", encoding="utf-8")

            archive = tmp_path / "latest-backup.tar.gz"
            with tarfile.open(archive, "w:gz") as tar:
                tar.add(str(restore_state), arcname="openclaw-state")
                tar.add(str(restore_root_config), arcname="root-config")
                tar.add(str(restore_root_codex), arcname="root-codex")
                tar.add(str(restore_root_claude), arcname="root-claude")
                tar.add(str(restore_root_agents), arcname="root-agents")

            config = BackupConfig(
                dataset_repo="user/demo-backup",
                state_dir=state_target,
                backup_source_dir=state_target,
                root_config_dir=root_config_target,
                root_codex_dir=root_codex_target,
                root_claude_dir=root_claude_target,
                root_agents_dir=root_agents_target,
                work_dir=tmp_path / "work",
                repo_type="dataset",
                path_prefix="backups",
                latest_name="latest-backup.tar.gz",
                private=True,
            )
            runner = OpenClawBackup(config=config, api=FakeApi(), token="hf_test")

            with mock.patch.object(runner, "download_latest_archive", return_value=archive):
                restored = runner.restore()

            self.assertTrue(restored)
            self.assertTrue((state_target / "new-state.txt").exists())
            self.assertFalse((state_target / "old-state.txt").exists())
            self.assertTrue((root_config_target / "new-config.json").exists())
            self.assertFalse((root_config_target / "old-config.json").exists())
            self.assertTrue((root_codex_target / "new-codex.toml").exists())
            self.assertFalse((root_codex_target / "old-codex.toml").exists())
            self.assertTrue((root_claude_target / "new-claude.json").exists())
            self.assertFalse((root_claude_target / "old-claude.json").exists())
            self.assertTrue((root_agents_target / "new-agent.yaml").exists())
            self.assertFalse((root_agents_target / "old-agent.yaml").exists())

    def test_restore_keeps_extra_root_dirs_untouched_when_archive_missing_them(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            state_target = tmp_path / "state-target"
            root_config_target = tmp_path / "root-config-target"
            root_codex_target = tmp_path / "root-codex-target"
            root_claude_target = tmp_path / "root-claude-target"
            root_agents_target = tmp_path / "root-agents-target"
            state_target.mkdir(parents=True)
            root_config_target.mkdir(parents=True)
            root_codex_target.mkdir(parents=True)
            root_claude_target.mkdir(parents=True)
            root_agents_target.mkdir(parents=True)
            (state_target / "old-state.txt").write_text("old-state\n", encoding="utf-8")
            (root_config_target / "old-config.json").write_text('{"old":true}\n', encoding="utf-8")
            (root_codex_target / "old-codex.toml").write_text("old = true\n", encoding="utf-8")
            (root_claude_target / "old-claude.json").write_text('{"old":true}\n', encoding="utf-8")
            (root_agents_target / "old-agent.yaml").write_text("old: true\n", encoding="utf-8")

            restore_payload = tmp_path / "restore-payload"
            restore_state = restore_payload / "openclaw-state"
            restore_state.mkdir(parents=True)
            (restore_state / "new-state.txt").write_text("new-state\n", encoding="utf-8")

            archive = tmp_path / "latest-backup.tar.gz"
            with tarfile.open(archive, "w:gz") as tar:
                tar.add(str(restore_state), arcname="openclaw-state")

            config = BackupConfig(
                dataset_repo="user/demo-backup",
                state_dir=state_target,
                backup_source_dir=state_target,
                root_config_dir=root_config_target,
                root_codex_dir=root_codex_target,
                root_claude_dir=root_claude_target,
                root_agents_dir=root_agents_target,
                work_dir=tmp_path / "work",
                repo_type="dataset",
                path_prefix="backups",
                latest_name="latest-backup.tar.gz",
                private=True,
            )
            runner = OpenClawBackup(config=config, api=FakeApi(), token="hf_test")

            with mock.patch.object(runner, "download_latest_archive", return_value=archive):
                restored = runner.restore()

            self.assertTrue(restored)
            self.assertTrue((state_target / "new-state.txt").exists())
            self.assertFalse((state_target / "old-state.txt").exists())
            self.assertTrue((root_config_target / "old-config.json").exists())
            self.assertTrue((root_codex_target / "old-codex.toml").exists())
            self.assertTrue((root_claude_target / "old-claude.json").exists())
            self.assertTrue((root_agents_target / "old-agent.yaml").exists())

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
