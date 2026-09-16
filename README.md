<p align="center"><img src="docs/koala-idle.png" width="400" alt="The koala"></p>

<h1 align="center">Koala</h1>

<p align="center">Lamar's personal, fully local, hands-free voice assistant for the Mac.<br>Forked from <a href="https://github.com/Pyanov/frog">Pyanov/frog</a> and being built up into something that can control the machine, not just type into it.</p>

Hold **fn** and talk. The koala types what you say into whatever is in front of you: a Claude Code prompt, a terminal, an email. Let go and the text is there. Start it before a call and it takes the notes: who said what, and a summary to read afterwards. Hold **right ⌥ Option** and talk to it. It answers out loud, remembers what you tell it, and keeps you company while you work. It's asleep whenever you're not using it.

Everything runs on this Mac. Speech recognition, speaker labels, and the koala's brain are local models, downloaded once. Nothing you say leaves the machine.

## What it does today

- **Dictation anywhere.** Hold fn, speak, release. The text lands where your cursor is.
- **Meeting notes.** Right-click the koala → Notes → Start before a call. It records you and the other side with a native Core Audio process tap (no BlackHole, no virtual audio device, no Multi-Output Device to configure by hand), transcribes both, labels the speakers, and writes a summary.
- **A koala to talk to.** Hold right Option and say something. It talks back, remembers facts, and sets reminders, which it says aloud when due.
- **It sleeps when you're not using it.** No dictation, meeting, or chat for a while (`sleepAfterSeconds` in `AppDelegate.swift`, default 3 minutes) and it dozes off; anything that counts as "using it" wakes it straight back up.
- **Words.** Teach it names and jargon. It suggests words it keeps hearing, and correcting a dictation teaches it.
- A small koala in the menu bar hides or shows it, opens Notes and settings, and quits.

## Where this is headed

The end goal isn't dictation, it's hands-free control of the Mac itself: hold a key, say what you want done, have it actually happen -- gated behind an explicit allowlist of what apps/actions/folders it's allowed to touch. None of that exists yet. Today this is still just a (very good) dictation + meeting-notes app. See `CLAUDE.md` for the shape of what's being added.

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

The pet is one three.js file, `web/src/main.js`. `CLAUDE.md` explains the small contract the app expects (`pet.setState`, `pet.setLevel`, `pet.lookAt`, plus optional `setVelocity`, `setTalking`). Personas for the brain live in `Sources/VoicePet/Brain.swift`.

## Under the hood

Swift/AppKit app built with SwiftPM. Apple SpeechAnalyzer or Parakeet v3 for speech, FluidAudio for diarization, llama.cpp via LLM.swift for the brain (Gemma 4 GGUFs from Unsloth), Apple Foundation Models for summaries, AVSpeechSynthesizer for the voice, a WKWebView with three.js for the pet. Notes, vocabulary, memory, and models live in `~/Library/Application Support/VoicePet/`.

## License

MIT, same as upstream.
