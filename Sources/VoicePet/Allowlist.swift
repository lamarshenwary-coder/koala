import Foundation

/// The permission gate's config: which apps/actions/paths the koala may touch,
/// which actions always need a confirmation dialog no matter what, and which
/// are refused outright. This file is data, not logic -- see ActionGate.swift
/// for the code that actually enforces it.
///
/// Lives on disk at ~/Library/Application Support/VoicePet/allowlist.json so
/// it can be hand-edited or (later) shown in a settings UI. `Allowlist.default`
/// below is what ships if that file doesn't exist yet.
struct Allowlist: Codable {
    struct AppRule: Codable {
        var allowedActions: [String]
        /// Whether the person has this app switched on at all in the Apps
        /// settings. Off means ActionGate refuses everything for this app
        /// outright -- no dialog, no exceptions -- regardless of
        /// allowedActions or alwaysConfirm. Defaults to true so existing
        /// allowlist.json files (written before this field existed) don't
        /// suddenly disable every app on load.
        var enabled: Bool

        init(allowedActions: [String], enabled: Bool = true) {
            self.allowedActions = allowedActions
            self.enabled = enabled
        }

        private enum CodingKeys: String, CodingKey { case allowedActions, enabled }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            allowedActions = try c.decode([String].self, forKey: .allowedActions)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(allowedActions, forKey: .allowedActions)
            try c.encode(enabled, forKey: .enabled)
        }
    }

    var apps: [String: AppRule]
    var readPaths: [String]
    var writePaths: [String]

    /// Verbs that ALWAYS show a confirmation dialog before running, regardless
    /// of which app they're on or whether that app/action is otherwise
    /// allowlisted. This is the non-negotiable list. Do not add a settings
    /// toggle that can turn any of these off -- if a new destructive verb
    /// shows up later, add it here in code, don't make it configurable.
    static let alwaysConfirm: Set<String> = [
        "delete", "trash", "empty_trash", "send", "purchase", "buy",
        "pay", "checkout", "unsubscribe", "cancel_subscription"
    ]

    /// Verbs that are refused outright, no dialog, not something the
    /// generated script gets a chance to argue for. Below the confirm list:
    /// confirm gates destructive-but-legitimate actions, this is stuff
    /// that's just out of scope for a voice pet.
    static let neverAllowed: Set<String> = [
        "system_settings_change", "install_software", "sudo",
        "disable_security", "modify_allowlist", "format_disk"
    ]

    static let `default` = Allowlist(
        apps: [
            "Mail": AppRule(allowedActions: ["read", "compose_draft"]),
            "Messages": AppRule(allowedActions: ["read"]),
            "Finder": AppRule(allowedActions: ["read", "move", "create_folder"]),
            "Safari": AppRule(allowedActions: ["open_url", "read_tabs"]),
            "Notes": AppRule(allowedActions: ["read", "create", "append"]),
            "Calendar": AppRule(allowedActions: ["read", "create_event"])
        ],
        readPaths: ["~/Documents", "~/Desktop", "~/Downloads"],
        writePaths: ["~/Documents/Koala"]
    )

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoicePet", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("allowlist.json")
    }

    static func load() -> Allowlist {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Allowlist.self, from: data) else {
            let d = Allowlist.default
            d.save()
            return d
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Allowlist.fileURL)
    }

    /// Is `action` on `app` something the allowlist says yes to at all?
    /// (Doesn't account for always-confirm -- that's checked separately by
    /// the gate, because "allowed" and "allowed without asking" are different
    /// questions.)
    func permits(app: String, action: String) -> Bool {
        guard let rule = apps[app] else { return false }
        return rule.allowedActions.contains(action)
    }
}
