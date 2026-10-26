$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Artifacts = Join-Path $Repo 'artifacts'
$Reports = Join-Path $Artifacts 'reports'
$WheelDir = Join-Path $Artifacts 'wheel'
$SourceDir = Join-Path $env:RUNNER_TEMP 'u21ao-numpy-source'
$BuildDir = Join-Path $env:RUNNER_TEMP 'u21ao-numpy-build'
$Venv = Join-Path $env:RUNNER_TEMP 'u21ao-numpy-venv'
$DriveName = ([IO.Path]::GetPathRoot($env:RUNNER_TEMP)).Substring(0,1)
$FreeBeforeBytes = (Get-PSDrive -Name $DriveName -ErrorAction Stop).Free
if ($FreeBeforeBytes -lt 4GB) { throw "Runner temp volume has less than the 4-GiB safety reserve: $FreeBeforeBytes bytes free" }
New-Item -ItemType Directory -Force -Path $Reports,$WheelDir,$SourceDir,$BuildDir | Out-Null
Copy-Item -LiteralPath (Join-Path $Repo 'requirements-build.lock') -Destination $Reports
Copy-Item -LiteralPath (Join-Path $Repo 'requirements-source.lock') -Destination $Reports
Copy-Item -LiteralPath (Join-Path $Repo 'build_inputs.json') -Destination $Reports

function Invoke-Logged {
    param([string]$Label, [scriptblock]$Command)
    Write-Host "===== $Label ====="
    & $Command 2>&1 | Tee-Object -FilePath (Join-Path $Reports "$Label.log")
    if ($LASTEXITCODE -ne 0) { throw "$Label failed with exit code $LASTEXITCODE" }
}

$pythonCommand = Get-Command python -ErrorAction Stop
$BasePython = $pythonCommand.Source
$pyInfo = & $BasePython -c 'import struct,sys; print(".".join(map(str,sys.version_info[:3])), struct.calcsize("P")*8)'
if ($LASTEXITCODE -ne 0 -or $pyInfo.Trim() -ne '3.12.10 64') { throw "Expected CPython 3.12.10 x64; got $pyInfo" }

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw "vswhere.exe missing: $vswhere" }
$vsPath = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $vsPath) { throw 'No Visual Studio x64 MSVC toolchain found' }
$devCmd = Join-Path $vsPath 'Common7\Tools\VsDevCmd.bat'
if (-not (Test-Path $devCmd)) { throw "VsDevCmd.bat missing: $devCmd" }
$cmdLine = 'call "' + $devCmd + '" -arch=x64 -host_arch=x64 >nul && set'
$envLines = & cmd.exe /d /c $cmdLine
if ($LASTEXITCODE -ne 0) { throw 'VsDevCmd failed to establish x64 compiler environment' }
foreach ($line in $envLines) {
    if ($line -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($Matches[1],$Matches[2],'Process') }
}

$cl = Get-Command cl.exe -ErrorAction Stop
$dumpbin = Get-ChildItem (Join-Path $vsPath 'VC\Tools\MSVC') -Filter dumpbin.exe -File -Recurse |
    Where-Object { $_.FullName -match '\\bin\\Hostx64\\x64\\dumpbin\.exe$' } |
    Sort-Object FullName -Descending | Select-Object -First 1
if (-not $dumpbin) { throw 'x64 dumpbin.exe not found in the selected Visual Studio toolchain' }

@{
    runner_image = $env:ImageOS
    runner_image_version = $env:ImageVersion
    python_executable = $BasePython
    python_version_arch = $pyInfo.Trim()
    visual_studio_path = $vsPath.Trim()
    cl_path = $cl.Source
    dumpbin_path = $dumpbin.FullName
    runner_temp_volume = "$DriveName`:\"
    runner_free_before_bytes = $FreeBeforeBytes
    built_at_utc = [DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 (Join-Path $Reports 'build_environment.json')
$MsvcProbeSource = Join-Path $env:RUNNER_TEMP 'u21ao_msvc_version_probe.cpp'
[IO.File]::WriteAllText($MsvcProbeSource, "int main() { return 0; }`n", [Text.Encoding]::ASCII)
Invoke-Logged 'msvc_version' { & $cl.Source /Bv /Zs $MsvcProbeSource }
Invoke-Logged 'python_version' { & $BasePython --version }

& $BasePython -m venv $Venv
if ($LASTEXITCODE -ne 0) { throw "venv creation failed: $LASTEXITCODE" }
$Python = Join-Path $Venv 'Scripts\python.exe'
$env:PATH = (Join-Path $Venv 'Scripts') + ';' + $env:PATH
$env:PIP_DISABLE_PIP_VERSION_CHECK = '1'
$env:PIP_INDEX_URL = 'https://pypi.org/simple'

Invoke-Logged 'install_locked_build_dependencies' {
    & $Python -m pip install --no-deps --require-hashes --index-url https://pypi.org/simple -r (Join-Path $Repo 'requirements-build.lock')
}
Invoke-Logged 'build_dependency_inventory' { & $Python -m pip freeze --all }

$pcFile = & $Python -c "import pathlib,scipy_openblas64; print(next((pathlib.Path(scipy_openblas64.__file__).parent/'lib'/'pkgconfig').glob('scipy-openblas.pc')))"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $pcFile.Trim())) { throw "scipy-openblas pkg-config file missing: $pcFile" }
$env:PKG_CONFIG = Join-Path $Venv 'Scripts\pkg-config.exe'
$env:PKG_CONFIG_PATH = Split-Path $pcFile.Trim()
Invoke-Logged 'openblas_pkgconfig' { & $env:PKG_CONFIG --modversion openblas }

