import AppKit
import SwiftUI

// MARK: - 文本结果面板（OCR 识别结果 / 翻译结果，Stitch 发光卡片风格）
// 功能清单 12.2.3 / 12.3.1：可复制 / 翻译 / 存为历史文本条目

final class TextResultPanel {
    enum Kind {
        case ocr
        case translation
    }

    static let shared = TextResultPanel()

    private var panel: NSPanel?
    private var keyMonitor: Any?

    private init() {}

    func show(kind: Kind, source: String, result: String) {
        let view = TextResultView(
            kind: kind,
            source: source,
            result: result,
            onCopy: {
                writeTextToPasteboard(result)
                Toast.shared.show("已复制")
            },
            onTranslate: { [weak self] in
                guard let self = self else { return }
                self.hide()
                self.translateThenShow(result)
            },
            onSave: {
                HistoryStore.shared.addText(result)
                Toast.shared.show("已存入历史")
            },
            onClose: { [weak self] in self?.hide() }
        )
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 460),
                            styleMask: [.titled, .fullSizeContentView, .closable],
                            backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.standardWindowButton(.miniaturizeButton)?.isHidden = true
            p.standardWindowButton(.zoomButton)?.isHidden = true
            p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: view)
            panel = p
        } else {
            panel?.contentView = NSHostingView(rootView: view)
        }
        panel?.setContentSize(NSHostingView(rootView: view).fittingSize)
        position()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installKeyMonitor()
    }

    func hide() {
        panel?.orderOut(nil)
        removeKeyMonitor()
    }

    private func translateThenShow(_ text: String) {
        Toast.shared.show("翻译中…（\(TranslationService.shared.engineLabel)）")
        TranslationService.shared.translate(text) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let translated):
                    self.show(kind: .translation, source: text, result: translated)
                case .failure(let err):
                    Toast.shared.show("翻译失败：\(err.localizedDescription)")
                }
            }
        }
    }

    private func position() {
        guard let p = panel else { return }
        let m = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(m) }) ?? NSScreen.main else { return }
        let vis = screen.visibleFrame
        var x = m.x - p.frame.width / 2
        var y = m.y - p.frame.height - 14
        x = min(max(x, vis.minX + 12), vis.maxX - p.frame.width - 12)
        y = min(max(y, vis.minY + 12), vis.maxY - p.frame.height - 12)
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.hide()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}

// MARK: - 视图

struct TextResultView: View {
    let kind: TextResultPanel.Kind
    let source: String
    let result: String
    let onCopy: () -> Void
    let onTranslate: () -> Void
    let onSave: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var isOCR: Bool {
        if case .ocr = kind { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            Divider().opacity(0.4)
            ScrollView {
                Text(result)
                    .font(.system(size: 12.5))
                    .foregroundStyle(RubickTheme.onSurface(scheme))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            Divider().opacity(0.4)
            footer
        }
        .padding(14)
        .frame(width: 430, height: 440)
        .background(.ultraThinMaterial)
        .background(RubickTheme.darkBackground.opacity(scheme == .dark ? 0.55 : 0))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(RubickTheme.primary(scheme).opacity(0.3), lineWidth: 0.8))
        .shadow(color: RubickTheme.emerald.opacity(0.15), radius: 10)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: isOCR ? "doc.text.viewfinder" : "character.bubble.fill")
                .font(.system(size: 13))
                .foregroundStyle(RubickTheme.primary(scheme))
            Text(isOCR ? "识别文字" : "翻译结果")
                .font(.system(size: 13, weight: .bold))
            if !isOCR {
                Text(TranslationService.shared.engineLabel)
                    .font(.system(size: 9.5))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(RubickTheme.primary(scheme).opacity(0.14)))
                    .foregroundStyle(RubickTheme.primary(scheme))
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(RubickTheme.muted(scheme))
            .help("关闭")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: onCopy) {
                Label("复制", systemImage: "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(RubickTheme.emerald)
            if isOCR {
                Button(action: onTranslate) {
                    Label("翻译", systemImage: "character.bubble")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(RubickTheme.emerald)
            }
            Button(action: onSave) {
                Label("存入历史", systemImage: "book.closed")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(RubickTheme.emerald)
            Spacer()
            if !source.isEmpty && !isOCR {
                Text("原文 \(source.count) 字")
                    .font(.system(size: 10))
                    .foregroundStyle(RubickTheme.muted(scheme).opacity(0.8))
            }
        }
    }
}
