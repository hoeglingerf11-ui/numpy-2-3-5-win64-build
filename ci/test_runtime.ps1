$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$work = Join-Path $env:RUNNER_TEMP 'u21bv'
$venv = Join-Path $work 'venv'
$pkgDir = Join-Path $work 'intel-nupkg'
New-Item -ItemType Directory -Force -Path $work,$pkgDir | Out-Null
py -3.12 -m venv $venv
$python = Join-Path $venv 'Scripts\python.exe'
& $python -m pip install --disable-pip-version-check --index-url https://download.pytorch.org/whl/cpu torch==2.10.0+cpu
if ($LASTEXITCODE -ne 0) { throw 'PyTorch CPU wheel install failed' }
& $python -m pip install --disable-pip-version-check numpy==2.3.5 transformers==4.39.2 tokenizers==0.15.2 huggingface-hub==0.26.2 loguru==0.7.3 attrs==25.3.0
if ($LASTEXITCODE -ne 0) { throw 'Python dependency install failed' }
& $python -m pip install --disable-pip-version-check kokoro==0.9.4 --no-deps
if ($LASTEXITCODE -ne 0) { throw 'Kokoro install failed' }
$nupkg = Join-Path $work 'intelopenmp.redist.win.2025.3.0.640.nupkg'
Invoke-WebRequest -Uri 'https://www.nuget.org/api/v2/package/intelopenmp.redist.win/2025.3.0.640' -OutFile $nupkg
$expected = 'L1NfgHUPbxtDZcMqPN0qlqvjjkdEA/W1xuwwppQb9llnr0cEqXGoFk2jV/ozDahM4CarMyxnK4jQghVadOwb8g=='
$actual = [Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData([IO.File]::ReadAllBytes($nupkg)))
if ($actual -cne $expected) { throw "Intel NuGet SHA-512 mismatch: $actual" }
Expand-Archive -LiteralPath $nupkg -DestinationPath $pkgDir -Force
$torchLib = Join-Path $venv 'Lib\site-packages\torch\lib'
foreach ($dll in @('libiomp5md.dll','libiompstubs5md.dll')) {
  $source = Get-ChildItem $pkgDir -Recurse -File -Filter $dll | Where-Object { $_.FullName -match 'win-x64|x64' } | Select-Object -First 1
  if (-not $source) { throw "Official Intel package lacks x64 $dll" }
  $sig = Get-AuthenticodeSignature -LiteralPath $source.FullName
  if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Intel') { throw "Invalid Intel signature: $dll ($($sig.Status))" }
  $target = Join-Path $torchLib $dll
  $priorHash = (Get-FileHash $target -Algorithm SHA256).Hash.ToLowerInvariant()
  $expectedPrior = if ($dll -eq 'libiomp5md.dll') { 'd41a71c38f627a95748596820ab380135dcccc4ceecd6fe7d4e247d015bf55a4' } else { '137dd44f652a926eb540861994c58ea24ebfbf6b45886ac964a68c5742549c47' }
  if ($priorHash -ne $expectedPrior) { throw "Unexpected PyTorch $dll hash before test: $priorHash" }
  Write-Host "TORCH_OPENMP_ORIGINAL $dll sha256=$priorHash"
  Copy-Item -LiteralPath $source.FullName -Destination $target -Force
  Write-Host "INTEL_DLL $dll sha256=$((Get-FileHash $target -Algorithm SHA256).Hash) version=$((Get-Item $target).VersionInfo.FileVersion) signer=$($sig.SignerCertificate.Subject)"
}
$privateCrt = Join-Path $torchLib 'MSVCP140.dll'
if (-not (Test-Path $privateCrt)) { throw 'Expected Torch private MSVCP140.dll not found before test' }
$crtHash = (Get-FileHash $privateCrt -Algorithm SHA256).Hash.ToLowerInvariant()
if ($crtHash -ne 'a4c2229bdc2a2a630acdc095b4d86008e5c3e3bc7773174354f3da4f5beb9cde') { throw "Unexpected Torch private CRT hash: $crtHash" }
Write-Host "TORCH_PRIVATE_CRT_ORIGINAL sha256=$crtHash version=$((Get-Item $privateCrt).VersionInfo.FileVersion)"
Remove-Item -LiteralPath $privateCrt -Force
if (Test-Path $privateCrt) { throw 'Torch private CRT still exists' }
$systemCrt = Join-Path $env:WINDIR 'System32\msvcp140.dll'
if (-not (Test-Path $systemCrt)) { throw 'Microsoft x64 runtime is not present in System32; no runtime substitution attempted' }
$crtSig = Get-AuthenticodeSignature -LiteralPath $systemCrt
if ($crtSig.Status -ne 'Valid' -or $crtSig.SignerCertificate.Subject -notmatch 'Microsoft') { throw 'System CRT is not signed by Microsoft' }
$systemVersion = (Get-Item $systemCrt).VersionInfo.FileVersion
if ([version]$systemVersion -lt [version]'14.40.0.0') { throw "System CRT below PyTorch private baseline 14.40: $systemVersion" }
Write-Host "SYSTEM_CRT path=$systemCrt version=$systemVersion signer=$($crtSig.SignerCertificate.Subject)"
& $python -m pip uninstall -y tokenizers
if ($LASTEXITCODE -ne 0) { throw 'Could not remove tokenizers from probe environment' }
& $python (Join-Path $PSScriptRoot 'runtime_probe.py') $work
if ($LASTEXITCODE -ne 0) { throw "Runtime probe failed with exit code $LASTEXITCODE" }
