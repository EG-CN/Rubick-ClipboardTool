import AppKit
import SwiftUI
import CoreImage

// MARK: - 截图标注编辑器（v2.0，功能清单 12.1）
// 7 工具 + 颜色/线宽 + 撤销重做 + 全部快捷键可配置（AnnotateKeyConfig）

struct Annotation: Identifiable, Equatable {
    enum Tool: String, CaseIterable {
        case rect, ellipse, arrow, pen, text, mosaic, highlight

        var symbol: String {
            switch self {
            case .rect: return "rectangle"
            case .ellipse: return "oval"
            case .arrow: return "arrow.up.right"
            case .pen: return "scribble"
            case .text: return "textformat"
            case .mosaic: return "square.grid.3x3"
            case .highlight: return "highlighter"
            }
        }
        var label: String {
            switch self {
            case .rect: return "矩形"
            case .ellipse: return "椭圆"
            case .arrow: return "箭头"
            case .pen: return "画笔"
            case .text: return "文字"
            case .mosaic: return "马赛克"
            case .highlight: return "高亮"
            }
        }
    }

    let id = UUID()
    var tool: Tool
    var rect: CGRect = .zero          // 归一化到图片（原点左上）
    var points: [CGPoint] = []        // 画笔路径（归一化）
    var text: String = ""
    var colorIndex: Int = 0
    var lineWidth: CGFloat = 4        // 创建时的显示点宽
    var cornerRadius: CGFloat = 0     // 矩形圆角（显示点，0 = 直角）
    var blockSize: CGFloat = 16       // 马赛克颗粒（像素）
    var mosaicStyle: Int = 0          // 0 像素 / 1 模糊 / 2 色块
    var fillOpacity: CGFloat = 0.35   // 高亮透明度
    var highlightEllipse: Bool = false // 高亮形状：false 方形 / true 圆形
    var startPoint: CGPoint = .zero   // 箭头起点（归一化）
    var endPoint: CGPoint = .zero     // 箭头终点（归一化）
    var fontSize: CGFloat = 16        // 文字工具字号（显示点）
    var displaySize: CGSize = .zero   // 创建时图片显示尺寸（用于展平缩放）
}

// MARK: - 编辑器共享状态（供视图绑定 + 控制器快捷键驱动）

final class AnnotateModel: ObservableObject {
    /// nil = 未选择工具（截图后默认待机，选工具后才可绘制）
    @Published var tool: Annotation.Tool? = nil
    @Published var colorIndex = 0
    @Published var lineWidth: CGFloat = 4
    @Published var fontSize: CGFloat = 16
    @Published var cornerRadius: CGFloat = 0
    @Published var blockSize: CGFloat = 16     // 马赛克颗粒
    @Published var mosaicStyle: Int = 0        // 0 像素 / 1 模糊 / 2 色块
    @Published var fillOpacity: CGFloat = 0.35 // 高亮透明度
    @Published var highlightEllipse: Bool = false // 高亮形状
    @Published var annotations: [Annotation] = []
    @Published var redoStack: [Annotation] = []
    @Published var textEditing: (id: UUID, position: CGPoint)?
    @Published var textDraft = ""
    @Published var imageRect: CGRect = .zero
    @Published var ocrText: String?
    @Published var translatedText: String?
    weak var panelTextView: NSTextView?

    func commit(_ a: Annotation) {
        annotations.append(a)
        redoStack.removeAll()
    }

    func undo() {
        textEditing = nil
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
    }

    func redo() {
        textEditing = nil
        guard let last = redoStack.popLast() else { return }
        annotations.append(last)
    }

    var sidePanelText: String? {
        translatedText ?? ocrText
    }

    func closeSidePanel() {
        ocrText = nil
        translatedText = nil
    }

    /// 识图：对原始截图整图做 OCR，结果显示在侧面板
    func runOCR(on image: NSImage) {
        closeSidePanel()
        Toast.shared.show("正在识别文字…")
        OCRService.shared.recognize(image: image) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let r):
                    let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else {
                        Toast.shared.show("未识别到文字")
                        return
                    }
                    self.ocrText = text
                    self.translatedText = nil
                case .failure(let err):
                    Toast.shared.show("识别失败：\(err.localizedDescription)")
                }
            }
        }
    }

    /// 翻译：优先翻译侧面板文本视图中选中的文字，否则翻译全部识别文本
    func translateSideSelection() {
        let whole = sidePanelText
        var text: String?
        if let tv = panelTextView {
            let full = tv.string as NSString
            let sel = tv.selectedRange()
            if sel.length > 0 && NSMaxRange(sel) <= full.length {
                text = full.substring(with: sel)
            }
        }
        let target = text ?? whole
        guard let target = target, !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Toast.shared.show("没有可翻译的文字")
            return
        }
        Toast.shared.show("翻译中…（\(TranslationService.shared.engineLabel)）")
        TranslationService.shared.translate(target) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let t):
                    self.ocrText = self.ocrText ?? target
                    self.translatedText = t
                case .failure(let err):
                    Toast.shared.show("翻译失败：\(err.localizedDescription)")
                }
            }
        }
    }

    /// 点击已有文字 → 进入编辑态
    func beginEditingText(_ a: Annotation) {
        textEditing = (a.id, a.rect.origin)
        textDraft = a.text
    }

    /// 提交文字：已有注释则更新，否则新建；清空文本 = 删除该注释
    func commitText() {
        let text = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let editing = textEditing else { return }
        let id = editing.id
        let pos = editing.position
        textEditing = nil
        if let idx = annotations.firstIndex(where: { $0.id == id }) {
            if text.isEmpty {
                annotations.remove(at: idx)
            } else {
                var a = annotations[idx]
                a.text = text
                a.fontSize = fontSize
                a.colorIndex = colorIndex
                a.rect.origin = pos
                annotations[idx] = a
            }
            return
        }
        guard !text.isEmpty else { return }
        var a = Annotation(tool: .text)
        a.rect = CGRect(origin: pos, size: .zero)
        a.text = text
        a.colorIndex = colorIndex
        a.lineWidth = lineWidth
        a.fontSize = fontSize
        a.displaySize = imageRect.size
        commit(a)
    }

    /// 拖动文字：整体赋值触发发布
    func updateTextPosition(id: UUID, to p: CGPoint) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        var a = annotations[idx]
        a.rect.origin = p
        annotations[idx] = a
    }
}

