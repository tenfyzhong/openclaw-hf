#!/usr/bin/env python3
"""Backup and restore OpenClaw state to/from Hugging Face Dataset."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import shutil
import sys
import tarfile
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

try:
    from huggingface_hub import HfApi, hf_hub_download
    from huggingface_hub.utils import HfHubHTTPError
except ModuleNotFoundError:  # pragma: no cover - runtime dependency, optional for unit tests
    HfApi = None  # type: ignore[assignment]
    hf_hub_download = None  # type: ignore[assignment]

    class HfHubHTTPError(Exception):  # type: ignore[no-redef]
        """Fallback error when huggingface_hub is not installed."""


def env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.UTC)


@dataclass
class BackupConfig:
    dataset_repo: str
    state_dir: Path
    backup_source_dir: Path
    work_dir: Path
    repo_type: str
    path_prefix: str
    latest_name: str
    private: bool

    @classmethod
    def from_env(cls) -> "BackupConfig":
        dataset_repo = (os.getenv("OPENCLAW_BACKUP_DATASET_REPO") or "").strip()
        if not dataset_repo:
            raise ValueError("OPENCLAW_BACKUP_DATASET_REPO is not set")

        state_dir = Path(os.getenv("OPENCLAW_STATE_DIR", "/root/.openclaw")).resolve()
        backup_source_dir = Path(os.getenv("OPENCLAW_BACKUP_SOURCE_DIR", "/root")).resolve()
        work_dir = Path(os.getenv("OPENCLAW_BACKUP_WORK_DIR", "/tmp/openclaw-backup")).resolve()
        repo_type = (os.getenv("OPENCLAW_BACKUP_REPO_TYPE") or "dataset").strip() or "dataset"
        path_prefix = (os.getenv("OPENCLAW_BACKUP_PATH_PREFIX") or "backups").strip("/")
        latest_name = (os.getenv("OPENCLAW_BACKUP_LATEST_NAME") or "latest-backup.tar.gz").strip()
        private = env_bool("OPENCLAW_BACKUP_PRIVATE", True)

        return cls(
            dataset_repo=dataset_repo,
            state_dir=state_dir,
            backup_source_dir=backup_source_dir,
            work_dir=work_dir,
            repo_type=repo_type,
            path_prefix=path_prefix,
            latest_name=latest_name,
            private=private,
        )


class OpenClawBackup:
    def __init__(self, config: BackupConfig, api: Optional[Any] = None, token: Optional[str] = None) -> None:
        self.config = config
        self.token = token or os.getenv("HF_TOKEN") or os.getenv("HUGGINGFACE_HUB_TOKEN")
        if api is not None:
            self.api = api
            return
        if HfApi is None:
            raise ModuleNotFoundError(
                "huggingface_hub is required. Install with: pip install 'huggingface_hub[cli]'"
            )
        self.api = HfApi(token=self.token)

    def ensure_dataset_repo(self) -> None:
        self.api.create_repo(
            repo_id=self.config.dataset_repo,
            repo_type=self.config.repo_type,
            private=self.config.private,
            exist_ok=True,
        )

    def create_archive(self, timestamp: Optional[str] = None) -> Path:
        if not self.config.backup_source_dir.exists():
            raise FileNotFoundError(f"backup source directory does not exist: {self.config.backup_source_dir}")

        stamp = timestamp or utc_now().strftime("%Y%m%d-%H%M%S")
        self.config.work_dir.mkdir(parents=True, exist_ok=True)

        archive = self.config.work_dir / f"openclaw-backup-{stamp}.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            tar.add(str(self.config.backup_source_dir), arcname="openclaw-state")

        return archive

    def upload_backup(self, archive: Path) -> str:
        if self.config.path_prefix:
            remote_archive_path = f"{self.config.path_prefix}/{archive.name}"
        else:
            remote_archive_path = archive.name

        self.api.upload_file(
            repo_id=self.config.dataset_repo,
            repo_type=self.config.repo_type,
            path_or_fileobj=str(archive),
            path_in_repo=remote_archive_path,
            commit_message=f"backup: {archive.name}",
        )

        self.api.upload_file(
            repo_id=self.config.dataset_repo,
            repo_type=self.config.repo_type,
            path_or_fileobj=str(archive),
            path_in_repo=self.config.latest_name,
            commit_message=f"backup: update {self.config.latest_name}",
        )

        metadata = {
            "dataset": self.config.dataset_repo,
            "archive": remote_archive_path,
            "latest": self.config.latest_name,
            "created_at_utc": utc_now().isoformat(timespec="seconds"),
            "state_root": "openclaw-state",
        }
        self.api.upload_file(
            repo_id=self.config.dataset_repo,
            repo_type=self.config.repo_type,
            path_or_fileobj=(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n").encode("utf-8"),
            path_in_repo="latest-backup.json",
            commit_message="backup: update latest-backup metadata",
        )

        return remote_archive_path

    def backup(self) -> Path:
        self.ensure_dataset_repo()
        archive = self.create_archive()
        remote_path = self.upload_backup(archive)
        print(f"backup uploaded: {self.config.dataset_repo}/{remote_path}")
        return archive

    def download_latest_archive(self) -> Optional[Path]:
        self.config.work_dir.mkdir(parents=True, exist_ok=True)
        if hf_hub_download is None:
            raise ModuleNotFoundError(
                "huggingface_hub is required. Install with: pip install 'huggingface_hub[cli]'"
            )
        try:
            local_path = hf_hub_download(
                repo_id=self.config.dataset_repo,
                repo_type=self.config.repo_type,
                filename=self.config.latest_name,
                local_dir=str(self.config.work_dir),
                local_dir_use_symlinks=False,
                token=self.token,
            )
            return Path(local_path)
        except HfHubHTTPError as exc:
            response = getattr(exc, "response", None)
            if response is not None and response.status_code == 404:
                return None
            raise

    @staticmethod
    def replace_dir_contents(source_dir: Path, target_dir: Path) -> None:
        target_dir.mkdir(parents=True, exist_ok=True)

        for existing in target_dir.iterdir():
            if existing.is_dir() and not existing.is_symlink():
                shutil.rmtree(existing)
            else:
                existing.unlink()

        for item in source_dir.iterdir():
            destination = target_dir / item.name
            if item.is_symlink():
                destination.symlink_to(os.readlink(item))
            elif item.is_dir():
                shutil.copytree(item, destination, symlinks=True)
            else:
                shutil.copy2(item, destination)

    def restore(self) -> bool:
        archive = self.download_latest_archive()
        if archive is None:
            print(
                f"no latest backup found in dataset {self.config.dataset_repo} ({self.config.latest_name})",
                file=sys.stderr,
            )
            return False

        with tempfile.TemporaryDirectory(prefix="openclaw-restore-") as tmp:
            tmp_dir = Path(tmp)
            with tarfile.open(archive, "r:gz") as tar:
                tar.extractall(tmp_dir)

            extracted_state = tmp_dir / "openclaw-state"
            if not extracted_state.exists() or not extracted_state.is_dir():
                raise RuntimeError("backup archive missing openclaw-state directory")

            self.replace_dir_contents(extracted_state, self.config.backup_source_dir)

        print(f"restore completed from {self.config.dataset_repo}/{self.config.latest_name}")
        return True


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Backup/restore OpenClaw state with Hugging Face Dataset")
    parser.add_argument("action", choices=["backup", "restore"], help="action to perform")
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)

    try:
        config = BackupConfig.from_env()
    except ValueError as exc:
        print(f"skip {args.action}: {exc}", file=sys.stderr)
        return 0

    try:
        runner = OpenClawBackup(config=config)
        if args.action == "backup":
            runner.backup()
            return 0
        runner.restore()
        return 0
    except Exception as exc:  # pragma: no cover
        print(f"{args.action} failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
