// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Foundation

/// One agent a local Paperclip server runs for a company.
struct PaperclipAgent: Identifiable, Equatable, Decodable {
    let id: String
    let name: String
    let title: String?
    let status: String
    let pauseReason: String?
    let errorReason: String?
    let budgetMonthlyCents: Int?
    let spentMonthlyCents: Int?
    let lastHeartbeatAt: Date?

    var isPaused: Bool { status == "paused" }
    var isErrored: Bool { status == "error" }
    /// Waiting on the board, or stopped for good; neither wakes from the notch.
    var isBlocked: Bool { status == "pending_approval" || status == "terminated" }
}

/// A heartbeat run in flight: what the agent is doing right now.
struct PaperclipRun: Identifiable, Equatable, Decodable {
    struct Execution: Equatable, Decodable {
        let phase: String?
        let label: String?
    }

    let id: String
    let agentId: String
    let status: String
    let startedAt: Date?
    let createdAt: Date?
    let currentToolName: String?
    let currentStatusMessage: String?
    let lastAssistantSnippet: String?
    let execution: Execution?

    var started: Date { startedAt ?? createdAt ?? Date() }

    /// The line a row shows under the agent's name: the tool it is using, what
    /// it last said, or the phase the server reports.
    var activity: String? {
        if let tool = currentToolName?.trimmed, !tool.isEmpty { return tool }
        if let said = lastAssistantSnippet?.trimmed, !said.isEmpty { return said }
        if let message = currentStatusMessage?.trimmed, !message.isEmpty,
           !message.hasPrefix("run phase:") { return message }
        return execution?.label
    }
}

/// What an agent is up to, as its avatar acts it out.
enum PaperclipAgentState: Equatable {
    /// No server answered.
    case offline
    case idle
    case working
    /// Errored, paused for its budget or waiting on the board: needs the person.
    case waiting
    /// Finished a run a moment ago.
    case done
    /// Paused by the person.
    case paused
}

struct PaperclipCrewSnapshot: Equatable {
    var reachable = false
    var loaded = false
    var companyID: String?
    var companyName: String?
    var agents: [PaperclipAgent] = []
    var runs: [PaperclipRun] = []
    /// When each agent's last run ended, while that is recent enough to show.
    var finished: [String: Date] = [:]

    static let doneShown: TimeInterval = 45

    func state(of agent: PaperclipAgent, now: Date = Date()) -> PaperclipAgentState {
        guard reachable else { return .offline }
        if runningAgentIDs.contains(agent.id) { return .working }
        if agent.isErrored || agent.status == "pending_approval" { return .waiting }
        if agent.isPaused { return agent.pauseReason == "budget" ? .waiting : .paused }
        if let ended = finished[agent.id], now.timeIntervalSince(ended) < Self.doneShown { return .done }
        return .idle
    }

    func run(for agent: PaperclipAgent) -> PaperclipRun? {
        runs.filter { $0.agentId == agent.id }.min { $0.started < $1.started }
    }

    var runningAgentIDs: Set<String> { Set(runs.map(\.agentId)) }
    var isWorking: Bool { reachable && !runs.isEmpty }
    var earliestRunStart: Date? { runs.map(\.started).min() }
    var pausedCount: Int { agents.filter(\.isPaused).count }

    /// The agents the closed island shows: the ones working, longest first.
    var working: [PaperclipAgent] {
        let starts = Dictionary(runs.map { ($0.agentId, $0.started) }, uniquingKeysWith: min)
        return agents.filter { starts[$0.id] != nil }.sorted { starts[$0.id]! < starts[$1.id]! }
    }

    var needsAttention: Bool { agents.contains { state(of: $0) == .waiting } }

