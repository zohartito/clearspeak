# Validation

Measured evidence for ClearSpeak v0.5.0 (build 7), condensed from the project's development log (September 2026). All runs were on one Apple M4 Max with 64 GB of unified memory, using fixed, harmless sample text, with the speech worker's network access denied. These are signal, timing and behavior checks. They are not listening scores, and other hardware will differ.

## Offline checks

- `./scripts/test.sh`: 15 native checks plus 3 Python asset-manifest checks pass. Coverage includes:
  - catalog consistency
  - missing model shard, reference, embedding or interpreter
  - worker process switching and warm reuse across engines
  - network denial inside the worker sandbox
  - PCM pause, resume, rate and drain
  - malformed audio
  - stale-generation cancellation
  - playback reserve, starvation recovery and short-reading drain
  - real Carbon hotkey registration and collision rollback
  - clipboard restoration races
- Release compilation, resource-bundle packaging and `codesign --verify --strict` pass with Command Line Tools alone.

## Real synthesis

- Every voice in the catalog generated finite, non-silent 24 kHz audio twice through the production worker. Each also passed real cancellation of an in-progress generation. Measured worker termination: Ryan 0.039 s, Fish 0.182 s.
- Long-form: 36 consecutive sentences per engine (Kokoro, VoxCPM, Fish, Voxtral) produced about 170 s of speech each.
- `swift run ClearSpeakChecks --live-narrators`: 5 real playback checks pass through AVAudioEngine. They cover Kokoro → VoxCPM → Fish → Voxtral → Kokoro switching, pause/resume during preparation, Stop, and recovery.
- `swift run ClearSpeakChecks --live-continuity`: a ~1,100-byte Warm Female (VoxCPM) passage at 1.25× ran as 3 chunks and 104 PCM packets with 1 playback start and 0 queue underruns.

## Measured warm runs

First PCM is measured after the worker is ready, so it excludes model load. MLX peak excludes other process memory.

| Voice | First PCM | Audio s / generation s | MLX peak |
| --- | ---: | ---: | ---: |
| Ryan (Qwen3-TTS) | 0.26–0.30 s | 3.36–3.41× | 5.48 GB |
| Heart (Kokoro) | 0.143 s | 41.63× | 2.14 GB |
| Bella (Kokoro) | 0.145 s | 45.34× | 2.25 GB |
| Michael (Kokoro) | 0.156 s | 43.83× | 2.27 GB |
| Emma (Kokoro) | 0.135 s | 42.86× | 2.10 GB |
| Warm Male (VoxCPM) | 5.123 s | 1.41× | 7.94 GB |
| Warm Female (VoxCPM) | 4.833 s | 1.39× | 8.07 GB |
| Warm Male (Fish) | 4.475 s | 1.45× | 12.81 GB |
| Warm Female (Fish) | 4.560 s | 1.49× | 13.43 GB |
| Fish | 5.589 s | ~1.48× | 13.77 GB |
| Casual Male (Voxtral) | 0.327 s | 3.29× | 3.37 GB |
| Casual Female (Voxtral) | 0.372 s | 3.11× | 3.40 GB |

Qwen model load took 1.76 s. A cold first run, including first-use shader compilation, took 6.26 s from launch to audio. Long-form throughput was:

- Kokoro: 4.16–44.92×
- VoxCPM: 0.67–1.40×
- Fish: 0.49–1.24×
- Voxtral: 1.37–2.75×

Some of those runs overlapped other GPU work, so they are not a controlled comparison. VoxCPM and Fish can leave gaps at fast playback speeds.

Breeze TTS 2 BF16 (audition only) generated at about 0.21× real time with the tested settings, which is why it is not offered as an app voice.

## Design checks behind current settings

