import Foundation

/// Correlates server item IDs with local turns, including completion-before-ack events.
public struct TranscriptRouter {
    private var queued: [UUID] = []
    private var items: [String: UUID] = [:]
    private var early: [String: String] = [:]
    public init() {}
    public mutating func enqueue(_ id: UUID) { queued.append(id) }
    public mutating func acknowledge(item: String) -> (UUID, String?)? {
        guard items[item] == nil, !queued.isEmpty else { return nil }
        let id = queued.removeFirst(); items[item] = id
        return (id, early.removeValue(forKey: item))
    }
    public mutating func complete(item: String, text: String) -> (UUID, String)? {
        guard let id = items[item] else { early[item] = text; return nil }
        return (id, text)
    }
    public func localID(for item: String) -> UUID? { items[item] }
}