    /// Working agents first, then the ones that need a look, then the rest.
    var ordered: [PaperclipAgent] {
        let running = runningAgentIDs
        func rank(_ agent: PaperclipAgent) -> Int {
            if running.contains(agent.id) { return 0 }
            if agent.isErrored || agent.status == "pending_approval" { return 1 }
            if agent.isPaused { return 3 }
            return 2
        }
        return agents.filter { $0.status != "terminated" }.sorted {
            rank($0) != rank($1) ? rank($0) < rank($1) : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// Follows a Paperclip server on this Mac and sends it the notch's commands.
/// The server runs in local trusted mode, so loopback requests need no key.
final class PaperclipCrewService: ObservableObject {
    static let shared = PaperclipCrewService()
    static let defaultURL = "http://127.0.0.1:3100"

    @Published private(set) var snapshot = PaperclipCrewSnapshot()
    /// Agents with a command on its way, so their button cannot be sent twice.
    @Published private(set) var pending: Set<String> = []
    /// The last command that failed, shown on the card for a moment.
    @Published private(set) var failure: (agentID: String, message: String, date: Date)?
    /// Starting the server from the notch, from the press until it answers.
    @Published private(set) var launch: Launch = .none

    enum Launch: Equatable {
        case none
        case starting(since: Date)
        /// It never answered; the log says why.
        case failed
    }

    /// A first run checks and repairs the install before it serves, which
    /// can take a while on a cold Mac.
    private static let launchPatience: TimeInterval = 90
    private static let launchInterval: TimeInterval = 1

    /// While anyone works the card reads every few seconds; a quiet crew less often.
    private static let busyInterval: TimeInterval = 3
    private static let quietInterval: TimeInterval = 12

    // Main thread.
    private var running = false
    private var paused = false
    private var timer: Timer?
    private var inFlight = false

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = fractional.date(from: text) ?? plain.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: text))
        }
        return decoder
    }()

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        NotchAgentSupport.isEnabled(in: defaults)
            && defaults.object(forKey: DefaultsKey.paperclipCrewEnabled) as? Bool ?? true
    }

    static func baseURL(in defaults: UserDefaults = .standard) -> URL? {
        let text = (defaults.string(forKey: DefaultsKey.paperclipCrewURL) ?? "").trimmed
        guard let url = URL(string: text.isEmpty ? defaultURL : text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    func syncWithPreferences() {
        guard Self.isEnabled() else { stop(); return }
        paused = false
        guard !running else { return }
        running = true
        refresh()
    }

    /// Stops reading and forgets the crew, as when the section is turned off.
    func stop() {
        running = false
        launch = .none
        timer?.invalidate(); timer = nil
        if snapshot != PaperclipCrewSnapshot() { snapshot = PaperclipCrewSnapshot() }
        pending = []
    }

    /// The island went away: keep what was read, read again on return.
    func pause() {
        paused = true
        running = false
        timer?.invalidate(); timer = nil
    }

    func refresh() {
        guard running, !inFlight, let base = Self.baseURL() else { return }
        inFlight = true
        Task { [weak self] in
            guard let self else { return }
            let next = await self.read(base)
            await MainActor.run { [self] in
                self.inFlight = false
                guard self.running else { return }
                var next = next
                next.finished = self.finishedTimes(from: self.snapshot, to: next)
                if next != self.snapshot { self.snapshot = next }
                if case .starting(let since) = self.launch {
                    if next.reachable { self.launch = .none }
                    else if Date().timeIntervalSince(since) > Self.launchPatience { self.launch = .failed }
                }
                self.schedule()
            }
        }
    }

    /// A run that was there last time and is gone now just ended.
    private func finishedTimes(from old: PaperclipCrewSnapshot, to new: PaperclipCrewSnapshot) -> [String: Date] {
        let now = Date()
        var finished = old.finished.filter { now.timeIntervalSince($0.value) < PaperclipCrewSnapshot.doneShown }
        guard old.reachable, new.reachable else { return finished }
        for id in old.runningAgentIDs.subtracting(new.runningAgentIDs) { finished[id] = now }
        for id in new.runningAgentIDs { finished[id] = nil }
        return finished
    }

    private func schedule() {
        timer?.invalidate()
        let starting = if case .starting = launch { true } else { false }
        let interval = starting ? Self.launchInterval
            : snapshot.isWorking || !pending.isEmpty || !snapshot.finished.isEmpty ? Self.busyInterval : Self.quietInterval
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in self?.refresh() }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private struct Company: Decodable {
        let id: String
        let name: String
        let status: String?
    }

    private func read(_ base: URL) async -> PaperclipCrewSnapshot {
        var next = PaperclipCrewSnapshot()
        next.loaded = true
        guard let companies: [Company] = await get(base, "api/companies") else { return next }
        let chosen = (UserDefaults.standard.string(forKey: DefaultsKey.paperclipCrewCompany) ?? "").trimmed
        // Names repeat (an onboarding run twice leaves two of the same name),
        // so an id wins, and of several candidates the first with agents does.
        let candidates = companies.filter { $0.id == chosen }.nilIfEmpty
            ?? companies.filter { !chosen.isEmpty && $0.name.caseInsensitiveCompare(chosen) == .orderedSame }.nilIfEmpty
            ?? companies.filter { $0.status == nil || $0.status == "active" }
        guard !candidates.isEmpty else { next.reachable = true; return next }
        var picked: (company: Company, agents: [PaperclipAgent])?
        for company in candidates {
            guard let agents: [PaperclipAgent] = await get(base, "api/companies/\(company.id)/agents") else { return next }
            if picked == nil { picked = (company, agents) }
            if agents.contains(where: { $0.status != "terminated" }) { picked = (company, agents); break }
        }
        guard let picked else { return next }
        let runs: [PaperclipRun]? = await get(base, "api/companies/\(picked.company.id)/live-runs")
        next.reachable = true
        next.companyID = picked.company.id
        next.companyName = picked.company.name
        next.agents = picked.agents
        next.runs = (runs ?? []).filter { $0.status == "running" || $0.status == "queued" }
        return next
    }

    private func get<T: Decodable>(_ base: URL, _ path: String) async -> T? {
        var request = URLRequest(url: base.appending(path: path))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? Self.decoder.decode(T.self, from: data)
    }

    // MARK: Commands

    enum Command {
        case wake, pause, resume

        var path: String {
            switch self {
            case .wake: return "wakeup"
            case .pause: return "pause"
            case .resume: return "resume"
            }
        }

        var body: [String: Any] {
            switch self {
            case .wake: return ["source": "on_demand", "triggerDetail": "manual", "reason": "Woken from the notch"]
            case .pause, .resume: return [:]
            }
        }
    }

    /// The command a row's button sends for an agent as it stands.
    func command(for agent: PaperclipAgent) -> Command? {
        if agent.isBlocked { return nil }
        if agent.isPaused { return .resume }
        return snapshot.runningAgentIDs.contains(agent.id) || agent.status == "running" ? .pause : .wake
    }

    func send(_ command: Command, to agent: PaperclipAgent) {
        guard let base = Self.baseURL(), !pending.contains(agent.id) else { return }
        pending.insert(agent.id)
        var request = URLRequest(url: base.appending(path: "api/agents/\(agent.id)/\(command.path)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: command.body)
        Task { [weak self] in
            guard let self else { return }
            var message: String?
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if !(200..<300).contains(status) {
                    let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                    message = error ?? "HTTP \(status)"
                }
            } catch {
                message = error.localizedDescription
            }
            let failed = message
            await MainActor.run { [self] in
                self.pending.remove(agent.id)
                if let failed { self.failure = (agent.id, failed, Date()) }
                // A wake takes a moment to become a run; read now and soon after.
                self.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
            }
        }
    }

    // MARK: Starting the server

    /// Where the `paperclipai` command lives: the one in Settings, or the
    /// places its installer and Homebrew put it. An app opened from the Dock
    /// has no shell PATH to search.
    static func launcherPath(in defaults: UserDefaults = .standard) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let custom = (defaults.string(forKey: DefaultsKey.paperclipCrewCommand) ?? "").trimmed
        let candidates = custom.isEmpty
            ? [home + "/.local/bin/paperclipai", "/opt/homebrew/bin/paperclipai", "/usr/local/bin/paperclipai"]
            : [(custom as NSString).expandingTildeInPath]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Only a server on this Mac can be started from here.
    static func canLaunch(in defaults: UserDefaults = .standard) -> Bool {
        guard let host = baseURL(in: defaults)?.host?.lowercased() else { return false }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) && launcherPath(in: defaults) != nil
    }

    static var launchLog: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/Vorssaint/paperclip-run.log")
    }

    /// Runs `paperclipai run` in its own session, so the server keeps going
    /// after this app quits, with its output kept in a log to read if it
    /// never answers.
    func startServer() {
        if case .starting = launch { return }
        guard !snapshot.reachable, Self.canLaunch(), let launcher = Self.launcherPath() else { return }
        let log = Self.launchLog
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            // The shell only redirects and then becomes the launcher.
            try DetachedProcess.spawn("/bin/sh", ["-c", "exec \"$0\" run >>\"$1\" 2>&1", launcher, log.path])
        } catch {
            launch = .failed
            return
        }
        launch = .starting(since: Date())
        if !running { syncWithPreferences() } else { schedule() }
    }

    /// Opens the agent's page in Paperclip's own interface.
    func dashboardURL(for agent: PaperclipAgent? = nil) -> URL? {
        guard let base = Self.baseURL() else { return nil }
        guard let agent else { return base }
        return base.appending(path: "agents/\(agent.id)")
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

private extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
