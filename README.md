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
  WhisperoidCore/     Audio capture, transcription, silence detection, clipboard
  Whisperoid/         Menu bar app, hotkeys, overlay, preferences
  vadcheck/           Development tool for tuning auto-stop against a recording
Resources/            Bundle configuration and entitlements
scripts/build-app.sh  Assembles and signs Whisperoid.app
scripts/package.sh    Produces a distributable archive in dist/
spike/                Standalone benchmark harness from model selection
```

## Building

```sh
./scripts/build-app.sh
open build/Whisperoid.app
```

SwiftPM cannot emit an `.app` bundle, so the script wraps the executable by
hand. It signs with a real certificate rather than ad-hoc: an ad-hoc signature
changes on every build, which invalidates the permissions macOS granted to the
previous build and makes the microphone prompt reappear each time. A Developer
ID Application certificate is preferred when present; otherwise an Apple
Development identity is used. Override with `WHISPEROID_SIGN_IDENTITY`.

Signing applies the hardened runtime, which notarisation requires, along with
the `com.apple.security.device.audio-input` entitlement that the hardened
runtime requires for microphone access. The nested `.bundle` directories from
SwiftPM hold no Mach-O code and are sealed as resources by the app signature;
signing them individually fails because swift-crypto's bundle has no
`Info.plist`.

The model is downloaded on first launch (about 1.5 GB) into
`~/Library/Application Support/Whisperoid`.

## Usage

Default shortcut is `⌘⌃D` to start and stop. `Escape` discards a recording
without transcribing, and is only registered while recording. Recording stops
automatically after 300 s; anything under 0.3 s is ignored.

`⌘⌃D` is not a macOS symbolic hotkey, but it is AppKit's built-in "Look Up in
Dictionary" shortcut within text views. A Carbon hotkey takes precedence, so
that lookup is shadowed while the app is running.

Note that `KeyboardShortcuts` persists its initial value to `UserDefaults` on
first launch, so changing the default in source has no effect afterwards. Clear
the stored value to pick up a new one:

```sh
defaults delete com.solshark.whisperoid KeyboardShortcuts_toggleDictation
```

Preferences (`⌘,` from the menu) cover both shortcuts, automatic stop on
silence, sound cues and opening at login.

Automatic stop only arms once speech has been heard, so a pause before the
first word will not end the recording. It defaults to 4 s of silence.

The silence threshold is derived from the loudest speech in the current
recording, not fixed in dBFS. Absolute levels depend entirely on microphone
gain: measured speech on this hardware peaks at -37 dBFS, so a fixed -42 dBFS
threshold classified 92% of active speech as silence and cut recordings off
mid-sentence. Silence is now anything 20 dB below the observed peak, bounded to
-65...-35 dBFS.

Use `vadcheck` to re-tune against a recording rather than by guesswork:

```sh
swift build -c release --product vadcheck
./.build/release/vadcheck path/to/recording.wav 4.0 20
```

It replays the file through the real `SilenceDetector` and prints the level
timeline, the derived threshold, the longest continuous silence, and where
auto-stop would fire. Across two real recordings, a 15 dB drop left gaps of
3.4-3.8 s within continuous speech; 20 dB reduced that to 1.9 s; beyond 25 dB
the threshold falls under the room's noise floor and auto-stop never fires.

Opening at login uses `SMAppService`, which records wherever the app currently
lives. Move it to /Applications before enabling.

## Distribution

```sh
./scripts/package.sh
```

Produces `dist/Whisperoid-<version>.zip`. The archive is built with `ditto`
rather than `zip`, which does not preserve the symlinks and extended attributes
inside an `.app` bundle and corrupts the signature on extraction.

Gatekeeper only accepts an app on another Mac without complaint when it is
signed with a **Developer ID Application** certificate and notarised. With
`notarytool` credentials stored in the keychain, the script does both:

```sh
xcrun notarytool store-credentials whisperoid \
    --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>

WHISPEROID_NOTARY_PROFILE=whisperoid ./scripts/package.sh
```

Without that certificate the archive still works, but the recipient must clear
the quarantine flag once after unzipping:

```sh
xattr -dr com.apple.quarantine /Applications/Whisperoid.app
```

If an Apple Development signature causes trouble on a machine other than the
one that built it, an ad-hoc signature is a working alternative and carries the
entitlements and hardened runtime correctly:

```sh
WHISPEROID_SIGN_IDENTITY="-" ./scripts/package.sh
```
