import Foundation
import TerminalMacCore

public struct ManualTraceTicket {
    let firstSequence: Int
    let lastSequence: Int
    let merged: Int
    let enqueued: Date
    let enqueuedUptime: TimeInterval
    let capture: Bool
    let context: String?
    let privacyEpoch: Int
}

/// Only receives terminal Viewer actions; never subscribes to global input.
@MainActor public final class ManualTracing {
    private let tracing: LangfuseTracing
    private let sessionID = UUID().uuidString
    private var sequence = 0
    private var context: String?
    private var privacyEpoch = 0
    public private(set) var paused = false
    public var attached: Bool { context != nil }
    public var enabled: Bool { tracing.isEnabled }

    public init(tracing: LangfuseTracing) { self.tracing = tracing }

    public func attach(_ handle: String) throws {
        guard context == nil else { throw Failure("Detach the current manual branch first.") }
        try tracing.validateContext(handle)
        let result = try tracing.begin(goal: "Manual Viewer intervention", parent: handle)
        context = result["context"] as? String
    }

    public func detach() throws {
        if let context { _ = try tracing.end(context: context, chain: true, outcome: "success", summary: "Manual Viewer branch ended; execution outcomes are recorded per action.") }
        context = nil
    }

    public func setPaused(_ value: Bool) {
        if value && !paused { privacyEpoch += 1 }
        paused = value
    }

    public func ticket(merging previous: ManualTraceTicket? = nil) -> ManualTraceTicket {
        sequence += 1
        return ManualTraceTicket(firstSequence: previous?.firstSequence ?? sequence, lastSequence: sequence,
            merged: (previous?.merged ?? 0) + 1, enqueued: previous?.enqueued ?? Date(),
            enqueuedUptime: previous?.enqueuedUptime ?? ProcessInfo.processInfo.systemUptime,
            capture: (previous?.capture ?? true) && !paused, context: context, privacyEpoch: privacyEpoch)
    }

    public func canMerge(_ ticket: ManualTraceTicket) -> Bool { ticket.capture == !paused && ticket.context == context && ticket.privacyEpoch == privacyEpoch }

    public func execute(_ request: Request, ticket: ManualTraceTicket, operation: () async throws -> Reply) async rethrows -> Reply {
        try await tracing.observeTool(request.action, arguments: request.arguments, channel: "viewer", sessionID: sessionID,
            contextHandle: ticket.context, actor: "human", requestID: request.id.uuidString,
            captureContent: ticket.capture && !paused, inheritActiveParent: false,
            captureGate: { ticket.privacyEpoch == self.privacyEpoch && !self.paused }, output: { self.tracing.actionOutput($0.values) }) {
                record(ticket, state: "dispatched")
                let result = try await tracing.observeGuest(request, operation: operation)
                tracing.recordMetadata(["queue_state": "completed"])
                return result
            }
    }

    public func dropped(_ request: Request, ticket: ManualTraceTicket, cause: String) async {
        _ = await tracing.observeTool(request.action, arguments: [:], channel: "viewer", sessionID: sessionID,
            contextHandle: ticket.context, actor: "human", requestID: request.id.uuidString,
            captureContent: false, inheritActiveParent: false, output: { _ in ["executed": false] }) {
                record(ticket, state: ["queue-full", "previous-failure", "viewer-exit"].contains(cause) ? cause : "dropped")
                tracing.recordWarning("manual-input-not-executed")
                return false
            }
    }

    private func record(_ ticket: ManualTraceTicket, state: String) {
        tracing.recordMetadata(["first_sequence": String(ticket.firstSequence), "last_sequence": String(ticket.lastSequence),
            "merge_count": String(ticket.merged), "enqueued_at": ISO8601DateFormatter().string(from: ticket.enqueued),
            "queue_ms": String(max(0, (ProcessInfo.processInfo.systemUptime - ticket.enqueuedUptime) * 1000)),
            "queue_state": state, "capture_state": ticket.capture && !paused ? "enabled" : "paused"])
    }
}
