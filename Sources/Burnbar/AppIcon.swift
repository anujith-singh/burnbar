import AppKit

/// Renders the static "Ember gauge" app icon into a .iconset folder (install.sh turns it into
/// AppIcon.icns with iconutil). The 100×100 design is placed on Apple's macOS icon grid:
/// an 824 px body centred on a 1024 px canvas, so it sits at the same size as other Dock/Finder icons.
enum AppIcon {
    static let flamePath = "M50 10 C60 26 76 38 76 60 C76 76 64 88 50 88 C36 88 24 76 24 60 C24 48 31 41 35 33 C37 43 42 48 46 50 C44 37 45 22 50 10 Z"

    static func writeIconset(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = points * scale
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try render(pixels: px).representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
            }
        }
    }

    static func render(pixels: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let gc = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = gc
        let ctx = gc.cgContext
        let canvas = CGFloat(pixels)
        // SVG is y-down; flip, then map the 100-unit design onto the 824/1024 body.
        ctx.translateBy(x: 0, y: canvas)
        ctx.scaleBy(x: 1, y: -1)
        let body = canvas * 824 / 1024
        ctx.translateBy(x: (canvas - body) / 2, y: (canvas - body) / 2)
        ctx.scaleBy(x: body / 100, y: body / 100)

        // <rect width="100" height="100" rx="22" fill="#1C1814"/>
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 100, height: 100), cornerWidth: 22, cornerHeight: 22, transform: nil))
        ctx.setFillColor(hex(0x1C1814))
        ctx.fillPath()

        let flame = SVGPath.cgPath(flamePath)
        // Fill clipped to <rect x="0" y="52" width="100" height="48"/>
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 52, width: 100, height: 48))
        ctx.addPath(flame)
        ctx.setFillColor(hex(0xFF8A1F))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.addPath(flame)
        ctx.setStrokeColor(hex(0xFFB547))
        ctx.setLineWidth(4)
        ctx.setLineJoin(.round)
        ctx.strokePath()

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func hex(_ v: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
