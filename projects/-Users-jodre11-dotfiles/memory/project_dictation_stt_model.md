---
name: Dictation STT model and periodic review
description: Local push-to-talk dictation uses whisper-cpp with large-v3-turbo-q8_0 and Silero VAD; user wants periodic checks for model improvements
type: project
originSessionId: f26029af-9c62-4304-9d39-971b4727ea54
---
Push-to-talk dictation pipeline: Print Screen → Karabiner → F20/F19 → Hammerspoon → sox → whisper-cli → clipboard paste.

**Current setup (2026-04-13):**
- whisper-cpp 1.8.4 (Homebrew)
- Model: `ggml-large-v3-turbo-q8_0.bin` (874MB) — large-v3 encoder + 4-layer turbo decoder, q8_0 quantisation
- VAD: Silero v6.2.0 (`ggml-silero-v6.2.0.bin`, 864KB) — filters silence before decoding
- Hardware: Apple M4, 16GB RAM

**History:**
- Previously used `ggml-medium.en` (1.4GB). Upgraded to large-v3-turbo for better quality.
- Tried q5_0 first but q8_0 gave noticeably better accuracy on similar-sounding words.

**Why:** User wants to regularly check for improvements to local STT models that fit a medium size envelope (~1.5GB, real-time on M4).

**How to apply:** Periodically check whisper.cpp releases, new quantised model variants on HuggingFace, and alternative engines (Moonshine, mlx-whisper). Compare against current large-v3-turbo-q8_0 baseline.