Invoke-Logged 'download_hash_pinned_numpy_source' {
    & $Python -m pip download --no-deps --no-binary=numpy --require-hashes --index-url https://pypi.org/simple -r (Join-Path $Repo 'requirements-source.lock') --dest $SourceDir
}
$sourceArchive = Get-ChildItem $SourceDir -Filter 'numpy-2.3.5.tar.gz' -File | Select-Object -First 1
if (-not $sourceArchive) { throw 'Hash-pinned NumPy source archive was not downloaded' }
$sourceHash = (Get-FileHash -Algorithm SHA256 $sourceArchive.FullName).Hash.ToLowerInvariant()
if ($sourceHash -ne '784db1dcdab56bf0517743e746dfb0f885fc68d948aba86eeec2cba234bdf1c0') { throw "NumPy sdist hash mismatch: $sourceHash" }
$envReportPath = Join-Path $Reports 'build_environment.json'
$envReport = Get-Content $envReportPath -Raw | ConvertFrom-Json
$envReport | Add-Member -NotePropertyName numpy_sdist_sha256 -NotePropertyValue $sourceHash
$envReport | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 $envReportPath
tar.exe -xzf $sourceArchive.FullName -C $BuildDir
if ($LASTEXITCODE -ne 0) { throw "NumPy source extraction failed: $LASTEXITCODE" }
$Source = Join-Path $BuildDir 'numpy-2.3.5'
if (-not (Test-Path (Join-Path $Source 'meson.build'))) { throw 'Expected NumPy 2.3.5 source tree missing' }

Invoke-Logged 'build_numpy_wheel' {
    & $Python -m pip wheel --no-deps --no-build-isolation --no-cache-dir `
        --config-settings=setup-args=-Duse-ilp64=true `
        --config-settings=setup-args=-Dblas=scipy-openblas `
        --config-settings=setup-args=-Dlapack=scipy-openblas `
        --config-settings=setup-args=-Dallow-noblas=false `
        --wheel-dir $WheelDir $Source
}
$numpyWheel = Get-ChildItem $WheelDir -Filter 'numpy-2.3.5-cp312-cp312-win_amd64.whl' -File | Select-Object -First 1
if (-not $numpyWheel) { throw 'Expected CPython 3.12 x64 NumPy wheel missing' }

Invoke-Logged 'install_built_numpy_for_smoke' { & $Python -m pip install --no-deps --no-index $numpyWheel.FullName }
Invoke-Logged 'numpy_linalg_native_smoke' { & $Python (Join-Path $Repo 'ci\numpy_smoke.py') }

$site = & $Python -c "import sysconfig; print(sysconfig.get_paths()['purelib'])"
$targets = Get-ChildItem $site.Trim() -Recurse -File | Where-Object { $_.Extension -in '.pyd','.dll' -and ($_.FullName -match '\\numpy\\|\\numpy\.libs\\|\\scipy_openblas64\\') }
$depFile = Join-Path $Reports 'native_pe_dependents.txt'
foreach ($target in $targets) {
    "===== $($target.FullName) =====" | Add-Content -Encoding utf8 $depFile
    $dep = & $dumpbin.FullName /DEPENDENTS $target.FullName 2>&1
    if ($LASTEXITCODE -ne 0) { throw "dumpbin failed on $($target.FullName)" }
    $dep | Add-Content -Encoding utf8 $depFile
}
$depText = Get-Content $depFile -Raw
if ($depText -match '(?i)msvcp140-[0-9a-f]{32}\.dll') { throw 'PE dependency inventory still references a hash-named MSVC CRT DLL' }

$openblasWheelName = 'scipy_openblas64-0.3.34.237.2-py3-none-win_amd64.whl'
# Keep the pinned BLAS/LAPACK runtime wheel with the build output, so the exact
# tested DLL/license payload can be examined later. This is not a product approval.
$openblasWheelPath = Get-ChildItem $SourceDir -Filter $openblasWheelName -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $openblasWheelPath) {
    Invoke-Logged 'download_hash_pinned_openblas_runtime' {
        & $Python -m pip download --no-deps --require-hashes --index-url https://pypi.org/simple -r (Join-Path $Repo 'requirements-build.lock') --dest $SourceDir
    }
    $openblasWheelPath = Get-ChildItem $SourceDir -Filter 'scipy_openblas64-0.3.34.237.2-*.whl' -File | Select-Object -First 1
}
if (-not $openblasWheelPath) { throw 'Pinned OpenBLAS wheel missing from artifact set' }
Copy-Item -LiteralPath $openblasWheelPath.FullName -Destination $WheelDir

$envReport = Get-Content $envReportPath -Raw | ConvertFrom-Json
$envReport | Add-Member -NotePropertyName runner_free_after_bytes -NotePropertyValue ((Get-PSDrive -Name $DriveName).Free)
$envReport | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 $envReportPath
$entries = foreach ($file in Get-ChildItem $Artifacts -Recurse -File | Where-Object { $_.Name -notin @('SHA256SUMS.txt') }) {
    '{0}  {1}' -f (Get-FileHash -Algorithm SHA256 $file.FullName).Hash.ToLowerInvariant(), $file.FullName.Substring($Artifacts.Length + 1)
}
$entries | Set-Content -Encoding ascii (Join-Path $Artifacts 'SHA256SUMS.txt')
Write-Host 'Completed build artifacts are limited to the NumPy wheel, the tested OpenBLAS runtime wheel and public-source build reports.'
