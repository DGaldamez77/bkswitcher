// Draws the BKSwitcher app icon: a stack of tilted, white-bordered photos on a dark rounded
// square, echoing the scattered collage wallpaper the app generates.
//
// Usage: swift scripts/make-icon.swift <output.png>   (renders 1024x1024)
// scripts/build-app.sh turns the PNG into Packaging/AppIcon.icns.
import AppKit

let canvas: CGFloat = 1024
let outputPath = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not create drawing context")
}
NSGraphicsContext.current = context
let cg = context.cgContext
cg.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// MARK: Background tile (macOS icon grid: 824pt body inset 100pt, ~185pt corner radius)

let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tileRect, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let tileShadow = NSShadow()
tileShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
tileShadow.shadowBlurRadius = 24
tileShadow.shadowOffset = NSSize(width: 0, height: -10)
tileShadow.set()
color(0x101828).setFill()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
tilePath.addClip()
NSGradient(colors: [color(0x1B2A4A), color(0x0B1020)])!.draw(in: tileRect, angle: -90)
// Soft glow behind the photos.
NSGradient(colors: [color(0x5B8DEF, 0.35), color(0x5B8DEF, 0)])!
    .draw(fromCenter: CGPoint(x: 512, y: 540), radius: 0, toCenter: CGPoint(x: 512, y: 540), radius: 420, options: [])
NSGraphicsContext.restoreGraphicsState()

// MARK: Photo cards

struct Scene {
    let skyTop: UInt32
    let skyBottom: UInt32
    let sun: UInt32
    let sunPosition: CGPoint   // unit coordinates inside the photo
    let far: UInt32
    let near: UInt32
    let water: UInt32?
}

/// Draws a white-bordered photo of size `size`, centered at `center`, rotated by `degrees`.
func drawCard(center: CGPoint, size: CGSize, degrees: CGFloat, scene: Scene) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: center.x, yBy: center.y)
    transform.rotate(byDegrees: degrees)
    transform.concat()

    let border = size.width * 0.06
    let frame = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
    let framePath = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0xFAFAF7).setFill()
    framePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Thicker bottom border, like a printed photo.
    let photo = CGRect(
        x: frame.minX + border,
        y: frame.minY + border * 1.9,
        width: frame.width - border * 2,
        height: frame.height - border * 2.9
    )
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: photo).addClip()

    NSGradient(colors: [color(scene.skyTop), color(scene.skyBottom)])!.draw(in: photo, angle: -90)

    let sunCenter = CGPoint(x: photo.minX + photo.width * scene.sunPosition.x, y: photo.minY + photo.height * scene.sunPosition.y)
    let sunRadius = photo.width * 0.11
    color(scene.sun).setFill()
    NSBezierPath(ovalIn: CGRect(x: sunCenter.x - sunRadius, y: sunCenter.y - sunRadius, width: sunRadius * 2, height: sunRadius * 2)).fill()

    func ridge(_ points: [(CGFloat, CGFloat)], _ fill: UInt32) {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: photo.minX, y: photo.minY))
        for (x, y) in points {
            path.line(to: CGPoint(x: photo.minX + photo.width * x, y: photo.minY + photo.height * y))
        }
        path.line(to: CGPoint(x: photo.maxX, y: photo.minY))
        path.close()
        color(fill).setFill()
        path.fill()
    }
    ridge([(0, 0.42), (0.22, 0.62), (0.38, 0.48), (0.58, 0.72), (0.8, 0.5), (1, 0.6)], scene.far)
    if let water = scene.water {
        color(water).setFill()
        NSBezierPath(rect: CGRect(x: photo.minX, y: photo.minY, width: photo.width, height: photo.height * 0.3)).fill()
        ridge([(0, 0.18), (0.3, 0.3), (0.55, 0.22), (1, 0.12)], scene.near)
    } else {
        ridge([(0, 0.3), (0.3, 0.4), (0.6, 0.26), (0.85, 0.36), (1, 0.3)], scene.near)
    }
    NSGraphicsContext.restoreGraphicsState()

    // Tiny "caption" lines in the bottom border, like the date/location printed by the app.
    color(0xB8BCC6).setFill()
    let captionY = frame.minY + border * 0.75
    NSBezierPath(roundedRect: CGRect(x: frame.maxX - border - photo.width * 0.42, y: captionY, width: photo.width * 0.42, height: border * 0.32), xRadius: 3, yRadius: 3).fill()

    NSGraphicsContext.restoreGraphicsState()
}

let sunset = Scene(skyTop: 0xF6845E, skyBottom: 0xFDD38A, sun: 0xFFF3C4, sunPosition: CGPoint(x: 0.7, y: 0.66),
                   far: 0x8E4F6E, near: 0x4A2C4F, water: nil)
let lake = Scene(skyTop: 0x4A9BE8, skyBottom: 0xBFE3FF, sun: 0xFFFFFF, sunPosition: CGPoint(x: 0.25, y: 0.74),
                 far: 0x5D7BA3, near: 0x2F6B4F, water: 0x3A86C8)
let meadow = Scene(skyTop: 0x7CC6F2, skyBottom: 0xE4F6FF, sun: 0xFFE27A, sunPosition: CGPoint(x: 0.76, y: 0.72),
                   far: 0x6FA86A, near: 0x3E8A47, water: nil)

drawCard(center: CGPoint(x: 400, y: 600), size: CGSize(width: 420, height: 360), degrees: 11, scene: sunset)
drawCard(center: CGPoint(x: 630, y: 560), size: CGSize(width: 380, height: 330), degrees: -9, scene: meadow)
drawCard(center: CGPoint(x: 505, y: 395), size: CGSize(width: 470, height: 400), degrees: 3, scene: lake)

NSGraphicsContext.current = nil
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("PNG encoding failed")
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
