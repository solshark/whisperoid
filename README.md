# Whisperoid

A menu bar dictation app for macOS. Press a hotkey, speak, press again: the
transcript is placed on the clipboard and confirmed with a floating overlay.

![The floating overlay during a recording, showing the live waveform and elapsed
time over whatever you happen to be looking at.](docs/screenshot.png)

Everything runs on the machine. Speech is transcribed locally by Whisper on the
Neural Engine, nothing is sent anywhere, and once the model has been downloaded
the app needs no network connection at all.

English and Russian are detected automatically, with no per-language shortcut to
remember.

## Requirements

- An Apple Silicon Mac. Intel is not supported.
- macOS 14 or later. Developed and tested on macOS 26 on an M3 Max.
- About 1.5 GB of disk for the speech model, downloaded on first launch.
- Permission to use the microphone, requested the first time you record. The app
  asks for nothing else.

## Getting started

There is no prebuilt download yet, so the app is built from source. This needs
Xcode installed, along with its Metal toolchain:

```sh
xcodebuild -downloadComponent MetalToolchain
```

Then, from a clone of this repository:

```sh
./scripts/build-app.sh
open build/Whisperoid.app
```

Whisperoid runs in the menu bar and has no Dock icon or window. On first launch
it downloads the speech model, which takes a few minutes and reports progress in
the menu — see [First launch on a new machine](#first-launch-on-a-new-machine)
if it looks like it has stalled.

Press `⌘⌃D` to start dictating, `⌘⌃D` again to stop, then paste with `⌘V`.
`Escape` discards a recording instead of transcribing it.

To keep it, drag `build/Whisperoid.app` to `/Applications`, or run
`./scripts/package.sh` to produce a disk image.

## Licence

Whisperoid is MIT licensed; see `LICENSE`.

Every dependency is Apache 2.0 or MIT, with no copyleft anywhere in the tree,
so the source may be published and a binary distributed commercially. Both
licences require their notices to accompany binary distribution, so
`Resources/THIRD-PARTY-NOTICES.txt` is copied into the app and shown by
Acknowledgements in the About window. Regenerate it from the resolved
dependencies after any change:

```sh
python3 scripts/make-notices.py
```

One caveat for commercial distribution: the Core ML weights in
`argmaxinc/whisperkit-coreml` carry no declared licence. The app downloads them
at runtime rather than bundling them, so they are not redistributed here. That
would need resolving before shipping a build with the model included.

## Design decisions

**Clipboard, not keystroke injection.** The app does not synthesise keystrokes
into the focused application. That keeps the microphone as the only permission
it ever requests, and avoids macOS Secure Input silently discarding synthetic
events in password fields and terminals. The cost is one `⌘V` and a clobbered
clipboard; transcript history in the menu compensates for the latter.

**No background service.** WhisperKit runs in-process. The model loads at launch
and is released when the app quits, so nothing Whisper-related outlives the
application.

**Carbon hotkeys, not a CGEventTap.** `RegisterEventHotKey` needs no Input
Monitoring permission. A CGEventTap would, and is also restricted under App
Sandbox. Registration, storage and the recorder UI are implemented in
`Sources/Whisperoid/Hotkeys.swift` and `ShortcutRecorder.swift`; see below for
why the `KeyboardShortcuts` package was removed.

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

## Transcript cleanup

Speech to text produces run-together words, missing punctuation and mangled
technical vocabulary. Cleanup is an optional pass over the transcript before it
reaches the clipboard, chosen in Settings:

| Mode | What it does |
| --- | --- |
| Off | Default. Nothing is downloaded and nothing runs. |
| Spelling (macOS) | The system spell checker splits run-together words. No model, no download. |
| Language model (experimental) | An on-device model repairs spacing, punctuation and misheard terms. |

**Model mode downloads a second model** of about 3.3 GB,
`mlx-community/gemma-4-e2b-it-4bit`, the first time it is selected. It runs
in-process through MLX, is loaded at launch and released again after an
idle period, and like everything else here it never contacts a network once
downloaded. A user who never opens Settings is unaffected by any of this.

**The glossary is what makes it work, not the model.** Across eight models
tested, a run with no glossary corrected roughly one defect in six; with one,
four to six. The glossary is editable in Settings, one term per line, and is
where names specific to your own work belong — colleagues, employers, internal
services. One entry covers both alphabets: listing `Colima` also repairs its
Cyrillic mishearings.

Cleanup is not permitted to cost you a dictation. The output is rejected
wholesale if the model invented a word that was not in the transcript or the
glossary, or dropped a glossary term it was given, and the original transcript
is returned untouched. The same applies if cleanup fails or times out.

## Why KeyboardShortcuts was removed

The `KeyboardShortcuts` package caused two unrelated crashes that both appeared
only away from the machine that built the app, and it was replaced with roughly
250 lines covering the eight APIs actually used.

**Its Carbon callback used `MainActor.assumeIsolated`.** Running on the main
thread is not the same as running on the main actor's executor, and on macOS 26
with Swift 6.3 that check reads an invalid executor reference and faults. Four
crash reports show it, as `EXC_BAD_ACCESS` or `EXC_BREAKPOINT` depending on
timing. Version 3.0.1 is the newest release and already contains an attempted
fix for a Swift 6.3 release-build crash, so there was nothing to upgrade to.
`Hotkeys.swift` hops onto the actor from the C callback instead of asserting it
is already there.

**Its recorder view read localised strings through `Bundle.module`.** See the
next section; there is no way to ship that in a signed application.

Shortcut storage keys changed with the replacement, so a customised shortcut
reverts to the default once. The default is unchanged.

## SwiftPM resource bundles in a signed app

A dependency that reads resources through SwiftPM's generated `Bundle.module`
accessor cannot be shipped in a signed `.app` without care, and the failure only
appears on machines other than the one that built it.

The generated accessor looks for its bundle in `Bundle.main.bundleURL`, which
for an application is the `.app` directory itself, and otherwise falls back to a
path hardcoded into the build machine's `.build` directory. Placing the bundle
in `Contents/Resources` — the only placement a signed bundle permits — means the
accessor never finds it and calls `fatalError`. On the build machine the
hardcoded fallback exists, so everything appears to work.

Putting the bundle at the top level of the `.app` satisfies the accessor but
leaves the signature invalid with "unsealed contents present in the bundle
root". Symlinks fail identically. There is no placement that satisfies both.

`KeyboardShortcuts` used that accessor for the localised strings in its
recorder view, which crashed the settings window on any other computer. That
package has since been removed entirely.

`swift-transformers` also reads a fallback tokenizer configuration this way. It
is unreachable through WhisperKit's loading path and has never been hit, but it
would fail the same way if it ever were.

To verify a change of this kind, hide the build directory's copy so the machine
behaves like a fresh one:

```sh
B=.build/arm64-apple-macosx/release/<Name>.bundle
mv "$B" "$B.hidden"
open build/Whisperoid.app --env WHISPEROID_SHOW_SETTINGS=1
```

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
  WhisperoidCore/     Audio capture, transcription, silence detection, cleanup
  Whisperoid/         Menu bar app, hotkeys, overlay, preferences
  vadcheck/           Development tool for tuning auto-stop against a recording
  cleanupcheck/       Development tool for scoring the cleanup model
Tests/                Swift Testing suites; run with `swift test`
Resources/            Bundle configuration and entitlements
scripts/build-app.sh  Assembles and signs Whisperoid.app
scripts/package.sh    Produces a distributable disk image in dist/
```

The tests gate a release: `scripts/package.sh` runs them and builds nothing if
they fail.

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

A recorded shortcut is stored under `hotkey.<name>` in `UserDefaults`; clearing
one is recorded separately so that it is not mistaken for never having set one,
which would otherwise resurrect the default on the next launch.

Preferences (`⌘,` from the menu) cover both shortcuts, automatic stop on
silence, sound cues and opening at login.

Automatic stop only arms once speech has been heard, so a pause before the
first word will not end the recording. It defaults to 4 s of silence, and both
the wait and the threshold are adjustable in preferences.

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

## Privacy

Audio never reaches disk. The only filesystem write the app performs is
creating its support directory for the model cache.

- Captured samples are held in memory and cleared by `stop()` and `cancel()`.
- Samples are handed to WhisperKit as an array, not a file path. WhisperKit's
  transcription path contains no `write(to:)`, no temporary directory use and
  no `AVAudioFile(forWriting:)`.
- Transcript history is text only, held in memory, capped at ten entries, and
  discarded when the app quits. It is not written to `UserDefaults` or disk.
- Nothing transcribed is logged. Log entries carry the model name, storage
  path, load timing and window geometry only.

The transcript is placed on the clipboard by design. A clipboard manager will
therefore archive it to disk, outside this app's control, which is worth
knowing before dictating anything sensitive.

## Diagnostics

The app logs to the unified log, not stderr: an app bundle launched by
LaunchServices has no terminal attached, so stderr is discarded exactly when it
would be most useful.

```sh
/usr/bin/log stream --predicate 'subsystem == "com.solshark.whisperoid"'
/usr/bin/log show --predicate 'subsystem == "com.solshark.whisperoid"' --last 5m --style compact
```

Use the absolute path. `log` is shadowed in some shells, and the resulting
error is easy to mistake for an empty result. Messages are emitted at `notice`
rather than `info`, because info-level entries are held in memory only and are
routinely dropped before `log show` can retrieve them.

### First launch on a new machine

The menu bar status reports each startup phase separately, because they stall
for entirely different reasons:

| Status | Meaning |
| --- | --- |
| `Finding model…` | Resolving the model on the remote repository |
| `Downloading model… file N of 6` | Transferring, with bytes on disk alongside |
| `Preparing model…` | Core ML compiling for this machine; no network activity |
| `Ready` | Usable |

Download progress is counted in **files, not bytes**. The model is six files
of which `AudioEncoder.mlmodelc` is about 1.3 GB of the 1.6 GB total, so the
file count appears frozen for most of the download. The size on disk shown
beside it is the reliable indicator of movement.

`Preparing model…` is Core ML compiling the model for this specific device. It
is CPU-bound, shows no network activity at all, and on a machine that has not
seen this model before it can take minutes. It is not a hang.

**Troubleshooting → Copy Diagnostics** in the menu puts a full report on the
clipboard: versions, architecture, storage path and writability, free space, a
per-file listing of the model folder with sizes, and reachability probes
against the model host. **Reveal Model Folder in Finder** opens the download
location so a partial transfer is visible directly.

`WHISPEROID_DUMP_DIAGNOSTICS=1` writes that same report to the unified log
instead, for a machine where using the menu is inconvenient.

Two overrides exist for exercising first-run behaviour without disturbing an
existing install:

```sh
open build/Whisperoid.app \
    --env WHISPEROID_SUPPORT_DIR=/tmp/whisperoid-fresh \
    --env WHISPEROID_MODEL_VARIANT=openai_whisper-base
```

Setting `WHISPEROID_SHOW_SETTINGS=1` opens preferences shortly after launch,
which allows the window to be verified without driving the menu bar:

```sh
open build/Whisperoid.app --env WHISPEROID_SHOW_SETTINGS=1
```

Note that a process launched from a background shell cannot take focus from the
frontmost application, so `active=false` in that situation is expected and does
not indicate a fault.

## Distribution

```sh
./scripts/package.sh
```

Produces `dist/Whisperoid-<version>.dmg` containing the app beside a symlink to
`/Applications`, which is the conventional drag-to-install layout. The image is
HFS+ rather than APFS so that older versions of macOS can mount it.

Gatekeeper only accepts an app on another Mac without complaint when it is
signed with a **Developer ID Application** certificate and notarised. With
`notarytool` credentials stored in the keychain, the script does both:

```sh
xcrun notarytool store-credentials whisperoid \
    --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>

WHISPEROID_NOTARY_PROFILE=whisperoid ./scripts/package.sh
```

Without that certificate the image still works, but the recipient must clear
the quarantine flag once after dragging the app across:

```sh
sudo xattr -dr com.apple.quarantine /Applications/Whisperoid.app
```

Use `sudo`. The copy in `/Applications` is not necessarily owned by the account
running the command, and the attribute is not removed without it.

Send that command with the image rather than waiting to be asked for it. A
recipient who skips it is not shown a signing or notarisation error: macOS
reports the app as damaged or unverifiable and offers to move it to the Trash,
which reads as a corrupt download or a broken build. The report that comes back
will describe a fault in the application rather than the missing signature that
actually caused it.

If an Apple Development signature causes trouble on a machine other than the
one that built it, an ad-hoc signature is a working alternative and carries the
entitlements and hardened runtime correctly:

```sh
WHISPEROID_SIGN_IDENTITY="-" ./scripts/package.sh
```
