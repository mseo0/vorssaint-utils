// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// The plan limits Claude Code itself reports. With every reply it hands its
/// status line the share of the 5-hour session and of the week used so far,
/// and the exact moment each renews. Once connected, a small status line
/// script keeps the latest of those on this Mac for Vorssaint to read, then
/// runs whatever status line the person had before. Nothing is sent anywhere.
///
/// Connecting changes `statusLine` in `~/.claude/settings.json`, keeps a copy
/// of the file beside it, and disconnecting puts the earlier status line back.
enum AgentClaudeCodeLimits {
    /// Readings older than this say little about the week, let alone the
    /// session: the Claude app's are preferred then, when it has any.
    static let maximumAge: TimeInterval = 7 * 86_400
    private static let maximumSize = 1 << 20

    /// One folder for every variant of the app, since Claude Code runs only
    /// one status line.
    static func folder(home: URL) -> URL {
        home.appending(path: "Library/Application Support/Vorssaint/ClaudeCode", directoryHint: .isDirectory)
    }

    static func readingURL(home: URL) -> URL { folder(home: home).appending(path: "limits.json") }
    static func scriptURL(home: URL) -> URL { folder(home: home).appending(path: "statusline.sh") }
    private static func previousCommandURL(home: URL) -> URL { folder(home: home).appending(path: "previous-command") }
    private static func previousStatusLineURL(home: URL) -> URL {
        folder(home: home).appending(path: "previous-statusline.json")
    }

    static func settingsURL(home: URL) -> URL { home.appending(path: ".claude/settings.json") }

    // MARK: Reading

