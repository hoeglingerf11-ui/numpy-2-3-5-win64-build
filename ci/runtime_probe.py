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

def download_assets(root: Path) -> dict[str, str]:
    hashes = {}
    for name, expected in FILES.items():
        path = root / 'model' / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists():
            request = urllib.request.Request(HF + name, headers={'User-Agent':'U21BV-runtime-probe/1.0'})
            with urllib.request.urlopen(request, timeout=120) as response, path.open('wb') as out:
                while chunk := response.read(1024 * 1024):
                    out.write(chunk)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if expected and digest != expected:
            raise RuntimeError(f'Public model asset hash mismatch: {name}')
        hashes[name] = digest
    return hashes

def loaded_modules() -> list[str]:
    psapi = ctypes.WinDLL('psapi', use_last_error=True)
    kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
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

def main() -> None:
    import sys
    root = Path(sys.argv[1])
    import torch
    import numpy as np
    assert torch.__version__.startswith('2.10.0'), torch.__version__
    assert importlib.util.find_spec('tokenizers') is None
    assert importlib.util.find_spec('misaki') is None
    assert 'tokenizers' not in sys.modules
    try:
        import transformers
        from transformers import AlbertConfig
    except Exception as exc:
        raise RuntimeError(f'Transformers/ALBERT import failed without tokenizers: {type(exc).__name__}: {exc}') from exc
    # Keep this runner's probe on Kokoro's language-blind model import path;
    # do not initialize the frontend package that imports Misaki.
    spec = importlib.util.find_spec('kokoro')
    if spec is None or spec.origin is None: raise RuntimeError('Kokoro package missing')
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
    assert 'tokenizers' not in sys.modules
    assert not any(x == 'misaki' or x.startswith('misaki.') for x in sys.modules)
    assert not any(x == 'spacy' or x.startswith('spacy.') for x in sys.modules)
    assets = download_assets(root)
    model = KModel(repo_id='hexgrad/Kokoro-82M', config=str(root/'model/config.json'), model=str(root/'model/kokoro-v1_0.pth')).to('cpu').eval()
    torch.set_num_threads(4)
    tensor = torch.arange(8192, dtype=torch.float32).reshape(64,128) / 8192
    values = []
    for _ in range(8):
        result = tensor @ tensor.T
        assert torch.isfinite(result).all()
        values.append(float(result.sum().item()))
    assert len(set(values)) == 1, values
    phonemes = 'hˈɛloʊ wˈɜɹld.'
    unsupported = sorted(set(phonemes) - set(model.vocab))
    if unsupported:
        raise RuntimeError(f'Probe phonemes are outside Kokoro vocabulary: {unsupported}')
    samples = {}
    with torch.inference_mode():
        for voice in ('af_sarah','am_echo','am_michael'):
            pack = torch.load(root/'model'/'voices'/f'{voice}.pt', map_location='cpu', weights_only=True)
            audio = model(phonemes, pack[len(phonemes)-1], 1.0)
            audio = audio.detach().cpu().float().numpy()
            if audio.ndim != 1 or not np.isfinite(audio).all() or not np.any(audio):
                raise RuntimeError(f'Invalid or silent output for {voice}')
            path = root / f'{voice}.wav'
            with wave.open(str(path), 'wb') as wav:
                wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(24000)
                pcm = np.clip(audio, -0.999, 0.999)
                wav.writeframes(np.rint(pcm*32767).astype('<i2').tobytes())
            samples[voice] = {'wav_temp':str(path),'seconds':round(len(audio)/24000,3),'peak':float(np.max(np.abs(audio)))}
    paths = loaded_modules()
    relevant = [p for p in paths if Path(p).name.lower() in {
        'libiomp5md.dll','libiompstubs5md.dll','msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll'}]
    print(json.dumps({
        'status':'PASS', 'python':sys.version, 'architecture':os.environ.get('PROCESSOR_ARCHITECTURE'),
        'torch':torch.__version__, 'transformers':transformers.__version__, 'tokenizers_installed':False,
        'kokoro':getattr(kokoro,'__version__','0.9.4'), 'numpy':np.__version__,
        'tokenizers_loaded':any(x=='tokenizers' or x.startswith('tokenizers.') for x in sys.modules),
        'misaki_loaded':any(x=='misaki' or x.startswith('misaki.') for x in sys.modules),
        'spacy_loaded':any(x=='spacy' or x.startswith('spacy.') for x in sys.modules),
        'torch_cpu_matmul_repeat_sum':values, 'tts':samples,'public_model_sha256':assets,
        'loaded_runtime_paths':relevant,
    }, indent=2))
    required = {'libiomp5md.dll','msvcp140.dll'}
    present = {Path(p).name.lower() for p in relevant}
    if not required.issubset(present):
        raise RuntimeError(f'Expected runtime DLLs not loaded: {sorted(required-present)}')
    if any('torch\\lib\\msvcp140.dll' in p.lower() for p in relevant):
        raise RuntimeError('Private Torch MSVCP140.dll was loaded')

if __name__ == '__main__':
    main()
