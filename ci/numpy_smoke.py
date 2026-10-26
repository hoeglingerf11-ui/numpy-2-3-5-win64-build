"""Small post-build NumPy/BLAS smoke and loaded-DLL-path inventory."""
from __future__ import annotations

import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import time


def loaded_modules() -> list[str]:
    psapi = ctypes.WinDLL("psapi", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.GetCurrentProcess.restype = ctypes.c_void_p
    psapi.EnumProcessModules.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_void_p),
        ctypes.c_ulong,
        ctypes.POINTER(ctypes.c_ulong),
    ]
    psapi.EnumProcessModules.restype = ctypes.c_int
    psapi.GetModuleFileNameExW.argtypes = [
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.c_wchar_p,
        ctypes.c_ulong,
    ]
    psapi.GetModuleFileNameExW.restype = ctypes.c_ulong
    process = kernel32.GetCurrentProcess()
    modules = (ctypes.c_void_p * 4096)()
    needed = ctypes.c_ulong()
    ok = psapi.EnumProcessModules(process, modules, ctypes.sizeof(modules), ctypes.byref(needed))
    if not ok:
        raise ctypes.WinError(ctypes.get_last_error())
    count = min(needed.value // ctypes.sizeof(ctypes.c_void_p), len(modules))
    paths: list[str] = []
    for module in modules[:count]:
        buf = ctypes.create_unicode_buffer(32768)
        size = psapi.GetModuleFileNameExW(process, module, buf, len(buf))
        if size:
            paths.append(buf.value)
    return sorted(set(paths), key=str.casefold)


def main() -> None:
    started = time.perf_counter()
    import numpy as np

    if np.__version__ != "2.3.5":
        raise AssertionError(f"Unexpected NumPy version: {np.__version__}")
    a = np.array([[3.0, 1.0], [1.0, 2.0]], dtype=np.float64)
    b = np.array([9.0, 8.0], dtype=np.float64)
    x = np.linalg.solve(a, b)
    np.testing.assert_allclose(a @ x, b, rtol=1e-12, atol=1e-12)
    u, s, vt = np.linalg.svd(a)
    np.testing.assert_allclose(u @ np.diag(s) @ vt, a, rtol=1e-12, atol=1e-12)
    determinant = float(np.linalg.det(a))
    if determinant != 5.0:
        raise AssertionError(f"Unexpected determinant: {determinant}")

    modules = loaded_modules()
    selected = [p for p in modules if re.search(r"(numpy|openblas|vcruntime|msvcp)", Path(p).name, re.I)]
    renamed_crt = [p for p in selected if re.fullmatch(r"msvcp140-[0-9a-f]{32}\.dll", Path(p).name, re.I)]
    if renamed_crt:
        raise AssertionError(f"Hash-named MSVC CRT dependency remains loaded: {renamed_crt}")
    openblas_modules = [p for p in modules if "libscipy_openblas64" in Path(p).name.casefold()]
    if len(openblas_modules) != 1:
        raise AssertionError(f"Expected one loaded scipy-openblas64 DLL, found: {openblas_modules}")
    if not any(part.casefold() == "numpy.libs" for part in Path(openblas_modules[0]).parts):
        raise AssertionError(f"OpenBLAS was not loaded from NumPy's vendored numpy.libs directory: {openblas_modules[0]}")
    if importlib.util.find_spec("scipy_openblas64") is not None:
        raise AssertionError("scipy_openblas64 is separately installed in the smoke environment")
    dll_records = []
    for item in selected:
        path = Path(item)
        record = {"path": str(path), "name": path.name}
        if path.is_file():
            record["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        dll_records.append(record)

    config = np.show_config(mode="dicts")
    dependencies = config.get("Build Dependencies", {})
    for dependency in ("blas", "lapack"):
        detail = dependencies.get(dependency, {})
        if detail.get("name") != "scipy-openblas" or detail.get("found") is not True:
            raise AssertionError(f"Required scipy-openblas {dependency} was not detected: {detail}")

    report = {
        "status": "PASS",
        "python": sys.version,
        "python_bits": ctypes.sizeof(ctypes.c_void_p) * 8,
        "numpy_version": np.__version__,
        "numpy_file": np.__file__,
        "linalg": {"solve": x.tolist(), "determinant": determinant, "svd_singular_values": s.tolist()},
        "loaded_runtime_modules": dll_records,
        "loaded_vendored_openblas_path": openblas_modules[0],
        "numpy_show_config": config,
        "elapsed_seconds": time.perf_counter() - started,
        "note": "This smoke test proves technical behavior in the hosted runner only; it is not a local SAC, MSIX, or commercial redistribution approval.",
    }
    out = Path("artifacts/reports/numpy_smoke.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
