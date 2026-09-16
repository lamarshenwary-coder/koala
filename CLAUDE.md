# Working on this repo with Claude Code

This is Koala -- Lamar's personal, fully local macOS desktop pet. It does push-to-talk dictation,
on-device meeting notes, a small on-device "Mind" (facts + reminders it recalls), and voice-driven
control of other apps (open a URL in Safari, draft an email, make a note, etc.) through a
safety-gated AppleScript pipeline. Forked from github.com/Pyanov/frog, which was just dictation +
notes for a frog -- almost everything else here (app control, Mind, the Me tab, the allowlist UI,
dynamic voices) was built on top of that fork specifically for this project. Swift app in
`Sources/VoicePet/`, the pet itself is three.js in `web/src/main.js`. Bundle id
`ai.learnvector.voicepet` (still `VoicePet` internally -- see Rules below on why that's staying).

See `docs/` and the Obsidian build retro for the fuller history/lessons-learned; this file is just
the working contract for making changes in this repo.

## The pet (web/src/main.js)

Edit only this file to change how the pet looks or animates. Keep this contract, everything else
is free:

- `window.pet.setState(name)` for `idle`, `listening`, `thinking`, `done`, `noting`, `confused`,
  `loading`, `sleeping`.
- `window.pet.setLevel(v)` with v in 0..1, the mic loudness while listening. The pet should
  visibly react to it.
- `window.pet.lookAt(x, y)` with x, y in -1..1, where the cursor is relative to the pet.
- `window.pet.setVelocity(x, y)` and `window.pet.setTalking(on)` -- both optional (called with
  `&&` guards from Swift), used by `Wander.swift` (idle wandering) and `Voice.swift` (TTS) respectively.
- `window.pet.setSounds(on)` -- toggles the pet's little sound effects (pop/gulp/ding/munch/huh/etc,
  see the bottom of `main.js`).
- Transparent canvas: `renderer.setClearColor(0, 0)` and `alpha: true`. The canvas is 260x300 CSS
  px (`W`, `H`), set in `index.html` and `PetPanel.size` in Swift. Change both if you change one.
- `?bg=1` paints a dark background for previews, `?demo=1` cycles states, `?state=name` forces one.

After editing, run `cd web && node tools/capture_local.cjs` and look at `web/shots/*.png` before
claiming it looks right -- it uses the local Playwright install (`PW_CHROMIUM` env, or
`/opt/pw-browsers/chromium`), unlike `capture.cjs` which is hardcoded to the upstream frog repo's
dev machine and won't run here. Then `./build.sh` and open `build/Koala.app` (or just launch it
from `/Applications` -- see build.sh notes below).

Design intent: cute, round, soft toon shading with a dark outline, squash-and-stretch on state
changes, always something moving (breathing, blinking, gaze). No UI chrome around the pet itself --
the Hub panel (below) is the only chrome in the app.

## Swift side

Build with `swift build -c release` or `./build.sh` (also builds the web bundle and assembles
`build/Koala.app`). No Xcode project; SwiftPM only. Language mode 5. **This repo is usually edited
over a cloud device-bridge (Claude Code/Cowork), which cannot compile Swift** -- every real build
and test has to happen in a real local Terminal; don't trust a "should compile" read of a diff,
and don't report something fixed until it's actually been rebuilt and run.

Key files, by feature:

- **Dictation**: `AppDelegate.startListening/stopListening` (push-to-talk via `fn`, see
  `HotkeyMonitor.swift`), `Transcriber` is the engine protocol (`AppleTranscriber` /
  `ParakeetTranscriber` implement it -- add new engines there), `Paster.swift` does the actual
  synthetic-paste insertion, `Store.swift` persists dictation history with a 1-hour auto-delete
  (opt-out, and failed-paste transcripts are exempt as "the only copy").
- **Meeting notes**: `Meeting.swift` (`MeetingRecorder`) + `SystemAudioTap.swift` (mic + system
  audio capture) + `Summarizer.swift` (Claude API or Apple Intelligence for the summary pass).