final class AnnotationController {
    static let shared = AnnotationController()

    /// Shift 锁定：以起点为锚的正方形
    static func squareRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        let side = max(abs(b.x - a.x), abs(b.y - a.y))
        return CGRect(x: b.x >= a.x ? a.x : a.x - side,
                      y: b.y >= a.y ? a.y : a.y - side,
                      width: side, height: side)
    }

    /// Shift 锁定：箭头方向对齐 45° 倍角
    static func snap45(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0.5 else { return b }
        let angle = atan2(dy, dx)
        let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: a.x + cos(snapped) * len, y: a.y + sin(snapped) * len)
    }

    private var window: NSWindow?
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var completion: ((NSImage) -> Void)?
    private var model: AnnotateModel?
    private var currentImage: NSImage?

    static let palette: [NSColor] = [
        NSColor(red: 0.18, green: 0.80, blue: 0.44, alpha: 1),   // 祖母绿
        NSColor(red: 1.00, green: 0.36, blue: 0.36, alpha: 1),   // 红
        NSColor(red: 1.00, green: 0.82, blue: 0.29, alpha: 1),   // 黄
        NSColor.white                                             // 白
    ]

    private init() {}

    /// at：截图选区（AppKit 全局坐标，左下原点）——编辑器原地弹出；nil 时贴鼠标
    func show(image: NSImage, at rect: CGRect? = nil, completion: @escaping (NSImage) -> Void) {
        self.completion = completion
        self.currentImage = image
        let m = AnnotateModel()
        model = m

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let vis = screen.visibleFrame
        let chromeH: CGFloat = 178   // 头部拖动条 + 两行工具栏 + 间距
        let pad: CGFloat = 24
        let maxW = min(vis.width * 0.88, image.size.width)
        let maxH = min(vis.height * 0.8, image.size.height + chromeH)
        let s = min(maxW / max(image.size.width, 1), maxH / max(image.size.height, 1), 1)
        let dispW = max(image.size.width * s, 60)
        let dispH = max(image.size.height * s, 40)
        let winW = max(dispW + pad, 540)
        let winH = dispH + chromeH

        let view = AnnotateEditorView(
            image: image,
            displaySize: CGSize(width: dispW, height: dispH),
            model: m,
            onMove: { [weak self] delta in
                guard let self = self, let w = self.window else { return }
                var f = w.frame
                f.origin.x += delta.x
                f.origin.y -= delta.y   // 视图坐标 y 向下 → 窗口坐标 y 向上
                w.setFrameOrigin(f.origin)
            },
            onConfirm: { [weak self] annotated in self?.finish(annotated) },
            onCancel: { [weak self] in self?.cancel() }
        )
        if window == nil {
            let w = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.backgroundColor = .clear
            w.isOpaque = false
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.setContentSize(NSSize(width: winW, height: winH))
        window?.contentView = NSHostingView(rootView: view)

        // 定位：优先选区原地（含工具栏下方空间）；无选区贴鼠标
        let origin: NSPoint
        if let r = rect {
            origin = NSPoint(x: r.minX - 12, y: r.minY - chromeH - 12)
        } else {
            let mp = NSEvent.mouseLocation
            origin = NSPoint(x: mp.x - winW / 2, y: mp.y - winH + 20)
        }
        var o = origin
        o.x = min(max(o.x, vis.minX + 8), vis.maxX - winW - 8)
        o.y = min(max(o.y, vis.minY + 8), vis.maxY - winH - 8)
        window?.setFrameOrigin(o)
        window?.makeKeyAndOrderFront(nil)
        installKeyMonitor(model: m)
    }

    private func installKeyMonitor(model: AnnotateModel) {
        if let mk = keyMonitor { NSEvent.removeMonitor(mk) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.window?.isVisible == true else { return event }
            let fr = NSApp.keyWindow?.firstResponder
            let ak = AnnotateKeyConfig.shared

            // 侧面板文本视图：T 翻译选中 / Esc 关面板 / 其余放行（⌘C 可用）
            if let tv = fr as? NSTextView, tv === model.panelTextView {
                if ak.matches(.translate, event: event) {
                    model.translateSideSelection()
                    return nil
                }
                if event.keyCode == 53 {
                    model.closeSidePanel()
                    return nil
                }
                return event
            }
            // 文字标注输入中：放行（Esc 取消输入）
            if fr is NSTextView {
                if event.keyCode == 53 {
                    model.textEditing = nil
                    return nil
                }
                return event
            }
            // 侧面板打开时 Esc 先关面板
            if event.keyCode == 53 && model.sidePanelText != nil {
                model.closeSidePanel()
                return nil
            }
            if ak.matches(.confirm, event: event) { self.confirm(); return nil }
            if ak.matches(.cancel, event: event) { self.cancel(); return nil }
            if ak.matches(.undo, event: event) { model.undo(); return nil }
            if ak.matches(.redo, event: event) { model.redo(); return nil }
            if ak.matches(.ocr, event: event) {
                if let img = self.currentImage { model.runOCR(on: img) }
                return nil
            }
            if ak.matches(.translate, event: event) {
                model.translateSideSelection()
                return nil
            }
            let toolMap: [(AnnotateKeyConfig.Action, Annotation.Tool)] = [
                (.toolRect, .rect), (.toolEllipse, .ellipse), (.toolArrow, .arrow),
                (.toolPen, .pen), (.toolText, .text), (.toolMosaic, .mosaic),
                (.toolHighlight, .highlight)
            ]
            for (action, tool) in toolMap where ak.matches(action, event: event) {
                model.tool = tool
                return nil
            }
            return event
        }

        // 全局监听兜底：编辑器打开时应用未激活也能响应按键
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.window?.isVisible == true else { return }
            DispatchQueue.main.async { self.handleGlobalEditorKey(event, model: model) }
        }
    }

    private func handleGlobalEditorKey(_ event: NSEvent, model: AnnotateModel) {
        let ak = AnnotateKeyConfig.shared
        if event.keyCode == 53 {
            if model.sidePanelText != nil { model.closeSidePanel() } else { cancel() }
            return
        }
        if ak.matches(.confirm, event: event) { confirm(); return }
        if ak.matches(.undo, event: event) { model.undo(); return }
        if ak.matches(.redo, event: event) { model.redo(); return }
        if ak.matches(.ocr, event: event) {
            if let img = currentImage { model.runOCR(on: img) }
            return
        }
        if ak.matches(.translate, event: event) { model.translateSideSelection(); return }
        let toolMap: [(AnnotateKeyConfig.Action, Annotation.Tool)] = [
            (.toolRect, .rect), (.toolEllipse, .ellipse), (.toolArrow, .arrow),
            (.toolPen, .pen), (.toolText, .text), (.toolMosaic, .mosaic),
            (.toolHighlight, .highlight)
        ]
        for (action, tool) in toolMap where ak.matches(action, event: event) {
            model.tool = tool
            return
        }
    }

    private func confirm() {
        guard let m = model, let img = currentImage else { return }
        m.textEditing = nil
        let out = Self.flatten(image: img, annotations: m.annotations) ?? img
        finish(out)
    }

    private func finish(_ image: NSImage) {
        teardown()
        completion?(image)
        completion = nil
    }

    private func cancel() {
        teardown()
        completion = nil
    }

    private func teardown() {
        window?.orderOut(nil)
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
        model = nil
        currentImage = nil
    }

    // MARK: 展平（标注烘焙进图片）

    static func flatten(image: NSImage, annotations: [Annotation]) -> NSImage? {
        let size = image.size
        let pw = max(Int(size.width), 1)
        let ph = max(Int(size.height), 1)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: size))
        let baseCG = image.cgImage()
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for a in annotations {
            draw(a, imageSize: size, baseCG: baseCG, ctx: ctx)
        }
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: size)
        out.addRepresentation(rep)
        return out
    }

    private static func draw(_ a: Annotation, imageSize: CGSize, baseCG: CGImage?, ctx: CGContext) {
        let scale = imageSize.width / max(a.displaySize.width, 1)
        let lw = max(a.lineWidth * scale, 1)
        let color = palette[a.colorIndex]
        let r = CGRect(x: a.rect.minX * imageSize.width,
                       y: (1 - a.rect.maxY) * imageSize.height,
                       width: a.rect.width * imageSize.width,
                       height: a.rect.height * imageSize.height)
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.withAlphaComponent(0.3).cgColor)
        ctx.setLineWidth(lw)

        switch a.tool {
        case .rect:
            let rad = a.cornerRadius * scale
            if rad > 0.5 {
                ctx.addPath(CGPath(roundedRect: r.insetBy(dx: lw / 2, dy: lw / 2),
                                   cornerWidth: rad, cornerHeight: rad, transform: nil))
                ctx.strokePath()
            } else {
                ctx.stroke(r.insetBy(dx: lw / 2, dy: lw / 2))
            }
        case .ellipse:
            ctx.strokeEllipse(in: r.insetBy(dx: lw / 2, dy: lw / 2))
        case .arrow:
            let hasDir = (a.startPoint != .zero || a.endPoint != .zero)
            let sPt = hasDir
                ? CGPoint(x: a.startPoint.x * imageSize.width, y: (1 - a.startPoint.y) * imageSize.height)
                : CGPoint(x: r.minX, y: r.minY)
            let ePt = hasDir
                ? CGPoint(x: a.endPoint.x * imageSize.width, y: (1 - a.endPoint.y) * imageSize.height)
                : CGPoint(x: r.maxX, y: r.maxY)
            drawArrow(from: sPt, to: ePt, ctx: ctx, color: color)
        case .pen:
            guard a.points.count > 1 else { break }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: a.points[0].x * imageSize.width,
                                  y: (1 - a.points[0].y) * imageSize.height))
            for p in a.points.dropFirst() {
                path.addLine(to: CGPoint(x: p.x * imageSize.width,
                                         y: (1 - p.y) * imageSize.height))
            }
            ctx.addPath(path)
            ctx.strokePath()
        case .text:
            let font = NSFont.systemFont(ofSize: max(a.fontSize * scale, 10), weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            (a.text as NSString).draw(at: CGPoint(x: r.minX, y: r.minY), withAttributes: attrs)
        case .mosaic:
            if a.mosaicStyle == 2 {
                ctx.setFillColor(color.withAlphaComponent(0.85).cgColor)
                ctx.fill(r)
            } else {
                drawMosaic(r, imageSize: imageSize, baseCG: baseCG,
                           blockSize: a.blockSize, blur: a.mosaicStyle == 1)
            }
        case .highlight:
            ctx.setFillColor(color.withAlphaComponent(a.fillOpacity).cgColor)
            if a.highlightEllipse {
                ctx.fillEllipse(in: r)
            } else {
                ctx.fill(r)
            }
        }
    }

    private static func drawArrow(from start: CGPoint, to tip: CGPoint, ctx: CGContext, color: NSColor) {
        let angle = atan2(tip.y - start.y, tip.x - start.x)
        let headLen = max(hypot(tip.x - start.x, tip.y - start.y) * 0.22, 16)
        let headHalf = headLen * 0.42
        let base = CGPoint(x: tip.x - cos(angle) * headLen, y: tip.y - sin(angle) * headLen)
        // 箭杆画到三角根部
        ctx.move(to: start)
        ctx.addLine(to: base)
        ctx.strokePath()
        // 实心三角箭头
        let perp = angle + .pi / 2
        let p1 = CGPoint(x: base.x + cos(perp) * headHalf, y: base.y + sin(perp) * headHalf)
        let p2 = CGPoint(x: base.x - cos(perp) * headHalf, y: base.y - sin(perp) * headHalf)
        ctx.move(to: p1)
        ctx.addLine(to: tip)
        ctx.addLine(to: p2)
        ctx.closePath()
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
    }

    private static func drawMosaic(_ r: CGRect, imageSize: CGSize, baseCG: CGImage?, blockSize: CGFloat = 16, blur: Bool = false) {
        guard let baseCG = baseCG else {
            NSColor.gray.withAlphaComponent(0.5).setFill()
            NSBezierPath(rect: r).fill()
            return
        }
        let scalePx = CGFloat(baseCG.width) / imageSize.width
        let cropPx = CGRect(x: r.minX * scalePx,
                            y: (imageSize.height - r.maxY) * scalePx,
                            width: r.width * scalePx,
                            height: r.height * scalePx)
        var ci = CIImage(cgImage: baseCG).cropped(to: cropPx)
        if blur {
            ci = ci.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 12])
        } else {
            ci = ci.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(blockSize, 4)])
        }
        if let cg = CIContext().createCGImage(ci, from: ci.extent) {
            NSImage(cgImage: cg, size: r.size).draw(in: r)
        }
    }
}

