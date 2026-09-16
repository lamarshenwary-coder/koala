import Foundation

/// Talks to LM Studio's local OpenAI-compatible server (Local Model API,
/// http://localhost:1234/v1 by default) to turn a transcript into a
/// structured Intent. This is the prototyping path: LM Studio has to be
/// running with its server on. Once this pipeline is proven out, swap this
/// for an in-process MLX Swift call so the app doesn't depend on a separate
/// app being open -- see the note at the bottom of this file.
enum IntentGenerator {
    /// Set this to whatever LM Studio's "Loaded Instances" panel shows as the
    /// model's id once you've loaded it (usually matches the folder name,
    /// e.g. "qwen3-4b-instruct-2507"). With "Just-in-time model loading" on,
    /// LM Studio will also load it on demand if it isn't already.
    static var modelID = "qwen/qwen3-4b-2507"
    static var baseURL = URL(string: "http://localhost:1234/v1/chat/completions")!

    static let systemPrompt = """
    You turn a spoken command into a single JSON action for a macOS assistant.
    Reply with ONLY the JSON object, nothing else -- no markdown fences, no explanation.

    Schema:
    {
      "app": string,      // the macOS app this touches: "Mail", "Finder", "Messages", "Safari", "Notes", "Calendar", "Brave", or "none" if it's just a question/chat with no action
      "action": string,   // one lowercase verb: open, read, compose_draft, send, delete, trash, move, create_folder, open_url, read_tabs, create, append, create_event, clarify -- use "open" for just launching/switching to the app itself, "open_url" only when a specific site/page is named
      "target": string,   // what it's acting on, plainly: "email to dad", "file report.pdf", "event Tuesday 3pm"
      "script": string,   // AppleScript/JXA that performs it. Empty string if app is "none" or action is "clarify".
      "summary": string   // one short sentence a human would read in a confirmation popup, e.g. "Send Dad an email saying you'll be late."
    }

    Rules:
    - If the request is ambiguous about WHICH item (which email, which file), reply with {"app":"none","action":"clarify","target":"","script":"","summary":"<your question>"} instead of guessing.
    - Never invent an app or action outside: Mail, Messages, Finder, Safari, Notes, Calendar, Brave, none -- EXCEPT for action "open" (just launching/switching to an app, nothing else), which may target ANY real macOS application by its actual name (e.g. "Notion Calendar", "Spotify", "Discord", "Notion"), since "tell application \\"<name>\\" to activate" works for any installed app and needs no special per-app knowledge. Every OTHER action (read, compose_draft, create_event, open_url, etc.) still requires one of these seven known apps -- don't guess app-specific scripting for an app you don't have worked examples for. Brave only has one worked example (open_url below) -- treat every other action on Brave as unsupported, same as any other custom app.
    - "action" must be a single lowercase snake_case verb, not a sentence.
    - Destructive actions (delete/send/etc.) still get a fully generated script -- you are not responsible for asking permission, the app does that after you reply. Just describe accurately in "summary".
    - If the speaker spells out or corrects part of a name/word ("Shenwari with a Y at the end", "that's Smith with an E", "spelled S-M-I-T-H"), apply that correction directly to the actual value it belongs to (the email address, the name, the search term) everywhere it's used in "target" and "script". Never append the correction letter/word as extra literal text somewhere else (e.g. never tack a stray "Y" onto a subject line or file name) -- that is always wrong.

    Worked examples (copy these AppleScript patterns exactly, only swapping the URL/text -- "make new tab with URL" and similar guessed syntax does NOT compile in Safari and will fail):
    - "open Safari" -> {"app":"Safari","action":"open","target":"","script":"tell application \\"Safari\\" to activate","summary":"Open Safari."}
    - "open Notion Calendar" / "launch Spotify" -> {"app":"Notion Calendar","action":"open","target":"","script":"tell application \\"Notion Calendar\\" to activate","summary":"Open Notion Calendar."} -- same pattern for any named app, not just the six known ones.
    - "search google for cats" / "open a safari tab and search for X" -> {"app":"Safari","action":"open_url","target":"https://www.google.com/search?q=cats","script":"tell application \\"Safari\\" to make new document with properties {URL:\\"https://www.google.com/search?q=cats\\"}","summary":"Search Google for \\"cats\\" in Safari."}
    - "go to apple.com" -> {"app":"Safari","action":"open_url","target":"https://www.apple.com","script":"tell application \\"Safari\\" to open location \\"https://www.apple.com\\"","summary":"Open apple.com in Safari."}
    For "open_url": always build a real https:// URL in "target" (turn a plain search phrase into a Google search URL with the query percent-encoded), and use one of the two Safari script patterns shown above -- "make new document with properties {URL:...}" for a new tab, or "open location ..." to navigate the current one. Never write "make new tab with URL ...", it is not valid AppleScript.
    - "open a brave tab to nytimes.com" / "search brave for weather" -> {"app":"Brave","action":"open_url","target":"https://www.nytimes.com","script":"tell application \\"Brave Browser\\" to open location \\"https://www.nytimes.com\\"","summary":"Open nytimes.com in Brave."}
    For Brave (and other Chromium-based browsers, same pattern with the app name swapped): only "open location <url>" is a known-working AppleScript pattern -- Chromium browsers do not support Safari's "make new document with properties {URL:...}" syntax. Brave's actual bundle name is "Brave Browser", not "Brave" -- always use "Brave Browser" in the script even though "app" is "Brave". Only "open_url" (and "open"/activate) are supported for Brave -- there is no worked example for reading tabs, bookmarks, history, or anything else, so never generate a script for any other Brave action.
    - "compose an email to bob@example.com saying hi" -> {"app":"Mail","action":"compose_draft","target":"email to bob@example.com","script":"tell application \\"Mail\\"\\n\\tset newMsg to make new outgoing message with properties {subject:\\"Hi\\", content:\\"Hi Bob,\\"}\\n\\ttell newMsg\\n\\t\\tmake new to recipient at end of to recipients with properties {address:\\"bob@example.com\\"}\\n\\tend tell\\n\\tactivate\\nend tell","summary":"Draft an email to bob@example.com saying hi."}
    For Mail compose_draft/send: never write "make new message with properties {to:...}" -- Mail's dictionary has no "to" property on message creation and this fails to compile. Always use the pattern above: "make new outgoing message with properties {subject:..., content:...}", then inside a "tell newMsg" block add each recipient with "make new to recipient at end of to recipients with properties {address:...}". For "send" instead of "compose_draft", append "send" as its own line inside the outer "tell application \\"Mail\\"" block, after the "tell newMsg...end tell".
    - "make me a note about the plumber quote" / "write a note saying X" -> {"app":"Notes","action":"create","target":"note about the plumber quote","script":"tell application \\"Notes\\"\\n\\tmake new note with properties {body:\\"<div>Plumber Quote</div><div>Got a quote of $450 from the plumber for the bathroom leak.</div>\\"}\\n\\tactivate\\nend tell","summary":"Create a note about the plumber quote."}
    For Notes create: Notes bodies are HTML, and the FIRST block becomes the note's title in the Notes UI -- always repeat a short title as the first "<div>...</div>", then the full content as a second "<div>...</div>" (more paragraphs as more "<div>" blocks). Never specify an account or folder by name ("iCloud", "On My Mac") -- that folder may not exist on this Mac and the script will fail; "make new note with properties {body:...}" with no account/folder targets the default one and always works.
    """

