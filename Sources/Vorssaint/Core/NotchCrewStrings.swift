// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

/// Words for the crew card. English only for now: the card belongs to a
/// local Paperclip setup rather than to every install.
enum NotchCrewStrings {
    static let title = "Crew"
    static let offline = "Paperclip isn’t answering"
    static let offlineHint = "Start it with paperclipai run"
    static let noAgents = "No agents hired yet"
    static let idle = "Idle"
    static let done = "Done"
    static let paused = "Paused"
    static let waitingApproval = "Waiting for board approval"
    static let errored = "Stopped with an error"
    static let budget = "Out of budget"
    static let starting = "Starting"
    static let wake = "Wake"
    static let pause = "Pause"
    static let resume = "Resume"
    static let openPaperclip = "Open in Paperclip"
    static func working(_ count: Int) -> String { "\(count) working" }
    static func waiting(_ count: Int) -> String { "\(count) need you" }
    static func pausedCount(_ count: Int) -> String { "\(count) paused" }
    static func spent(_ spent: String, of budget: String) -> String { "\(spent) of \(budget) this month" }
}
