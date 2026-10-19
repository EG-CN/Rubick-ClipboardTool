#!/bin/bash
# Render the shared vector emblem; no external image service or font needed.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build-brand
cat > .build-brand/main.swift <<'SWIFT'
import AppKit
func writePNG(_ image: NSImage, to path: String, pixels: Int) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
try writePNG(RubickBrand.image(size: 1024, appIcon: true), to: "Resources/AppIcon.png", pixels: 1024)
try writePNG(RubickBrand.image(size: 36), to: "Resources/menuGlyph.png", pixels: 36)
SWIFT
swiftc -module-cache-path .build-brand/module-cache Sources/ClipboardTool/RubickBrand.swift Sources/ClipboardTool/Theme.swift .build-brand/main.swift -o .build-brand/render
.build-brand/render
bash scripts/make-icns.sh Resources/AppIcon.png Resources/AppIcon.icns
