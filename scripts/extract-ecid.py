#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Print a macosvm guest's ECID in decimal.

    scripts/extract-ecid.py VM_JSON

VM_JSON is the vm.json macosvm writes. Its "machineId" member is base64 of
a property list (binary or XML) whose top-level dictionary holds the
machine's ECID as an integer. scripts/launch-kvm.sh passes the ECID to QEMU
as the vmapple machine's uuid.

Exit status: 0 with the ECID on stdout; 1 when the file cannot be read or
holds no positive integer ECID; 2 for a wrong number of arguments.
"""

import base64
import binascii
import json
import plistlib
import sys


class EcidError(Exception):
    pass


def read_ecid(path):
    try:
        with open(path, "rb") as f:
            doc = json.load(f)
    except OSError as e:
        raise EcidError(f"cannot read {path}: {e.strerror or e}") from None
    except ValueError as e:
        raise EcidError(f"{path} is not valid JSON: {e}") from None

    if not isinstance(doc, dict) or "machineId" not in doc:
        raise EcidError(f"{path} has no machineId")
    encoded = doc["machineId"]
    if not isinstance(encoded, str) or not encoded.strip():
        raise EcidError(f"{path}: machineId is not a base64 string")

    try:
        blob = base64.b64decode("".join(encoded.split()), validate=True)
    except (binascii.Error, ValueError) as e:
        raise EcidError(f"{path}: machineId is not valid base64: {e}") from None

    try:
        identity = plistlib.loads(blob)
    except Exception as e:  # plistlib raises several types for bad input
        raise EcidError(f"{path}: machineId is not a property list: {e}") from None

    if not isinstance(identity, dict) or "ECID" not in identity:
        raise EcidError(f"{path}: machineId property list has no ECID")
    ecid = identity["ECID"]
    # bool is an int subclass; a plist <true/> is not an ECID.
    if isinstance(ecid, bool) or not isinstance(ecid, int) or ecid <= 0:
        raise EcidError(f"{path}: ECID is not a positive integer: {ecid!r}")
    return ecid


def main(argv):
    if len(argv) != 2:
        print(f"usage: {argv[0] if argv else 'extract-ecid.py'} VM_JSON", file=sys.stderr)
        return 2
    try:
        ecid = read_ecid(argv[1])
    except EcidError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    print(ecid)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
