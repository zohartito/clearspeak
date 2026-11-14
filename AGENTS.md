# ClearSpeak — notes for contributors and coding agents

ClearSpeak's requirement is **entirely local, free inference on Apple Silicon**: no cloud speech, API keys, subscriptions or system-TTS fallback. Do not claim an unmeasured "best model" ranking.

- Keep the native AppKit menu bar app focused on reading selected or pasted text.
- Models live under ignored `models/`. Python and MLX-Audio are isolated in `.venv/`; Voxtral has its own `.local-runtime/voxtral/` interpreter. Preserve each environment's numerical pins.
- The shared voice catalog is `Sources/ClearSpeakCore/Resources/voices.json`; both Swift and Python read it.
- Voices must be stock model presets or original synthetic voices. Never add a voice that imitates a real, identifiable person, and never retain user readings as voice references.
- Fish S2 Pro uses a local 8-bit conversion with its original-precision codec, conditioned on fixed synthetic references. Never add free-form Fish system instructions: the current port can speak them aloud.
- VoxCPM uses fixed synthetic prompt audio plus its transcript, six diffusion steps and a repeatable seed.
- Sentence targets are soft (360 bytes for VoxCPM, 160 for Fish and Voxtral); the hard chunk limit is 600 bytes. Preserve exact text; no hardcoded pronunciation replacements.
- Playback keeps a rate-aware four-second reserve and a 30-source-second scheduling cap. Automatic buffering is separate from user Pause. Validate playback changes with `swift run ClearSpeakChecks --live-continuity`.
- `./scripts/setup-local.sh` installs the base model; `./scripts/test.sh` runs offline checks; `./scripts/build.sh` builds the app. Quit the app before rebuilding.
- Never commit model weights, environments, build outputs, generated audio or selected text.
- Keep the worker network-denied, using local files, offline settings and private pipes. Never log text, clipboard data, audio, credentials or raw model errors.
- Preserve opt-in clipboard fallback, change-count protection, cancellation and no-history behavior. Stop/Quit must tear down the worker and stale generation must never resume playback.
- Do not change macOS privacy or security settings automatically.
- Compilation, mocked playback, real local synthesis, cross-app capture and subjective listening are different checks; record which one you ran in `VALIDATION.md`.
- macOS only.
