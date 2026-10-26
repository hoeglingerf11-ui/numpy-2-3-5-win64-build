$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Artifacts = Join-Path $Repo 'artifacts'
$Reports = Join-Path $Artifacts 'reports'
$WheelDir = Join-Path $Artifacts 'wheel'
$SourceDir = Join-Path $env:RUNNER_TEMP 'u21ao-numpy-source'
$BuildDir = Join-Path $env:RUNNER_TEMP 'u21ao-numpy-build'
$Venv = Join-Path $env:RUNNER_TEMP 'u21ao-numpy-venv'
$FreshVenv = Join-Path $env:RUNNER_TEMP 'u21ao-numpy-repaired-smoke-venv'
$RawExtract = Join-Path $env:RUNNER_TEMP 'u21ao-numpy-raw-wheel'
$RepairedWheelDir = Join-Path $env:RUNNER_TEMP 'u21ao-numpy-repaired-wheel'
$LicensedWheelDir = Join-Path $env:RUNNER_TEMP 'u21ao-numpy-licensed-wheel'
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
$vsPath = & $vswhere -latest -products '*' -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $vsPath) { throw 'No Visual Studio 2022 x64 MSVC toolchain found' }
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
    expected_compiler_family = 'Visual Studio 2022 / MSVC 19.44.x (v143) x64'
    built_at_utc = [DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 (Join-Path $Reports 'build_environment.json')
$MsvcProbeSource = Join-Path $env:RUNNER_TEMP 'u21ao_msvc_version_probe.cpp'
[IO.File]::WriteAllText($MsvcProbeSource, "int main() { return 0; }`n", [Text.Encoding]::ASCII)
Invoke-Logged 'msvc_version' { & $cl.Source /Bv /Zs $MsvcProbeSource }
$msvcVersionText = Get-Content -LiteralPath (Join-Path $Reports 'msvc_version.log') -Raw
if ($msvcVersionText -notmatch 'Compiler Version\s+(?<version>19\.44\.\d+)\s+for x64') {
    throw 'Expected the VS 2022 MSVC 19.44.x x64 compiler; see msvc_version.log'
}
$MsvcVersion = $Matches['version']
$envReportPath = Join-Path $Reports 'build_environment.json'
$envReport = Get-Content -LiteralPath $envReportPath -Raw | ConvertFrom-Json
$envReport | Add-Member -NotePropertyName msvc_compiler_version -NotePropertyValue $MsvcVersion
$envReport | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 $envReportPath
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
$pcFilePath = (Resolve-Path -LiteralPath $pcFile.Trim()).Path
$pcFileStem = [IO.Path]::GetFileNameWithoutExtension($pcFilePath)
if ($pcFileStem -ne 'scipy-openblas') { throw "Unexpected pkg-config module name: $pcFileStem" }
$pcContents = Get-Content -LiteralPath $pcFilePath -Raw
if ($pcContents -notmatch '(?m)^version=0\.3\.34\.237\.2\s*$' -or
    $pcContents -notmatch '(?m)^Libs:.*-llibscipy_openblas64_' -or
    $pcContents -notmatch '(?m)^Cflags:.*-DHAVE_BLAS_ILP64') {
    throw "scipy-openblas pkg-config metadata does not match the locked ILP64 runtime: $pcFilePath"
}
$env:PKG_CONFIG = Join-Path $Venv 'Scripts\pkg-config.exe'
$env:PKG_CONFIG_PATH = Split-Path $pcFile.Trim()
Write-Host "OpenBLAS pkg-config file: $pcFilePath"
Write-Host "OpenBLAS pkg-config module: $pcFileStem"

function Invoke-PkgConfig {
    param([string]$Label, [string[]]$Arguments)
    Write-Host "===== $Label ====="
    $output = @(& $env:PKG_CONFIG @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $output | Set-Content -Encoding utf8 (Join-Path $Reports "$Label.log")
    Write-Host ($output -join "`n")
    if ($exitCode -ne 0) { throw "$Label failed with exit code $exitCode" }
    if (-not $output -or -not (($output -join '').Trim())) { throw "$Label returned empty output" }
    return ($output -join "`n").Trim()
}

$pkgVersion = Invoke-PkgConfig 'openblas_pkgconfig_version' @('--modversion','scipy-openblas')
if ($pkgVersion -ne '0.3.34.237.2') { throw "Unexpected scipy-openblas pkg-config version: $pkgVersion" }
$pkgLibs = Invoke-PkgConfig 'openblas_pkgconfig_libs' @('--libs','scipy-openblas')
if ($pkgLibs -notmatch '-llibscipy_openblas64_' -or $pkgLibs -notmatch '(?i)scipy_openblas64[/\\]lib') {
    throw "scipy-openblas linker flags do not reference the locked ILP64 library: $pkgLibs"
}
$pkgCflags = Invoke-PkgConfig 'openblas_pkgconfig_cflags' @('--cflags','scipy-openblas')
if ($pkgCflags -notmatch '(?i)-I\S*scipy_openblas64.*include' -or
    $pkgCflags -notmatch '-DHAVE_BLAS_ILP64' -or $pkgCflags -notmatch '-DBLAS_SYMBOL_SUFFIX=64_') {
    throw "scipy-openblas compiler flags do not identify the expected ILP64 interface: $pkgCflags"
}

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

$openblasWheelName = 'scipy_openblas64-0.3.34.237.2-py3-none-win_amd64.whl'
$openblasWheelPath = Get-ChildItem $SourceDir -Filter $openblasWheelName -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $openblasWheelPath) {
    Invoke-Logged 'download_hash_pinned_openblas_runtime' {
        & $Python -m pip download --no-deps --require-hashes --index-url https://pypi.org/simple -r (Join-Path $Repo 'requirements-build.lock') --dest $SourceDir
    }
    $openblasWheelPath = Get-ChildItem $SourceDir -Filter 'scipy_openblas64-0.3.34.237.2-*.whl' -File | Select-Object -First 1
}
if (-not $openblasWheelPath) { throw 'Pinned OpenBLAS wheel missing from artifact set' }
Copy-Item -LiteralPath $openblasWheelPath.FullName -Destination $WheelDir

$openblasInfo = & $Python -c "import pathlib,scipy_openblas64; print(pathlib.Path(scipy_openblas64.__file__).parent/'lib')"
if ($LASTEXITCODE -ne 0 -or -not $openblasInfo.Trim()) { throw 'Could not locate installed scipy-openblas64 runtime directory' }
$OpenBlasLib = Join-Path $openblasInfo.Trim() 'libscipy_openblas64_.dll'
if (-not (Test-Path -LiteralPath $OpenBlasLib)) { throw "Expected OpenBLAS DLL missing: $OpenBlasLib" }
$openblasHash = (Get-FileHash -Algorithm SHA256 $OpenBlasLib).Hash.ToLowerInvariant()
@{
    package = 'scipy-openblas64'
    version = '0.3.34.237.2'
    wheel = $openblasWheelName
    wheel_sha256 = (Get-FileHash -Algorithm SHA256 $openblasWheelPath.FullName).Hash.ToLowerInvariant()
    dll_path = $OpenBlasLib
    dll_sha256 = $openblasHash
    license_source = 'scipy_openblas64-0.3.34.237.2.dist-info/licenses/LICENSE.txt inside the pinned wheel'
} | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 (Join-Path $Reports 'openblas_runtime.json')

$ExtractCheck = & $BasePython -c "import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" $numpyWheel.FullName $RawExtract 2>&1
if ($LASTEXITCODE -ne 0) { throw "Raw NumPy wheel extraction failed: $ExtractCheck" }
$rawTargets = Get-ChildItem $RawExtract -Recurse -File | Where-Object { $_.Extension -in '.pyd','.dll' -and $_.FullName -match '\\numpy\\' }
if (-not $rawTargets) { throw 'No NumPy PE files found in the raw wheel for dependency inventory' }
$depFile = Join-Path $Reports 'native_pe_dependents_raw.txt'
foreach ($target in $rawTargets) {
    "===== $($target.FullName.Substring($RawExtract.Length + 1)) =====" | Add-Content -Encoding utf8 $depFile
    $dep = & $dumpbin.FullName /DEPENDENTS $target.FullName 2>&1
    if ($LASTEXITCODE -ne 0) { throw "dumpbin failed on raw wheel file $($target.FullName)" }
    $dep | Add-Content -Encoding utf8 $depFile
}
"===== scipy-openblas64 runtime DLL =====" | Add-Content -Encoding utf8 $depFile
$openblasDeps = & $dumpbin.FullName /DEPENDENTS $OpenBlasLib 2>&1
if ($LASTEXITCODE -ne 0) { throw 'dumpbin failed on the pinned OpenBLAS runtime DLL' }
$openblasDeps | Add-Content -Encoding utf8 $depFile
$rawDepText = Get-Content $depFile -Raw
foreach ($expectedModule in @('_multiarray_umath','lapack_lite','_umath_linalg')) {
    $moduleBlock = [regex]::Match($rawDepText, "(?s)===== [^\r\n]*$([regex]::Escape($expectedModule))[^\r\n]* =====(?<body>.*?)(?=^===== |\z)", [Text.RegularExpressions.RegexOptions]::Multiline)
    if (-not $moduleBlock.Success -or $moduleBlock.Groups['body'].Value -notmatch '(?i)libscipy_openblas64_\.dll') {
        throw "$expectedModule does not show the expected direct libscipy_openblas64_.dll import in the PE report"
    }
}
if ($rawDepText -match '(?i)msvcp140-[0-9a-f]{32}\.dll') { throw 'Raw NumPy PE imports contain an unexpected hash-named MSVC CRT DLL' }
if ($rawDepText -notmatch '(?i)MSVCP140\.dll' -or $rawDepText -notmatch '(?i)VCRUNTIME140\.dll') {
    throw 'Expected standard-name MSVC runtime imports were not present in the raw PE inventory'
}

$delvewheel = Join-Path $Venv 'Scripts\delvewheel.exe'
if (-not (Test-Path $delvewheel)) { throw 'Hash-locked delvewheel executable missing from build venv' }
$crtExcludes = 'MSVCP140*.dll;VCRUNTIME140*.dll;VCOMP140.dll;CONCRT140.dll;ucrtbase.dll;api-ms-win-crt-*.dll'
Invoke-Logged 'delvewheel_show_raw_dependencies' {
    & $delvewheel show --add-path (Split-Path $OpenBlasLib) --exclude $crtExcludes $numpyWheel.FullName
}
New-Item -ItemType Directory -Force -Path $RepairedWheelDir,$LicensedWheelDir | Out-Null
Invoke-Logged 'delvewheel_repair_numpy' {
    & $delvewheel repair --add-path (Split-Path $OpenBlasLib) --exclude $crtExcludes --wheel-dir $RepairedWheelDir $numpyWheel.FullName
}
$repairedWheel = Get-ChildItem $RepairedWheelDir -Filter 'numpy-2.3.5-cp312-cp312-win_amd64.whl' -File | Select-Object -First 1
if (-not $repairedWheel) { throw 'delvewheel did not produce the expected repaired NumPy wheel' }
Invoke-Logged 'delvewheel_show_repaired_dependencies' { & $delvewheel show $repairedWheel.FullName }

$licensedWheel = Join-Path $LicensedWheelDir $repairedWheel.Name
Invoke-Logged 'attach_openblas_license_notice' {
    & $BasePython (Join-Path $Repo 'ci\attach_openblas_license.py') $repairedWheel.FullName $openblasWheelPath.FullName $licensedWheel
}
if (-not (Test-Path $licensedWheel)) { throw 'Licensed repaired wheel was not produced' }
$RepairedArtifactDir = Join-Path $WheelDir 'repaired'
New-Item -ItemType Directory -Force -Path $RepairedArtifactDir | Out-Null
Copy-Item -LiteralPath $licensedWheel -Destination (Join-Path $RepairedArtifactDir $licensedWheel.Name)

$wheelAudit = @'
import pathlib, re, sys, zipfile
wheel = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(wheel) as z:
    bad = z.testzip()
    if bad:
        raise SystemExit(f"wheel CRC error: {bad}")
    names = z.namelist()
    dlls = [n for n in names if n.lower().endswith(".dll")]
    openblas = [n for n in dlls if re.search(r"libscipy_openblas64_.*\.dll$", n, re.I)]
    if not openblas:
        raise SystemExit("repaired wheel has no vendored libscipy_openblas64_ DLL")
    crt = [n for n in dlls if re.search(r"(?:msvcp140|vcruntime140|vcomp140|concrt140|ucrtbase|api-ms-win-crt-).*\.dll$", n, re.I)]
    if crt:
        raise SystemExit(f"Microsoft CRT DLLs were bundled or renamed: {crt}")
    if not any(n.endswith("/licenses/scipy-openblas64-LICENSE.txt") for n in names):
        raise SystemExit("OpenBLAS license bundle is absent from the repaired NumPy wheel")
    print("Vendored OpenBLAS DLLs:", openblas)
    print("Microsoft CRT DLL payloads:", crt)
    print("OpenBLAS license notice: present")
'@
$wheelAuditFile = Join-Path $env:RUNNER_TEMP 'u21ao_audit_repaired_wheel.py'
[IO.File]::WriteAllText($wheelAuditFile, $wheelAudit, [Text.Encoding]::UTF8)
Invoke-Logged 'audit_repaired_wheel_contents' { & $BasePython $wheelAuditFile $licensedWheel }

& $BasePython -m venv $FreshVenv
if ($LASTEXITCODE -ne 0) { throw "fresh smoke venv creation failed: $LASTEXITCODE" }
$FreshPython = Join-Path $FreshVenv 'Scripts\python.exe'
Invoke-Logged 'confirm_openblas_python_package_absent' {
    & $FreshPython -I -c "import importlib.util,sys; found=importlib.util.find_spec('scipy_openblas64'); print('scipy_openblas64 spec:',found); sys.exit(1 if found else 0)"
}
Invoke-Logged 'install_repaired_numpy_in_fresh_venv' {
    & $FreshPython -m pip install --no-deps --no-index $licensedWheel
}
$freshSite = & $FreshPython -I -c "import sysconfig; print(sysconfig.get_paths()['purelib'])"
if ($LASTEXITCODE -ne 0 -or -not $freshSite.Trim()) { throw 'Could not resolve fresh venv site-packages path' }
$freshTargets = Get-ChildItem $freshSite.Trim() -Recurse -File | Where-Object { $_.Extension -in '.pyd','.dll' -and $_.FullName -match '\\numpy\\|\\numpy\.libs\\' }
$freshDepFile = Join-Path $Reports 'native_pe_dependents_repaired.txt'
foreach ($target in $freshTargets) {
    "===== $($target.FullName.Substring($freshSite.Trim().Length + 1)) =====" | Add-Content -Encoding utf8 $freshDepFile
    $dep = & $dumpbin.FullName /DEPENDENTS $target.FullName 2>&1
    if ($LASTEXITCODE -ne 0) { throw "dumpbin failed on repaired file $($target.FullName)" }
    $dep | Add-Content -Encoding utf8 $freshDepFile
}
$freshDepText = Get-Content $freshDepFile -Raw
if ($freshDepText -match '(?i)msvcp140-[0-9a-f]{32}\.dll') { throw 'Repaired PE imports contain an unexpected hash-named MSVC CRT DLL' }
Invoke-Logged 'numpy_repaired_fresh_venv_linalg_smoke' { & $FreshPython -I (Join-Path $Repo 'ci\numpy_smoke.py') }
$smoke = Get-Content (Join-Path $Reports 'numpy_smoke.json') -Raw | ConvertFrom-Json
$runtimeVersions = foreach ($module in $smoke.loaded_runtime_modules | Where-Object { $_.name -match '^(MSVCP140|VCRUNTIME140)' }) {
    $item = Get-Item -LiteralPath $module.path -ErrorAction Stop
    [pscustomobject]@{ name = $item.Name; path = $item.FullName; file_version = $item.VersionInfo.FileVersion; product_version = $item.VersionInfo.ProductVersion; sha256 = (Get-FileHash -Algorithm SHA256 $item.FullName).Hash.ToLowerInvariant() }
}
$runtimeVersions | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 (Join-Path $Reports 'microsoft_runtime_loaded.json')
$licenseCopy = Join-Path $Reports 'scipy-openblas64-LICENSE.txt'
Invoke-Logged 'extract_openblas_license_bundle' {
    & $BasePython -c "import pathlib,sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); n='scipy_openblas64-0.3.34.237.2.dist-info/licenses/LICENSE.txt'; pathlib.Path(sys.argv[2]).write_bytes(z.read(n))" $openblasWheelPath.FullName $licenseCopy
}
$repairNotes = @(
    '# NumPy Run 3 targeted DLL repair',
    '',
    '- Raw input: existing NumPy 2.3.5 CPython 3.12 x64 wheel built from the hash-pinned upstream source; it is retained unchanged.',
    '- PE inspection is completed before any NumPy import. _multiarray_umath, lapack_lite, and _umath_linalg must directly import libscipy_openblas64_.dll.',
    '- delvewheel resolves the DLL only from the pinned scipy-openblas64==0.3.34.237.2 package and repairs a copy of the raw wheel.',
    '- The pinned package wheel and its complete bundled license text are retained as provenance/notice evidence. The notice is added to the repaired wheel and wheel RECORD is regenerated.',
    '- Explicit delvewheel exclusions prevent bundling MSVCP/VCRUNTIME/UCRT/API-set runtime DLLs. Direct imports remain under Microsoft standard names.',
    '- Microsoft runtime imports observed in the PE files: MSVCP140.dll, VCRUNTIME140.dll, VCRUNTIME140_1.dll, plus Windows API-set UCRT imports. Actual loaded paths and file versions are recorded by the fresh smoke.',
    '- Import names do not establish a minimum CRT version or a redistribution grant. The test records the actual runner runtime; product licensing remains subject to the relevant Visual Studio REDIST terms.',
    '- OpenBLAS licensing remains governed by the complete included license bundle. Technical repair is not legal clearance.',
    '- Smoke installs only the repaired NumPy wheel into a brand-new venv and asserts scipy_openblas64 has no installed Python package specification.'
) -join [Environment]::NewLine
$repairNotes | Set-Content -Encoding utf8 (Join-Path $Reports 'numpy_dll_repair_notes.md')

$envReport = Get-Content $envReportPath -Raw | ConvertFrom-Json
$envReport | Add-Member -NotePropertyName runner_free_after_bytes -NotePropertyValue ((Get-PSDrive -Name $DriveName).Free)
$envReport | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 $envReportPath
$entries = foreach ($file in Get-ChildItem $Artifacts -Recurse -File | Where-Object { $_.Name -notin @('SHA256SUMS.txt') }) {
    '{0}  {1}' -f (Get-FileHash -Algorithm SHA256 $file.FullName).Hash.ToLowerInvariant(), $file.FullName.Substring($Artifacts.Length + 1)
}
$entries | Set-Content -Encoding ascii (Join-Path $Artifacts 'SHA256SUMS.txt')
Write-Host 'Completed artifacts include raw and repaired NumPy wheels, pinned OpenBLAS wheel/license evidence and dependency reports.'
