# Intent generation prompt (draft)

Goal: the local model (Qwen2.5-Coder, once it's swapped in for this job)
turns a transcript into ONE JSON object matching `Intent` in
`Sources/VoicePet/ActionGate.swift` -- never a raw script with no
metadata, because the gate can't classify what it can't see structured.

## System prompt

```
You turn a spoken command into a single JSON action for a macOS assistant.
Reply with ONLY the JSON object, nothing else -- no markdown fences, no
explanation.

Schema:
{
  "app": string,      // the macOS app this touches: "Mail", "Finder", "Messages", "Safari", "Notes", "Calendar", or "none" if it's just a question/chat with no action
  "action": string,   // one lowercase verb: read, compose_draft, send, delete, trash, move, create_folder, open_url, read_tabs, create, append, create_event, ...
  "target": string,   // what it's acting on, plainly: "email to dad", "file report.pdf", "event Tuesday 3pm"
  "script": string,   // AppleScript/JXA that performs it. Empty string if app is "none".
  "summary": string   // one short sentence a human would read in a confirmation popup, written in plain English, e.g. "Send Dad an email saying you'll be late."
}

Rules:
- If the request is ambiguous about WHICH item (which email, which file), ask
  a clarifying question instead -- reply with {"app":"none","action":"clarify","target":"","script":"","summary":"<your question>"}.
- Never invent an app or action outside the allowlist you're given.
- "action" must be a single lowercase snake_case verb, not a sentence.
- If it's destructive (delete/send/purchase/etc.) the script must still be
  fully generated -- you are NOT responsible for asking permission, the app
  does that after you reply. Just describe what would happen accurately in
  "summary" so the confirmation dialog is honest.
```

## Why structured JSON, not "just write me the AppleScript"

The gate (`ActionGate.evaluate`) has to answer three questions before
anything runs: which app, which verb, is that verb on the always-confirm
list. If the model just hands back a script, we'd need to parse AppleScript
to figure that out after the fact -- fragile and easy to get wrong exactly
where it matters most. Asking the model to self-report `app`/`action`
up front, then double-checking `action` against `Allowlist.alwaysConfirm`
in Swift (not trusting the model's word for it), is the two-layer check:
model classifies, code verifies.

## Still open

- Where in the pipeline does this replace/extend `Brain.chat()`? Probably a
  new `Brain.generateIntent(from:) -> Intent` method, called instead of
  `chat()` when the utterance looks like a command rather than
  conversation (or always, with "none/chat" as one of the possible
  actions -- simpler, avoids a second classifier).
- Confirmation UI: a real modal dialog (blocks until answered) vs. the pet
  saying the summary out loud and waiting for a second push-to-talk
  "yes"/"no". Voice confirmation is more in-character but a modal is safer
  (can't be misheard). Probably modal for v1.
- `AppleScriptRunner` itself doesn't exist yet -- needs `NSAppleScript` or
  `osascript` invocation, plus surfacing script errors back to the user
  instead of failing silently.
