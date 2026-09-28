import AppKit
import SwiftUI
import CoreImage

// MARK: - 截图标注编辑器（v2.0，功能清单 12.1）
// 7 工具 + 颜色/线宽 + 撤销重做 + 全部快捷键可配置（AnnotateKeyConfig）

struct Annotation: Identifiable, Equatable {
    enum Tool: String, CaseIterable {
        case rect, ellipse, arrow, pen, text, step, mosaic, highlight

        var symbol: String {
            switch self {
            case .rect: return "rectangle"
            case .ellipse: return "oval"
            case .arrow: return "arrow.up.right"
            case .pen: return "scribble"
            case .text: return "textformat"
            case .step: return "number.circle"
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
            case .step: return "序号"
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

        // 用选区所在屏（多屏下 NSScreen.main 是焦点屏，会弹到主屏）
        let anchorRect = rect ?? CGRect(origin: NSEvent.mouseLocation, size: .zero)
        let screen = screenContaining(NSPoint(x: anchorRect.midX, y: anchorRect.midY))
            ?? NSScreen.screens.first
        guard let screen else { return }
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
            onMoveTo: { [weak self] x, y in
                self?.window?.setFrameOrigin(NSPoint(x: x, y: y))
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

    /// 编辑器窗口当前全局 frame（拖动用）
    var currentFrame: CGRect? { window?.frame }

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
                    // ⎋ 退出编辑态：提交草稿而不是丢弃（空草稿自然无操作，误输可 ⌘Z 撤销）
                    model.commitText()
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
                if let img = self.currentImage {
                    let composite = Self.flatten(image: img, annotations: model.annotations) ?? img
                    model.runOCR(on: composite)
                }
                return nil
            }
            if ak.matches(.translate, event: event) {
                model.translateSideSelection()
                return nil
            }
            let toolMap: [(AnnotateKeyConfig.Action, Annotation.Tool)] = [
                (.toolRect, .rect), (.toolEllipse, .ellipse), (.toolArrow, .arrow),
                (.toolPen, .pen), (.toolText, .text), (.toolStep, .step),
                (.toolMosaic, .mosaic), (.toolHighlight, .highlight)
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
            if let img = currentImage {
                let composite = Self.flatten(image: img, annotations: model.annotations) ?? img
                model.runOCR(on: composite)
            }
            return
        }
        if ak.matches(.translate, event: event) { model.translateSideSelection(); return }
        let toolMap: [(AnnotateKeyConfig.Action, Annotation.Tool)] = [
            (.toolRect, .rect), (.toolEllipse, .ellipse), (.toolArrow, .arrow),
            (.toolPen, .pen), (.toolText, .text), (.toolStep, .step),
            (.toolMosaic, .mosaic), (.toolHighlight, .highlight)
        ]
        for (action, tool) in toolMap where ak.matches(action, event: event) {
            model.tool = tool
            return
        }
    }

    /// 调试用：展平当前标注为成品图
    func debugFlattenedImage() -> NSImage? {
        guard let m = model, let img = currentImage else { return nil }
        return Self.flatten(image: img, annotations: m.annotations)
    }

    /// 调试用：注入样例标注（箭头/马赛克/文字），供自拍验证渲染
    func debugAddSampleAnnotations() {
        guard let m = model else { return }
        var arrow = Annotation(tool: .arrow)
        arrow.startPoint = CGPoint(x: 0.15, y: 0.8)
        arrow.endPoint = CGPoint(x: 0.75, y: 0.25)
        arrow.colorIndex = 0
        arrow.lineWidth = 4
        arrow.displaySize = m.imageRect.size
        m.commit(arrow)
        var mos = Annotation(tool: .mosaic)
        mos.rect = CGRect(x: 0.55, y: 0.55, width: 0.4, height: 0.35)
        mos.mosaicStyle = 0
        mos.displaySize = m.imageRect.size
        m.commit(mos)
        var blurAnn = Annotation(tool: .mosaic)
        blurAnn.rect = CGRect(x: 0.2, y: 0.02, width: 0.25, height: 0.18)
        blurAnn.mosaicStyle = 1
        blurAnn.displaySize = m.imageRect.size
        m.commit(blurAnn)
        var txt = Annotation(tool: .text)
        txt.rect = CGRect(origin: CGPoint(x: 0.05, y: 0.08), size: .zero)
        txt.text = "你好世界 Hello"
        txt.colorIndex = 3
        txt.fontSize = 24
        txt.displaySize = m.imageRect.size
        m.commit(txt)
    }

    private func confirm() {
        guard let m = model, let img = currentImage else { return }
        m.commitText()
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
        let baseCG = image.cgImage()
        // 以源图真实像素密度建位图（Retina 2x 不再减半）；rep.size 保持点尺寸，绘制坐标不变
        let pw = max(baseCG?.width ?? 0, Int(size.width), 1)
        let ph = max(baseCG?.height ?? 0, Int(size.height), 1)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: size))
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
            drawArrow(from: sPt, to: ePt, ctx: ctx, color: color, minHead: max(12 * scale, 4))
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
        case .step:
            // 与预览同语义（CG 底部原点：引线向右下 = y 减小）
            let c = CGPoint(x: a.rect.origin.x * imageSize.width,
                            y: (1 - a.rect.origin.y) * imageSize.height)
            let radius = max(a.fontSize * scale * 0.75, 10)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(max(1.5 * scale, 1))
            ctx.beginPath()
            ctx.move(to: CGPoint(x: c.x + radius * 0.7, y: c.y - radius * 0.7))
            ctx.addLine(to: CGPoint(x: c.x + radius * 1.7, y: c.y - radius * 1.7))
            ctx.strokePath()
            let circle = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillEllipse(in: circle)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.8))
            ctx.strokeEllipse(in: circle)
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: radius, weight: .bold),
                .foregroundColor: NSColor.black,
                .paragraphStyle: para
            ]
            (a.text as NSString).draw(in: circle.offsetBy(dx: 0, dy: radius * 0.15), withAttributes: attrs)
        }
    }

    private static func drawArrow(from start: CGPoint, to tip: CGPoint, ctx: CGContext, color: NSColor, minHead: CGFloat = 12) {
        let angle = atan2(tip.y - start.y, tip.x - start.x)
        let headLen = max(hypot(tip.x - start.x, tip.y - start.y) * 0.18, minHead)
        let headHalf = headLen * 0.5
        let base = CGPoint(x: tip.x - cos(angle) * headLen, y: tip.y - sin(angle) * headLen)
        let perp = angle + .pi / 2
        // 三根线：箭杆 + 两根斜线（开口 V 形）
        ctx.move(to: start)
        ctx.addLine(to: base)
        ctx.move(to: CGPoint(x: base.x + cos(perp) * headHalf, y: base.y + sin(perp) * headHalf))
        ctx.addLine(to: tip)
        ctx.move(to: CGPoint(x: base.x - cos(perp) * headHalf, y: base.y - sin(perp) * headHalf))
        ctx.addLine(to: tip)
        ctx.strokePath()
    }

    /// 共享 CI 上下文（每次新建会在多块马赛克时反复分配，卡顿+内存峰值）
    private static let sharedCIContext = CIContext()

    private static func drawMosaic(_ r: CGRect, imageSize: CGSize, baseCG: CGImage?, blockSize: CGFloat = 16, blur: Bool = false) {
        guard let baseCG = baseCG else {
            NSColor.gray.withAlphaComponent(0.5).setFill()
            NSBezierPath(rect: r).fill()
            return
        }
        let scalePx = CGFloat(baseCG.width) / imageSize.width
        // r 已是 CG（底部原点）坐标；CIImage(cgImage:) 的取窗同为底部原点，直接按 minY 取，
        // 不可再按 (H - maxY) 翻转——那会把打码内容取成垂直镜像区域（打码失效）
        let cropPx = CGRect(x: r.minX * scalePx,
                            y: r.minY * scalePx,
                            width: r.width * scalePx,
                            height: r.height * scalePx)
        var ci = CIImage(cgImage: baseCG).cropped(to: cropPx)
        if blur {
            ci = ci.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 12])
        } else {
            // 颗粒 = blockSize 点 × 像素密度，与预览观感一致
            let blockPx = max(blockSize * scalePx, 8)
            ci = ci.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: blockPx])
        }
        if let cg = sharedCIContext.createCGImage(ci, from: ci.extent) {
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
    let onMoveTo: (CGFloat, CGFloat) -> Void
    let onConfirm: (NSImage) -> Void
    let onCancel: () -> Void

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var penPath: [CGPoint] = []
    @State private var grabOffset: CGPoint?
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
                        // 首次按下：仅未选工具或文字工具时才命中已有文字 → 拖动它；
                        // 否则形状工具从文字上起笔会被劫持成拖字
                        if dragStart == nil, dragTextID == nil,
                           model.tool == nil || model.tool == .text,
                           let hit = hitTextAnnotation(at: normalize(p)) {
                            dragTextID = hit.id
                            dragTextStart = p
                            model.commitText()
                            hoveredHelp = "文字：按住拖动移动 · 点击编辑内容"
                            return
                        }
                        if let id = dragTextID {
                            model.updateTextPosition(id: id, to: normalize(clamp(v.location)))
                            return
                        }
                        model.commitText()
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
                                model.commitText()   // 先落上一个草稿，避免切换新文字位时静默丢字
                                model.textDraft = ""
                                model.textEditing = (UUID(), normStart)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { textFocused = true }
                            }
                            return
                        }
                        if model.tool == .step {
                            // 步骤序号（规格 B1）：点击落号，编号取现有最大值+1（删除中间号不重复）
                            if hypot(start.x - end.x, start.y - end.y) < 6 {
                                let n = (model.annotations
                                    .filter { $0.tool == .step }
                                    .compactMap { Int($0.text) }
                                    .max() ?? 0) + 1
                                var a = Annotation(tool: .step)
                                a.rect = CGRect(origin: normalize(start), size: .zero)
                                a.text = "\(n)"
                                a.fontSize = model.fontSize
                                a.colorIndex = model.colorIndex
                                a.displaySize = model.imageRect.size
                                model.commit(a)
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
                .onChanged { _ in
                    let m = NSEvent.mouseLocation
                    if let off = grabOffset {
                        onMoveTo(m.x - off.x, m.y - off.y)
                    } else if let f = AnnotationController.shared.currentFrame {
                        grabOffset = CGPoint(x: m.x - f.minX, y: m.y - f.minY)
                    }
                }
                .onEnded { _ in grabOffset = nil }
        )
    }

    /// 命中检测：点是否落在已提交的文字上
    private func hitTextAnnotation(at normalized: CGPoint) -> Annotation? {
        let viewPoint = CGPoint(x: normalized.x * displaySize.width,
                                y: normalized.y * displaySize.height)
        for a in model.annotations.reversed() where a.tool == .text {
            let size = textSize(a.text, fontSize: a.fontSize)
            // 渲染时文字画在 origin 上方一个行高（anchor .bottomLeading），命中框必须跟着偏移，
            // 否则点字选不中、点字下方空白反而把字拖走
            let r = CGRect(x: a.rect.origin.x * displaySize.width,
                           y: a.rect.origin.y * displaySize.height - size.height,
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
            let headLen = max(totalLen * 0.18, 12)
            let headHalf = headLen * 0.5
            let base = CGPoint(x: ePt.x - cos(angle) * headLen, y: ePt.y - sin(angle) * headLen)
            let perp = angle + .pi / 2
            var p = Path()
            p.move(to: sPt)
            p.addLine(to: base)
            p.move(to: CGPoint(x: base.x + cos(perp) * headHalf, y: base.y + sin(perp) * headHalf))
            p.addLine(to: ePt)
            p.move(to: CGPoint(x: base.x - cos(perp) * headHalf, y: base.y - sin(perp) * headHalf))
            p.addLine(to: ePt)
            ctx.stroke(p, with: .color(color), lineWidth: a.lineWidth)
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
        case .step:
            // 白底黑字圆号 + 右下引线（规格 B1）；预览与展平共用语义
            let c = CGPoint(x: a.rect.origin.x * imageRect.width,
                            y: a.rect.origin.y * imageRect.height)
            let radius = max(a.fontSize * 0.75, 10)
            var leader = Path()
            leader.move(to: CGPoint(x: c.x + radius * 0.7, y: c.y + radius * 0.7))
            leader.addLine(to: CGPoint(x: c.x + radius * 1.7, y: c.y + radius * 1.7))
            ctx.stroke(leader, with: .color(.white), lineWidth: 1.5)
            let circle = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
            ctx.fill(Path(ellipseIn: circle), with: .color(.white))
            ctx.stroke(Path(ellipseIn: circle), with: .color(.black.opacity(0.8)), lineWidth: 1.5)
            ctx.draw(Text(a.text)
                .font(.system(size: radius, weight: .bold))
                .foregroundColor(.black), in: circle)
        }
    }

    // MARK: 工具栏（定宽两段式：第一行工具恒定不抖，属性控件固定在第二行左槽）

    private var toolbar: some View {
        VStack(spacing: 6) {
            // 第一行（恒定）：工具 + 识图 + 颜色 + 线宽 + 撤销重做
            HStack(spacing: 6) {
                ForEach(visibleTools, id: \.self) { t in
                    toolButton(t)
                }
                divider
                Button {
                    ocrOnComposite()
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
                    hoveredHelp = hovering ? "识图当前画面（\(keyDisplay(.ocr))）" : nil
                }
                divider
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
                Spacer()
                toolbarAction("arrow.uturn.backward", help: "撤销 \(keyDisplay(.undo))", enabled: !model.annotations.isEmpty) {
                    model.undo()
                }
                toolbarAction("arrow.uturn.forward", help: "重做 \(keyDisplay(.redo))", enabled: !model.redoStack.isEmpty) {
                    model.redo()
                }
            }
            // 第二行（恒定高度）：左槽=当前工具属性（不抖动），右=提示 + 确认/取消
            HStack(spacing: 8) {
                contextualControls
                    .frame(minWidth: 240, alignment: .leading)
                Text(hoveredHelp ?? "\(keyDisplay(.toolRect))–\(keyDisplay(.toolHighlight)) 工具 · \(keyDisplay(.ocr)) 识图 · \(keyDisplay(.undo)) 撤销 · ⎋ 取消")
                    .font(.system(size: 9.5))
                    .foregroundStyle(hoveredHelp != nil ? RubickTheme.emeraldBright : .white.opacity(0.55))
                    .lineLimit(1)
                Spacer()
                Button {
                    onCancel()
                } label: {
                    Label("取消", systemImage: "xmark")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    model.commitText()
                    onConfirm(AnnotationController.flatten(image: image, annotations: model.annotations) ?? image)
                } label: {
                    Label("确认", systemImage: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(RubickTheme.emerald)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(RubickTheme.emerald.opacity(0.3), lineWidth: 0.8))
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 20)
    }

    /// 当前工具的属性控件（固定槽位，切换工具只换内容不改变行高/布局）
    @ViewBuilder private var contextualControls: some View {
        switch model.tool {
        case .rect:
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
        case .text:
            Picker("", selection: $model.fontSize) {
                Text("小").tag(CGFloat(12))
                Text("中").tag(CGFloat(16))
                Text("大").tag(CGFloat(22))
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
        case .step:
            Picker("", selection: $model.fontSize) {
                Text("小").tag(CGFloat(14))
                Text("中").tag(CGFloat(18))
                Text("大").tag(CGFloat(24))
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
        case .mosaic:
            Picker("", selection: $model.mosaicStyle) {
                Text("马赛克").tag(0)
                Text("模糊").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
        case .highlight:
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
        case .pen:
            Text("拖拽绘制 · Shift 直线")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
        case .arrow, .ellipse:
            Text("拖拽绘制 · Shift 约束")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
        case nil:
            Text("选择上方工具开始标注，或按 ↵ 直接完成")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    /// OCR 识别当前合成画面（含已画标注），避免识别结果包含被马赛克遮住的原文
    private func ocrOnComposite() {
        let composite = AnnotationController.flatten(image: image, annotations: model.annotations) ?? image
        model.runOCR(on: composite)
    }

    /// 工具栏可见工具（规格 A2：序号 + 高亮回归）
    private var visibleTools: [Annotation.Tool] {
        [.rect, .ellipse, .arrow, .pen, .text, .step, .mosaic, .highlight]
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
            .pen: .toolPen, .text: .toolText, .step: .toolStep,
            .mosaic: .toolMosaic, .highlight: .toolHighlight
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
        let cols = max(Int(rect.width / 22), 5)
        let rows = max(Int(rect.height / 22), 5)
        let out = NSImage(size: NSSize(width: cols, height: rows))
        out.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: cols, height: rows),
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
