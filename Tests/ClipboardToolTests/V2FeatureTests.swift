import XCTest
import AppKit
@testable import ClipboardTool

// MARK: - v2.0 功能单元测试：吸附 / 翻译纯函数 / OCR 坐标 / 快捷键配置 / 真实 OCR

final class V2FeatureTests: XCTestCase {

    // MARK: 吸附逻辑（功能清单 12.6）

    func testSnapEdgeThreshold() {
        let win = CGRect(x: 100, y: 100, width: 400, height: 300)
        let rect = CGRect(x: 104, y: 120, width: 200, height: 100)   // 左边缘距窗口左边缘 4pt
        let (r, w) = SnapLogic.snappedRect(rect, windows: [win], threshold: 8)
        XCTAssertEqual(r.minX, win.minX)
        XCTAssertNotNil(w)
    }

    func testSnapOutsideThresholdNoChange() {
        let win = CGRect(x: 100, y: 100, width: 400, height: 300)
        let rect = CGRect(x: 150, y: 150, width: 200, height: 100)   // 距所有边 > 8
        let (r, w) = SnapLogic.snappedRect(rect, windows: [win], threshold: 8)
        XCTAssertEqual(r, rect)
        XCTAssertNil(w)
    }

    func testWindowUnderCursor() {
        let win = CGRect(x: 10, y: 10, width: 100, height: 100)
        XCTAssertEqual(SnapLogic.window(under: CGPoint(x: 50, y: 50), windows: [win]), win)
        XCTAssertNil(SnapLogic.window(under: CGPoint(x: 500, y: 500), windows: [win]))
    }

