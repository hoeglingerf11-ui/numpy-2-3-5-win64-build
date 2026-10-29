$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repoTemp = Join-Path $env:RUNNER_TEMP 'u21bv'
$venv = Join-Path $repoTemp 'venv'
$wheelDir = Join-Path $repoTemp 'wheels'
$pkgDir = Join-Path $repoTemp 'intel-nupkg'
$originalDllDir = Join-Path $repoTemp 'torch-openmp-original'
New-Item -ItemType Directory -Force -Path $repoTemp,$wheelDir,$pkgDir,$originalDllDir | Out-Null
py -3.12 -m venv $venv
$python = Join-Path $venv 'Scripts\python.exe'
if (-not (Test-Path $python)) { throw 'Python 3.12 venv creation failed' }

function Install-HashedWheel([string]$Requirement, [string]$WheelPattern, [string]$IndexUrl) {
  $null = & $python -m pip download --disable-pip-version-check --no-deps --index-url $IndexUrl --dest $wheelDir $Requirement
  if ($LASTEXITCODE -ne 0) { throw "Wheel download failed: $Requirement from $IndexUrl" }
  $wheel = Get-ChildItem $wheelDir -File -Filter $WheelPattern | Select-Object -First 1
  if (-not $wheel) { throw "Expected wheel missing for ${Requirement}: $WheelPattern" }
  $hash = (Get-FileHash $wheel.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  Write-Host "PACKAGE_WHEEL requirement=$Requirement source=$IndexUrl filename=$($wheel.Name) sha256=$hash"
  $null = & $python -m pip install --disable-pip-version-check --no-deps $wheel.FullName
  if ($LASTEXITCODE -ne 0) { throw "Wheel install failed: $Requirement" }
  return @{ path=$wheel.FullName; sha256=$hash; filename=$wheel.Name; source=$IndexUrl }
}

$torchWheel = Install-HashedWheel 'torch==2.10.0+cpu' 'torch-2.10.0+cpu-cp312-cp312-win_amd64.whl' 'https://download.pytorch.org/whl/cpu'
$numpyWheel = Install-HashedWheel 'numpy==2.3.5' 'numpy-2.3.5-cp312-cp312-win_amd64.whl' 'https://pypi.org/simple'
$transformersWheel = Install-HashedWheel 'transformers==4.39.2' 'transformers-4.39.2-py3-none-any.whl' 'https://pypi.org/simple'
$tokenizersWheel = Install-HashedWheel 'tokenizers==0.15.2' 'tokenizers-0.15.2-cp312-none-win_amd64.whl' 'https://pypi.org/simple'
$kokoroWheel = Install-HashedWheel 'kokoro==0.9.4' 'kokoro-0.9.4-py3-none-any.whl' 'https://pypi.org/simple'
$null = & $python -m pip install --disable-pip-version-check --index-url https://pypi.org/simple transformers==4.39.2 huggingface-hub==0.26.2 loguru==0.7.3 attrs==25.3.0 pefile==2024.8.26
if ($LASTEXITCODE -ne 0) { throw 'Python dependency resolution failed' }

$nupkg = Join-Path $repoTemp 'intelopenmp.redist.win.2025.3.0.640.nupkg'
Invoke-WebRequest -Uri 'https://www.nuget.org/api/v2/package/intelopenmp.redist.win/2025.3.0.640' -OutFile $nupkg
$expectedNugetSha512 = 'L1NfgHUPbxtDZcMqPN0qlqvjjkdEA/W1xuwwppQb9llnr0cEqXGoFk2jV/ozDahM4CarMyxnK4jQghVadOwb8g=='
$actualNugetSha512 = [Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData([IO.File]::ReadAllBytes($nupkg)))
if ($actualNugetSha512 -cne $expectedNugetSha512) { throw "Intel NuGet package SHA-512 mismatch: $actualNugetSha512" }
Expand-Archive -LiteralPath $nupkg -DestinationPath $pkgDir -Force
$nugetSha256 = (Get-FileHash $nupkg -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "INTEL_NUGET source=https://www.nuget.org/packages/intelopenmp.redist.win/2025.3.0.640 version=2025.3.0.640 sha256=$nugetSha256 sha512=$actualNugetSha512"

$torchLib = Join-Path $venv 'Lib\site-packages\torch\lib'
$intelExpected = @{
  'libiomp5md.dll' = '982233366b0afcda1e0f55a0b134097e35b779613f54ddb69e685e6cd06b755f'
  'libiompstubs5md.dll' = '554014b3600c40fa515755edbb77662a196aa9460f3ecaeb1f2b84f946e3ad7e'
}
foreach ($dll in $intelExpected.Keys) {
  $source = Get-ChildItem $pkgDir -Recurse -File -Filter $dll | Where-Object { $_.FullName -match 'win-x64|x64' } | Select-Object -First 1
  if (-not $source) { throw "Official Intel package lacks x64 $dll" }
  $sig = Get-AuthenticodeSignature -LiteralPath $source.FullName
  if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Intel') { throw "Invalid Intel signature: $dll ($($sig.Status))" }
  $sourceHash = (Get-FileHash $source.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($sourceHash -ne $intelExpected[$dll]) { throw "Unexpected official Intel DLL hash: $dll $sourceHash" }
  $target = Join-Path $torchLib $dll
  $priorHash = (Get-FileHash $target -Algorithm SHA256).Hash.ToLowerInvariant()
  $expectedPrior = if ($dll -eq 'libiomp5md.dll') { 'd41a71c38f627a95748596820ab380135dcccc4ceecd6fe7d4e247d015bf55a4' } else { '137dd44f652a926eb540861994c58ea24ebfbf6b45886ac964a68c5742549c47' }
  if ($priorHash -ne $expectedPrior) { throw "Unexpected PyTorch original $dll hash: $priorHash" }
  Copy-Item -LiteralPath $target -Destination (Join-Path $originalDllDir $dll) -Force
  Copy-Item -LiteralPath $source.FullName -Destination $target -Force
  Write-Host "TORCH_OPENMP_ORIGINAL $dll sha256=$priorHash"
  Write-Host "INTEL_DLL $dll sha256=$sourceHash version=$((Get-Item $source.FullName).VersionInfo.FileVersion) signer=$($sig.SignerCertificate.Subject) package_path=$($source.FullName)"
  $envName = if ($dll -eq 'libiomp5md.dll') { 'U21BV_TORCH_ORIGINAL_IOMP5_SHA256' } else { 'U21BV_TORCH_ORIGINAL_IOMPSTUBS_SHA256' }
  [Environment]::SetEnvironmentVariable($envName, $priorHash, 'Process')
  $envName = if ($dll -eq 'libiomp5md.dll') { 'U21BV_INTEL_IOMP5_VERSION' } else { 'U21BV_INTEL_IOMPSTUBS_VERSION' }
  [Environment]::SetEnvironmentVariable($envName, (Get-Item $source.FullName).VersionInfo.FileVersion, 'Process')
  $envName = if ($dll -eq 'libiomp5md.dll') { 'U21BV_INTEL_IOMP5_SIGNER' } else { 'U21BV_INTEL_IOMPSTUBS_SIGNER' }
  [Environment]::SetEnvironmentVariable($envName, $sig.SignerCertificate.Subject, 'Process')
}

$privateCrt = Join-Path $torchLib 'MSVCP140.dll'
$crtHash = $null
$crtFileVersion = $null
if (Test-Path $privateCrt) {
  $crtHash = (Get-FileHash $privateCrt -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($crtHash -ne 'a4c2229bdc2a2a630acdc095b4d86008e5c3e3bc7773174354f3da4f5beb9cde') { throw "Unexpected Torch private CRT hash; refusing removal: $crtHash" }
  $crtFileVersion = (Get-Item $privateCrt).VersionInfo.FileVersion
  Write-Host "TORCH_PRIVATE_CRT state=REMOVED_FROM_TEMP_TEST_ENVIRONMENT sha256=$crtHash version=$crtFileVersion"
  Remove-Item -LiteralPath $privateCrt -Force
  if (Test-Path $privateCrt) { throw 'Torch private CRT still exists after removal' }
  $crtState = 'REMOVED_FROM_TEMP_TEST_ENVIRONMENT'
} else {
  Write-Host 'TORCH_PRIVATE_CRT state=ABSENT_IN_OFFICIAL_WHEEL path=torch/lib/MSVCP140.dll'
  $crtState = 'ABSENT_IN_OFFICIAL_WHEEL'
}

$systemCrt = Join-Path $env:WINDIR 'System32\msvcp140.dll'
if (-not (Test-Path $systemCrt)) { throw 'Microsoft x64 CRT is absent from System32; no substitute was attempted' }
$crtSignature = Get-AuthenticodeSignature -LiteralPath $systemCrt
if ($crtSignature.Status -ne 'Valid' -or $crtSignature.SignerCertificate.Subject -notmatch 'Microsoft') { throw 'System CRT signature is not valid Microsoft Authenticode' }
$crtVersion = (Get-Item $systemCrt).VersionInfo.FileVersion
if ([version]$crtVersion -lt [version]'14.40.0.0') { throw "System CRT below 14.40.0.0: $crtVersion" }
Write-Host "MICROSOFT_SYSTEM_CRT path=$systemCrt version=$crtVersion signer=$($crtSignature.SignerCertificate.Subject) signature=$($crtSignature.Status)"

& $python -m pip uninstall -y tokenizers
if ($LASTEXITCODE -ne 0) { throw 'Could not uninstall tokenizers from the temporary environment' }
$tokenizersSpec = & $python -c "import importlib.util; print(importlib.util.find_spec('tokenizers'))"
if ($LASTEXITCODE -ne 0 -or $tokenizersSpec.Trim() -ne 'None') { throw 'tokenizers remains importable after uninstall' }
Write-Host "TOKENIZERS state=UNINSTALLED version=0.15.2 original_wheel_sha256=$($tokenizersWheel.sha256)"

$reportPath = Join-Path $repoTemp 'runtime_probe_report.json'
$env:U21BV_REPORT_PATH = $reportPath
$env:U21BV_TORCH_WHEEL_SHA256 = $torchWheel.sha256
$env:U21BV_NUMPY_WHEEL_SHA256 = $numpyWheel.sha256
$env:U21BV_TRANSFORMERS_WHEEL_SHA256 = $transformersWheel.sha256
$env:U21BV_TOKENIZERS_WHEEL_SHA256 = $tokenizersWheel.sha256
$env:U21BV_KOKORO_WHEEL_SHA256 = $kokoroWheel.sha256
$env:U21BV_INTEL_NUPKG_SHA256 = $nugetSha256
$env:U21BV_INTEL_NUPKG_SHA512 = $actualNugetSha512
$env:U21BV_TORCH_CRT_STATE = $crtState
$env:U21BV_TORCH_CRT_ORIGINAL_SHA256 = $crtHash
$env:U21BV_TORCH_CRT_ORIGINAL_VERSION = $crtFileVersion
$env:U21BV_MICROSOFT_CRT_PREVALIDATED_PATH = $systemCrt
$env:U21BV_MICROSOFT_CRT_PREVALIDATED_VERSION = $crtVersion
$env:U21BV_FINAL_DLLS_VALIDATED = '0'
& $python (Join-Path $PSScriptRoot 'runtime_probe.py') $repoTemp $originalDllDir $torchLib $systemCrt
if ($LASTEXITCODE -ne 0) { throw "Runtime inference probe failed with exit code $LASTEXITCODE" }
if (-not (Test-Path $reportPath)) { throw 'Runtime probe did not write its evidence report' }
$report = Get-Content $reportPath -Raw | ConvertFrom-Json
$loadedCrt = @($report.loaded_runtime_paths | Where-Object { [IO.Path]::GetFileName($_).Equals('msvcp140.dll',[StringComparison]::OrdinalIgnoreCase) })
if ($loadedCrt.Count -ne 1) { throw "Expected exactly one loaded MSVCP140.dll, observed: $($loadedCrt -join '; ')" }
$loadedCrtSignature = Get-AuthenticodeSignature -LiteralPath $loadedCrt[0]
if ($loadedCrtSignature.Status -ne 'Valid' -or $loadedCrtSignature.SignerCertificate.Subject -notmatch 'Microsoft') { throw 'Actually loaded MSVCP140 is not Microsoft-signed' }
$loadedCrtVersion = (Get-Item $loadedCrt[0]).VersionInfo.FileVersion
if ([version]$loadedCrtVersion -lt [version]'14.40.0.0') { throw "Actually loaded CRT below 14.40: $loadedCrtVersion" }
Write-Host "ACTUAL_LOADED_MICROSOFT_CRT path=$($loadedCrt[0]) version=$loadedCrtVersion signature=$($loadedCrtSignature.Status)"
$env:U21BV_MICROSOFT_CRT_ACTUAL_PATH = $loadedCrt[0]
$env:U21BV_MICROSOFT_CRT_ACTUAL_VERSION = $loadedCrtVersion
$env:U21BV_MICROSOFT_CRT_ACTUAL_SIGNER = $loadedCrtSignature.SignerCertificate.Subject
$env:U21BV_MICROSOFT_CRT_ACTUAL_SHA256 = (Get-FileHash -LiteralPath $loadedCrt[0] -Algorithm SHA256).Hash.ToLowerInvariant()
$env:U21BV_FINAL_DLLS_VALIDATED = '1'
& $python (Join-Path $PSScriptRoot 'runtime_probe.py') --finalize
if ($LASTEXITCODE -ne 0) { throw 'Final DLL evidence validation failed' }
$finalReport = Get-Content $reportPath -Raw | ConvertFrom-Json
if ($finalReport.status -ne 'PASS') { throw 'Final report did not reach PASS after all checks' }
Write-Host 'U21BV_FINAL_STATUS=PASS'
