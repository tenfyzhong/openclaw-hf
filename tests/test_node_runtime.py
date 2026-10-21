import subprocess
import unittest
from pathlib import Path


class NodeRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dockerfile = (Path(__file__).resolve().parents[1] / "Dockerfile").read_text()
        cls.version_guard = 'test "$(node --version)" = "v24.22.1"'

    def test_pins_official_patched_runtime_and_preserves_ubuntu(self):
        stages = [line for line in self.dockerfile.splitlines() if line.startswith("FROM ")]
        self.assertEqual(stages, [
            "FROM node:24.22.1-bookworm-slim@sha256:1681862882da07ee5476fee047bcf34138833f1df42633bb25bcb0f438d5bf3d AS node-runtime",
            "FROM ubuntu:24.04",
        ])

    def test_provisions_node_and_preserves_global_cli_paths_before_installer(self):
        installer = self.dockerfile.index("https://openclaw.ai/install.sh")
        for required in (
            "libatomic1", "libstdc++6",
            "COPY --from=node-runtime /usr/local/bin/node /usr/local/bin/node",
            "COPY --from=node-runtime /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm",
            "ENV NPM_CONFIG_PREFIX=/usr",
            "../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm",
            "../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx",
        ):
            self.assertLess(self.dockerfile.index(required), installer)

    def test_checks_runtime_before_and_after_all_installers(self):
        self.assertEqual(self.dockerfile.count(self.version_guard), 2)
        self.assertLess(self.dockerfile.index(self.version_guard), self.dockerfile.index("https://openclaw.ai/install.sh"))
        self.assertGreater(self.dockerfile.rindex(self.version_guard), self.dockerfile.index("https://sshx.io/get"))
        self.assertEqual(self.dockerfile.count('test "$(npm config get prefix)" = "/usr"'), 2)

    def test_version_guard_rejects_old_or_replaced_runtime(self):
        for version, expected in (("v24.22.1", 0), ("v24.22.0", 1), ("v22.23.4", 1), ("v26.12.1", 1)):
            with self.subTest(version=version):
                result = subprocess.run(["bash", "-c", f'node() {{ printf "%s\\n" "{version}"; }}; {self.version_guard}'])
                self.assertEqual(result.returncode, expected)
