import Foundation

/// A single generated action, as the local LLM should emit it: structured
/// JSON, not a raw script we have to guess the intent of. Ask the model for
/// exactly this shape (see docs/intent-prompt-template.md) so the gate below
/// has something reliable to check *before* any AppleScript/JXA runs.
struct Intent: Codable {
    var app: String          // "Mail", "Finder", "Messages", ...
    var action: String       // "send", "delete", "read", "compose_draft", ...
    var target: String       // human-readable summary of what it's acting on
    var script: String       // the actual AppleScript/JXA to run if approved
    var summary: String      // one line for the confirmation dialog / log, e.g. "Email dad: 'On my way'"
}

enum GateDecision {
    case run                                   // fine, execute immediately
    case confirm(reason: String)               // show a dialog, wait for yes
    case refuse(reason: String)                // never runs, no dialog
}

/// The thing that stands between "the model generated a script" and "the
/// script touched the Mac." Every generated Intent goes through here first.
/// No exceptions, no fast path that skips this for any app.
@MainActor
enum ActionGate {
    /// Every `tell application "X"` target named anywhere in a script.
    /// AppleScript can address more than one app in a single script, so this
    /// returns all of them, not just the first.
    static func scriptAppTargets(_ script: String) -> [String] {
        let ns = script as NSString
        guard let re = try? NSRegularExpression(pattern: "tell\\s+application\\s+(?:id\\s+)?\"([^\"]+)\"", options: [.caseInsensitive]) else { return [] }
        var out: [String] = []
        re.enumerateMatches(in: script, options: [], range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges > 1 else { return }
            out.append(ns.substring(with: m.range(at: 1)))
        }
        return out
    }

    /// Things a generated script must never do, whatever it claims its action
    /// is. `do shell script` in particular turns the whole allowlist into
    /// decoration, since it can run anything at all.
    static let forbiddenInScript = ["do shell script", "do javascript", "system attribute", "administrator privileges"]

    /// Destructive things that, if present in the script body, mean the script
    /// does more than its declared `action` admits -- so it gets a dialog even
    /// if the declared verb was something innocuous.
    static let destructiveInScript = ["delete", "empty trash", "move to trash", "erase", " send", "shut down", "restart", "log out"]

    static func firstMatch(_ needles: [String], in script: String) -> String? {
        let lower = script.lowercased()
        return needles.first { lower.contains($0) }
    }

    static func evaluate(_ intent: Intent, allowlist: Allowlist = .load()) -> GateDecision {
        let action = intent.action.lowercased()

        // 0. Look at the SCRIPT, not just at what the model said about itself.
        // `intent.app` and `intent.action` are strings a local model wrote; the
        // script is the thing that actually touches the Mac. Without this,
        // {"app":"Notes","action":"read"} carrying a script full of
        // `tell application "Mail" ... delete ...` sailed straight through
        // rules 1-4 and auto-ran with no dialog at all.
        if !intent.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let bad = firstMatch(Self.forbiddenInScript, in: intent.script) {
                log(intent, decision: "refused (script contains \(bad))")
                return .refuse(reason: "That script wanted to run \(bad), which I'm never allowed to do.")
            }
            // Every app the script addresses must be the one the intent declared.
            let declared = intent.app.lowercased()
            let strays = Self.scriptAppTargets(intent.script).filter { $0.lowercased() != declared }
            if let stray = strays.first {
                log(intent, decision: "refused (script targets \(stray), declared \(intent.app))")
                return .refuse(reason: "That script said it was for \(intent.app) but actually targets \(stray). I won't run it.")
            }
        }

        // 1. Hard wall. Not confirmable, not configurable.
        if Allowlist.neverAllowed.contains(action) {
            log(intent, decision: "refused")
            return .refuse(reason: "\(intent.action) is not something I'm allowed to do.")
        }

        // 1.5. The person switched this whole app off in the Apps settings.
        // That's a deliberate "never touch this app" choice -- it overrides
        // even alwaysConfirm (delete/send/etc.), no dialog, just refuse.
        // Apps not present in the allowlist at all (e.g. a generically-named
        // third-party app opened via the "open" exception in IntentGenerator)
        // aren't affected by this -- they fall through to the confirm-by-
        // default rule below, same as before.
        if let rule = allowlist.apps[intent.app], !rule.enabled {
            log(intent, decision: "refused (app disabled)")
            return .refuse(reason: "\(intent.app) is turned off in my app permissions.")
        }

        // 2. Non-negotiable per Lamar: delete / send / purchase (and friends)
        // always confirm, even if the app+action is otherwise allowlisted.
        if Allowlist.alwaysConfirm.contains(action) {
            return .confirm(reason: intent.summary)
        }

        // 3. Not in the allowlist at all for this app -> ask, don't refuse
        // outright, in case it's a reasonable thing that just isn't
        // enumerated yet. (Flip this to .refuse if that's ever abused.)
        guard allowlist.permits(app: intent.app, action: action) else {
            return .confirm(reason: "\(intent.app) isn't on the allowlist for \"\(intent.action)\" yet. \(intent.summary)")
        }

        // 4. Allowlisted by verb -- but only auto-run if the script body agrees
        // that this is harmless. A script that quietly deletes or sends while
        // declaring itself a "read" gets a dialog rather than a free pass.
        if let verb = Self.firstMatch(Self.destructiveInScript, in: intent.script) {
            log(intent, decision: "escalated to confirm (script contains \(verb.trimmingCharacters(in: .whitespaces)))")
            return .confirm(reason: "\(intent.summary)\n\nHeads up: the script also does \"\(verb.trimmingCharacters(in: .whitespaces))\", which isn't what it called itself.")
        }
        log(intent, decision: "auto-run")
        return .run
    }

    /// Every decision gets written down: what was asked, what was generated,
    /// and what happened to it. This is the audit trail if something ever
    /// does the wrong thing.
    static func log(_ intent: Intent, decision: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoicePet", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let logURL = base.appendingPathComponent("action_log.jsonl")

        struct Entry: Codable {
            var timestamp: String
            var app: String
            var action: String
            var target: String
            var summary: String
            var decision: String
        }
        let entry = Entry(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            app: intent.app, action: intent.action, target: intent.target,
            summary: intent.summary, decision: decision
        )
        guard let data = try? JSONEncoder().encode(entry),
              let line = String(data: data, encoding: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            // defer, so the descriptor is closed even if seek/write throws an
            // ObjC exception (disk full, file yanked) on the way through.
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write((line + "\n").data(using: .utf8)!)
        } else {
            try? (line + "\n").write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
}

/*
 Wiring this in, once there's an actual "run a generated intent" call site:

 let intent = try await brain.generateIntent(from: transcript)   // TODO: doesn't exist yet
 switch ActionGate.evaluate(intent) {
 case .run:
     AppleScriptRunner.run(intent.script)
     ActionGate.log(intent, decision: "auto-run")
 case .confirm(let reason):
     panel.js("pet.setState('confused')")   // or a dedicated "asking" state
     confirmDialog(reason) { approved in
         ActionGate.log(intent, decision: approved ? "confirmed" : "denied")
         if approved { AppleScriptRunner.run(intent.script) }
     }
 case .refuse(let reason):
     ActionGate.log(intent, decision: "refused")
     voice.say(reason, force: true)
 }
*/
