<p align="center">
  <img src="Brand/logo/zflow-mark.svg" width="72" height="72" alt="">
</p>

<h1 align="center">ZFlow</h1>

<p align="center">
  Dictation for macOS. Hold a key, speak, and the words land where your cursor is.<br>
  Part of the <a href="https://zippytal.com/fr">Zippytal</a> suite.
</p>

---

## What it does

- **Dictate anywhere.** Hold your key, speak, release. The text is pasted into
  whatever had focus.
- **On device or through a provider.** Apple's speech model runs on this Mac at
  no cost and sends nothing anywhere. Any OpenAI-compatible provider works too,
  per stage, so speech-to-text and cleanup can live in different places.
- **Cleanup that reads the room.** Filler removed, punctuation fixed, and —
  when you allow it — the app you are dictating into used as a spelling
  reference so names come out right.
- **A dictionary that fills itself.** Respell a word by hand just after a
  dictation and ZFlow remembers, then applies it to every later one.
- **Notetaker.** Record a call, get it back as a conversation with who said
  what. Your microphone and everything the Mac plays are recorded separately,
  and the remote voices are told apart on this machine.
- **Transcribe a file.** Drop a recording in and get the words out.
- **Insights.** How much you dictate, how fast, where, and what it did not cost.

## Architecture

Two pieces, and it matters which does what:

| | |
|---|---|
| **`Sources/`** — Swift | The app. Menu bar, microphone, global shortcuts, Accessibility, transcription, cleanup, meeting capture, history, storage. Built with `swiftc` and Make: no Swift Package Manager, no Xcode project. |
| **`electron/`** — TypeScript + React | The settings window, and only that. It reads and writes the app's settings over a loopback HTTP bridge and owns no dictation logic. |

The bridge binds to `127.0.0.1` only, requires a token generated fresh at each
launch and written to a `0600` file, and can reach nothing but the settings
keys it lists. Credentials are writable through it and never readable: a read
reports whether one is set, never its value.

## Build

```bash
make check      # type-check, tests, plist and shell validation
make ui         # build and package the settings window
make            # build the app bundle
make run        # build and launch
```

`make check` is the gate before any change is handed off.

## Layout

```
Sources/        the app
Tests/          dependency-free executable tests, run by make check
electron/       the settings window
Brand/          logo, palette, typography, icon renderer — see Brand/BRAND.md
Resources/      generated icons and DMG artwork
```

## Privacy

There is no ZFlow server. Audio, transcripts, and meeting recordings go only
to the provider you configure — and with both engines set to on-device,
nowhere at all. Screen Recording is never requested unless you turn on the
setting that needs it. Usage counts are words and dates, never what you said.

## Advanced

Timeouts can be overridden per stage:

```bash
defaults write com.zippy.zflow transcription_timeout_seconds -float 120
defaults write com.zippy.zflow post_processing_timeout_seconds -float 120
defaults write com.zippy.zflow context_request_timeout_seconds -float 120
```

Remove an override with `defaults delete` and the same key. Use
`com.zippy.zflow.dev` for a development build.

## Licence

MIT. See [LICENSE](LICENSE), and [THIRD-PARTY.md](THIRD-PARTY.md) for the
components ZFlow builds on.
