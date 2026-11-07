import Foundation
import DockCore

/// The app-wide queue of agent items that need the user. The inbox server posts items and receives decisions;
/// the notch panel and the strip observe `items` and answer through `respond` or `dismiss`.
@MainActor
final class AttentionCenter: ObservableObject {
    @Published private(set) var items: [AgentAttention] = []
    /// Called once per answered or dismissed request that still awaits a decision. Set by the inbox server.
    var onDecision: ((_ id: String, _ decision: AttentionDecision) -> Void)?
    private var answered: Set<String> = []
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    /// Adds an item. A newer item from the same session replaces an older one that awaits no decision
    /// (a fresh "Done" replaces the previous "Done"); requests that await a decision are never replaced silently.
    func post(_ item: AgentAttention) {
        guard !answered.contains(item.id) else { return }
        items.removeAll { $0.id == item.id || ($0.sessionID == item.sessionID && $0.source == item.source && !$0.awaitsDecision) }
        items.append(item)
        items.sort(by: Self.urgency)
    }

    /// Answers a request. Ignored for unknown or already answered ids.
    func respond(_ id: String, _ decision: AttentionDecision) {
        guard let item = items.first(where: { $0.id == id }), answered.insert(id).inserted else { return }
        items.removeAll { $0.id == id }
        if item.awaitsDecision { onDecision?(id, decision) }
    }

    /// The user closed the item without answering: the agent's own dialog takes over.
    func dismiss(_ id: String) { respond(id, .passThrough) }

    /// The hook stopped waiting (deadline passed or the connection closed). Removes a request without a decision.
    func expire(_ id: String) {
        answered.insert(id)
        items.removeAll { $0.id == id }
    }

    /// Removes every item for a session, for example when its terminal closed or the user answered in the agent itself.
    func clear(source: String, sessionID: String) {
        for item in items where item.source == source && item.sessionID == sessionID {
            if item.awaitsDecision { respond(item.id, .passThrough) } else { items.removeAll { $0.id == item.id } }
        }
    }

    /// Drops answered ids older than the newest 500 so the set stays small.
    func compact() { if answered.count > 1000 { answered = Set(answered.suffix(500)) } }

    var needsDecisionCount: Int { items.filter(\.awaitsDecision).count }

    /// Requests that hold an agent first (oldest first), then questions and waiting prompts, then finished turns.
    static func urgency(_ a: AgentAttention, _ b: AgentAttention) -> Bool {
        func rank(_ item: AgentAttention) -> Int {
            switch item.kind { case .permission, .question: return item.awaitsDecision ? 0 : 1; case .waiting: return 2; case .finished: return 3 }
        }
        let (ra, rb) = (rank(a), rank(b))
        return ra != rb ? ra < rb : a.receivedAt < b.receivedAt
    }
}
