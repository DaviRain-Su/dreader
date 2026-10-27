import AppKit
import CoreGraphics
import Foundation

func drawDReaderIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let scale = size / 1024.0
    ctx.scaleBy(x: scale, y: scale)

    // Colors
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    func cgColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> CGColor {
        CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
    }

    // 1. Drop Shadow for Squircle
    let squircleRect = CGRect(x: 104, y: 104, width: 816, height: 816)
    let cornerRadius: CGFloat = 184

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 36, color: cgColor(0, 0, 0, 0.55))
    let shadowPath = CGPath(roundedRect: squircleRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(shadowPath)
    ctx.setFillColor(cgColor(0.08, 0.04, 0.02, 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // 2. Base Squircle with Rich Walnut Wood / Obsidian Gradient
    ctx.saveGState()
    let squirclePath = CGPath(roundedRect: squircleRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(squirclePath)
    ctx.clip()

    let bgColors = [
        cgColor(0.24, 0.14, 0.09, 1.0), // Top warm mahogany
        cgColor(0.14, 0.08, 0.05, 1.0), // Mid walnut
        cgColor(0.08, 0.04, 0.03, 1.0)  // Deep obsidian
    ] as CFArray
    let bgLocations: [CGFloat] = [0.0, 0.48, 1.0]
    if let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: bgLocations) {
        ctx.drawLinearGradient(bgGradient, start: CGPoint(x: 104, y: 920), end: CGPoint(x: 920, y: 104), options: [])
    }

    // Top Radial Ambient Glow
    let glowColors = [
        cgColor(0.95, 0.82, 0.62, 0.18),
        cgColor(0.95, 0.82, 0.62, 0.0)
    ] as CFArray
    if let glowGradient = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(glowGradient, startCenter: CGPoint(x: 512, y: 880), startRadius: 20, endCenter: CGPoint(x: 512, y: 880), endRadius: 520, options: [])
    }

    // Fine Diagonal Sheen Line
    ctx.saveGState()
    ctx.setBlendMode(.screen)
    let sheenColors = [
        cgColor(1, 1, 1, 0.0),
        cgColor(1, 1, 1, 0.08),
        cgColor(1, 1, 1, 0.0)
    ] as CFArray
    if let sheenGradient = CGGradient(colorsSpace: colorSpace, colors: sheenColors, locations: [0.0, 0.5, 1.0]) {
        ctx.drawLinearGradient(sheenGradient, start: CGPoint(x: 200, y: 900), end: CGPoint(x: 850, y: 250), options: [])
    }
    ctx.restoreGState()

    // 3. Squircle Inner Hairline Rim
    ctx.addPath(squirclePath)
    ctx.setLineWidth(2.5)
    ctx.setStrokeColor(cgColor(0.92, 0.78, 0.52, 0.35))
    ctx.strokePath()
    ctx.restoreGState()

    // 4. DRAW 3D HARDCOVER BOOK
    let spineX: CGFloat = 512
    let spineY: CGFloat = 340
    let bookWidth: CGFloat = 320
    let bookHeight: CGFloat = 250

    // Book Cover Underlay (Deep Sapphire Blue & Gold Trim)
    let coverPath = CGMutablePath()
    coverPath.move(to: CGPoint(x: spineX, y: spineY - 26))
    coverPath.addCurve(to: CGPoint(x: spineX - bookWidth - 14, y: spineY + 14),
                       control1: CGPoint(x: spineX - 160, y: spineY - 30),
                       control2: CGPoint(x: spineX - 260, y: spineY))
    coverPath.addLine(to: CGPoint(x: spineX - bookWidth - 14, y: spineY + bookHeight + 16))
    coverPath.addCurve(to: CGPoint(x: spineX, y: spineY + bookHeight - 16),
                       control1: CGPoint(x: spineX - 260, y: spineY + bookHeight),
                       control2: CGPoint(x: spineX - 160, y: spineY + bookHeight - 26))
    coverPath.addCurve(to: CGPoint(x: spineX + bookWidth + 14, y: spineY + bookHeight + 16),
                       control1: CGPoint(x: spineX + 160, y: spineY + bookHeight - 26),
                       control2: CGPoint(x: spineX + 260, y: spineY + bookHeight))
    coverPath.addLine(to: CGPoint(x: spineX + bookWidth + 14, y: spineY + 14))
    coverPath.addCurve(to: CGPoint(x: spineX, y: spineY - 26),
                       control1: CGPoint(x: spineX + 260, y: spineY),
                       control2: CGPoint(x: spineX + 160, y: spineY - 30))
    coverPath.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 28, color: cgColor(0, 0, 0, 0.6))
    ctx.addPath(coverPath)
    ctx.setFillColor(cgColor(0.07, 0.12, 0.22, 1.0)) // Sapphire Leather
    ctx.fillPath()
    ctx.restoreGState()

    // Cover Gold Trim
    ctx.saveGState()
    ctx.addPath(coverPath)
    ctx.setLineWidth(3)
    ctx.setStrokeColor(cgColor(0.88, 0.72, 0.38, 0.75))
    ctx.strokePath()
    ctx.restoreGState()

    // Fanned Paper Layers (Bottom Block)
    for i in (1...3).reversed() {
        let offset = CGFloat(i) * 4.0
        let layerPath = CGMutablePath()
        layerPath.move(to: CGPoint(x: spineX, y: spineY - 14 + offset))
        layerPath.addCurve(to: CGPoint(x: spineX - bookWidth + offset, y: spineY + offset),
                           control1: CGPoint(x: spineX - 150, y: spineY - 20 + offset),
                           control2: CGPoint(x: spineX - 250, y: spineY - 5 + offset))
        layerPath.addLine(to: CGPoint(x: spineX - bookWidth + offset, y: spineY + bookHeight - offset))
        layerPath.addCurve(to: CGPoint(x: spineX, y: spineY + bookHeight - 24 - offset),
                           control1: CGPoint(x: spineX - 250, y: spineY + bookHeight - 10 - offset),
                           control2: CGPoint(x: spineX - 150, y: spineY + bookHeight - 24 - offset))
        layerPath.addCurve(to: CGPoint(x: spineX + bookWidth - offset, y: spineY + bookHeight - offset),
                           control1: CGPoint(x: spineX + 150, y: spineY + bookHeight - 24 - offset),
                           control2: CGPoint(x: spineX + 250, y: spineY + bookHeight - 10 - offset))
        layerPath.addLine(to: CGPoint(x: spineX + bookWidth - offset, y: spineY + offset))
        layerPath.addCurve(to: CGPoint(x: spineX, y: spineY - 14 + offset),
                           control1: CGPoint(x: spineX + 250, y: spineY - 5 + offset),
                           control2: CGPoint(x: spineX + 150, y: spineY - 20 + offset))
        layerPath.closeSubpath()

        ctx.addPath(layerPath)
        ctx.setFillColor(cgColor(0.88 - CGFloat(i) * 0.05, 0.84 - CGFloat(i) * 0.05, 0.76 - CGFloat(i) * 0.05, 1.0))
        ctx.fillPath()
    }

    // Top Main Ivory Pages
    // Left Page
    let leftPagePath = CGMutablePath()
    leftPagePath.move(to: CGPoint(x: spineX, y: spineY))
    leftPagePath.addCurve(to: CGPoint(x: spineX - bookWidth, y: spineY + 12),
                          control1: CGPoint(x: spineX - 140, y: spineY - 18),
                          control2: CGPoint(x: spineX - 250, y: spineY - 2))
    leftPagePath.addLine(to: CGPoint(x: spineX - bookWidth, y: spineY + bookHeight))
    leftPagePath.addCurve(to: CGPoint(x: spineX, y: spineY + bookHeight - 14),
                          control1: CGPoint(x: spineX - 250, y: spineY + bookHeight - 10),
                          control2: CGPoint(x: spineX - 140, y: spineY + bookHeight - 26))
    leftPagePath.closeSubpath()

    ctx.saveGState()
    ctx.addPath(leftPagePath)
    ctx.clip()
    let leftPageColors = [
        cgColor(0.99, 0.97, 0.93, 1.0), // Warm ivory
        cgColor(0.94, 0.90, 0.83, 1.0)
    ] as CFArray
    if let pageGrad = CGGradient(colorsSpace: colorSpace, colors: leftPageColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(pageGrad, start: CGPoint(x: spineX - bookWidth, y: spineY + bookHeight), end: CGPoint(x: spineX, y: spineY), options: [])
    }
    ctx.restoreGState()

    // Right Page
    let rightPagePath = CGMutablePath()
    rightPagePath.move(to: CGPoint(x: spineX, y: spineY))
    rightPagePath.addCurve(to: CGPoint(x: spineX + bookWidth, y: spineY + 12),
                           control1: CGPoint(x: spineX + 140, y: spineY - 18),
                           control2: CGPoint(x: spineX + 250, y: spineY - 2))
    rightPagePath.addLine(to: CGPoint(x: spineX + bookWidth, y: spineY + bookHeight))
    rightPagePath.addCurve(to: CGPoint(x: spineX, y: spineY + bookHeight - 14),
                           control1: CGPoint(x: spineX + 250, y: spineY + bookHeight - 10),
                           control2: CGPoint(x: spineX + 140, y: spineY + bookHeight - 26))
    rightPagePath.closeSubpath()

    ctx.saveGState()
    ctx.addPath(rightPagePath)
    ctx.clip()
    let rightPageColors = [
        cgColor(0.98, 0.96, 0.91, 1.0),
        cgColor(0.92, 0.88, 0.80, 1.0)
    ] as CFArray
    if let pageGrad = CGGradient(colorsSpace: colorSpace, colors: rightPageColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(pageGrad, start: CGPoint(x: spineX + bookWidth, y: spineY + bookHeight), end: CGPoint(x: spineX, y: spineY), options: [])
    }
    ctx.restoreGState()

    // Center Spine Shadow (书脊立体明暗缝)
    ctx.saveGState()
    let spineShadowColors = [
        cgColor(0, 0, 0, 0.35),
        cgColor(0, 0, 0, 0.0)
    ] as CFArray
    if let spineGrad = CGGradient(colorsSpace: colorSpace, colors: spineShadowColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(spineGrad, start: CGPoint(x: spineX - 18, y: spineY), end: CGPoint(x: spineX - 60, y: spineY), options: [])
        ctx.drawLinearGradient(spineGrad, start: CGPoint(x: spineX + 18, y: spineY), end: CGPoint(x: spineX + 60, y: spineY), options: [])
    }
    ctx.restoreGState()

    // Left Page Content: The Embossed "D" Monogram
    let dFont = NSFont(name: "Times New Roman Bold", size: 130) ?? NSFont.systemFont(ofSize: 130, weight: .bold)
    let dAttrs: [NSAttributedString.Key: Any] = [
        .font: dFont,
        .foregroundColor: NSColor(calibratedRed: 0.65, green: 0.48, blue: 0.22, alpha: 0.9)
    ]
    let dStr = NSAttributedString(string: "D", attributes: dAttrs)
    let dRect = CGRect(x: spineX - 225, y: spineY + 55, width: 140, height: 140)
    dStr.draw(in: dRect)

    // Right Page Content: Literary Paragraph Lines
    for lineIdx in 0..<5 {
        let lineY = spineY + 185 - CGFloat(lineIdx) * 26
        let lineLength: CGFloat = lineIdx == 4 ? 120 : (200 - CGFloat(lineIdx % 2) * 24)
        let lineRect = CGRect(x: spineX + 65, y: lineY, width: lineLength, height: 6)
        let linePath = CGPath(roundedRect: lineRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.addPath(linePath)
        ctx.setFillColor(cgColor(0.72, 0.64, 0.52, 0.55))
        ctx.fillPath()
    }

    // 5. HERO AI SPARKLE & NEURAL CORE (Hovering radiant 4-point star)
    let starCenterX: CGFloat = spineX
    let starCenterY: CGFloat = spineY + bookHeight + 60

    // Radial Golden Halo
    let starGlowColors = [
        cgColor(0.98, 0.84, 0.45, 0.65), // Radiant Gold
        cgColor(0.40, 0.88, 0.98, 0.25), // Cyan Aurora rim
        cgColor(0.98, 0.84, 0.45, 0.0)
    ] as CFArray
    if let starGlow = CGGradient(colorsSpace: colorSpace, colors: starGlowColors, locations: [0.0, 0.4, 1.0]) {
        ctx.drawRadialGradient(starGlow, startCenter: CGPoint(x: starCenterX, y: starCenterY), startRadius: 4,
                               endCenter: CGPoint(x: starCenterX, y: starCenterY), endRadius: 130, options: [])
    }

    // 4-point Star Shape
    func drawSparkle(center: CGPoint, radius: CGFloat, innerRadius: CGFloat, fillColor: CGColor) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x, y: center.y + radius))
        path.addQuadCurve(to: CGPoint(x: center.x + innerRadius, y: center.y), control: CGPoint(x: center.x + innerRadius * 0.4, y: center.y + innerRadius * 0.4))
        path.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y - innerRadius), control: CGPoint(x: center.x + innerRadius * 0.4, y: center.y - innerRadius * 0.4))
        path.addLine(to: CGPoint(x: center.x, y: center.y - radius))
        path.addQuadCurve(to: CGPoint(x: center.x - innerRadius, y: center.y), control: CGPoint(x: center.x - innerRadius * 0.4, y: center.y - innerRadius * 0.4))
        path.addLine(to: CGPoint(x: center.x - radius, y: center.y))
        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y + innerRadius), control: CGPoint(x: center.x - innerRadius * 0.4, y: center.y + innerRadius * 0.4))
        path.closeSubpath()

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 0), blur: 14, color: cgColor(0.98, 0.85, 0.4, 0.85))
        ctx.addPath(path)
        ctx.setFillColor(fillColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Main Core Star
    drawSparkle(center: CGPoint(x: starCenterX, y: starCenterY), radius: 64, innerRadius: 16, fillColor: cgColor(1.0, 0.94, 0.65, 1.0))
    // Core Bright Center Point
    ctx.addArc(center: CGPoint(x: starCenterX, y: starCenterY), radius: 6, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.setFillColor(cgColor(1.0, 1.0, 1.0, 1.0))
    ctx.fillPath()

    // 2 Orbital Satellite Sparkles
    drawSparkle(center: CGPoint(x: starCenterX - 95, y: starCenterY + 45), radius: 24, innerRadius: 6, fillColor: cgColor(0.55, 0.92, 0.98, 0.9))
    drawSparkle(center: CGPoint(x: starCenterX + 105, y: starCenterY - 15), radius: 20, innerRadius: 5, fillColor: cgColor(0.98, 0.85, 0.5, 0.85))

    image.unlockFocus()
    return image
}

// Generate all standard iconset sizes
let iconsetDir = "DReader.iconset"
try? FileManager.default.removeItem(atPath: iconsetDir)
try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for item in sizes {
    let img = drawDReaderIcon(size: CGFloat(item.px))
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("Failed to render \(item.name)")
        continue
    }
    let path = "\(iconsetDir)/\(item.name)"
    try? png.write(to: URL(fileURLWithPath: path))
    print("Generated \(item.name) (\(item.px)x\(item.px))")
}

print("Running iconutil to generate AppIcon.icns...")
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetDir, "-o", "AppIcon.icns"]
try proc.run()
proc.waitUntilExit()

if FileManager.default.fileExists(atPath: "AppIcon.icns") {
    print("✅ Successfully generated AppIcon.icns!")
} else {
    print("❌ Failed to generate AppIcon.icns")
}
