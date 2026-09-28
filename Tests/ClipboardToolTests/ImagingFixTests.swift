import XCTest
import AppKit
@testable import ClipboardTool

/// 批次 A（成像正确性）回归：马赛克取窗方向、Retina 像素密度、合成/裁剪密度继承
final class ImagingFixTests: XCTestCase {

    // MARK: 工具

    /// 上红下蓝的合成底图（视觉上半红、下半蓝）
    private func makeTwoToneCG(width: Int, height: Int) -> CGImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: CGFloat(height) / 2, width: CGFloat(width), height: CGFloat(height) / 2)).fill()
        NSColor.blue.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height) / 2)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    /// 把 NSImage 重采样到 1x 位图后按视觉坐标取色（colorAt 行 0 = 视觉顶部）
    private func pixelColor(of image: NSImage, at visualPoint: CGPoint) -> NSColor {
        let size = image.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: max(Int(size.width), 1), pixelsHigh: max(Int(size.height), 1),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.colorAt(x: Int(visualPoint.x), y: Int(visualPoint.y)) ?? .black
    }

    // MARK: 马赛克方向

    func testMosaicExportSamplesSameVisualRegion() {
        let base = NSImage(cgImage: makeTwoToneCG(width: 200, height: 100), size: CGSize(width: 200, height: 100))
        var mos = Annotation(tool: .mosaic)
        mos.rect = CGRect(x: 0, y: 0, width: 1, height: 0.5)   // 归一化（顶部原点）= 视觉上半
        mos.mosaicStyle = 0
        mos.displaySize = base.size
        let out = AnnotationController.flatten(image: base, annotations: [mos])!
        // 视觉上半中心的马赛克块应取自红色区域（取错方向则呈蓝色 = 打码内容镜像）
        let c = pixelColor(of: out, at: CGPoint(x: 100, y: 25))
        XCTAssertGreaterThan(c.redComponent, 0.6, "马赛克应取自同视觉位置内容（上半→红）")
        XCTAssertLessThan(c.blueComponent, 0.4)
    }

    func testBlurExportSamplesSameVisualRegion() {
        let base = NSImage(cgImage: makeTwoToneCG(width: 200, height: 100), size: CGSize(width: 200, height: 100))
        var blur = Annotation(tool: .mosaic)
        blur.rect = CGRect(x: 0, y: 0, width: 1, height: 0.5)
        blur.mosaicStyle = 1
        blur.displaySize = base.size
        let out = AnnotationController.flatten(image: base, annotations: [blur])!
        let c = pixelColor(of: out, at: CGPoint(x: 100, y: 25))
        XCTAssertGreaterThan(c.redComponent, 0.6, "模糊应取自同视觉位置内容（上半→红）")
        XCTAssertLessThan(c.blueComponent, 0.4)
    }

    // MARK: Retina 像素密度

    func testFlattenKeepsRetinaPixelDensity() {
        // 2x 源图：400×200 px 声明为 200×100 pt
        let base = NSImage(cgImage: makeTwoToneCG(width: 400, height: 200), size: CGSize(width: 200, height: 100))
        var a = Annotation(tool: .rect)
        a.rect = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        a.displaySize = base.size
        a.lineWidth = 4
        let out = AnnotationController.flatten(image: base, annotations: [a])!
        XCTAssertEqual(out.size, CGSize(width: 200, height: 100), "点尺寸不变")
        XCTAssertEqual(out.cgImage()?.width, 400, "Retina 源图导出应保持 2x 像素密度，不得减半")
    }

    func testCompositeCropKeepRetinaPixelDensity() {
        let cg = makeTwoToneCG(width: 400, height: 200)
        let shot = ScreenShot(frame: CGRect(x: 0, y: 0, width: 200, height: 100), image: cg)
        let union = CGRect(x: 0, y: 0, width: 200, height: 100)
        let composite = ImageCompose.composite([shot], union: union)!
        XCTAssertEqual(composite.cgImage()?.width, 400, "合成图应继承分片 2x 密度")
        let crop = ImageCompose.crop(composite, rectInUnion: CGRect(x: 0, y: 50, width: 200, height: 50), union: union)!
        XCTAssertEqual(crop.size, CGSize(width: 200, height: 50), "裁剪点尺寸不变")
        XCTAssertEqual(crop.cgImage()?.height, 100, "裁剪输出应继承 2x 密度")
        // 上半裁剪仍是红（2x 路径下方向不回退）
        let c = pixelColor(of: crop, at: CGPoint(x: 100, y: 12))
        XCTAssertGreaterThan(c.redComponent, 0.6)
    }

    // MARK: 1x 路径不回归

    func testOneXPipelineUnchanged() {
        let base = NSImage(cgImage: makeTwoToneCG(width: 200, height: 100), size: CGSize(width: 200, height: 100))
        let shot = ScreenShot(frame: CGRect(x: 0, y: 0, width: 200, height: 100), image: base.cgImage()!)
        let composite = ImageCompose.composite([shot], union: CGRect(x: 0, y: 0, width: 200, height: 100))!
        XCTAssertEqual(composite.cgImage()?.width, 200, "1x 源不放大")
        let out = AnnotationController.flatten(image: base, annotations: [])!
        XCTAssertEqual(out.cgImage()?.width, 200)
    }
}
