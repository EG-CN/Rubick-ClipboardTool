import Foundation

/// One state owner controls opening, receiving, delivery and cancellation.
struct PhotoWallInteraction {
    enum Phase { case closed, manual, waitingForDrop, receiving, sending, receipt }
    private(set) var phase: Phase = .closed
    private(set) var isOpen = false
    private var priorOpen = false
    private var revealAt: TimeInterval?
    private var restoreAt: TimeInterval?
    private var closeAt: TimeInterval?
    var incoming: Bool { phase == .waitingForDrop || phase == .receiving }
    var outgoing: Bool { phase == .sending }

    mutating func showManually(_ open: Bool) {
        phase = open ? .manual : .closed; isOpen = open
        revealAt = nil; restoreAt = nil; closeAt = nil
    }
    mutating func enterDrop(at now: TimeInterval) {
        guard !outgoing else { return }
        if !incoming {
            priorOpen = isOpen; phase = .waitingForDrop
            revealAt = now + 0.32; closeAt = nil
        }
        restoreAt = nil
    }
    mutating func leaveDrop(at now: TimeInterval) {
        guard incoming else { return }
        restoreAt = now + 0.65
    }
    mutating func received(at now: TimeInterval) {
        // 新规则：挂入后保持垂绳，便于继续拖出；收绳只由取用完成、取空或 Esc 触发。
        phase = .receipt; isOpen = true
        revealAt = nil; restoreAt = nil; closeAt = nil
    }
    mutating func cancelDrop() {
        guard incoming else { return }
        showManually(priorOpen)
    }
    mutating func startTaking() {
        showManually(true); phase = .sending
    }
    mutating func finishTaking(accepted: Bool, at now: TimeInterval) {
        showManually(true)
        if accepted { phase = .receipt; closeAt = now + 0.3 }
    }
    mutating func advance(to now: TimeInterval) {
        if incoming, let restoreAt, now >= restoreAt { cancelDrop(); return }
        if incoming, restoreAt == nil, let revealAt, now >= revealAt {
            phase = .receiving; isOpen = true; self.revealAt = nil
        }
        if let closeAt, now >= closeAt { showManually(false) }
    }
}
