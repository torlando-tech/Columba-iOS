"""Execute the production host seam without requiring an iOS runtime."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class UnifiedHostingContracts(unittest.TestCase):
    @unittest.skipUnless(shutil.which("swiftc"), "Swift compiler unavailable")
    def test_production_command_storage_and_ownership_contracts(self):
        sources = [
            "Sources/Shared/ProxyIPC.swift",
            "Sources/Shared/OutboxEntry.swift",
            "Sources/Shared/NodeHostingMode.swift",
            "Sources/Shared/NodeStateMigration.swift",
            "Sources/RNSHost/NodeProcessLease.swift",
            "Tests/host-contracts/main.swift",
        ]
        with tempfile.TemporaryDirectory() as directory:
            executable = str(Path(directory) / "host-contracts")
            subprocess.run(["swiftc", *(str(ROOT / s) for s in sources), "-o", executable], check=True, capture_output=True, text=True)
            result = subprocess.run([executable], check=True, capture_output=True, text=True)
            self.assertIn("Host contracts passed", result.stdout)
