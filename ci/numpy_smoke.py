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
import warnings


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
    # Treat import-time numerical warnings as failures: Run 4's longdouble
    # overflow warning preceded the import exception.
    with warnings.catch_warnings():
        warnings.simplefilter("error", RuntimeWarning)
        import numpy as np

    if np.__version__ != "2.3.5":
        raise AssertionError(f"Unexpected NumPy version: {np.__version__}")

    arange_result = np.arange(5)
    np.testing.assert_array_equal(arange_result, np.array([0, 1, 2, 3, 4]))
    linspace_result = np.linspace(0, 1, 3)
    np.testing.assert_array_equal(linspace_result, np.array([0.0, 0.5, 1.0]))

    finite_probe = np.array([0.0, -1.25, np.nan, np.inf], dtype=np.float64)
    finite_result = np.isfinite(finite_probe)
    np.testing.assert_array_equal(finite_result, np.array([True, True, False, False]))
    longdouble_info = np.finfo(np.longdouble)
    if not np.isfinite(longdouble_info.eps) or longdouble_info.eps <= 0:
        raise AssertionError(f"Invalid longdouble epsilon: {longdouble_info.eps!r}")
    longdouble_probe = np.array([np.longdouble("1.25"), np.longdouble("-0.5"),
                                 np.longdouble("nan"), np.longdouble("inf")])
    np.testing.assert_array_equal(
        np.isfinite(longdouble_probe), np.array([True, True, False, False])
    )

    rendered_positional = np.format_float_positional(np.float64("1.25"), unique=True, trim="-")
    rendered_scientific = np.format_float_scientific(np.float64("1.25"), unique=True, trim="-")
    rendered_array_repr = repr(np.array([1.0, 2.0, 3.0], dtype=np.float64))
    if rendered_positional != "1.25" or rendered_scientific != "1.25e+00":
        raise AssertionError(
            f"Unexpected finite float rendering: {rendered_positional!r}, {rendered_scientific!r}"
        )
    if rendered_array_repr != "array([1., 2., 3.])":
        raise AssertionError(f"Finite float array representation is incorrect: {rendered_array_repr!r}")
    if not np.isfinite(float(rendered_positional)) or float(rendered_positional) != 1.25:
        raise AssertionError(f"Finite float text did not round-trip: {rendered_positional!r}")

    a = np.array([[3.0, 1.0], [1.0, 2.0]], dtype=np.float64)
    b = np.array([9.0, 8.0], dtype=np.float64)
    x = np.linalg.solve(a, b)
    np.testing.assert_array_equal(x, np.array([2.0, 3.0]))
    np.testing.assert_allclose(a @ x, b, rtol=1e-12, atol=1e-12)
    u, s, vt = np.linalg.svd(a)
    np.testing.assert_allclose(u @ np.diag(s) @ vt, a, rtol=1e-12, atol=1e-12)
    determinant = float(np.linalg.det(a))
    np.testing.assert_allclose(determinant, 5.0, rtol=1e-12, atol=1e-12)

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
    microsoft_crt_modules = [
        p for p in modules
        if re.fullmatch(r"(?:(?:msvcp|vcruntime)140(?:_[0-9]+)?|ucrtbase)\.dll", Path(p).name, re.I)
    ]
    if not microsoft_crt_modules:
        raise AssertionError("No Microsoft VC++ CRT DLL load path was observed")
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
        "basic_numeric_checks": {
            "arange_5": arange_result.tolist(),
            "linspace_0_1_3": linspace_result.tolist(),
            "isfinite_float64": finite_result.tolist(),
            "isfinite_longdouble": np.isfinite(longdouble_probe).tolist(),
            "longdouble_epsilon": str(longdouble_info.eps),
            "finite_rendering_positional": rendered_positional,
            "finite_rendering_scientific": rendered_scientific,
            "finite_array_repr": rendered_array_repr,
        },
        "linalg": {"solve": x.tolist(), "determinant": determinant, "svd_singular_values": s.tolist()},
        "loaded_runtime_modules": dll_records,
        "loaded_microsoft_crt_paths": microsoft_crt_modules,
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
