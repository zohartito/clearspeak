# ClearSpeak: natural, comfortable local voices

Researched September 22, 2026. Target: personal offline reading on a 64 GB M4 Max. This is a research shortlist, not a listening verdict or completed installation.

## Recommendation

Audition VoxCPM2 designed voices and new narrator references for the existing Fish engine first. Include Kokoro Heart/Bella as inexpensive-to-run comparison voices and Voxtral casual male/female as a second-round option. Retain Breeze as a quality reference until a fresh Mac benchmark resolves its previously poor throughput. Choose by listening to identical passages, including several minutes of continuous reading.

For the initial voice brief, use warm conversational delivery, restrained expression, clear consonants, moderate pacing and natural sentence endings. Compare male and female voices. These are proposed audition targets, not claims about how an unheard voice sounds.

## What is actually installed

Inspected production source, installed package metadata and model directories today. MLX-Audio is 0.5.1. ClearSpeak offered Fish, Ryan, Aiden, Vivian and Serena. Qwen CustomVoice BF16, Fish BF16/8-bit and Breeze BF16 directories are present; new shortlist models are not installed there.

`engine/worker.py` conditions Fish on `ordinary-qwen.wav`, a synthetic Qwen reference. The current Fish option therefore does not explore a broad set of independent narrator voices. A different clean, permitted reference is a promising variable to test; it is not proof of improved naturalness.

The existing Qwen delivery instruction already requests warm, relaxed conversational speech. Simply adding those adjectives again is unlikely to be a meaningful experiment. Existing Fish code intentionally omits free-form system instructions because the installed port previously spoke them aloud.

## Shortlist and evidence

| Candidate | Why audition it | Local route and limits |
| --- | --- | --- |
| **VoxCPM2** | Voice design can target a specific narrator character without imitating a real person. Also supports reference cloning. Best new experiment for tailoring comfort. | Official 2B model; MLX BF16 and quantized ports exist. BF16 card lists about 4.96 GB of model files, not total runtime memory. Speed and quality on this M4 Max remain unmeasured. |
| **Fish S2 Pro with new narrator references** | Reuses an engine already integrated and previously measured here. Tests whether the current reference voice, rather than only the engine, is limiting preference. | Keep current 8-bit language model and original-precision codec as baseline. Use a clean licensed/consented narrator or an approved synthetic design. Do not insert free-form Fish instructions into production. |
| **Kokoro Heart / Bella** | Concrete stock voices, small model, useful everyday-reading comparison. Upstream rates Heart A and Bella A-minus; those are creator grades, not an independent comfort study. | 82M model, MLX support. Also compare Michael for a male option and Emma for British English, without assuming equal quality. It may be less expressive, which is something to assess rather than automatically penalize. |
| **Voxtral casual_male / casual_female** | Ready-made conversational presets with a local MLX path; neutral presets provide a useful comparison. | 4B, 20 presets across nine languages. BF16 model files about 8 GB. Start by measuring a quantized build against BF16 on a short fixed passage; do not import the provider's server-latency claims into Mac expectations. |
| **Breeze TTS 2** | Highest-ranked open-weight entry on the freshly opened Artificial Analysis provider-voice board; voice design and direction fit the desired delivery. | Already staged locally. September 8 project evidence reports only 0.21 audio-seconds generated per wall-second at tested BF16/CFG4 settings—roughly 4.8 seconds of computation per second of speech. A new port/configuration must earn a fresh performance result. |

