"""Launch real Godot host/client processes; fail on errors, timeouts, or missing evidence."""

import os
from pathlib import Path
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]  # Run from any working directory.
BASE = [os.environ.get("GODOT", "godot"), "--headless", "--path", str(ROOT),
        "--script", "res://tests/network_peer.gd", "--"]


def main():
    # Files prevent pipe-buffer deadlocks, and TemporaryDirectory cleans all logs.
    with tempfile.TemporaryDirectory(prefix="bean-net-") as directory:
        processes = []
        files = []
        try:
            for role in ("host", "client"):
                output = open(Path(directory) / f"{role}.log", "w+")
                files.append(output)
                processes.append(subprocess.Popen(BASE + [role], cwd=ROOT,
                                                  stdout=output, stderr=subprocess.STDOUT))
                if role == "host":
                    time.sleep(0.6)  # Short startup grace; each peer also has a deadline.
            for process in processes:
                process.wait(timeout=18)
            for role, process, output in zip(("host", "client"), processes, files):
                output.seek(0)
                text = output.read()
                print(text, end="")
                if process.returncode != 0 or f"{role.upper()}_PASS:" not in text or "ERROR:" in text:
                    raise RuntimeError(f"{role} failed; see log above")
            print("NETWORK_TEST: real ENet host/client passed")
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()  # Only children created by this test are stopped.
                process.wait()
            for output in files:
                output.close()


if __name__ == "__main__":
    main()
