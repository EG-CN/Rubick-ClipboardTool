import AppKit

/// References local regular files; never moves, copies or deletes the source bytes.
enum FileTransfer {
    static func existingFiles(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            guard url.isFileURL else { return nil }
            let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: normalized.path, isDirectory: &directory), !directory.boolValue,
                  seen.insert(normalized.path).inserted else { return nil }
            return normalized
        }
    }
    static func files(from pasteboard: NSPasteboard) -> [URL] {
        let values = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return existingFiles(values)
    }
    static func urls(for items: [ClipboardItem]) -> [URL]? {
        guard !items.isEmpty, items.allSatisfy({ $0.kind == .file && $0.filePath != nil }) else { return nil }
        let values = items.compactMap { $0.filePath.map { URL(fileURLWithPath: $0) } }
        let valid = existingFiles(values)
        return valid.count == values.count ? valid : nil
    }
    static func filename(_ item: ClipboardItem) -> String { item.filePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "文件位置不可用" }
}