- An early Fish experiment with a free-form style instruction spoke that instruction aloud. A local Whisper-tiny pass detected it. Production Fish therefore uses reference audio only.
- For VoxCPM, a fixed synthetic prompt plus its transcript, 6 diffusion steps and a fixed seed narrowed the estimated median-pitch range across three paragraphs from 29 Hz to 6 Hz. It also narrowed the phrase RMS range from 5.4 dB to 1.1 dB and raised throughput from 1.27× to 1.48–1.70×, compared with reference-only at 10 steps. These are limited signal diagnostics.
- Offline Whisper-tiny diagnostics recovered the intended main passages, but some clips showed omissions or hallucinated tails. No word-accuracy score is claimed.

## Not yet verified

- Selected-text reading from every app. Acrobat, for example, needs the Cmd+C fallback.
- A real logout or reboot with Launch at login. Only a simulated login-launch event was checked (`swift scripts/check-login-launch.swift`).
- Other Macs, other macOS versions, and notarized distribution.
- Subjective voice quality and long-reading comfort.

## Audit fixes — 2026-11-15

- CLR-01 baseline: 12 passed, 0 failed, 6 skipped (9 native checks and 3 Python asset checks passed). The audit forbids hardware and desktop interaction, so an isolated scratch copy skips the five AVAudioEngine checks and the global hotkey check before their closures run. The private named pasteboards and sandboxed mock workers run normally; the real clipboard, models and desktop apps are not used. The same exclusions apply to subsequent audit runs; existing repository checks are unchanged.
- CLR-01: reproduced the pinned dependency resolution failure with `MACOSX_DEPLOYMENT_TARGET=13.0 uv pip install --dry-run --python-version 3.12 --python-platform aarch64-apple-darwin -r engine/requirements.lock`; macOS 14 resolves all 35 packages. `RepositoryChecks.test_clr01_minimum_macos_matches_pinned_runtime` failed for the three macOS 13 declarations, then passed with README, SwiftPM and the app bundle set to macOS 14. This is resolver and metadata evidence, not execution on macOS 13 or 14.
- CLR-02: `NarratorCLIChecks.test_clr02_defaults_require_only_narrator_pack` reproduced the sixth-voice failure with a mock worker rejecting missing Fish assets, then passed for all eight Kokoro/VoxCPM/Voxtral voices. `test_clr02_load_failure_identifies_voice` failed on the anonymous load error, then passed with the catalog voice in the message; `test_clr02_explicit_optional_voices_remain_supported` preserves explicit Fish/Qwen selection. These are CLI checks with worker/audio/NumPy doubles, not model synthesis or listening.
- CLR-03: `CLR-03 capture rejects two clipboard writes before the first poll` failed with the unchanged polling logic accepting the newer copy, then passed with the exact-one-change guard. Three companion capture checks pass for a single copy, changed focus and cancellation cleanup. The production fallback now shares its polling path with these checks using an explicit pasteboard, copy closure and focus predicate. All fixtures use private named pasteboards; real cross-app capture and Accessibility remain untested in this audit. The permitted suite passed: 20 passed, 0 failed, 6 skipped.
- CLR-04 / CLR-05: isolated Swift probes against the compiled core confirmed that `LocalSpeechProvider(runtime: nil)` lists four base voices with `isInstalled == false`, and that an untrimmed text fixture loses outer whitespace while preserving internal spaces and newlines. Source inspection also confirmed Settings retains the selected voice and shows its installation status. Corrected the README to match these deliberate behaviors; no voice-availability or chunking behavior changed.
- CLR-06: `RepositoryChecks.test_clr06_fish_license_link_uses_audited_target` failed on the README's `LICENSE` URL, then passed after changing it to the checker-supplied model-card target `LICENSE.md`. This is an offline link-target regression; the reported HTTP 404/200 was not independently repeated because this audit permits network access only for declared dependency installation.
- CLR-15: both `actions/checkout@v7` references and `gitleaks/gitleaks-action@v3` are pinned to the full commits those tags pointed to on 2026-11-15 (resolved with read-only `git ls-remote`), with the exact release in a trailing comment so weekly Dependabot updates keep working. `RepositoryChecks.test_clr15_actions_use_commit_pins` in `scripts/check-repository.py` fails on the previous workflows and passes now.
