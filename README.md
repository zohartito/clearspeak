# ClearSpeak

A native macOS menu bar app that reads highlighted or pasted text aloud using open text-to-speech models that run entirely on your Mac. No cloud service, API key, account or usage fee. The speech worker runs in a macOS sandbox that denies it network access.

Highlight text in almost any app, press **Control–Option–R**, and ClearSpeak reads it. Paste & Read covers apps that do not expose their selection.

## Requirements

- A Mac with Apple Silicon (M1 or later). The MLX runtime does not support Intel Macs.
- macOS 14 or later.
- Xcode Command Line Tools (`xcode-select --install`), with Swift 5.9 or later. Full Xcode is not needed.
- [uv](https://docs.astral.sh/uv/) for the isolated Python 3.12 environment. Setup downloads Python if it is missing and does not touch other projects.
- Disk and memory, depending on which voices you install:

| Pack | Download / disk | Peak model memory (measured) |
| --- | --- | --- |
| Base (Qwen3-TTS) | ~4.2 GB | ~5.5 GB |
| Narrator pack (Kokoro, VoxCPM2, Voxtral) | ~8 GB | 2–8 GB per voice |
| Fish S2 Pro | ~10 GB download, ~16 GB kept on disk | ~13–14 GB |

Memory figures come from one 64 GB M4 Max and exclude app and Python overhead. 16 GB of RAM should be enough for the base and Kokoro voices. Fish and VoxCPM need more headroom. Smaller Macs are untested.

## Build and run

Get the source, then from the repository root:

```sh
./scripts/setup-local.sh   # Python env + base Qwen3-TTS model (~4.2 GB), pinned and verified
./scripts/test.sh          # Offline checks; no models or XCTest needed
./scripts/build.sh         # Builds and ad-hoc signs dist/ClearSpeak.app
open dist/ClearSpeak.app
```

Optional voices (quit ClearSpeak first, then rebuild and reopen):

```sh
./scripts/setup-narrators.sh all   # or: kokoro | voxcpm | voxtral
./scripts/setup-quality.sh fish    # Fish S2 Pro (downloads BF16, converts to 8-bit locally)
./scripts/build.sh
open dist/ClearSpeak.app
```

The app does not bundle the Python runtime or models. `build.sh` writes the absolute paths of this repository's `.venv`, `engine/worker.py` and `models/` into the app, so keep the repository where it is. If you move it, run `build.sh` again. The `.app` itself can live anywhere. Keep the checkout at a reasonably short path (for example `~/src/clearspeak`). With a very deep path (~170 characters to `site-packages`), espeak-ng could not find its data and the Kokoro voices failed.

To read highlighted text, enable ClearSpeak in **System Settings → Privacy & Security → Accessibility** (the Settings window has a button for this). Paste & Read works without that permission. The build is ad-hoc signed, so each rebuild may need the Accessibility entry removed and re-added.

## Voices

Settings always lists the four base Qwen voices (Ryan, Aiden, Vivian and Serena), and keeps the selected voice visible even if its files are missing. Other optional voices appear only when fully installed. The status line shows whether the selected model is installed or needs setup; unavailable voices need setup before they can read.

Models are downloaded from Hugging Face at pinned revisions by the setup scripts. Each download is checked against `hf cache verify` or the sizes and digests in `engine/narrator-models.json`. **No model weights, voice embeddings or reference audio are included in this repository.** After setup, reading works offline.

| Voice(s) in the app | Model and source | Licence |
| --- | --- | --- |
| Ryan, Aiden, Vivian, Serena (default: Ryan) | Qwen3-TTS 12Hz 1.7B CustomVoice, BF16. [Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice), MLX port [mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16) | Apache-2.0 |
| Heart, Bella, Michael, Emma (Kokoro) | Kokoro 82M, BF16. [hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M), MLX port [mlx-community/Kokoro-82M-bf16](https://huggingface.co/mlx-community/Kokoro-82M-bf16) | Apache-2.0 |
| Warm Male, Warm Female (VoxCPM) | VoxCPM2, BF16. [openbmb/VoxCPM2](https://huggingface.co/openbmb/VoxCPM2), MLX port [mlx-community/VoxCPM2-bf16](https://huggingface.co/mlx-community/VoxCPM2-bf16). Setup *designs* two original voices from text descriptions ("an adult man/woman … warm, relaxed, conversational voice"); no recording of a real person is used. | Apache-2.0 |
| Casual Male, Casual Female (Voxtral) | Voxtral 4B TTS 2603, 4-bit. [mistralai/Voxtral-4B-TTS-2603](https://huggingface.co/mistralai/Voxtral-4B-TTS-2603), MLX port [mlx-community/Voxtral-4B-TTS-2603-mlx-4bit](https://huggingface.co/mlx-community/Voxtral-4B-TTS-2603-mlx-4bit) | CC BY-NC 4.0 (non-commercial) |
| Fish; Warm Male, Warm Female (Fish) | Fish Audio S2 Pro, converted locally to 8-bit. [fishaudio/s2-pro](https://huggingface.co/fishaudio/s2-pro), MLX port [mlx-community/fish-audio-s2-pro-bf16](https://huggingface.co/mlx-community/fish-audio-s2-pro-bf16). Fish speaks in the voice of a short reference clip; ClearSpeak only uses synthetic references it generates itself (Qwen "Ryan" for *Fish*, the VoxCPM designed voices for *Warm … (Fish)*). | [Fish Audio Research License](https://huggingface.co/fishaudio/s2-pro/blob/main/LICENSE.md): research and non-commercial use only |
| Not in the app: audition only | Breeze TTS 2, BF16 ([BreezeBlue/Breeze-TTS-2](https://huggingface.co/BreezeBlue/Breeze-TTS-2)). `setup-quality.sh breeze` downloads it for `scripts/audition-local.py` comparisons. | BreezeBlue Research and Non-Commercial License |

Licences were read from each model card on Hugging Face on 2026-11-14. Read the upstream terms yourself before any use beyond personal reading. In particular:

- **Voxtral** presets are derived from CC BY-NC 4.0 speech datasets (per Mistral's model card). Its voices and anything you make with them are non-commercial.
- **Fish S2 Pro** is not open source. Commercial use needs a separate licence from Fish Audio, and use must follow Fish Audio's Acceptable Use Policy. If you redistribute Fish materials or a product that uses them, the licence requires you to include a copy of it, a NOTICE file with Fish Audio's attribution, and a visible "Built with Fish Audio" credit. This app is built with Fish Audio for its Fish voices.
- **Kokoro** setup also installs `espeakng-loader`, which ships espeak-ng (GPL-3.0), as a Python dependency. It is installed on your machine and is not part of this repository.

ClearSpeak does not include any voice that imitates a real, identifiable person, and it has no feature for cloning a voice from user audio.

## Using it

| Action | Shortcut |
| --- | --- |
| Read selection | Control–Option–R |
| Pause / resume | Control–Option–Shift–R |
| Stop | Control–Option–Escape |
| Read in Paste & Read | Command–Return |

- Settings → **Read shortcut** offers R, T or L. Pause adds Shift to whichever you pick. If a key is already taken, ClearSpeak says which action failed and keeps the previous shortcuts.
- **Test Shortcut** checks that a key press reaches ClearSpeak without reading anything.
- Some apps don't expose their selection to Accessibility. For those, opt in to the **Cmd+C fallback** in Settings (off by default) or use Paste & Read.
- The waveform menu has playback speeds from 0.75× to 2×, and **Unload Model** frees the model's memory. The model stays loaded between readings until you stop, unload or quit.
- **Launch at login** in Settings uses macOS's native login item (`SMAppService`). Turning it off in System Settings is respected.

## Privacy

- The Swift app has no network synthesis code, cloud provider or API-key field. Text goes to a private child process over stdin, and PCM audio comes back over stdout. There is no local server or open port.
- The worker loads only local files, runs with Hugging Face/Transformers offline mode and telemetry off, and is launched under `sandbox-exec` with network access denied. Third-party diagnostics are discarded. Error messages never include the selected text.
- Text and audio stay in memory. There is no reading history or audio cache. Only the explicit benchmark and audition scripts write fixed sample text to WAV files under the ignored `dist/` folder.
- Selection capture uses Accessibility and refuses known password fields. No screenshots, OCR, microphone or browser extension. The clipboard fallback waits for a fresh copy, never reuses stale clipboard data, and restores your previous clipboard only if nothing newer arrived. Clipboard managers may still record the temporary copy.

## Architecture

- AppKit menu bar UI, Carbon global shortcuts and Accessibility selection capture (`Sources/ClearSpeak`, `Sources/ClearSpeakCore`).
- One voice catalog, `Sources/ClearSpeakCore/Resources/voices.json`, drives Swift settings, install checks and Python dispatch.
- A Python worker (`engine/worker.py`) runs MLX-Audio 0.5.1. Voxtral has its own interpreter in `.local-runtime/voxtral/` because its tokenizer needs a different NumPy.
- Text is split at sentence boundaries, with soft targets of 160–600 bytes per engine, a hard 600-byte chunk limit and at most 50 KB per reading. Wording and internal whitespace are preserved; leading and trailing whitespace is trimmed.
- Playback goes through AVAudioEngine with pitch-preserving rate control. It builds about four seconds of audio before starting and rebuilds that reserve if generation falls behind.

## Testing

- `./scripts/test.sh` runs the offline native checks (`swift run ClearSpeakChecks`) and the Python asset-manifest checks. It needs no models.
- Real synthesis checks need installed models. Each runs fixed harmless text with networking denied:
  - `.venv/bin/python scripts/check-local.py` checks Qwen.
  - `--voice Fish` checks Fish.
  - `scripts/check-narrators.py` checks the narrator pack.
  - `swift run ClearSpeakChecks --live-narrators` and `--live-continuity` play audio through AVAudioEngine.

See [VALIDATION.md](VALIDATION.md) for measured results.

## Limits

- macOS on Apple Silicon only. Tested only on one M4 Max (64 GB) running recent macOS. Other hardware is untested.
- Not notarized and not distributed as a binary. You build it yourself, and it is ad-hoc signed. Rebuilds can invalidate the Accessibility approval.
- Selection capture depends on each app's Accessibility support. Some apps, PDF viewers among them, need the Cmd+C fallback or Paste & Read.
- Models can mispronounce or skip words. Fish and VoxCPM generate close to real time on an M4 Max, so fast playback speeds can outrun them and leave gaps.
- `sandbox-exec` is deprecated by Apple. If a future macOS removes it, the worker fails closed and the app reports an engine error.
- Voice quality is a matter of taste. The measurements in VALIDATION.md are signal and timing checks, not listening scores.

## Uninstall

Quit ClearSpeak, delete the app and the repository (including the ignored `models/`, `.venv/` and `.local-runtime/` folders), and remove its Accessibility entry if you like. Preferences are stored under the `com.zohartito.clearspeak` defaults domain.

## Licence

The code in this repository is released under the [MIT License](LICENSE). The speech models it downloads are not covered by that licence; each keeps its own terms (see [Voices](#voices)).
