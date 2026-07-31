# Whisperoid

A menu bar dictation app for macOS. Press a hotkey, speak, press again: the
transcript is placed on the clipboard and confirmed with a floating overlay.
Transcription runs locally via Whisper on the Neural Engine.

Personal tool, Apple Silicon only. Built and tested on an M3 Max running
macOS 26.

## Design decisions

**Clipboard, not keystroke injection.** The app does not synthesise keystrokes
into the focused application. That keeps the microphone as the only permission
it ever requests, and avoids macOS Secure Input silently discarding synthetic
events in password fields and terminals. The cost is one `⌘V` and a clobbered
clipboard; transcript history in the menu compensates for the latter.

**No background service.** WhisperKit runs in-process. The model loads at launch
and is released when the app quits, so nothing Whisper-related outlives the
application.

**Carbon hotkeys, not a CGEventTap.** `RegisterEventHotKey` (via
`KeyboardShortcuts`) needs no Input Monitoring permission. A CGEventTap would,
and is also restricted under App Sandbox.

**Automatic language detection.** One hotkey, no per-language binding. The
selected model detects English and Russian reliably and preserves Latin-script
technical terms inside Russian prose.

## Model selection

The app uses `openai_whisper-large-v3-v20240930_turbo`.

Beware the naming. In the WhisperKit model repository, the `_turbo` suffix
denotes Argmax's own Neural Engine optimisation, *not* OpenAI's turbo model.
The `v20240930` component is what identifies large-v3-turbo:

| Variant | `decoder_layers` | Actual model |
| --- | --- | --- |
| `openai_whisper-large-v3-v20240930_turbo` | 4 | large-v3-turbo, ANE-optimised |
| `openai_whisper-large-v3_turbo` | 32 | full large-v3, ANE-optimised |

Measured on an M3 Max, warm, second run:

| Model | Real voice, 24.6 s EN | Real voice, 16.8 s RU | Language detection |
| --- | --- | --- | --- |
| large-v3-turbo | 0.69 s (35.8x) | 0.85 s (19.9x) | correct on every run |
| full large-v3 | 2.63 s (9.4x) | 3.38 s (5.0x) | returned `fr`, `ro`, `es` |

Full large-v3 is roughly four times slower, produced identical English text, and
misdetected Russian as Romanian badly enough to transcribe it *as* Romanian.
Warm model load is about 5.6 s; resident memory is about 0.8 GB.

## Known upstream issue

`DecodingOptions.promptTokens` returns empty output on this model variant in
WhisperKit 0.18. Reproduced with WhisperKit's own `whisperkit-cli --prompt`, so
it is not an integration fault. It works on `openai_whisper-base` and is
unreliable on full large-v3.

Custom vocabulary via decoder prompting is therefore not used. This matters:
prompting measurably improved accuracy where it worked, correcting both jargon
and adjacent ordinary words.

## Layout

```
Sources/
  WhisperoidCore/     Audio capture, transcription, clipboard, paths
  Whisperoid/         Menu bar app, hotkeys, overlay
Resources/Info.plist  Bundle configuration
scripts/build-app.sh  Assembles and signs Whisperoid.app
spike/                Standalone benchmark harness from model selection
```

## Building

```sh
./scripts/build-app.sh
open build/Whisperoid.app
```

SwiftPM cannot emit an `.app` bundle, so the script wraps the executable by
hand. It signs with an Apple Development identity rather than ad-hoc: an ad-hoc
signature changes on every build, which invalidates the permissions granted to
the previous build. Override with `WHISPEROID_SIGN_IDENTITY`.

The model is downloaded on first launch (about 1.5 GB) into
`~/Library/Application Support/Whisperoid`.

## Usage

Default shortcut is `⌥⌘D` to start and stop. `Escape` discards a recording
without transcribing, and is only registered while recording. Recording stops
automatically after 300 s; anything under 0.3 s is ignored.
