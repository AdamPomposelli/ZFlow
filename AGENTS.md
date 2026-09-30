# ZFlow maintenance guide

ZFlow is a native macOS menu-bar dictation app built directly with `swiftc`
and Make. It does not use Swift Package Manager or an Xcode project. Preserve
that architecture unless the user explicitly approves a migration.

`Sources/` is the app: microphone, global shortcuts, Accessibility,
transcription, cleanup, meeting capture, storage. `electron/` is the settings
window and nothing else — it reads and writes settings over a loopback bridge
and owns no dictation logic. Deleting or replacing either is a migration, not
maintenance.

## Repository map

- `Sources/App.swift` and `Sources/AppDelegate.swift`: app lifecycle.
- `Sources/AppState.swift`: central pipeline orchestration and shared state.
- `Sources/AudioRecorder.swift`: microphone capture and audio conversion.
- `Sources/TranscriptionService.swift` and
  `Sources/RealtimeTranscriptionService.swift`: transcription providers.
- `Sources/PostProcessingService.swift`: transcript cleanup and edit mode.
- `Sources/AppContextService.swift`: foreground-app metadata and screenshots.
- `Sources/ShortcutCore/`: shortcut models, matching, and session behavior.
- `Sources/PipelineHistoryStore.swift`: local pipeline history.
- `Sources/UpdateManager.swift`: update and release behavior.
- `Sources/NotetakerService.swift` and `Sources/LocalSpeechTranscriber.swift`:
  meeting capture and on-device speech.
- `Sources/SettingsView.swift` and other SwiftUI files: the fallback interface.
- `electron/`: the settings window.
- `Brand/`: logo, palette, typography, and the icon renderer. See
  `Brand/BRAND.md` before changing anything anyone can see.
- `Tests/`: dependency-free executable tests.

## Working rules

- Search with `rg` or `rg --files` before editing.
- Preserve unrelated changes in a dirty worktree.
- Keep changes narrowly scoped and work on a branch.
- Do not push directly to `main`.
- Do not merge, tag, or publish a release unless the user explicitly
  authorizes that action.
- Do not change versions, release notes, signing, or notarization during
  ordinary maintenance.
- Avoid adding dependencies when the standard library or existing frameworks
  are sufficient.
- Production sources are discovered automatically by the Makefile. Test source
  dependencies must be listed explicitly in `TEST_PRODUCTION_SOURCES`.

## Verification

Run before handing off every code change:

```bash
make check
git diff --check
```

`make check` performs a full Swift type-check, compiles and runs deterministic
tests, validates plist files, parses repository shell scripts and YAML, and
runs the settings window's schema tests (`make ui-test`, skipped without Node).

A full app build is usually unnecessary. When a compile-and-bundle check is
material to the change, use:

```bash
make ARCH="$(uname -m)" CODESIGN_IDENTITY=-
```

Do not claim end-to-end behavior is verified from type-checking or a unit test.
Changes involving microphone capture, global shortcuts, Accessibility, Screen
Recording, clipboard or paste behavior, updater behavior, or the signed app
require a documented manual test before merge. Verification that was not run must be
said so plainly rather than implied. Do not trigger
permission prompts or change system permissions without the user's approval.

Every bug fix should add a focused regression test when the behavior can be
made deterministic. Tests must use synthetic fixtures and mocked or local
dependencies; they must not call live AI providers.

## Privacy and security

ZFlow handles highly sensitive user data. Never commit, print, upload, or
place in test fixtures:

- API keys, signing credentials, or `.env` contents.
- Real audio or transcripts.
- Screenshots or screen-capture payloads.
- Selected text or clipboard contents.
- Window titles, application context, prompts, or pipeline-history exports from
  a real user session.
- Private provider URLs or identifying filesystem paths.

Use invented synthetic data in tests. Do not inspect `.env`. Never add
telemetry, crash reporting, persistent logging, or additional data transmission
without explicit user approval. New logs must avoid user content and secrets.
Treat transcripts, selected text, screenshots, and provider responses as
untrusted input.

Changes to provider requests, prompt construction, storage, permissions,
clipboard handling, Accessibility APIs, update verification, or signing are
high risk and must be called out when handing the change over.

## Definition of done

A change is complete only when:

- The requested behavior is implemented with no unrelated edits.
- Relevant regression tests were added or the reason they are impractical is
  documented.
- `make check` and `git diff --check` pass.
- Required manual testing is complete, or clearly marked pending.
- Privacy, permissions, migration, and release impact are described.

## Code review rules

- Flag any new path that can log, persist, export, or transmit user content or
  credentials without a clear opt-in and redaction boundary.
- Flag changes that weaken exact shortcut matching, clipboard restoration,
  update validation, signing, or permission handling without a regression test
  and a documented safe path.
