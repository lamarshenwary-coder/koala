<p align="center">
  <img src="docs/koala-idle.png" width="340" alt="The koala">
  <img src="docs/koala-app-icon.png" width="120" alt="Koala app icon">
</p>

<h1 align="center">Koala</h1>

<p align="center">Lamar's personal, fully local, hands-free voice assistant for the Mac.<br>Forked from <a href="https://github.com/Pyanov/frog">Pyanov/frog</a>: dictation, meeting notes, a koala to talk to, and allowlist-gated voice control of other apps.</p>

Hold **fn** and talk. The koala types what you say into whatever is in front of you: a Claude Code prompt, a terminal, an email. Let go and the text is there. Start it before a call and it takes the notes: who said what, and a summary to read afterwards. Hold **right ⌥ Option** and talk to it. It answers out loud, remembers what you tell it, and keeps you company while you work. It's asleep whenever you're not using it.

Everything runs on this Mac. Speech recognition, speaker labels, and the koala's brain are local models, downloaded once. Nothing you say leaves the machine.

## What it does today

- **Dictation anywhere.** Hold fn, speak, release. The text lands where your cursor is.
- **Meeting notes.** Menu bar koala → Notes & settings → Notes → Start, before a call. (Right-clicking the koala itself opens the same window, when it's on screen -- see the note below about it starting hidden.) It records you and the other side with a native Core Audio process tap (no BlackHole, no virtual audio device, no Multi-Output Device to configure by hand), transcribes both, labels the speakers, and writes a summary.
- **A koala to talk to.** Hold right Option and say something. It talks back, remembers facts, and sets reminders, which it says aloud when due.
- **It sleeps when you're not using it.** No dictation, meeting, or chat for a while (`sleepAfterSeconds` in `AppDelegate.swift`, default 3 minutes) and it dozes off; anything that counts as "using it" wakes it straight back up.
- **Words.** Teach it names and jargon. It suggests words it keeps hearing, and correcting a dictation teaches it.
- A small koala in the menu bar hides or shows it, opens Notes and settings, toggles wandering/voice/sounds, and quits.
- **The koala itself starts hidden right now.** The panel is deliberately not shown at launch while the app-control pipeline is being worked on (see the comment in `applicationDidFinishLaunching`); the menu bar item's "Show the koala" brings it up. Hotkeys, dictation, notes, and app control all work either way.

## Controlling apps by voice

Hold right Option and ask for something concrete -- "open Spotify," "make me a note about the plumber quote," "email dad I'll be late" -- and it does it, not just talks about it. This part is built and working, not a roadmap item:

1. What you said gets turned into a structured action (`{app, action, target, script, summary}`) by a local model.
2. That action is checked against an **allowlist** before anything touches your Mac -- every app, every action, every read/write path it's permitted to use is explicit, nothing is allowed by default.
3. Depending on what the allowlist says, it either runs immediately, asks you to confirm first, or refuses outright with no dialog at all.

The default allowlist:

| App | Allowed actions |
|---|---|
| Mail | read, compose_draft |
| Messages | read |
| Finder | read, move, create_folder |
| Safari | open_url, read_tabs |
| Notes | read, create, append |
| Calendar | read, create_event |

Plus one blanket exception: "open X" (just launching/switching to an app) works for *any* installed app by name, not just the six above -- that action can't do anything but bring an app to the front, so it doesn't need to be enumerated per-app.

**One honest limitation:** turning speech into that structured action currently depends on [LM Studio](https://lmstudio.ai) running separately with its local server on (`localhost:1234`) -- see the comment at the top of `IntentGenerator.swift`. It's called "the prototyping path" in the code for a reason: the plan is to replace it with an in-process MLX Swift call so the app doesn't need a second app running to control anything. Until then, app control needs LM Studio open; dictation, meeting notes, and chat don't.

**Also worth knowing:** which Brain size you pick (Tiny/Quick/Smart/Genius, see below) has no effect on what actions it can do. The Brain and the app-control model are two separate systems -- Brain tier only changes chat/conversation quality, not the allowlist or what LM Studio is capable of generating.

### Customizing what it's allowed to do

The Me tab has an "Apps it can control" and a "Folders it can use" section for this -- no JSON editing needed for the common case:

- Turn any app fully on/off with a switch.
- Add any app by name (opens/switches to it by name -- see the note below on why that's the limit for a newly-added app).
- For the six built-in apps (Mail, Messages, Finder, Safari, Notes, Calendar), toggle exactly which actions each one is allowed to do -- read, compose_draft, send, delete, trash, move, create_folder, open_url, read_tabs, create, append, create_event -- as individual switches, not an all-or-nothing per app.
- Add or remove the folders it can read from and write to, picked through a real folder dialog rather than typed by hand, so a typo can't quietly grant access to the wrong place.

Every change there writes straight through to `~/Library/Application Support/VoicePet/allowlist.json`, so hand-editing that file still works too -- useful for bulk changes, or for actions beyond what's listed as a toggle (the UI only exposes the verbs IntentGenerator actually has worked-example scripting for; see `IntentGenerator.swift` if you're teaching it a new one). It's created with the defaults below the first time the app runs. Example of the raw format, adding Spotify playback actions by hand:

```json
{
  "apps": {
    "Spotify": { "allowedActions": ["open", "play", "pause", "next_track"], "enabled": true },
    "Mail": { "allowedActions": ["read", "compose_draft"], "enabled": true }
  },
  "readPaths": ["~/Documents", "~/Desktop", "~/Downloads", "~/Projects"],
  "writePaths": ["~/Documents/Koala"]
}
```

Two things stay fixed and are **not** in that file, on purpose:

- **Always-confirm verbs** -- `delete`, `trash`, `empty_trash`, `send`, `purchase`, `buy`, `pay`, `checkout`, `unsubscribe`, `cancel_subscription`. These ask before running no matter what the allowlist says, even for an app/action you've otherwise allowlisted.
- **Never-allowed verbs** -- `system_settings_change`, `install_software`, `sudo`, `disable_security`, `modify_allowlist`, `format_disk`. These refuse outright, no dialog, no exception. Nothing in `allowlist.json` can turn these back on.

That's deliberate, not an oversight: everything about *which apps and actions it can reach* is yours to open up as wide as you want, but the handful of genuinely destructive or self-defeating actions (a voice assistant that can edit its own permission file, for instance) are a hardcoded floor rather than a setting, because a misheard word or a bad transcription shouldn't be able to reach those. `ActionGate.swift` is short and readable if you want to see exactly what's checked before anything runs.

## The models

All on device, downloaded on first use.

| Job | Model |
|---|---|
| Speech to text | Apple's on-device speech model (SpeechAnalyzer). NVIDIA Parakeet TDT v3 (Core ML, via FluidAudio) is an option in Me. |
| Who said what | FluidAudio speaker diarization (Core ML). |
| The koala's brain | Gemma 4 through llama.cpp, picked by RAM: E4B (5 GB) on 16 GB Macs, 12B (7 GB) on 24 GB, 26B-A4B (17 GB) on 40 GB and up. Qwen2.5 1.5B (1 GB) is the tiny option. Swapping in Qwen2.5-Coder for the intent/action step is the next big change here. |
| Meeting summaries | Apple Intelligence's on-device model. Add a Claude API key in Me and it uses Claude instead; that's the one optional thing that leaves this Mac. |
| Voice | macOS system voice (AVSpeechSynthesizer). Pick another in Me. |

## Build from source

```bash
cd web && npm install && cd ..
./build.sh && cp -R build/Koala.app ~/Applications/ && open ~/Applications/Koala.app
```

Xcode Command Line Tools and Node 18+ are enough; no Xcode needed. The first build compiles llama.cpp and takes a few minutes.

First launch: macOS will say it's from an unidentified developer -- System Settings › Privacy & Security › **Open Anyway**, once. Grant Microphone, Speech Recognition, and Accessibility when asked. Set System Settings › Keyboard › "Press 🌐 key to" → **Do Nothing**, or fn also opens the emoji picker. Needs macOS 26 on Apple Silicon.

## Make it your own creature

The pet is one three.js file, `web/src/main.js`. `CLAUDE.md` explains the small contract the app expects (`pet.setState`, `pet.setLevel`, `pet.lookAt`, `pet.setSounds`, plus optional `setTalking` and `setVelocity` -- the koala implements `setTalking` but not `setVelocity`, and Swift calls both behind `&&` guards). Personas for the brain live in `Sources/VoicePet/Brain.swift`.

## Under the hood

Swift/AppKit app built with SwiftPM. Apple SpeechAnalyzer or Parakeet v3 for speech, FluidAudio for diarization, llama.cpp via LLM.swift for the brain (Gemma 4 GGUFs from Unsloth), Apple Foundation Models for summaries, AVSpeechSynthesizer for the voice, a WKWebView with three.js for the pet. Notes, vocabulary, memory, and models live in `~/Library/Application Support/VoicePet/`.

## License

MIT, same as upstream.
