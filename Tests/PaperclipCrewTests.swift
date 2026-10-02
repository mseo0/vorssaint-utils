// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// The Paperclip crew: what the server's answers decode to, the state each
/// agent's face acts out, and the order the card lists them in.
enum PaperclipCrewTests {
    static func run(_ suite: TestSuite) {
        decoding(suite)
        states(suite)
        ordering(suite)
        layout(suite)
        launching(suite)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
        try? PaperclipCrewService.decoder.decode(type, from: Data(json.utf8))
    }

    private static func agent(_ id: String, _ name: String, status: String = "idle",
                              pauseReason: String? = nil) -> PaperclipAgent {
        PaperclipAgent(id: id, name: name, title: nil, status: status, pauseReason: pauseReason, errorReason: nil,
                       budgetMonthlyCents: nil, spentMonthlyCents: nil, lastHeartbeatAt: nil)
    }

    private static func run(_ agentID: String, started: Date, tool: String? = nil, snippet: String? = nil,
                            message: String? = nil, label: String? = nil) -> PaperclipRun {
        PaperclipRun(id: "run-" + agentID, agentId: agentID, status: "running", startedAt: started, createdAt: nil,
                     currentToolName: tool, currentStatusMessage: message, lastAssistantSnippet: snippet,
                     execution: label.map { PaperclipRun.Execution(phase: "working", label: $0) })
    }

    // MARK: Decoding

    private static func decoding(_ suite: TestSuite) {
        // Shaped like the server's answers, trimmed to a few fields and with
        // ones the app ignores left in.
        let agents = decode([PaperclipAgent].self, """
        [{"id":"a1","companyId":"c","name":"Backend Engineer","title":"Backend Engineer","status":"idle",
          "adapterConfig":{"cwd":"/tmp"},"budgetMonthlyCents":2000,"spentMonthlyCents":125,"pauseReason":null,
          "errorReason":null,"lastHeartbeatAt":"2026-09-30T09:23:34.312Z","permissions":{"canCreateAgents":false}},
         {"id":"a2","name":"Security","status":"paused","pauseReason":"budget","lastHeartbeatAt":null}]
        """)
        suite.expect(agents?.count == 2 && agents?[0].spentMonthlyCents == 125
                     && agents?[0].lastHeartbeatAt != nil && agents?[1].isPaused == true,
                     "Paperclip agents decode, with their budget and last heartbeat")
        let runs = decode([PaperclipRun].self, """
        [{"id":"r1","companyId":"c","status":"running","startedAt":"2026-10-02T01:24:02.090Z",
          "createdAt":"2026-10-02T01:24:01.944Z","agentId":"a1","currentToolName":null,
          "currentStatusMessage":"run phase: create_runtime (0ms)","lastAssistantSnippet":null,
          "execution":{"phase":"working","label":"Working","permittedActions":["inspect_run"]}}]
        """)
        suite.expect(runs?.first?.agentId == "a1" && runs?.first?.execution?.label == "Working"
                     && runs?.first?.startedAt != nil,
                     "Paperclip live runs decode, with fractional-second dates")
        suite.expect(runs?.first?.activity == "Working",
                     "A run's internal phase message gives way to its execution label")

        let started = Date(timeIntervalSince1970: 1_790_000_000)
        suite.expect(run("a", started: started, tool: "Bash", snippet: "Looking", message: "Reading").activity == "Bash"
                     && run("a", started: started, snippet: " Looking ", message: "Reading").activity == "Looking"
                     && run("a", started: started, message: "Reading").activity == "Reading",
                     "A row names the tool first, then what the agent said, then the server's message")
    }

    // MARK: States

