from __future__ import annotations
import ctypes
from ctypes import wintypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import urllib.request
import wave

HF = 'https://huggingface.co/hexgrad/Kokoro-82M/resolve/f3ff3571791e39611d31c381e3a41a3af07b4987/'
FILES = {
    'config.json': None,
    'kokoro-v1_0.pth': '496dba118d1a58f5f3db2efc88dbdc216e0483fc89fe6e47ee1f2c53f18ad1e4',
    'voices/af_sarah.pt': '49bd364ea3be9eb3e9685e8f9a15448c4883112a7c0ff7ab139fa4088b08cef9',
    'voices/am_echo.pt': '8bcfdc852bc985fb45c396c561e571ffb9183930071f962f1b50df5c97b161e8',
    'voices/am_michael.pt': '9a443b79a4b22489a5b0ab7c651a0bcd1a30bef675c28333f06971abbd47bd37',
}
EXPECTED_INTEL = {
    'libiomp5md.dll': '982233366b0afcda1e0f55a0b134097e35b779613f54ddb69e685e6cd06b755f',
    'libiompstubs5md.dll': '554014b3600c40fa515755edbb77662a196aa9460f3ecaeb1f2b84f946e3ad7e',
}

def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()

def download_assets(root: Path) -> dict[str, str]:
    hashes = {}
    for name, expected in FILES.items():
        path = root / 'model' / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists():
            request = urllib.request.Request(HF + name, headers={'User-Agent':'U21BV-runtime-probe/1.1'})
            with urllib.request.urlopen(request, timeout=180) as response, path.open('wb') as out:
                while chunk := response.read(1024 * 1024):
                    out.write(chunk)
        digest = sha256(path)
        if expected and digest != expected:
            raise RuntimeError(f'Pinned public model asset SHA-256 mismatch: {name}')
        hashes[name] = digest
    return hashes

