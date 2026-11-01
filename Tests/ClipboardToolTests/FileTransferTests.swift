import AppKit
import Testing
@testable import ClipboardTool

@Suite(.serialized)
@MainActor
struct FileTransferTests {
    private func fixture() throws -> (URL, [URL]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let names = ["方案 文档.md", "财务%预算.xlsx", "参考资料.pdf", "报告.docx"]
        let files = try names.map { name -> URL in
            let url = root.appendingPathComponent(name)
            try Data("fixture \(name)".utf8).write(to: url)
            return url
        }
        return (root, files)
    }
    @Test func multipleFileURLsRoundTripWithoutLosingUnicodeOrSpaces() throws {
        let (root, files) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(pasteboard.writeObjects(files.map { $0 as NSURL }))
        let read = FileTransfer.files(from: pasteboard)
        #expect(read.map(\.lastPathComponent) == files.map(\.lastPathComponent))
        #expect(read.count == 4)
    }
    @Test func referencesNeverModifySourceFilesAndPersistAsOneBatch() throws {
        let (root, files) = try fixture()
        let store = HistoryStore(baseDir: root.appendingPathComponent("history"))
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.addFiles(files.map(\.path)) == 4)
        let before = try files.map { try Data(contentsOf: $0) }
        store.saveNow()
        let reopened = HistoryStore(baseDir: store.baseDir)
        #expect(reopened.items.map { FileTransfer.filename($0) } == files.map(\.lastPathComponent))
        #expect(ClotheslineLayout.items(reopened.items).count == 4)
        let urls = try #require(FileTransfer.urls(for: reopened.items))
        let destination = NSPasteboard.withUniqueName()
        defer { destination.releaseGlobally() }
        #expect(destination.writeObjects(urls.map { $0 as NSURL }))
        #expect(FileTransfer.files(from: destination).count == 4)
        let undo = try #require(store.removeUndoable(store.items[0].id))
        #expect(try files.map { try Data(contentsOf: $0) } == before)
        undo()
        #expect(store.items.count == 4)
        store.saveNow()
    }
    @Test func repeatedBatchDeduplicatesInOriginalOrder() throws {
        let (root, files) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(baseDir: root.appendingPathComponent("history"))
        store.addFiles(files.map(\.path))
        let ids = store.items.map(\.id)
        store.addFiles(files.map(\.path) + [files[0].path])
        #expect(store.items.map(\.id) == ids)
        store.saveNow()
    }
    @Test func rejectsDirectoriesRemoteURLsAndMissingSources() throws {
        let (root, files) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let accepted = FileTransfer.existingFiles([root, URL(string: "https://example.com/test.pdf")!, root.appendingPathComponent("missing.pdf")] + files)
        #expect(accepted.count == 4)
        let store = HistoryStore(baseDir: root.appendingPathComponent("history"))
        store.addFiles(files.map(\.path))
        try FileManager.default.removeItem(at: files[0])
        #expect(FileTransfer.urls(for: store.items) == nil)
        #expect(store.items.count == 4)
        store.clear(); store.saveNow()
        #expect(FileManager.default.fileExists(atPath: files[1].path))
    }
}
