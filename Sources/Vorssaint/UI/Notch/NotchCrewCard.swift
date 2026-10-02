// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// The crew a local Paperclip server runs: every agent's face acting out what
/// it does, what it is doing now, and the one command that fits it.
struct NotchCrewCard: View {
    @ObservedObject private var crew = PaperclipCrewService.shared
    @State private var hovered: String?

    var body: some View {
        let snapshot = crew.snapshot
        NotchAgentCardChrome {
            VStack(alignment: .leading, spacing: 7) {
                header(snapshot)
                if !snapshot.loaded {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !snapshot.reachable {
                    offline
                } else if snapshot.ordered.isEmpty {
                    Text(NotchCrewStrings.noAgents).font(.system(size: 10.5)).foregroundStyle(.secondary)
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(snapshot.ordered) { agent in
                                    NotchCrewRow(agent: agent, snapshot: snapshot, now: context.date,
                                                 expanded: hovered == agent.id, crew: crew)
                                        .onHover { inside in
                                            withAnimation(.snappy(duration: 0.22)) {
                                                if inside { hovered = agent.id } else if hovered == agent.id { hovered = nil }
                                            }
                                        }
                                }
                            }
                        }
                        .scrollIndicators(.never)
                        .mask(NotchScrollEdgeMask())
                    }
                }
            }
        }
        .onAppear { crew.refresh() }
    }

    private func header(_ snapshot: PaperclipCrewSnapshot) -> some View {
        HStack(spacing: 6) {
            Image(systemName: NotchAgentCard.crew.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 13)
            Text(snapshot.companyName.map { "\(NotchCrewStrings.title) · \($0)" } ?? NotchCrewStrings.title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 4)
            summary(snapshot)
            Button {
                if let url = crew.dashboardURL() { NSWorkspace.shared.open(url) }
            } label: {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 17, height: 17)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NotchButtonStyle(cornerRadius: 8))
            .help(NotchCrewStrings.openPaperclip)
        }
        .frame(height: 17)
    }

    @ViewBuilder private func summary(_ snapshot: PaperclipCrewSnapshot) -> some View {
        let working = snapshot.working.count
        let waiting = snapshot.agents.filter { snapshot.state(of: $0) == .waiting }.count
        HStack(spacing: 4) {
            if waiting > 0 { chip(NotchCrewStrings.waiting(waiting), tint: .orange) }
            if working > 0 { chip(NotchCrewStrings.working(working), tint: Color(red: 0.55, green: 0.78, blue: 1)) }
            if working == 0, waiting == 0, snapshot.pausedCount > 0 {
                chip(NotchCrewStrings.pausedCount(snapshot.pausedCount), tint: .white)
            }
        }
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint.opacity(0.9))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.14), in: Capsule(style: .continuous))
    }

    private var offline: some View {
        HStack(spacing: 10) {
            NotchCrewAvatar(agentID: "paperclip", state: .offline, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(NotchCrewStrings.offline).font(.system(size: 11, weight: .medium))
                Text(NotchCrewStrings.offlineHint).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }
}

/// A fade at the scroll's top and bottom edges, so rows slide out of view.
private struct NotchScrollEdgeMask: View {
    var body: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                               .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}

private struct NotchCrewRow: View {
    let agent: PaperclipAgent
    let snapshot: PaperclipCrewSnapshot
    let now: Date
    let expanded: Bool
    @ObservedObject var crew: PaperclipCrewService

    private var state: PaperclipAgentState { snapshot.state(of: agent, now: now) }
    private var run: PaperclipRun? { snapshot.run(for: agent) }
    private var identity: NotchCrewIdentity { NotchCrewIdentity(id: agent.id) }

    var body: some View {
        let state = state
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                NotchCrewAvatar(agentID: agent.id, state: state, size: 20)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(line(state))
                        .font(.system(size: 9.5))
                        .foregroundStyle(state == .waiting ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                if let run, state == .working {
                    Text(AgentFormat.clock(now.timeIntervalSince(run.started)))
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(identity.tint)
                }
                action
            }
            if expanded { details(state) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.white.opacity(expanded ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if let url = crew.dashboardURL(for: agent) { NSWorkspace.shared.open(url) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(agent.name)
        .accessibilityValue(line(state))
    }

    /// What the agent is doing, in one line.
    private func line(_ state: PaperclipAgentState) -> String {
        if let failure = crew.failure, failure.agentID == agent.id, now.timeIntervalSince(failure.date) < 8 {
            return failure.message
        }
        switch state {
        case .working: return run?.activity ?? NotchCrewStrings.starting
        case .done: return NotchCrewStrings.done
        case .paused: return NotchCrewStrings.paused
        case .offline: return NotchCrewStrings.offline
        case .waiting:
            if agent.status == "pending_approval" { return NotchCrewStrings.waitingApproval }
            if agent.isPaused, agent.pauseReason == "budget" { return NotchCrewStrings.budget }
            return agent.errorReason ?? NotchCrewStrings.errored
        case .idle:
            guard let last = agent.lastHeartbeatAt else { return agent.title ?? NotchCrewStrings.idle }
            return NotchCrewStrings.idle + " · "
                + last.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        }
    }

    /// Revealed on hover: the steps behind the one line, without crowding the list.
    @ViewBuilder private func details(_ state: PaperclipAgentState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let run {
                if let tool = run.currentToolName, !tool.isEmpty { step("wrench.and.screwdriver", tool) }
                if let said = run.lastAssistantSnippet, !said.isEmpty { step("text.bubble", said, lines: 3) }
                if let phase = run.execution?.label ?? run.currentStatusMessage { step("dot.radiowaves.left.and.right", phase) }
                step("clock", run.started.formatted(date: .omitted, time: .shortened))
            } else if let title = agent.title, !title.isEmpty {
                step("person.crop.square", title)
            }
            if let budget = agent.budgetMonthlyCents, budget > 0 {
                step("dollarsign.circle", NotchCrewStrings.spent(AgentFormat.cost(Double(agent.spentMonthlyCents ?? 0) / 100),
                                                                 of: AgentFormat.cost(Double(budget) / 100)))
            }
        }
        .padding(.leading, 32)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func step(_ symbol: String, _ text: String, lines: Int = 1) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol).font(.system(size: 8.5)).foregroundStyle(.tertiary).frame(width: 11)
            Text(text).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(lines)
        }
    }

    @ViewBuilder private var action: some View {
        if crew.pending.contains(agent.id) {
            ProgressView().controlSize(.mini).frame(width: 24, height: 20)
        } else if let command = crew.command(for: agent), state != .offline {
            let (symbol, label): (String, String) = {
                switch command {
                case .wake: return ("play.fill", NotchCrewStrings.wake)
                case .pause: return ("pause.fill", NotchCrewStrings.pause)
                case .resume: return ("play.fill", NotchCrewStrings.resume)
                }
            }()
            Button { crew.send(command, to: agent) } label: {
                Image(systemName: symbol)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(command == .pause ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(identity.tint))
                    .frame(width: 24, height: 20)
                    .background(command == .pause ? Color.white.opacity(0.1) : identity.tint.opacity(0.2),
                                in: Capsule(style: .continuous))
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(NotchButtonStyle(cornerRadius: 10))
            .help(label)
            .accessibilityLabel(label)
        }
    }
}