    /// The latest reading Claude Code reported, or nil when it never did or
    /// the reading is too old to trust.
    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date) -> AgentLimits? {
        let url = readingURL(home: home)
        guard let modified = modified(home: home),
              let data = try? Data(contentsOf: url) else { return nil }
        return limits(from: data, observedAt: modified, now: now)
    }

    /// When Claude Code last reported its limits; nil when it never has.
    static func modified(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Date? {
        (try? readingURL(home: home).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// The windows in a status line input. A window that renewed since the
    /// reading has spent an unknown amount since, so it is left out, as
    /// Claude Code itself does.
    static func limits(from data: Data, observedAt: Date, now: Date) -> AgentLimits? {
        guard data.count <= maximumSize, now.timeIntervalSince(observedAt) < maximumAge,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rates = json["rate_limits"] as? [String: Any] else { return nil }
        let known: [(key: String, id: String, kind: AgentLimitWindow.Kind, minutes: Int)] = [
            ("five_hour", "claude.fh", .session, 300), ("seven_day", "claude.sd", .weekly, 10_080)]
        var windows: [AgentLimitWindow] = []
        for window in known {
            guard let entry = rates[window.key] as? [String: Any],
                  let used = number(entry["used_percentage"]) else { continue }
            let resets = number(entry["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            if let resets, resets <= now { continue }
            // Without a renewal a session older than its length has renewed.
            if resets == nil, now.timeIntervalSince(observedAt) >= TimeInterval(window.minutes) * 60 { continue }
            windows.append(AgentLimitWindow(id: window.id, kind: window.kind, minutes: window.minutes, scope: nil,
                                            usedPercent: min(100, max(0, used)), resetsAt: resets))
        }
        guard !windows.isEmpty else { return nil }
        return AgentLimits(provider: .claude, windows: windows, observedAt: observedAt, source: .claudeCode)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    /// Claude Code's reading for the windows it reports, and the Claude app's
    /// for the rest, such as the weekly Opus and Sonnet shares. Where both
    /// report a window, the newer share wins, as use elsewhere moves it, but
    /// the renewal stays Claude Code's: the app's is an estimate, and one
    /// still ahead means the window has not renewed since.
    static func merged(_ code: AgentLimits?, _ app: AgentLimits?) -> AgentLimits? {
        guard let code else { return app }
        guard let app else { return code }
        let (newer, older) = code.observedAt >= app.observedAt ? (code, app) : (app, code)
        var result = newer
        result.windows = newer.windows.map { window in
            guard let exact = code.windows.first(where: { $0.id == window.id })?.resetsAt else { return window }
            return AgentLimitWindow(id: window.id, kind: window.kind, minutes: window.minutes, scope: window.scope,
                                    usedPercent: window.usedPercent, resetsAt: exact)
        }
        let ids = Set(newer.windows.map(\.id))
        result.windows += older.windows.filter { !ids.contains($0.id) }
        return result
    }

    // MARK: Connecting

    enum Failure: Error, Equatable {
        /// `settings.json` holds something other than a JSON object.
        case unreadableSettings
        case writeFailed
    }

    /// The status line command, quoted for the shell Claude Code runs it in.
    static func command(home: URL) -> String {
        "'" + scriptURL(home: home).path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func isConnected(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard let settings = try? loadSettings(home: home),
              let line = settings["statusLine"] as? [String: Any],
              let command = line["command"] as? String else { return false }
        return isOurs(command, home: home)
    }

    private static func isOurs(_ command: String, home: URL) -> Bool {
        command.contains(scriptURL(home: home).path)
    }

    /// Writes the status line script and points Claude Code at it, keeping
    /// any status line already there running after it.
    static func connect(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        var settings = try loadSettings(home: home)
        let manager = FileManager.default
        let folder = folder(home: home)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(script.utf8).write(to: scriptURL(home: home), options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL(home: home).path)
        } catch {
            throw Failure.writeFailed
        }
        let existing = settings["statusLine"] as? [String: Any]
        let existingCommand = existing?["command"] as? String
        // Connecting again keeps the status line saved the first time.
        if existingCommand.map({ !isOurs($0, home: home) }) ?? true {
            do {
                if let existing {
                    let data = try JSONSerialization.data(withJSONObject: existing, options: [.sortedKeys])
                    try data.write(to: previousStatusLineURL(home: home), options: .atomic)
                } else {
                    try? manager.removeItem(at: previousStatusLineURL(home: home))
                }
                if let existingCommand, !existingCommand.isEmpty {
                    try Data(existingCommand.utf8).write(to: previousCommandURL(home: home), options: .atomic)
                } else {
                    try? manager.removeItem(at: previousCommandURL(home: home))
                }
            } catch {
                throw Failure.writeFailed
            }
        }
        // Its padding and other options stay as they were.
        var line = existing ?? [:]
        line["type"] = "command"
        line["command"] = command(home: home)
        settings["statusLine"] = line
        try save(settings, home: home)
    }

    /// Puts back the status line there was before connecting, or none.
    static func disconnect(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        var settings = try loadSettings(home: home)
        let manager = FileManager.default
        if let line = settings["statusLine"] as? [String: Any], let command = line["command"] as? String,
           isOurs(command, home: home) {
            if let data = try? Data(contentsOf: previousStatusLineURL(home: home)),
               let previous = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                settings["statusLine"] = previous
            } else {
                settings["statusLine"] = nil
            }
            try save(settings, home: home)
        }
        for url in [scriptURL(home: home), previousCommandURL(home: home), previousStatusLineURL(home: home),
                    readingURL(home: home)] {
            try? manager.removeItem(at: url)
        }
    }

    private static func loadSettings(home: URL) throws -> [String: Any] {
        let url = settingsURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadableSettings }
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return [:] }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.unreadableSettings
        }
        return object
    }

    /// Keeps the file as it was beside it before changing it.
    private static func save(_ settings: [String: Any], home: URL) throws {
        let url = settingsURL(home: home)
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: url.path) {
                let backup = url.deletingLastPathComponent().appending(path: "settings.json.vorssaint-backup")
                try? manager.removeItem(at: backup)
                try manager.copyItem(at: url, to: backup)
            }
            let data = try JSONSerialization.data(withJSONObject: settings,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try (data + Data("\n".utf8)).write(to: url, options: .atomic)
        } catch {
            throw Failure.writeFailed
        }
    }

    /// Saves the input when it holds limits, then hands it to the status
    /// line there was before, whose output Claude Code shows.
    static let script = """
        #!/bin/sh
        # Written by Vorssaint. Keeps the plan limits Claude Code reports for
        # Vorssaint's AI Agents page, then runs the status line you had before.
        # Disconnect from Vorssaint's settings to put that status line back.
        dir=$(dirname "$0")
        input=$(cat)
        case "$input" in
          *'"rate_limits"'*)
            tmp="$dir/limits.json.$$"
            printf '%s\\n' "$input" > "$tmp" && mv -f "$tmp" "$dir/limits.json" ;;
        esac
        if [ -s "$dir/previous-command" ]; then
          printf '%s\\n' "$input" | /bin/bash -c "$(cat "$dir/previous-command")"
        fi

        """
}
