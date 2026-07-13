#!/usr/bin/python3

import errno
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


DIRECTORY = Path(__file__).parent


class ProcessGroupLauncherTests(unittest.TestCase):
    def test_group_signal_reaches_spawned_adapter_child(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            pid_file = Path(temporary) / "child.pid"
            process = subprocess.Popen([
                sys.executable,
                str(DIRECTORY / "process_group_launcher.py"),
                sys.executable,
                str(DIRECTORY / "contract_adapter.py"),
                "--mode",
                "hang-child",
                "--child-pid-file",
                str(pid_file),
            ])
            try:
                deadline = time.monotonic() + 5
                while not pid_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(pid_file.exists(), "adapter child PID was not materialized")
                child_pid = int(pid_file.read_text(encoding="utf-8"))
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=5)
                for _ in range(100):
                    try:
                        os.kill(child_pid, 0)
                    except OSError as error:
                        self.assertEqual(error.errno, errno.ESRCH)
                        break
                    time.sleep(0.01)
                else:
                    self.fail("adapter descendant survived its process-group termination")
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
