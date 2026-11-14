"""Convert the verified Fish BF16 language/audio decoders to 8-bit locally.

The waveform codec stays at its original precision. Uses the pinned MLX-Audio
converter primitives directly: generic model discovery imports unrelated models
which attempt to download their codecs even when converting Fish.
"""
import os
os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1")
import hashlib
import json
from pathlib import Path
import shutil
import mlx.core as mx
from mlx_audio.tts.models.fish_qwen3_omni import Model, ModelConfig
from mlx_audio.lm.convert import quantize_model, save_model, save_config
from mlx_audio.convert import build_quant_predicate

root = Path(__file__).resolve().parents[1]
source = root / "models/fish-s2-pro-bf16"
output = root / "models/fish-s2-pro-8bit"
config = json.loads((source / "config.json").read_text())
index = json.loads((source / "model.safetensors.index.json").read_text())
weights = {}
for name in sorted(set(index["weight_map"].values())):
    assert Path(name).name == name and name.endswith(".safetensors")
    weights.update(mx.load(source / name))
model = Model(ModelConfig.from_dict(config))
model.load_weights(list(model.sanitize(weights).items()), strict=True)
del weights
_, config = quantize_model(model, config, 64, 8, mode="affine", quant_predicate=build_quant_predicate(model))
output.mkdir(parents=True, exist_ok=True)
save_model(output, model, donate_model=True)
config["model_type"] = "fish_qwen3_omni"
save_config(config, config_path=output / "config.json")
for name in ("codec.safetensors", "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json",
             "chat_template.jinja", "LICENSE.md", "README.md"):
    shutil.copy2(source / name, output / name)
def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(8 * 1024 * 1024), b""): digest.update(chunk)
    return digest.hexdigest()
manifest = dict(source="mlx-community/fish-audio-s2-pro-bf16",
    revision="eccd57bf5c1ebc13cb2f993df867f4e49931a36a", mlx_audio="0.5.1",
    quantization="8-bit affine, group size 64; codec unchanged",
    files={path.name: sha(path) for path in sorted(output.iterdir()) if path.is_file() and path.name != "manifest.json"})
(output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print("Prepared local Fish 8-bit tensors and integrity manifest.")
