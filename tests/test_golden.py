"""The golden vectors the Swift core is tested against (core/Tests/.../Golden) must match what the Python engine writes now."""

import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class GoldenVectors(unittest.TestCase):
    def test_committed_vectors_are_current(self):
        r = subprocess.run([sys.executable, str(ROOT / "scripts" / "golden"), "--check"], capture_output=True, text=True, cwd=ROOT)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