// MARK: - 编辑器视图（紧凑悬浮卡片：原地弹出 + 祖母绿荧光，非全屏）

struct AnnotateEditorView: View {
    let image: NSImage
    let displaySize: CGSize      // 图片显示尺寸
    @ObservedObject var model: AnnotateModel
    let onMove: (CGPoint) -> Void
    let onConfirm: (NSImage) -> Void
    let onCancel: () -> Void

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var penPath: [CGPoint] = []
    @State private var moveLast: CGPoint?
    @State private var hoveredHelp: String?
    @State private var dragTextID: UUID?
    @State private var dragTextStart: CGPoint?
    @FocusState private var textFocused: Bool

    @ObservedObject private var keys = AnnotateKeyConfig.shared

    private var imageRect: CGRect { CGRect(origin: .zero, size: displaySize) }

    private func keyDisplay(_ action: AnnotateKeyConfig.Action) -> String {
        keys.keys[action]?.display ?? "?"
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: displaySize.width, height: displaySize.height)
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 2)

                Canvas { ctx, _ in
                    for a in model.annotations
                    where model.textEditing?.id != a.id { drawPreview(&ctx, a, imageRect: imageRect) }
                    if model.tool == .pen && penPath.count > 1 {
                        var a = Annotation(tool: .pen)
                        a.points = penPath
                        a.colorIndex = model.colorIndex
                        a.lineWidth = model.lineWidth
                        a.displaySize = displaySize
                        drawPreview(&ctx, a, imageRect: imageRect)
                    } else if let p = inProgress() {
                        drawPreview(&ctx, p, imageRect: imageRect)
                    }
                    if let editing = model.textEditing, !model.textDraft.isEmpty {
                        var a = Annotation(tool: .text)
                        a.rect = CGRect(origin: editing.position, size: .zero)
                        a.text = model.textDraft
                        a.colorIndex = model.colorIndex
                        a.fontSize = model.fontSize
                        a.displaySize = displaySize
                        drawPreview(&ctx, a, imageRect: imageRect)
                    }
                }
                .frame(width: displaySize.width, height: displaySize.height)
                .allowsHitTesting(false)

                if let editing = model.textEditing {
                    TextField("输入文字…", text: $model.textDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: model.fontSize, weight: .semibold))
                        .foregroundStyle(Color(AnnotationController.palette[model.colorIndex]))
                        .focused($textFocused)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(width: 240, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.7)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(RubickTheme.emerald, lineWidth: 1))
                        .position(x: min(displaySize.width - 120, max(120, editing.position.x * displaySize.width + 120)),
                                  y: min(displaySize.height - 12, max(14, editing.position.y * displaySize.height + 10)))
                        .onSubmit { model.commitText() }
                }

                if model.sidePanelText != nil {
                    EditorSidePanel(model: model)
                        .frame(width: min(330, displaySize.width), height: displaySize.height)
                }
            }
            .frame(width: displaySize.width, height: displaySize.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let p = clamp(v.startLocation)
                        // 首次按下：未选工具或文字工具时，命中已有文字 → 拖动它
                        if dragStart == nil, dragTextID == nil,
                           (model.tool == nil || model.tool == .text),
                           let hit = hitTextAnnotation(at: normalize(p)) {
                            dragTextID = hit.id
                            dragTextStart = p
                            model.textEditing = nil
                            return
                        }
                        if let id = dragTextID {
                            model.updateTextPosition(id: id, to: normalize(clamp(v.location)))
                            return
                        }
                        model.textEditing = nil
                        dragStart = dragStart ?? p
                        dragCurrent = clamp(v.location)
                        if model.tool == .pen {
                            let n = normalize(clamp(v.location))
                            if let last = penPath.last {
                                if hypot(n.x - last.x, n.y - last.y) > 0.002 { penPath.append(n) }
                            } else {
                                penPath = [n]
                            }
                        }
                    }
                    .onEnded { v in
                        if let id = dragTextID {
                            let moved = hypot(v.location.x - (dragTextStart?.x ?? v.location.x),
                                              v.location.y - (dragTextStart?.y ?? v.location.y))
                            dragTextID = nil
                            dragTextStart = nil
                            if moved < 6,
                               let idx = model.annotations.firstIndex(where: { $0.id == id }) {
                                model.beginEditingText(model.annotations[idx])
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { textFocused = true }
                            }
                            return
                        }
                        dragCurrent = clamp(v.location)
                        defer { dragStart = nil; dragCurrent = nil; penPath = [] }
                        guard let start = dragStart else { return }
                        var end = dragCurrent ?? start
                        if model.tool == .text {
                            let normStart = normalize(start)
                            if hypot(start.x - end.x, start.y - end.y) < 6 {
                                model.textDraft = ""
                                model.textEditing = (UUID(), normStart)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { textFocused = true }
                            }
                            return
                        }
                        guard let tool = model.tool else { return }
                        // Shift 锁定：形状→正方形/正圆；箭头→45°；画笔→直线
                        if NSEvent.modifierFlags.contains(.shift) {
                            switch tool {
                            case .rect, .ellipse, .highlight:
                                let sq = AnnotationController.squareRect(from: start, to: end)
                                end = CGPoint(x: sq.maxX, y: sq.maxY)
                            case .arrow:
                                end = AnnotationController.snap45(from: start, to: end)
                            case .pen:
                                penPath = [normalize(start), normalize(end)]
                            default: break
                            }
                        }
                        let normStart = normalize(start)
                        let normEnd = normalize(end)
                        if tool == .pen {
                            var pts = penPath
                            if pts.count < 2 { pts = [normStart, normEnd] }
                            guard pts.count >= 2 else { return }
                            var a = Annotation(tool: .pen)
                            a.points = pts
                            let xs = pts.map { $0.x }
                            let ys = pts.map { $0.y }
                            a.rect = CGRect(x: xs.min()!, y: ys.min()!,
                                            width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                            a.colorIndex = model.colorIndex
                            a.lineWidth = model.lineWidth
                            a.displaySize = displaySize
                            model.commit(a)
                            return
                        }
                        let w = abs(normEnd.x - normStart.x)
                        let h = abs(normEnd.y - normStart.y)
                        guard w > 0.004 || h > 0.004 else { return }
                        var a = Annotation(tool: tool)
                        a.rect = CGRect(x: min(normStart.x, normEnd.x), y: min(normStart.y, normEnd.y),
                                        width: w, height: h)
                        a.colorIndex = model.colorIndex
                        a.lineWidth = model.lineWidth
                        a.cornerRadius = tool == .rect ? model.cornerRadius : 0
                        a.blockSize = model.blockSize
                        a.mosaicStyle = model.mosaicStyle
                        a.fillOpacity = model.fillOpacity
                        a.highlightEllipse = model.highlightEllipse
                        a.startPoint = tool == .arrow ? normStart : .zero
                        a.endPoint = tool == .arrow ? normEnd : .zero
                        a.fontSize = tool == .text ? model.fontSize : model.lineWidth * 4
                        a.displaySize = displaySize
                        model.commit(a)
                    }
            )

            toolbar
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(RubickTheme.darkBackground.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(RubickTheme.emerald.opacity(0.45), lineWidth: 1))
        .shadow(color: RubickTheme.emerald.opacity(0.35), radius: 18)   // 祖母绿荧光
        .onAppear {
            model.imageRect = imageRect
            NSCursor.crosshair.set()
        }
        .onDisappear { NSCursor.arrow.set() }
    }

    /// 顶部拖动条：按住拖动移动卡片
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil.and.outline")
                .font(.system(size: 10))
                .foregroundStyle(RubickTheme.emeraldBright)
            Text("标注 · 按住此处拖动")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { v in
                    let t = CGPoint(x: v.translation.width, y: v.translation.height)
                    if let last = moveLast {
                        onMove(CGPoint(x: t.x - last.x, y: t.y - last.y))
                    }
                    moveLast = t
                }
                .onEnded { _ in moveLast = nil }
        )
    }

    /// 命中检测：点是否落在已提交的文字上
    private func hitTextAnnotation(at normalized: CGPoint) -> Annotation? {
        let viewPoint = CGPoint(x: normalized.x * displaySize.width,
                                y: normalized.y * displaySize.height)
        for a in model.annotations.reversed() where a.tool == .text {
            let size = textSize(a.text, fontSize: a.fontSize)
            let r = CGRect(x: a.rect.origin.x * displaySize.width,
                           y: a.rect.origin.y * displaySize.height,
                           width: size.width, height: size.height)
            if r.insetBy(dx: -4, dy: -4).contains(viewPoint) {
                return a
            }
        }
        return nil
    }

    private func textSize(_ text: String, fontSize: CGFloat) -> CGSize {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(fontSize, 8), weight: .semibold)
        ]
        return (text as NSString).size(withAttributes: attrs)
    }

    private func normalize(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / max(displaySize.width, 1),
                y: p.y / max(displaySize.height, 1))
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), displaySize.width),
                y: min(max(p.y, 0), displaySize.height))
    }

    private func inProgress() -> Annotation? {
        guard let tool = model.tool, let start = dragStart else { return nil }
        var end = dragCurrent ?? start
        if NSEvent.modifierFlags.contains(.shift) {
            switch tool {
            case .rect, .ellipse, .highlight:
                let sq = AnnotationController.squareRect(from: start, to: end)
                end = CGPoint(x: sq.maxX, y: sq.maxY)
            case .arrow:
                end = AnnotationController.snap45(from: start, to: end)
            default: break
            }
        }
        let n1 = normalize(start)
        let n2 = normalize(end)
        var a = Annotation(tool: tool)
        a.rect = CGRect(x: min(n1.x, n2.x), y: min(n1.y, n2.y),
                        width: abs(n2.x - n1.x), height: abs(n2.y - n1.y))
        a.colorIndex = model.colorIndex
        a.lineWidth = model.lineWidth
        a.cornerRadius = tool == .rect ? model.cornerRadius : 0
        a.mosaicStyle = model.mosaicStyle
        a.fillOpacity = model.fillOpacity
        a.highlightEllipse = model.highlightEllipse
        a.startPoint = tool == .arrow ? n1 : .zero
        a.endPoint = tool == .arrow ? n2 : .zero
        a.fontSize = model.lineWidth * 4
        a.displaySize = displaySize
        return a
    }

    private func drawPreview(_ ctx: inout GraphicsContext, _ a: Annotation, imageRect: CGRect) {
        let r = CGRect(x: a.rect.minX * imageRect.width,
                       y: a.rect.minY * imageRect.height,
                       width: a.rect.width * imageRect.width,
                       height: a.rect.height * imageRect.height)
        let color = Color(AnnotationController.palette[a.colorIndex])
        switch a.tool {
        case .rect:
            let rad = a.cornerRadius * (imageRect.width / max(a.displaySize.width, 1))
            if rad > 0.5 {
                ctx.stroke(Path(roundedRect: r, cornerRadius: rad), with: .color(color), lineWidth: a.lineWidth)
            } else {
                ctx.stroke(Path(r), with: .color(color), lineWidth: a.lineWidth)
            }
        case .ellipse:
            ctx.stroke(Path(ellipseIn: r), with: .color(color), lineWidth: a.lineWidth)
        case .arrow:
            let hasDir = (a.startPoint != .zero || a.endPoint != .zero)
            let sPt = hasDir
                ? CGPoint(x: a.startPoint.x * imageRect.width, y: a.startPoint.y * imageRect.height)
                : CGPoint(x: r.minX, y: r.minY)
            let ePt = hasDir
                ? CGPoint(x: a.endPoint.x * imageRect.width, y: a.endPoint.y * imageRect.height)
                : CGPoint(x: r.maxX, y: r.maxY)
            let angle = atan2(ePt.y - sPt.y, ePt.x - sPt.x)
            let totalLen = hypot(ePt.x - sPt.x, ePt.y - sPt.y)
            let headLen = max(totalLen * 0.22, 14)
            let headHalf = headLen * 0.45
            let base = CGPoint(x: ePt.x - cos(angle) * headLen, y: ePt.y - sin(angle) * headLen)
            var p = Path()
            p.move(to: sPt)
            p.addLine(to: base)
            ctx.stroke(p, with: .color(color), lineWidth: a.lineWidth)
            let perp = angle + .pi / 2
            var tri = Path()
            tri.move(to: CGPoint(x: base.x + cos(perp) * headHalf, y: base.y + sin(perp) * headHalf))
            tri.addLine(to: ePt)
            tri.addLine(to: CGPoint(x: base.x - cos(perp) * headHalf, y: base.y - sin(perp) * headHalf))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(color))
        case .pen:
            var p = Path()
            let pts = a.points
            if let first = pts.first {
                p.move(to: CGPoint(x: first.x * imageRect.width,
                                   y: first.y * imageRect.height))
                for pt in pts.dropFirst() {
                    p.addLine(to: CGPoint(x: pt.x * imageRect.width,
                                          y: pt.y * imageRect.height))
                }
            }
            ctx.stroke(p, with: .color(color),
                       style: StrokeStyle(lineWidth: a.lineWidth, lineCap: .round, lineJoin: .round))
        case .text:
            ctx.draw(Text(a.text).font(.system(size: a.fontSize, weight: .semibold)).foregroundStyle(color),
                     at: CGPoint(x: r.minX, y: r.minY), anchor: .bottomLeading)
        case .mosaic:
            switch a.mosaicStyle {
            case 2:
                ctx.fill(Path(r), with: .color(color.opacity(0.85)))
            case 1:
                if let tiny = mosaicTiny(for: r) {
                    ctx.draw(Image(nsImage: tiny).interpolation(.high), in: r)
                } else {
                    ctx.fill(Path(r), with: .color(.gray.opacity(0.45)))
                }
            default:
                if let tiny = mosaicTiny(for: r) {
                    ctx.draw(Image(nsImage: tiny).interpolation(.none), in: r)
                } else {
                    ctx.fill(Path(r), with: .color(.gray.opacity(0.45)))
                }
            }
        case .highlight:
            if a.highlightEllipse {
                ctx.fill(Path(ellipseIn: r), with: .color(color.opacity(a.fillOpacity)))
            } else {
                ctx.fill(Path(r), with: .color(color.opacity(a.fillOpacity)))
            }
        }
    }

    // MARK: 工具栏（两行紧凑）

    private var toolbar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Annotation.Tool.allCases, id: \.self) { t in
                    toolButton(t)
                }
                Button {
                    model.runOCR(on: image)
                } label: {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 14))
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                        .foregroundStyle(RubickTheme.emeraldBright)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredHelp = hovering ? "识图（\(keyDisplay(.ocr))）" : nil
                }
                if model.tool == .rect {
                    Picker("", selection: $model.cornerRadius) {
                        Text("直角").tag(CGFloat(0))
                        Text("圆角").tag(CGFloat(8))
                        Text("大圆角").tag(CGFloat(16))
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .onChange(of: model.cornerRadius) { newValue in
                        if let idx = model.annotations.lastIndex(where: { $0.tool == .rect }) {
                            var a = model.annotations[idx]
                            a.cornerRadius = newValue
                            model.annotations[idx] = a
                        }
                    }
                }
                if model.tool == .text {
                    Picker("", selection: $model.fontSize) {
                        Text("小").tag(CGFloat(12))
                        Text("中").tag(CGFloat(16))
                        Text("大").tag(CGFloat(22))
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                }
                if model.tool == .mosaic {
                    Picker("", selection: $model.mosaicStyle) {
                        Text("马赛克").tag(0)
                        Text("模糊").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                }
                if model.tool == .highlight {
                    Picker("", selection: $model.highlightEllipse) {
                        Text("方形").tag(false)
                        Text("圆形").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                    Picker("", selection: $model.fillOpacity) {
                        Text("浅").tag(CGFloat(0.18))
                        Text("中").tag(CGFloat(0.35))
                        Text("深").tag(CGFloat(0.55))
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                }
                Spacer()
                ForEach(0..<AnnotationController.palette.count, id: \.self) { i in
                    colorDot(i)
                }
                Picker("", selection: $model.lineWidth) {
                    Text("细").tag(CGFloat(2))
                    Text("中").tag(CGFloat(4))
                    Text("粗").tag(CGFloat(6))
                }
                .pickerStyle(.segmented)
                .frame(width: 104)
            }
            HStack(spacing: 8) {
                toolbarAction("arrow.uturn.backward", help: "撤销 \(keyDisplay(.undo))", enabled: !model.annotations.isEmpty) {
                    model.undo()
                }
                toolbarAction("arrow.uturn.forward", help: "重做 \(keyDisplay(.redo))", enabled: !model.redoStack.isEmpty) {
                    model.redo()
                }
                Text(hoveredHelp ?? "\(keyDisplay(.toolRect))–\(keyDisplay(.toolHighlight)) 工具 · \(keyDisplay(.ocr)) 识图 · \(keyDisplay(.translate)) 翻译 · \(keyDisplay(.undo)) 撤销 · \(keyDisplay(.confirm)) 确认 · ⎋ 取消")
                    .font(.system(size: 9.5))
                    .foregroundStyle(hoveredHelp != nil ? RubickTheme.emeraldBright : .white.opacity(0.55))
                    .lineLimit(1)
                Spacer()
                Button {
                    model.textEditing = nil
                    onConfirm(AnnotationController.flatten(image: image, annotations: model.annotations) ?? image)
                } label: {
                    Label("确认", systemImage: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(RubickTheme.emerald)
                Button {
                    onCancel()
                } label: {
                    Label("取消", systemImage: "xmark")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(RubickTheme.emerald.opacity(0.3), lineWidth: 0.8))
    }

    private func toolButton(_ t: Annotation.Tool) -> some View {
        Button {
            model.tool = (model.tool == t) ? nil : t
        } label: {
            Group {
                if t == .text {
                    Text("T")
                        .font(.system(size: 15, weight: .heavy))
                } else {
                    Image(systemName: t.symbol)
                        .font(.system(size: 13))
                }
            }
            .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 7).fill(model.tool == t
                                                                   ? RubickTheme.emerald.opacity(0.22)
                                                                   : .white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
                    model.tool == t ? RubickTheme.emerald : .white.opacity(0.12), lineWidth: 1))
                .foregroundStyle(model.tool == t ? RubickTheme.emeraldBright : .white.opacity(0.85))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredHelp = hovering ? "\(t.label)（\(keyForTool(t) ?? "点击")）" : nil
        }
    }

    private func keyForTool(_ t: Annotation.Tool) -> String? {
        let map: [Annotation.Tool: AnnotateKeyConfig.Action] = [
            .rect: .toolRect, .ellipse: .toolEllipse, .arrow: .toolArrow,
            .pen: .toolPen, .text: .toolText, .mosaic: .toolMosaic, .highlight: .toolHighlight
        ]
        guard let a = map[t] else { return nil }
        return keys.keys[a]?.display
    }

    private func colorDot(_ i: Int) -> some View {
        Button {
            model.colorIndex = i
        } label: {
            Circle()
                .fill(Color(AnnotationController.palette[i]))
                .frame(width: 15, height: 15)
                .overlay(Circle().strokeBorder(model.colorIndex == i ? .white : .clear, lineWidth: 1.5))
                .shadow(color: model.colorIndex == i ? Color(AnnotationController.palette[i]).opacity(0.8) : .clear, radius: 3)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredHelp = hovering ? "标注颜色" : nil
        }
    }

    /// 马赛克预览：把区域压成 14×14 小图再放大 → 像素块效果（实时、廉价）
    private func mosaicTiny(for rect: CGRect) -> NSImage? {
        guard rect.width > 2, rect.height > 2 else { return nil }
        let sx = displaySize.width / max(image.size.width, 1)
        let sy = displaySize.height / max(image.size.height, 1)
        let srcTop = CGRect(x: rect.minX / sx,
                            y: rect.minY / sy,
                            width: rect.width / sx,
                            height: rect.height / sy)
        let from = CGRect(x: srcTop.minX,
                          y: image.size.height - srcTop.maxY,
                          width: srcTop.width, height: srcTop.height)
        let out = NSImage(size: NSSize(width: 14, height: 14))
        out.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: 14, height: 14),
                   from: from, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }

    private func toolbarAction(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .foregroundStyle(enabled ? .white.opacity(0.85) : .white.opacity(0.3))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering in
            hoveredHelp = hovering ? help : nil
        }
    }
}

// MARK: - 标注编辑器侧面板（OCR 结果 / 翻译，选中文字按 T 翻译，⌘C 复制）

struct EditorSidePanel: View {
    @ObservedObject var model: AnnotateModel

    private var isTranslation: Bool { model.translatedText != nil }
    private var text: String { model.sidePanelText ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: isTranslation ? "character.bubble.fill" : "doc.text.viewfinder")
                    .font(.system(size: 13))
                    .foregroundStyle(RubickTheme.emeraldBright)
                Text(isTranslation ? "翻译结果" : "识别文字")
                    .font(.system(size: 13, weight: .bold))
                if isTranslation {
                    Text(TranslationService.shared.engineLabel)
                        .font(.system(size: 9.5))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(RubickTheme.emerald.opacity(0.14)))
                        .foregroundStyle(RubickTheme.emeraldBright)
                }
                Spacer()
                Button {
                    model.closeSidePanel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.7))
                .help("关闭（⎋）")
            }

            SelectableTextView(text: text) { tv in
                model.panelTextView = tv
            }
            .frame(maxHeight: .infinity)

            Text("选中文字按 T 翻译 · ⌘C 复制")
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.5))

            HStack(spacing: 8) {
                Button {
                    writeTextToPasteboard(text)
                    Toast.shared.show("已复制")
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(RubickTheme.emerald)
                if !isTranslation {
                    Button {
                        model.translateSideSelection()
                    } label: {
                        Label("翻译", systemImage: "character.bubble")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(RubickTheme.emerald)
                }
                Button {
                    HistoryStore.shared.addText(text)
                    Toast.shared.show("已存入历史")
                } label: {
                    Label("存入历史", systemImage: "book.closed")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(RubickTheme.emerald)
                Spacer()
            }
        }
        .padding(12)
        .frame(width: 330)
        .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.82)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(RubickTheme.emerald.opacity(0.35), lineWidth: 0.8))
        .shadow(color: RubickTheme.emerald.opacity(0.2), radius: 10)
    }
}
