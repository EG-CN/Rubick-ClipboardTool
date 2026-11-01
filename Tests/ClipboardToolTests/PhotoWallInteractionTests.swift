import Testing
@testable import ClipboardTool

struct PhotoWallInteractionTests {
    @Test func manualOpeningNeverExpiresFromPointerMovement() {
        var state = PhotoWallInteraction()
        state.showManually(true); state.advance(to: 10000)
        #expect(state.isOpen && state.phase == .manual)
        state.showManually(false); state.advance(to: 20000)
        #expect(!state.isOpen)
    }
    @Test func passingDragDoesNotOpenAndCancelRestoresClosed() {
        var state = PhotoWallInteraction()
        state.enterDrop(at: 0); state.advance(to: 0.2)
        #expect(!state.isOpen)
        state.leaveDrop(at: 0.2); state.advance(to: 0.5)
        #expect(!state.isOpen)
        state.advance(to: 0.86)
        #expect(!state.incoming && !state.isOpen)
    }
    @Test func incomingDwellOpensAndGapDoesNotFlicker() {
        var state = PhotoWallInteraction()
        state.enterDrop(at: 0); state.advance(to: 0.33)
        #expect(state.isOpen && state.incoming)
        state.leaveDrop(at: 0.4); state.advance(to: 0.8)
        #expect(state.isOpen)
        state.enterDrop(at: 0.9); state.advance(to: 100)
        #expect(state.isOpen && state.incoming)
    }
    @Test func abandonedDropRestoresPriorManualOpening() {
        var state = PhotoWallInteraction()
        state.showManually(true); state.enterDrop(at: 0)
        state.leaveDrop(at: 0.1); state.advance(to: 0.8)
        #expect(state.isOpen && state.phase == .manual)
    }
    @Test func directDropIsAcceptedBeforeDwellAndStaysOpenForDraggingOut() {
        var state = PhotoWallInteraction()
        state.enterDrop(at: 0); state.received(at: 0.1)
        state.advance(to: 0.9); #expect(state.isOpen)
        state.advance(to: 100); #expect(state.isOpen)
    }
    @Test func takingFreezesWallAndCancellationKeepsItOpen() {
        var state = PhotoWallInteraction()
        state.startTaking(); state.advance(to: 1000)
        #expect(state.isOpen && state.outgoing)
        state.finishTaking(accepted: false, at: 1001); state.advance(to: 2000)
        #expect(state.isOpen && state.phase == .manual)
    }
    @Test func acceptedTakeClosesOnlyAfterAcknowledgement() {
        var state = PhotoWallInteraction()
        state.startTaking(); state.finishTaking(accepted: true, at: 1)
        state.advance(to: 1.2); #expect(state.isOpen)
        state.advance(to: 1.31); #expect(!state.isOpen)
    }
    @Test func newInteractionCancelsOldClosingTimer() {
        var state = PhotoWallInteraction()
        state.received(at: 0); state.startTaking(); state.advance(to: 10)
        #expect(state.isOpen && state.outgoing)
        state.finishTaking(accepted: true, at: 10)
        state.showManually(true); state.advance(to: 100)
        #expect(state.isOpen && state.phase == .manual)
    }
    @Test func receiptThenCancelledTakeKeepsRopeOpen() {
        // 挂入后的绳子，取消送出（拖拽未成功）不能把它收走。
        var state = PhotoWallInteraction()
        state.received(at: 0)
        #expect(state.isOpen)
        state.startTaking()
        #expect(state.isOpen && state.outgoing)
        state.finishTaking(accepted: false, at: 1)
        state.advance(to: 100)
        #expect(state.isOpen && state.phase == .manual)
    }
    @Test func receiptThenManualCollapseClosesRope() {
        // 手动收绳（Esc / 点外部）始终生效，即使刚挂入内容。
        var state = PhotoWallInteraction()
        state.received(at: 0)
        #expect(state.isOpen)
        state.showManually(false)
        #expect(!state.isOpen && state.phase == .closed)
        state.advance(to: 100)
        #expect(!state.isOpen)
    }
}