    func testNearlyEqualsTolerance() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 3, y: 2, width: 100, height: 100)
        XCTAssertTrue(SnapLogic.nearlyEquals(a, b, tolerance: 5))
        XCTAssertFalse(SnapLogic.nearlyEquals(a, b, tolerance: 1))
    }

    // MARK: 翻译纯函数

    func testDetectPairAutoCJK() {
        let (s, t) = TranslationService.detectPair("你好世界 hello", direction: .auto)
        XCTAssertEqual(s, Locale.Language(identifier: "zh-Hans"))
        XCTAssertEqual(t, Locale.Language(identifier: "en"))
    }

    func testDetectPairAutoLatin() {
        let (s, t) = TranslationService.detectPair("Hello Rubick Board", direction: .auto)
        XCTAssertEqual(s, Locale.Language(identifier: "en"))
        XCTAssertEqual(t, Locale.Language(identifier: "zh-Hans"))
    }

    func testDetectPairFixedDirections() {
        XCTAssertEqual(TranslationService.detectPair("abc", direction: .zhToEn).target, Locale.Language(identifier: "en"))
        XCTAssertEqual(TranslationService.detectPair("中文", direction: .enToZh).target, Locale.Language(identifier: "zh-Hans"))
    }

    func testChunksShortText() {
        XCTAssertEqual(TranslationService.chunks("短文本"), ["短文本"])
        XCTAssertEqual(TranslationService.chunks("   "), [])
    }

    func testChunksLongTextSplitByParagraph() {
        let para = String(repeating: "拉比克", count: 600)   // 1800 字 > 1500
        let text = para + "\n" + para
        let chunks = TranslationService.chunks(text)
        XCTAssertEqual(chunks.count, 4)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 1500 })
    }

    func testLLMRequestBuilder() throws {
        let cfg = LLMConfig(baseURL: "https://api.example.com/v1/", model: "mimo-v2.5", apiKey: "sk-test")
        let req = try TranslationService.llmRequest(config: cfg, systemPrompt: "翻译", userText: "hello")
        XCTAssertEqual(req.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["model"] as? String, "mimo-v2.5")
        let messages = body?["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?.first?["role"] as? String, "system")
        XCTAssertEqual(messages?.last?["content"] as? String, "hello")
    }

    func testLLMConfigValidation() {
        XCTAssertFalse(LLMConfig(baseURL: "", model: "m", apiKey: "k").isValid)
        XCTAssertFalse(LLMConfig(baseURL: "u", model: "", apiKey: "k").isValid)
        XCTAssertFalse(LLMConfig(baseURL: "u", model: "m", apiKey: " ").isValid)
        XCTAssertTrue(LLMConfig(baseURL: "u", model: "m", apiKey: "k").isValid)
    }

    // MARK: OCR 坐标翻转

    func testFlippedRect() {
        let r = CGRect(x: 10, y: 20, width: 100, height: 50)
        let f = OCRService.flippedRect(r, height: 300)
        XCTAssertEqual(f.minY, 230, accuracy: 0.001)   // 300 - 70
        XCTAssertEqual(f.width, 100)
        XCTAssertEqual(f.height, 50)
    }

    // MARK: 快捷键配置

    func testAnnotateKeysDefaults() {
        let ak = AnnotateKeyConfig.shared
        XCTAssertEqual(ak.keys.count, AnnotateKeyConfig.Action.allCases.count)
        XCTAssertEqual(ak.keys[.confirm]?.keyCode, 36)
        XCTAssertEqual(ak.keys[.cancel]?.keyCode, 53)
        XCTAssertEqual(ak.keys[.toolRect]?.display, "1")
        XCTAssertEqual(ak.keys[.toolHighlight]?.display, "7")
    }

    func testAnnotateKeyResetKeepsDefaults() {
        AnnotateKeyConfig.shared.update(.undo, keyCode: 40, mods: 0, display: "K")
        XCTAssertEqual(AnnotateKeyConfig.shared.keys[.undo]?.display, "K")
        AnnotateKeyConfig.shared.reset(.undo)
        XCTAssertEqual(AnnotateKeyConfig.shared.keys[.undo]?.display, "⌘Z")
    }

    func testPanelKeysHaveV2Actions() {
        let pk = PanelKeyConfig.shared
        XCTAssertNotNil(pk.keys[.translate])
        XCTAssertNotNil(pk.keys[.ocr])
        XCTAssertEqual(pk.keys[.translate]?.display, "T")
        XCTAssertEqual(pk.keys[.ocr]?.display, "O")
    }

    // MARK: 真实 OCR（Vision 本地识别）

    func testOCRRecognizesRenderedText() {
        let img = makeTextImage("RUBICK OCR TEST")
        let exp = expectation(description: "ocr")
        OCRService.shared.recognize(image: img) { result in
            switch result {
            case .success(let r):
                XCTAssertTrue(r.text.uppercased().contains("RUBICK"), "识别结果: \(r.text)")
            case .failure(let err):
                XCTFail("OCR 失败: \(err.localizedDescription)")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 30)
    }

    // MARK: 标注展平（纯绘制路径）

    func testFlattenKeepsSizeAndDraws() {
        let img = makeTextImage("FLATTEN")
        var a = Annotation(tool: .rect)
        a.rect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        a.displaySize = img.size
        a.lineWidth = 4
        let out = AnnotationController.flatten(image: img, annotations: [a])
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.size, img.size)
    }

    // MARK: 视图↔全局坐标换算（防「选区偏移/所见非所截」回归）

    func testViewRectToAppKitRect() {
        // 视图高 1000，窗口原点 (0,0)：视图里顶部选区 y=100 → 全局 y=900（左上→左下翻转）
        let v = CGRect(x: 200, y: 100, width: 400, height: 300)
        let a = SnapLogic.appKitRect(fromViewRect: v, viewHeight: 1000, windowOrigin: .zero)
        XCTAssertEqual(a.minY, 600, accuracy: 0.001)   // 1000 - 100 - 300 = 600
        XCTAssertEqual(a.minX, 200)
        XCTAssertEqual(a.width, 400)
        XCTAssertEqual(a.height, 300)
    }

    func testAppKitRectToViewRectRoundTrip() {
        let v = CGRect(x: 200, y: 100, width: 400, height: 300)
        let a = SnapLogic.appKitRect(fromViewRect: v, viewHeight: 1000, windowOrigin: .zero)
        let back = SnapLogic.viewRect(fromAppKitRect: a, viewHeight: 1000, windowOrigin: .zero)
        XCTAssertEqual(back, v)
    }

    // MARK: 合成/裁剪方向性（防「截到背景桌面」回归）

    func testCompositeOrientationTopRedBottomBlue() {
        // 上半红、下半蓝的“屏幕”
        let cg = syntheticImage(top: NSColor.red, bottom: NSColor.blue, width: 200, height: 100)
        let shot = ScreenShot(frame: CGRect(x: 0, y: 0, width: 200, height: 100), image: cg)
        let union = CGRect(x: 0, y: 0, width: 200, height: 100)
        let composite = ImageCompose.composite([shot], union: union)!
        // 裁上半 → 应为红色（若上下翻转则是蓝色 = 方向性回归）
        let top = ImageCompose.crop(composite, rectInUnion: CGRect(x: 0, y: 50, width: 200, height: 50), union: union)!
        let topColor = topColorOf(top)
        XCTAssertGreaterThan(topColor.redComponent, 0.8, "上半裁剪应为红色")
        XCTAssertLessThan(topColor.blueComponent, 0.3)
        // 裁下半 → 应为蓝色
        let bottom = ImageCompose.crop(composite, rectInUnion: CGRect(x: 0, y: 0, width: 200, height: 50), union: union)!
        let bottomColor = topColorOf(bottom)
        XCTAssertGreaterThan(bottomColor.blueComponent, 0.8, "下半裁剪应为蓝色")
        XCTAssertLessThan(bottomColor.redComponent, 0.3)
    }

    private func syntheticImage(top: NSColor, bottom: NSColor, width: Int, height: Int) -> CGImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        top.setFill()
        NSRect(x: 0, y: height / 2, width: width, height: height / 2).fill()
        bottom.setFill()
        NSRect(x: 0, y: 0, width: width, height: height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    private func topColorOf(_ image: NSImage) -> NSColor {
        guard let cg = image.cgImage() else { return .clear }
        let rep = NSBitmapImageRep(cgImage: cg)
        // NSBitmapImageRep.colorAt 原点在左上
        return rep.colorAt(x: 10, y: 5) ?? .clear
    }

    // MARK: 工具

    private func makeTextImage(_ text: String, size: CGSize = CGSize(width: 480, height: 120)) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 48, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        (text as NSString).draw(at: NSPoint(x: 20, y: 28), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        return img
    }
}
