"""Add the pinned OpenBLAS license bundle to a repaired NumPy wheel.

This only adds notice text and updates wheel RECORD; it does not alter PE files.
"""
from __future__ import annotations

import base64
import csv
import hashlib
import io
from pathlib import Path
import sys
import tempfile
import zipfile


OPENBLAS_LICENSE = (
    "scipy_openblas64-0.3.34.237.2.dist-info/licenses/LICENSE.txt"
)
LICENSE_DEST = "numpy-2.3.5.dist-info/licenses/scipy-openblas64-LICENSE.txt"


def record_digest(data: bytes) -> str:
    digest = hashlib.sha256(data).digest()
    encoded = base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
    return f"sha256={encoded}"


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: attach_openblas_license.py INPUT_WHEEL OPENBLAS_WHEEL OUTPUT_WHEEL")
    input_wheel, openblas_wheel, output_wheel = map(Path, sys.argv[1:])
    with zipfile.ZipFile(openblas_wheel) as src:
        license_data = src.read(OPENBLAS_LICENSE)
    with zipfile.ZipFile(input_wheel) as src:
        names = src.namelist()
        if LICENSE_DEST in names:
            raise SystemExit(f"license destination already exists: {LICENSE_DEST}")
        records = [name for name in names if name.endswith(".dist-info/RECORD")]
        if len(records) != 1:
            raise SystemExit(f"expected one wheel RECORD, found {len(records)}")
        record_name = records[0]
        package_prefix = record_name.rsplit("/", 1)[0]
        license_dest = f"{package_prefix}/licenses/scipy-openblas64-LICENSE.txt"
        if license_dest != LICENSE_DEST:
            raise SystemExit(f"unexpected NumPy wheel dist-info path: {package_prefix}")
        if license_dest in names:
            raise SystemExit(f"license destination already exists: {license_dest}")

        payloads = {name: src.read(name) for name in names if name != record_name}
        payloads[license_dest] = license_data
        record_buffer = io.StringIO(newline="")
        writer = csv.writer(record_buffer, lineterminator="\n")
        for name in sorted(payloads):
            data = payloads[name]
            writer.writerow((name, record_digest(data), str(len(data))))
        writer.writerow((record_name, "", ""))
        payloads[record_name] = record_buffer.getvalue().encode("utf-8")

    output_wheel.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        prefix=f".{output_wheel.name}.", suffix=".tmp", dir=output_wheel.parent, delete=False
    ) as temp_file:
        temp_path = Path(temp_file.name)
    try:
        with zipfile.ZipFile(input_wheel) as src, zipfile.ZipFile(temp_path, "w") as dst:
            for info in src.infolist():
                if info.filename == record_name:
                    continue
                dst.writestr(info, payloads[info.filename])
            dst.writestr(
                license_dest,
                license_data,
                compress_type=zipfile.ZIP_DEFLATED,
            )
            dst.writestr(
                src.getinfo(record_name),
                payloads[record_name],
                compress_type=zipfile.ZIP_DEFLATED,
            )
        temp_path.replace(output_wheel)
    finally:
        temp_path.unlink(missing_ok=True)
    with zipfile.ZipFile(output_wheel) as check:
        if check.read(license_dest) != license_data:
            raise SystemExit("embedded OpenBLAS license verification failed")
        bad = check.testzip()
        if bad:
            raise SystemExit(f"wheel CRC verification failed: {bad}")
    print(f"Added {license_dest}; PE payloads copied unchanged from {input_wheel.name}")


if __name__ == "__main__":
    main()
