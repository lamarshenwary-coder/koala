import AppKit

/// Executes a generated AppleScript/JXA string. This is the very last step
/// after ActionGate has already said yes (auto-run or confirmed) -- nothing
/// else in the app should call NSAppleScript directly.
enum AppleScriptRunner {
    enum RunResult { case ok(String), failed(String) }

    /// Runs synchronously off the main thread (NSAppleScript is blocking),
    /// hops back to main for the completion handler.
    static func run(_ script: String, completion: @escaping (RunResult) -> Void) {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            DispatchQueue.main.async { completion(.failed("no script to run")) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var errorDict: NSDictionary?
            guard let appleScript = NSAppleScript(source: script) else {
                DispatchQueue.main.async { completion(.failed("couldn't parse script")) }
                return
            }
            let result = appleScript.executeAndReturnError(&errorDict)
            DispatchQueue.main.async {
                if let errorDict {
                    let msg = errorDict[NSAppleScript.errorMessage] as? String ?? "unknown AppleScript error"
                    completion(.failed(msg))
                } else {
                    completion(.ok(result.stringValue ?? ""))
                }
            }
        }
    }
}

/// A blocking, modal yes/no dialog for actions ActionGate wants confirmed.
/// Modal is the right call for v1 over a spoken confirmation: it can't be
/// misheard, and delete/send/purchase should never turn on a misrecognized
/// "yes".
@MainActor
enum ConfirmDialog {
    static func ask(_ summary: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Koala wants to do this:"
        alert.informativeText = summary
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Do it")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
