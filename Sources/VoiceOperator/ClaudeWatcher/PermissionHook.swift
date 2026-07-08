import Foundation

/// Installs/removes VoiceOperator's Claude Code `PermissionRequest` hook and owns
/// the paths it uses.
///
/// The hook is a PURE OBSERVER: it drops each permission-request payload into a
/// spool directory and always exits 0, writing nothing to stdout — so it can
/// never approve, deny, block, or delay a Claude permission prompt, and it works
/// whether or not VoiceOperator is running.
///
/// The PRESENCE of our entry in `~/.claude/settings.json` is the feature's on/off
/// state — there is no separate persisted flag that could drift out of sync. We
/// never force-install on launch and never silently re-add ourselves after an
/// external removal; the menu checkbox simply reflects the file.
enum PermissionHook {
    enum HookError: Error { case malformed }

    /// Substring that identifies our hook command in settings.json. Robust to the
    /// space in "Application Support" and to the app bundle being moved.
    static let marker = "VoiceOperator/hooks/permission-hook.sh"

    static var scriptURL: URL {
        HistoryStore.supportDir.appendingPathComponent("hooks/permission-hook.sh")
    }
    static var spoolDir: URL {
        HistoryStore.supportDir.appendingPathComponent("permission-spool", isDirectory: true)
    }
    static var settingsURL: URL {
        URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json"))
    }

    // MARK: - Hook script

    // NOTE: `\\n` becomes a literal backslash-n in the emitted script (printf's
    // newline). Everything else is plain sh; no Swift interpolation is used.
    private static let scriptBody = """
    #!/bin/sh
    # VoiceOperator PermissionRequest hook — PURE OBSERVER.
    # Always exits 0 and writes nothing to stdout, so it can never approve, deny,
    # block, or delay a Claude permission prompt. It only drops the hook payload
    # into VoiceOperator's spool for narration and does not require VoiceOperator
    # to be running.
    payload=$(cat)                        # always drain stdin
    SPOOL="$HOME/Library/Application Support/VoiceOperator/permission-spool"
    {
      mkdir -p "$SPOOL"
      count=$(ls "$SPOOL" 2>/dev/null | wc -l)
      if [ "$count" -lt 100 ]; then       # bound the spool if VO isn't draining it
        tmp=$(mktemp "$SPOOL/tmp.XXXXXX")
        printf '{"receivedAt":%s,"payload":%s}\\n' "$(date +%s)" "$payload" > "$tmp"
        mv "$tmp" "$SPOOL/$(date +%s)-$(basename "$tmp").json"
      fi
    } 2>/dev/null || true
    exit 0
    """

    /// Write (or refresh) the hook script and make it executable. Cheap; called on
    /// launch only when the hook is already installed, and by `install()`.
    static func ensureScriptInstalled() throws {
        let url = scriptURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try scriptBody.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - settings.json (source of truth for on/off)

    /// Whether our hook is currently registered. A missing or unparseable settings
    /// file reads as "not installed" (we never guess when we can't read the file).
    static func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return hasHook(in: obj)
    }

    /// Register the hook: write the script, then add our entry to settings.json
    /// (idempotent). Never clobbers a settings file we can't parse.
    static func install() throws {
        try ensureScriptInstalled()
        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let data = try Data(contentsOf: settingsURL)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HookError.malformed
            }
            settings = obj
        }
        guard !hasHook(in: settings) else { return }
        try writeSettings(addHook(to: settings, command: hookCommand))
    }

    /// Remove only our entry from settings.json, leaving any other hooks intact.
    /// The script file is left in place (harmless once unreferenced).
    static func uninstall() throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let data = try Data(contentsOf: settingsURL)
        guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookError.malformed
        }
        try writeSettings(removeHook(from: settings))
    }

    /// The command string we register — the absolute script path, single-quoted so
    /// the space in "Application Support" survives the shell.
    static var hookCommand: String { "'\(scriptURL.path)'" }

    // MARK: - Pure settings transforms (unit-tested)

    static func hasHook(in settings: [String: Any]) -> Bool {
        permissionCommands(in: settings).contains { $0.contains(marker) }
    }

    static func addHook(to settings: [String: Any], command: String) -> [String: Any] {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var groups = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        groups.append(["hooks": [["type": "command", "command": command, "timeout": 5]]])
        hooks["PermissionRequest"] = groups
        settings["hooks"] = hooks
        return settings
    }

    static func removeHook(from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any],
              let groups = hooks["PermissionRequest"] as? [[String: Any]] else { return settings }
        let pruned: [[String: Any]] = groups.compactMap { group in
            guard var hs = group["hooks"] as? [[String: Any]] else { return group }
            hs.removeAll { ($0["command"] as? String)?.contains(marker) == true }
            if hs.isEmpty { return nil }        // drop a now-empty matcher group
            var g = group; g["hooks"] = hs; return g
        }
        if pruned.isEmpty { hooks["PermissionRequest"] = nil } else { hooks["PermissionRequest"] = pruned }
        if hooks.isEmpty { settings["hooks"] = nil } else { settings["hooks"] = hooks }
        return settings
    }

    private static func permissionCommands(in settings: [String: Any]) -> [String] {
        guard let hooks = settings["hooks"] as? [String: Any],
              let groups = hooks["PermissionRequest"] as? [[String: Any]] else { return [] }
        return groups.flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        if let existing = try? Data(contentsOf: settingsURL) {   // keep a one-deep backup
            try? existing.write(to: settingsURL.appendingPathExtension("vo-bak"))
        }
        try data.write(to: settingsURL, options: .atomic)
    }
}