def loaded_modules() -> list[str]:
    psapi = ctypes.WinDLL('psapi', use_last_error=True)
    kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel32.GetCurrentProcess.restype = wintypes.HANDLE
    psapi.EnumProcessModules.argtypes = (wintypes.HANDLE, ctypes.POINTER(wintypes.HMODULE), wintypes.DWORD, ctypes.POINTER(wintypes.DWORD))
    psapi.EnumProcessModules.restype = wintypes.BOOL
    psapi.GetModuleFileNameExW.argtypes = (wintypes.HANDLE, wintypes.HMODULE, wintypes.LPWSTR, wintypes.DWORD)
    psapi.GetModuleFileNameExW.restype = wintypes.DWORD
    process = kernel32.GetCurrentProcess()
    modules = (wintypes.HMODULE * 4096)()
    needed = wintypes.DWORD()
    if not psapi.EnumProcessModules(process, modules, ctypes.sizeof(modules), ctypes.byref(needed)):
        raise ctypes.WinError(ctypes.get_last_error())
    count = min(needed.value // ctypes.sizeof(wintypes.HMODULE), len(modules))
    paths = []
    for module in modules[:count]:
        buf = ctypes.create_unicode_buffer(32768)
        if psapi.GetModuleFileNameExW(process, module, buf, len(buf)):
            paths.append(buf.value)
    return paths

def exports(path: Path) -> tuple[set[str], set[int]]:
    import pefile
    pe = pefile.PE(str(path), fast_load=True)
    pe.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_EXPORT']])
    if not hasattr(pe, 'DIRECTORY_ENTRY_EXPORT'):
        return set(), set()
    names = {symbol.name.decode('ascii', errors='replace') for symbol in pe.DIRECTORY_ENTRY_EXPORT.symbols if symbol.name}
    ordinals = {int(symbol.ordinal) for symbol in pe.DIRECTORY_ENTRY_EXPORT.symbols}
    return names, ordinals

def check_openmp_import_abi(torch_root: Path, baseline_dir: Path, current_lib: Path) -> dict:
    import pefile
    data = {}
    for name in EXPECTED_INTEL:
        baseline_names, _ = exports(baseline_dir / name)
        current_names, current_ordinals = exports(current_lib / name)
        diff = {
            'baseline_export_count': len(baseline_names),
            'candidate_export_count': len(current_names),
            'candidate_only_exports': sorted(current_names - baseline_names),
            'baseline_only_exports': sorted(baseline_names - current_names),
        }
        missing = []
        scanned = 0
        for path in torch_root.rglob('*'):
            if path.suffix.lower() not in {'.dll', '.pyd'}:
                continue
            try:
                pe = pefile.PE(str(path), fast_load=True)
                pe.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_IMPORT']])
            except pefile.PEFormatError:
                continue
            scanned += 1
            for descriptor in getattr(pe, 'DIRECTORY_ENTRY_IMPORT', []):
                if descriptor.dll.decode('ascii', errors='ignore').lower() != name.lower():
                    continue
                for item in descriptor.imports:
                    if item.name:
                        imported = item.name.decode('ascii', errors='replace')
                        if imported not in current_names:
                            missing.append({'binary':str(path.relative_to(torch_root)), 'name':imported})
                    elif item.ordinal not in current_ordinals:
                        missing.append({'binary':str(path.relative_to(torch_root)), 'ordinal':int(item.ordinal)})
        diff['torch_pe_binaries_scanned'] = scanned
        diff['static_imports_missing_from_candidate'] = missing
        if missing:
            raise RuntimeError(f'{name} candidate is missing symbols statically imported by PyTorch: {missing[:20]}')
        data[name] = diff
    return data

def main() -> None:
    import sys
    if len(sys.argv) == 2 and sys.argv[1] == '--finalize':
        report_path = Path(os.environ['U21BV_REPORT_PATH'])
        payload = json.loads(report_path.read_text(encoding='utf-8'))
        if os.environ.get('U21BV_FINAL_DLLS_VALIDATED') != '1':
            raise RuntimeError('Final DLL/signature validation was not confirmed by the PowerShell wrapper')
        payload['microsoft_crt_actual'] = {
            'path': os.environ.get('U21BV_MICROSOFT_CRT_ACTUAL_PATH'),
            'version': os.environ.get('U21BV_MICROSOFT_CRT_ACTUAL_VERSION'),
            'authenticode_signer': os.environ.get('U21BV_MICROSOFT_CRT_ACTUAL_SIGNER'),
            'sha256': os.environ.get('U21BV_MICROSOFT_CRT_ACTUAL_SHA256'),
            'status': 'Valid; verified after runtime module enumeration',
        }
        payload['checks']['torch_without_private_msvcp140']['status'] = 'PASS'
        payload['checks']['intel_openmp_replacement']['status'] = 'PASS'
        payload['checks']['kokoro_albert_without_tokenizers']['status'] = 'PASS'
        payload['status'] = 'PASS'
        payload['final_dll_signatures_and_paths'] = 'PASS'
        report_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding='utf-8')
        print(json.dumps(payload, indent=2, sort_keys=True))
        return

    if len(sys.argv) != 5:
        raise SystemExit('usage: runtime_probe.py <work> <original-dll-dir> <torch-lib-dir> <system-crt-path>')
    root, original_dir, torch_lib, system_crt = map(Path, sys.argv[1:])
    import torch
    import numpy as np
    if not torch.__version__.startswith('2.10.0'):
        raise RuntimeError(f'Unexpected PyTorch version {torch.__version__}')
    if np.__version__ != '2.3.5':
        raise RuntimeError(f'Unexpected standard NumPy test version {np.__version__}')
    if importlib.util.find_spec('tokenizers') is not None or 'tokenizers' in sys.modules:
        raise RuntimeError('tokenizers is still installed/importable before model initialization')
    if importlib.util.find_spec('misaki') is not None:
        raise RuntimeError('Misaki is unexpectedly installed on the test path')
    try:
        import transformers
        from transformers import AlbertConfig, AlbertModel
    except Exception as exc:
        raise RuntimeError(f'Transformers ALBERT import failed without tokenizers: {type(exc).__name__}: {exc}') from exc
    if importlib.util.find_spec('tokenizers') is not None or 'tokenizers' in sys.modules:
        raise RuntimeError('Transformers imported tokenizers despite its absence')

    # Patch only the ephemeral public Kokoro wheel so the test follows its KModel/ALBERT path
    # without importing the KPipeline frontend, which initializes Misaki.
    spec = importlib.util.find_spec('kokoro')
    if spec is None or spec.origin is None:
        raise RuntimeError('Kokoro package missing')
    package = Path(spec.origin).parent
    (package / '__init__.py').write_text(
        "from .model import KModel\n"
        "def __getattr__(name):\n"
        "    if name == 'KPipeline':\n"
        "        from .pipeline import KPipeline\n"
        "        globals()[name] = KPipeline\n"
        "        return KPipeline\n"
        "    raise AttributeError(name)\n", encoding='utf-8')
    import kokoro
    from kokoro import KModel
    if any(name == 'misaki' or name.startswith('misaki.') for name in sys.modules):
        raise RuntimeError('Kokoro US KModel path imported Misaki')
    if any(name == 'spacy' or name.startswith('spacy.') for name in sys.modules):
        raise RuntimeError('Kokoro US KModel path imported spaCy')
    assets = download_assets(root)
    model = KModel(repo_id='hexgrad/Kokoro-82M', config=str(root/'model/config.json'), model=str(root/'model/kokoro-v1_0.pth')).to('cpu').eval()
    if model.device.type != 'cpu' or any(param.device.type != 'cpu' for param in model.parameters()):
        raise RuntimeError('Kokoro model did not remain on CPU')

    import os as _os
    torch_root = Path(torch.__file__).parent
    abi_report = check_openmp_import_abi(torch_root, original_dir, torch_lib)
    for name, expected in EXPECTED_INTEL.items():
        installed = torch_lib / name
        if sha256(installed) != expected:
            raise RuntimeError(f'Intel runtime file changed after staging: {name}')
        if not (original_dir / name).is_file():
            raise RuntimeError(f'Original Torch runtime copy was not preserved in temporary evidence: {name}')
    if (torch_lib / 'MSVCP140.dll').exists():
        raise RuntimeError('Private Torch MSVCP140.dll still exists in the temporary test environment')

    torch.set_num_threads(4)
    tensor = torch.arange(8192, dtype=torch.float32).reshape(64, 128) / 8192
    def cpu_job() -> float:
        result = tensor @ tensor.T
        solved = torch.linalg.solve(torch.eye(8), torch.arange(8, dtype=torch.float32).reshape(8, 1))
        if not torch.isfinite(result).all() or not torch.isfinite(solved).all():
            raise RuntimeError('Non-finite result in PyTorch CPU operation')
        return float(result.sum().item() + solved.sum().item())
    cpu_values = [cpu_job() for _ in range(8)]
    if len(set(cpu_values)) != 1:
        raise RuntimeError(f'Repeated CPU computations were unstable: {cpu_values}')
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=4) as pool:
        concurrent_values = list(pool.map(lambda _: cpu_job(), range(8)))
    if any(value != cpu_values[0] for value in concurrent_values):
        raise RuntimeError(f'Concurrent CPU computations were unstable: {concurrent_values}')

    phonemes = 'hˈɛloʊ wˈɜɹld.'
    unsupported = sorted(set(phonemes) - set(model.vocab))
    if unsupported:
        raise RuntimeError(f'Probe phonemes are outside Kokoro model vocabulary: {unsupported}')
    samples = {}
    with torch.inference_mode():
        for voice in ('af_sarah', 'am_echo', 'am_michael'):
            voice_path = root / 'model' / 'voices' / f'{voice}.pt'
            pack = torch.load(voice_path, map_location='cpu', weights_only=True)
            audio = model(phonemes, pack[len(phonemes) - 1], 1.0)
            audio = audio.detach().cpu().float().numpy()
            if audio.ndim != 1 or not np.isfinite(audio).all() or not np.any(audio):
                raise RuntimeError(f'Kokoro returned invalid/silent TTS audio for {voice}')
            wav_path = root / f'{voice}.wav'
            pcm = np.rint(np.clip(audio, -0.999, 0.999) * 32767).astype('<i2')
            with wave.open(str(wav_path), 'wb') as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(24000)
                wav.writeframes(pcm.tobytes())
            samples[voice] = {
                'temporary_wav': str(wav_path), 'sample_rate': 24000, 'channels': 1,
                'samples': int(audio.size), 'duration_seconds': round(audio.size / 24000, 3),
                'peak': float(np.max(np.abs(audio))), 'sha256': sha256(wav_path),
            }

    paths = loaded_modules()
    relevant = sorted({str(Path(p).resolve()) for p in paths if Path(p).name.lower() in {
        'libiomp5md.dll', 'libiompstubs5md.dll', 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll'}})
    path_by_name = {Path(p).name.lower(): p for p in relevant}
    expected_iomp_path = {name.lower(): str((torch_lib / name).resolve()) for name in EXPECTED_INTEL}
    for name, expected_path in expected_iomp_path.items():
        if not Path(expected_path).is_file() or sha256(Path(expected_path)) != EXPECTED_INTEL[Path(name).name]:
            raise RuntimeError(f'Staged Intel OpenMP replacement missing or changed: {expected_path}')
        if name == 'libiomp5md.dll' and name not in path_by_name:
            raise RuntimeError('Primary OpenMP runtime libiomp5md.dll was not loaded')
        if name in path_by_name:
            if Path(path_by_name[name]).resolve() != Path(expected_path).resolve():
                raise RuntimeError(f'Unexpected loaded OpenMP DLL path for {name}: {path_by_name[name]}')
            if sha256(Path(path_by_name[name])) != EXPECTED_INTEL[Path(name).name]:
                raise RuntimeError(f'Loaded OpenMP replacement hash mismatch for {name}')
    if 'msvcp140.dll' not in path_by_name:
        raise RuntimeError('No MSVCP140.dll was observed in the process module list')
    if str(torch_lib / 'MSVCP140.dll').lower() in {p.lower() for p in paths}:
        raise RuntimeError('Private Torch MSVCP140.dll appeared in the loaded module list')
    if any(name == 'tokenizers' or name.startswith('tokenizers.') for name in sys.modules):
        raise RuntimeError('tokenizers was imported during the US KModel/TTS test')
    if any(name == 'misaki' or name.startswith('misaki.') for name in sys.modules):
        raise RuntimeError('Misaki was imported during the US KModel/TTS test')
    if any(name == 'spacy' or name.startswith('spacy.') for name in sys.modules):
        raise RuntimeError('spaCy was imported during the US KModel/TTS test')

    report = {
        'status': 'RUNTIME_CHECKS_COMPLETE_PENDING_FINAL_AUTHENTICODE',
        'python': sys.version,
        'architecture': _os.environ.get('PROCESSOR_ARCHITECTURE'),
        'torch': {'version': torch.__version__, 'wheel_sha256': _os.environ.get('U21BV_TORCH_WHEEL_SHA256'), 'origin': 'official download.pytorch.org CPU index'},
        'numpy': {'version': np.__version__, 'wheel_sha256': _os.environ.get('U21BV_NUMPY_WHEEL_SHA256'), 'origin': 'standard public PyPI wheel; not ShyCreator Eigenbuild'},
        'transformers': {'version':transformers.__version__, 'wheel_sha256':_os.environ.get('U21BV_TRANSFORMERS_WHEEL_SHA256'), 'origin':'PyPI'},
        'tokenizers': {'version_before_uninstall': '0.15.2', 'wheel_sha256':_os.environ.get('U21BV_TOKENIZERS_WHEEL_SHA256'), 'origin':'PyPI', 'installed_for_test':False, 'imported':False},
        'kokoro': {'version':'0.9.4', 'wheel_sha256':_os.environ.get('U21BV_KOKORO_WHEEL_SHA256'), 'origin':'PyPI'},
        'model_repo': 'hexgrad/Kokoro-82M',
        'model_revision': 'f3ff3571791e39611d31c381e3a41a3af07b4987',
        'model_asset_sha256': assets,
        'intel_redist': {
            'package':'intelopenmp.redist.win', 'version':'2025.3.0.640',
            'source':'https://www.nuget.org/packages/intelopenmp.redist.win/2025.3.0.640',
            'nupkg_sha256':_os.environ.get('U21BV_INTEL_NUPKG_SHA256'),
            'nupkg_sha512':_os.environ.get('U21BV_INTEL_NUPKG_SHA512'),
            'dlls':{
                'libiomp5md.dll':{'sha256':EXPECTED_INTEL['libiomp5md.dll'], 'version':_os.environ.get('U21BV_INTEL_IOMP5_VERSION'), 'authenticode_signer':_os.environ.get('U21BV_INTEL_IOMP5_SIGNER'), 'torch_original_sha256':_os.environ.get('U21BV_TORCH_ORIGINAL_IOMP5_SHA256')},
                'libiompstubs5md.dll':{'sha256':EXPECTED_INTEL['libiompstubs5md.dll'], 'version':_os.environ.get('U21BV_INTEL_IOMPSTUBS_VERSION'), 'authenticode_signer':_os.environ.get('U21BV_INTEL_IOMPSTUBS_SIGNER'), 'torch_original_sha256':_os.environ.get('U21BV_TORCH_ORIGINAL_IOMPSTUBS_SHA256')},
            },
        },
        'torch_private_msvcp140': {
            'state':_os.environ.get('U21BV_TORCH_CRT_STATE'),
            'original_sha256':_os.environ.get('U21BV_TORCH_CRT_ORIGINAL_SHA256'),
            'original_version':_os.environ.get('U21BV_TORCH_CRT_ORIGINAL_VERSION'),
        },
        'microsoft_crt_prevalidated_system_copy': {'path':str(system_crt), 'version':_os.environ.get('U21BV_MICROSOFT_CRT_PREVALIDATED_VERSION'), 'authenticode':'Valid; Microsoft signer verified before runtime test'},
        'checks': {
            'torch_without_private_msvcp140': {'status':'PENDING_FINAL_DLL_VALIDATION', 'wheel_state':_os.environ.get('U21BV_TORCH_CRT_STATE'), 'actual_crt_path':path_by_name['msvcp140.dll']},
            'intel_openmp_replacement': {'status':'PENDING_FINAL_DLL_VALIDATION', 'dlls':{name:{'staged_path':str(torch_lib / name), 'sha256':EXPECTED_INTEL[name], 'loaded_path':path_by_name.get(name.lower())} for name in EXPECTED_INTEL}, 'abi_export_differences_reported':abi_report},
            'kokoro_albert_without_tokenizers': {'status':'PENDING_FINAL_DLL_VALIDATION', 'voices':sorted(samples), 'tokenizers_imported':False, 'misaki_imported':False, 'spacy_imported':False},
        },
        'cpu': {'threads':torch.get_num_threads(), 'repeated_solve_matmul_sums':cpu_values, 'parallel_repeated_sums':concurrent_values},
        'openmp_abi': abi_report,
        'tts': samples,
        'tokenizers_loaded': False, 'misaki_loaded': False, 'spacy_loaded': False,
        'loaded_runtime_paths': relevant,
    }
    report_path = Path(_os.environ['U21BV_REPORT_PATH'])
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True), encoding='utf-8')
    print(json.dumps(report, indent=2, sort_keys=True))

if __name__ == '__main__':
    main()
