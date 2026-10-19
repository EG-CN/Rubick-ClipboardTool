import AppKit
import Testing
@testable import ClipboardTool

@Suite(.serialized)
@MainActor
struct InlineTextInputTests {
    private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], characters: String = "\r") throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: characters, charactersIgnoringModifiers: characters,
                                     isARepeat: false, keyCode: code))
    }

    @Test(arguments: [NSEvent.ModifierFlags(), .shift])
    func returnAddsNewlineWithoutCommitting(modifiers: NSEvent.ModifierFlags) throws {
        _ = NSApplication.shared
        let view = InlineTextView(frame: CGRect(x: 0, y: 0, width: 240, height: 100))
        view.isRichText = false
        view.string = "第一行"
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        var committed = false
        view.onCommit = { committed = true }
        view.keyDown(with: try key(36, modifiers: modifiers))
        #expect(view.string == "第一行\n")
        #expect(!committed)
    }

    @Test(arguments: [UInt16(36), UInt16(76)])
    func commandReturnFinishesInputWithoutNewline(code: UInt16) throws {
        _ = NSApplication.shared
        let view = InlineTextView(frame: .zero)
        view.string = "已有内容"
        var committed = false
        view.onCommit = { committed = true }
        view.keyDown(with: try key(code, modifiers: .command))
        #expect(committed)
        #expect(view.string == "已有内容")
    }

    @Test func escapeKeepsItsExistingCallback() throws {
        _ = NSApplication.shared
        let view = InlineTextView(frame: .zero)
        var escaped = false
        view.onEscape = { escaped = true }
        view.keyDown(with: try key(53, characters: "\u{1b}"))
        #expect(escaped)
    }

    @Test func markedTextGetsReturnBeforeTheCommitShortcut() throws {
        _ = NSApplication.shared
        let view = InlineTextView(frame: CGRect(x: 0, y: 0, width: 240, height: 100))
        view.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        var committed = false
        view.onCommit = { committed = true }
        view.keyDown(with: try key(36, modifiers: .command))
        #expect(!committed)
    }
}
