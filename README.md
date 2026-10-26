# Reproducible NumPy 2.3.5 Windows x64 build

A manual-only GitHub Actions workflow builds the official NumPy 2.3.5 source distribution for CPython 3.12.10 x64 on GitHub's standard windows-2025-vs2026 runner. It tests NumPy imports and BLAS/LAPACK operations, records PE dependencies and loaded runtime DLL paths, and emits checksums.

## Public repository disclosure

This repository is intended to be public so standard GitHub-hosted runners are free. The workflow source is visible to everyone. A successful run uploads only the NumPy wheel, the pinned OpenBLAS runtime wheel, and build/test reports. The workflow enforces a 100 MiB total artifact ceiling and one-day retention. Artifacts are public during retention. Do not add private project files, account details, credentials, proprietary sources, models, voices, or media.

GitHub documents standard Windows runners as free and unlimited for public repositories. GitHub Free includes 500 MB shared artifact/Packages storage; this harness caps each run artifact at 100 MiB for one day. If the account's included storage is already exhausted and no payment method is present, GitHub blocks over-quota usage rather than charging it. The account's current pooled storage usage still must be checked by its owner before the run.

## Build inputs

- Official NumPy 2.3.5 PyPI source distribution, pinned by SHA-256 in requirements-source.lock.
- Hash-locked build dependencies in requirements-build.lock.
- OpenBLAS/LAPACK supplied by the hash-locked scipy-openblas64 wheel.
- GitHub Actions pinned to immutable commit SHAs in the workflow.
- No secrets or repository variables are required.

The workflow is workflow_dispatch only. It has one job, a 90-minute ceiling, no cache, no retry, and no larger-runner labels. It has not been run from this repository copy. A successful hosted build is not proof of local Windows trust, product compatibility, or commercial redistribution rights.

## Before enabling or starting

The source and build artifacts will be public. Review the account/owner identity shown on the repository page before approving publication. Check that the GitHub Free shared artifact/Packages allowance has room for the bounded artifact. Do not start unless publication and the 0.00 EUR condition are approved.

See build_inputs.json and the pinned requirements for exact public inputs and license references.
