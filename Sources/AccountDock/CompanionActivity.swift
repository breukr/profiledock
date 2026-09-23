import Foundation
import DockCore

extension ActivityMonitor {
    func updateCompanions(model: DockModel, now: Date = Date()) {
        for profile in model.preferences.profiles where profile.kind != .codex {
            let records = model.companions.sessions(for: profile)
            let live = records.filter { $0.state != .closed && ClaudeProcess.isAlive($0) }
            let open = model.running[profile.id]?.isEmpty == false
            if open, model.activeProfile == profile.id {
                let unseen = records.contains { ($0.completedAt ?? .distantPast) > (model.preferences.claudeReadAt?[$0.id] ?? .distantPast) }
                if unseen { model.markCompanionRead(profile) }
            }
            let unread = records.filter { session in
                guard let completed = session.completedAt else { return false }
                return completed > (model.preferences.claudeReadAt?[session.id] ?? .distantPast)
            }.count
            let summary = ActivitySummary(unread: unread, working: live.filter { $0.state == .working }.count,
                waiting: live.filter { $0.state == .waiting || $0.state == .failed }.count,
                liveAvailable: !live.isEmpty, appOpen: open)
            for session in live {
                let key = profile.id + ":" + session.id
                if let previous = companionStates[key], previous != session.state {
                    if session.state == .waiting || session.state == .failed { event = ActivityEvent(profileID: profile.id, signal: .needsInput) }
                    else if session.state == .idle, previous == .working || previous == .waiting { event = ActivityEvent(profileID: profile.id, signal: .finished) }
                }
                companionStates[key] = session.state
            }
            if entries[profile.id] != summary { entries[profile.id] = summary }
        }
        let allowed = Set(model.preferences.profiles.filter { $0.kind != .codex }.map(\.id))
        companionStates = companionStates.filter { allowed.contains(String($0.key.split(separator: ":").first ?? "")) }
    }
}
