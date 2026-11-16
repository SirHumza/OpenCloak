#!/bin/bash
set -euo pipefail
python3 - <<'PY'
import os
import plistlib
import secrets
import subprocess
import tempfile

HDIUTIL = "/usr/bin/hdiutil"


def run(arguments, password=None, expected_success=True):
    result = subprocess.run(
        [HDIUTIL, *arguments],
        input=(password + b"\0") if password is not None else b"",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if expected_success and result.returncode != 0:
        raise RuntimeError(result.stderr.decode(errors="replace"))
    if not expected_success and result.returncode == 0:
        raise RuntimeError("A wrong vault password unexpectedly succeeded")
    return result.stdout


def attach(image, password, read_only=False):
    arguments = ["attach", "-plist", "-nobrowse"]
    if read_only:
        arguments.append("-readonly")
    arguments.extend(["-stdinpass", image])
    info = plistlib.loads(run(arguments, password))
    entity = next(item for item in info["system-entities"] if "mount-point" in item)
    return entity["mount-point"], entity["dev-entry"]


for cycle in range(8):
    with tempfile.TemporaryDirectory(prefix="opencloak-hdiutil-") as directory:
        image = os.path.join(directory, "test.sparsebundle")
        password = secrets.token_hex(32).encode("ascii")
        run([
            "create", "-type", "SPARSEBUNDLE", "-fs", "APFS", "-size", "64m",
            "-encryption", "AES-256", "-stdinpass", "-volname", "OpenCloakStress", "-o", image,
        ], password)
        mount, device = attach(image, password)
        with open(os.path.join(mount, "integrity-check.txt"), "w", encoding="utf-8") as handle:
            handle.write("cycle-" + str(cycle))
        run(["detach", device])
        run(["attach", "-plist", "-nobrowse", "-readonly", "-stdinpass", image], b"wrong-password", False)
        mount, device = attach(image, password, read_only=True)
        with open(os.path.join(mount, "integrity-check.txt"), encoding="utf-8") as handle:
            assert handle.read() == "cycle-" + str(cycle)
        run(["detach", device])

print("8 encrypted APFS create/wrong-key/remount/read-only/eject cycles passed")
PY