    private static func states(_ suite: TestSuite) {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var snapshot = PaperclipCrewSnapshot()
        snapshot.reachable = true
        snapshot.agents = [agent("w", "Worker"), agent("e", "Broken", status: "error"),
                           agent("b", "Broke", status: "paused", pauseReason: "budget"),
                           agent("p", "Resting", status: "paused", pauseReason: "manual"),
                           agent("d", "Finisher"), agent("o", "Old"), agent("i", "Idle")]
        snapshot.runs = [run("w", started: now.addingTimeInterval(-30))]
        snapshot.finished = ["d": now.addingTimeInterval(-5), "o": now.addingTimeInterval(-600)]
        let states = Dictionary(uniqueKeysWithValues: snapshot.agents.map { ($0.id, snapshot.state(of: $0, now: now)) })
        suite.expect(states["w"] == .working, "An agent with a live run is working")
        suite.expect(states["e"] == .waiting && states["b"] == .waiting,
                     "An errored agent and one out of budget both wait for the person")
        suite.expect(states["p"] == .paused, "An agent the person paused sleeps")
        suite.expect(states["d"] == .done && states["o"] == .idle,
                     "A run that just ended shows as done, then settles to idle")
        suite.expect(states["i"] == .idle, "An agent with nothing going on is idle")
        suite.expect(snapshot.needsAttention && snapshot.isWorking, "The crew reports work and agents that need a look")

        snapshot.reachable = false
        suite.expect(snapshot.agents.allSatisfy { snapshot.state(of: $0, now: now) == .offline } && !snapshot.isWorking,
                     "Without an answering server every agent is offline and nothing works")
    }

    // MARK: Ordering

    private static func ordering(_ suite: TestSuite) {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var snapshot = PaperclipCrewSnapshot()
        snapshot.reachable = true
        snapshot.agents = [agent("z", "Zed", status: "paused"), agent("q", "QA"), agent("x", "Gone", status: "terminated"),
                           agent("l", "Late"), agent("e", "Error", status: "error"), agent("s", "Soon")]
        snapshot.runs = [run("l", started: now.addingTimeInterval(-10)), run("s", started: now.addingTimeInterval(-90))]
        suite.expect(snapshot.ordered.map(\.id) == ["l", "s", "e", "q", "z"],
                     "Working agents come first, then ones that need a look, the rest, and paused ones last; terminated are hidden")
        suite.expect(snapshot.working.map(\.id) == ["s", "l"], "The strip shows the longest-running agents first")
        suite.expect(snapshot.earliestRunStart == now.addingTimeInterval(-90), "The strip's clock starts with the first run")
    }

    // MARK: Layout

    private static func layout(_ suite: TestSuite) {
        let crew = NotchAgentTile(card: .crew, provider: nil)
        let spend = NotchAgentTile(card: .spend, provider: nil)
        let live = NotchAgentTile(card: .live, provider: nil)
        let rows = NotchAgentSupport.rows([spend, crew, live], width: 600)
        suite.expect(rows.map { $0.map(\.card) } == [[.spend], [.crew], [.live]],
                     "The crew card takes a whole row of its own")
        suite.expect(NotchAgentSupport.height(of: [crew]) == NotchAgentSupport.crewHeight,
                     "The crew card's row is tall enough for its list")
        suite.expect(NotchAgentStrings.enUS.card(.crew) == NotchCrewStrings.title, "The crew card has a name")
    }

    // MARK: Launching

    private static func launching(_ suite: TestSuite) {
        let name = "com.vorssaint.tests.paperclip-crew"
        guard let defaults = UserDefaults(suiteName: name) else { return }
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set("/bin/sh", forKey: DefaultsKey.paperclipCrewCommand)
        suite.expect(PaperclipCrewService.launcherPath(in: defaults) == "/bin/sh",
                     "A start command from Settings is used when it can run")
        defaults.set("/nonexistent/paperclipai", forKey: DefaultsKey.paperclipCrewCommand)
        suite.expect(PaperclipCrewService.launcherPath(in: defaults) == nil,
                     "A start command that is not there offers no start button")

        defaults.set("/bin/sh", forKey: DefaultsKey.paperclipCrewCommand)
        defaults.set("http://127.0.0.1:3100", forKey: DefaultsKey.paperclipCrewURL)
        suite.expect(PaperclipCrewService.canLaunch(in: defaults), "A server on this Mac can be started from the notch")
        defaults.set("http://localhost:3100", forKey: DefaultsKey.paperclipCrewURL)
        suite.expect(PaperclipCrewService.canLaunch(in: defaults), "localhost counts as this Mac")
        defaults.set("http://studio.local:3100", forKey: DefaultsKey.paperclipCrewURL)
        suite.expect(!PaperclipCrewService.canLaunch(in: defaults), "A server on another machine is never started from here")
    }
}