    enum GenerateError: Error, CustomStringConvertible {
        case badResponse(status: Int, body: String), noContent, notJSON(String)
        var description: String {
            switch self {
            case .badResponse(let status, let body): return "HTTP \(status): \(body.prefix(300))"
            case .noContent: return "response had no choices[0].message.content"
            case .notJSON(let content): return "couldn't find {...} in: \(content.prefix(300))"
            }
        }
    }

    /// Turns a transcript into an Intent by calling the local model. Throws
    /// on network/parse failure; the caller should fall back to plain chat
    /// (Brain.chat) rather than silently doing nothing, since a person who
    /// gets no response at all will assume it's broken.
    static func generate(from transcript: String) async throws -> Intent {
        var req = URLRequest(url: baseURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The default is 60s. A wedged LM Studio would leave the user staring
        // at a stuck "transcribing" pill for a full minute with no feedback --
        // and this path is on every single hold-to-talk. Fail fast and fall
        // back to plain chat instead.
        req.timeoutInterval = 8
        let body: [String: Any] = [
            "model": modelID,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": transcript]
            ],
            "temperature": 0.2   // low: we want reliable JSON, not creative variation
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw GenerateError.badResponse(status: status, body: String(data: data, encoding: .utf8) ?? "<binary>")
        }

        guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = top["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw GenerateError.noContent }

        // The model was told to reply with JSON only, but small local models
        // occasionally wrap it in prose or a code fence anyway -- pull out
        // the outermost {...} rather than trusting the whole string parses.
        guard let a = content.firstIndex(of: "{"), let b = content.lastIndex(of: "}"), a < b,
              let jsonData = String(content[a...b]).data(using: .utf8) else { throw GenerateError.notJSON(content) }

        let intent = try JSONDecoder().decode(Intent.self, from: jsonData)

        // A real action with no script is worse than useless -- it either
        // silently no-ops or (if it slips past the gate) throws an
        // "AppleScriptRunner failed" error the user can't do anything
        // about. Treat it as a generation failure so the caller falls back
        // to plain chat instead of showing a hollow confirm dialog.
        if intent.app.lowercased() != "none", intent.action != "clarify", intent.script.trimmingCharacters(in: .whitespaces).isEmpty {
            throw GenerateError.notJSON("action \"\(intent.action)\" with empty script: \(content)")
        }
        return intent
    }
}

/*
 Wiring this into AppDelegate (draft -- decide for real in the Terminal session):

 Right now `startTalk`/`stopTalk` always calls `brain.chat(said)`, which is
 pure persona conversation through the in-process llama.cpp model. Command
 handling needs to be a fork on the transcript, not a replacement:

 func stopTalk() {
     ...
     let said = try await engine.transcribe(samples)
     if let intent = try? await IntentGenerator.generate(from: said), intent.app != "none" {
         switch ActionGate.evaluate(intent) {
         case .run:
             AppleScriptRunner.run(intent.script) { result in ... }
         case .confirm(let reason):
             showConfirmDialog(reason) { approved in
                 ActionGate.log(intent, decision: approved ? "confirmed" : "denied")
                 if approved { AppleScriptRunner.run(intent.script) { result in ... } }
             }
         case .refuse(let reason):
             voice.say(reason, force: true)
         }
     } else {
         // fall through to today's persona chat
         let reply = await brain.chat(said)
         voice.say(reply ?? "Mm.", force: true)
     }
 }

 Two real decisions to make on-device, not here:
 1. Every utterance costs an extra network round-trip to LM Studio before
    falling back to chat -- on a slow reply this could make dictation-only
    use feel laggier. Worth benchmarking with `Verbose logs` in LM Studio's
    Local Model API panel before deciding whether intent-detection runs on
    every hold-to-talk, or only when a separate hotkey/wake-phrase is used.
 2. IntentGenerator hits localhost:1234 unconditionally right now -- if LM
    Studio isn't running, this fails closed (falls back to chat), which is
    the safe default. Keep it that way; don't add a retry loop that could
    make a held-down key feel stuck.
*/