Sources: [VoxCPM official repository](https://github.com/OpenBMB/VoxCPM), [VoxCPM2 MLX card](https://huggingface.co/mlx-community/VoxCPM2-bf16), [Fish S2 Pro](https://huggingface.co/fishaudio/s2-pro), [Kokoro voice roster](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md), [Voxtral MLX card and presets](https://huggingface.co/mlx-community/Voxtral-4B-TTS-2603-mlx-bf16), [Breeze model card](https://huggingface.co/BreezeBlue/Breeze-TTS-2), [current provider-voice leaderboard](https://artificialanalysis.ai/text-to-speech/leaderboard/provider-voice).

The current board showed Breeze 1204, Fish S2 Pro 1121, Voxtral 1075 and Kokoro 1061 Elo. These compare provider-selected voices, not ClearSpeak's exact quantizations/references or the user's long-form comfort. An older search-index result for the generic leaderboard disagreed; the current provider-voice page was used. Fish S2.1 Pro on that board is not evidence of downloadable S2.1 weights or a local upgrade.

## Other candidates screened

- **Qwen3 VoiceDesign:** a distinct checkpoint from installed CustomVoice; could create original narrator references and then compare those through Qwen Base or Fish. Useful for voice variety, not automatically a new quality tier. [Official model](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign).
- **OmniVoice:** active project with voice cloning/design, broad language support and an MLX route. Worth a second-round audition if the first set disappoints. Its published CUDA acceleration is not a Mac benchmark. [Official repository](https://github.com/k2-fsa/OmniVoice).
- **Higgs TTS 3:** conversational controls and an MLX route are interesting, but its model card explicitly distinguishes creator use from embedding in an application. Resolve the applicable integration terms before selecting it for ClearSpeak. It is not the most straightforward first addition. [Model card](https://huggingface.co/bosonai/higgs-tts-3-4b).

MLX support was checked against the [current upstream roster](https://github.com/Blaizzy/mlx-audio). Current upstream support does not establish compatibility with the project's installed 0.5.1 package. Evaluate candidates in an isolated environment; do not upgrade production dependencies as part of research.

## Audition that answers the actual question

1. Generate the same 45–60 second fixed, nonprivate passage for each candidate. Include ordinary prose, architecture terminology, numbers and a question. Preserve the exact words.
2. Compare at matched perceived loudness and the same playback rate. Avoid making a louder sample appear better. Use anonymous labels for first preference scoring.
3. Score naturalness, pleasantness, pronunciation, pauses and sentence endings. Note breathiness, sharp consonants, exaggerated emotion and repeated intonation separately.
4. Run the top two on 3–5 minutes of continuous prose. This checks fatigue, voice drift, repetition, omissions and audible joins that short demos can hide.
5. Record cold startup, warm first audio, audio duration divided by generation time, peak memory and cancellation. Distinguish these from subjective listening approval. The online MLX cards use inconsistent RTF conventions, so record the ratio explicitly.
6. Add the winning voices as optional choices only after real offline playback and Stop/cancellation pass. Preserve original voices and user settings.

Research completed without model downloads, dependency upgrades, app rebuild, preference changes or new synthesis. Historical Fish/Breeze measurements were read from VALIDATION.md, not rerun today. No claim that a candidate has already sounded better to the user.

## Follow-up: consistent delivery and playback gaps

The first integrated VoxCPM run exposed two separate issues during user listening: playback starvation and phrase-to-phrase changes in delivery. The original reader began on its first 0.8-second PCM packet, while VoxCPM only returns audio after generating the entire phrase. At the user's 1.25× playback rate, a model generating around 1.27× has almost no timing margin.

The MLX port supports both reference-only cloning and continuation from prompt audio plus its transcript. Reference-only mode is valid; a missing transcript is not an API error. Continuation supplies a stronger example of delivery, and can use our fixed original synthetic reference instead of retaining user readings. See [MLX VoxCPM2 modes](https://github.com/Blaizzy/mlx-audio/blob/main/mlx_audio/tts/models/voxcpm2/README.md) and [upstream cloning modes](https://github.com/OpenBMB/VoxCPM).

A controlled local comparison of three fixed paragraphs used the same female reference. Reference-only/10 steps produced estimated phrase median pitches of 193.7, 164.7 and 173.5 Hz, a 5.4 dB RMS range, and 1.27–1.29 audio seconds per generation second. Fixed prompt audio plus transcript/6 steps with a repeatable seed produced 163.8, 163.3 and 158.2 Hz, a 1.1 dB RMS range, and 1.48–1.70× generation throughput. Combined reference-plus-prompt added computation without a clear benefit in these samples. These small pitch/RMS diagnostics support an implementation choice, not a universal voice-quality ranking or human listening approval. Fixed seeding can repeat cadence; listen for that tradeoff.

The implementation follow-up uses a rate-aware playback reserve, longer bounded VoxCPM passages, and the fixed synthetic prompt/transcript. Final live queue-underrun evidence belongs in VALIDATION.md; concatenating generated WAV files cannot demonstrate uninterrupted real playback.
