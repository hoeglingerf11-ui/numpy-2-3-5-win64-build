# Reproducible NumPy 2.3.5 Windows x64 build

A manual-only GitHub Actions workflow builds the official NumPy 2.3.5 source distribution for CPython 3.12.10 x64 on GitHub's standard `windows-2022` runner. The runner image inventory lists CPython 3.12.10 x64 and Visual Studio Enterprise 2022 17.14; Microsoft maps VS 17.14 to MSVC 14.44 (v143). The build script verifies the actual x64 compiler version and stops if it is not 19.44.x. Before importing NumPy, it inventories PE imports, repairs the wheel with the unchanged hash-locked scipy-openblas64 runtime using delvewheel, and tests the repaired wheel in a fresh venv where scipy-openblas64 is not installed as a Python package.

## Public repository disclosure

This repository is intended to be public so standard GitHub-hosted runners are free. The workflow source is visible to everyone. A successful run uploads the raw NumPy wheel, repaired NumPy wheel, pinned OpenBLAS source wheel/license evidence, and build/test reports. The workflow enforces a 100 MiB total artifact ceiling and one-day retention. Artifacts are public during retention. Do not add private project files, account details, credentials, proprietary sources, models, voices, or media.

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