- **Mind**: `Mind.swift` -- facts and reminders the pet remembers about you, JSON in Application
  Support, separate from dictation history (which expires; Mind facts don't).
- **App control**: `IntentGenerator.swift` turns a transcript into a structured `Intent` JSON via a
  *separate* local LM Studio server (`localhost:1234`, OpenAI-compatible) -- not the on-device
  "Brain" (see Brain.swift), a completely different system, and the two are easy to confuse when
  debugging ("brain is broken" symptoms are often actually "LM Studio isn't running"). Intents only
  get real AppleScript for apps `IntentGenerator.swift`'s `systemPrompt` has an explicit worked
  example for (Mail, Messages, Finder, Safari, Notes, Calendar, Brave) -- never guess scripting for
  an app without one; "open"/activate is the one action that works for any named app with no
  worked example needed. `ActionGate.swift` gates every generated intent into `.run` / `.confirm` /
  `.refuse` against `Allowlist.swift` (per-app enabled actions, plus two hardcoded non-configurable
  safety floors: always-confirm for destructive-sounding verbs, never-allowed for system-level
  ones). `AppleScriptRunner.swift` actually executes an approved script.
- **Me tab / Hub.swift**: the SwiftUI settings UI (Notes / Words / Mind / Me tabs). The "Apps it
  can control" card is per-app, not universal -- `knownActionsByApp` maps each known app to only
  the actions that are actually meaningful (and actually have a worked example) for it; don't add
  an app/action pair there without a matching real worked example in `IntentGenerator.swift` first,
  or the toggle will silently do nothing when pressed. Folder read/write grants use a real
  `NSOpenPanel`, never a free-text path field.
- **Voice**: `Voice.swift` -- TTS voice list is built at runtime from
  `AVSpeechSynthesisVoice.speechVoices()`, not hardcoded, since novelty voices vary by what's
  actually installed on the Mac.
- Every state change the pet shows goes through `panel.js("pet.setState('...')")` (`PetPanel.swift`
  hosts the `WKWebView`).
- Permissions: Microphone, Speech Recognition, Accessibility (fn-key capture + typing), and System
  Audio Recording (meeting notes) -- usage strings live in `Resources/Info.plist`. App control adds
  a *separate*, per-target-app Automation permission macOS prompts for the first time a script
  actually controls that app (System Settings > Privacy & Security > Automation) -- this can't be
  pre-declared in Info.plist for apps not known in advance.
- Debug flags in `main.swift` run without the UI. Use them to test engines with a WAV instead of
  talking.

## build.sh specifics worth knowing before touching it

- Kills any already-running `Koala`/`VoicePet` process before rebuilding -- a stale instance with a
  now-invalid code signature otherwise just gets focused instead of replaced, which looks exactly
  like "the hotkey is dead" for no obvious reason.
- `xattr -cr` on the built `.app` before signing, every time -- files that pass through SwiftPM
  deps, npm, or the cloud device-bridge tend to pick up a quarantine flag, which triggers macOS
  "app translocation" (random read-only temp path per launch) and makes every launch look like a
  brand-new app to TCC, silently dropping Accessibility/Mic/Speech grants.
- Signs with the local "VoicePet Dev" identity if present (keeps TCC grants stable across
  rebuilds), otherwise falls back to ad-hoc (grants reset every rebuild -- expected but annoying;
  worth actually creating a stable identity in Keychain if this keeps biting).
- Installs to `/Applications/Koala.app` via `ditto` (not `cp -R`, which can drop the signature/xattrs
  on some macOS versions), then makes `build/Koala.app` a symlink to it. Never let both be real,
  independently-launchable bundles -- TCC grants are tracked per bundle *path*, not just signature,
  so two real copies means re-earning permissions depending on which one you happen to launch.
  Install failure is non-fatal (doesn't trip `set -e`) since a build can succeed even if the
  install step can't grab a briefly-in-use target.

## Rules

- Never commit `build/`, `.build/`, `web/dist*`, `web/shots/`, `web/node_modules/`.
- Don't rename the bundle id `ai.learnvector.voicepet`, and don't rename the internal executable
  target away from `VoicePet` (Info.plist's `CFBundleExecutable`, the codesign identity name,
  `build.sh`'s process-kill match) without updating every place that references it -- macOS
  permissions and the stale-process kill are both keyed on these.
- The pet is `web/src/main.js`. It's a koala on this fork (was a frog upstream) -- keep it a koala
  unless asked for another creature; if asked, only `main.js` needs to change (see contract above).
- Feature branches and pull requests, not pushes to main.
- Never fabricate an AppleScript worked example for app control. If an app has no real, tested
  pattern in `IntentGenerator.swift`, the honest answer is "open only" -- not a guess that might
  compile-fail or silently no-op at runtime.
