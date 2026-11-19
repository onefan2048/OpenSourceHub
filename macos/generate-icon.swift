import Cocoa

guard CommandLine.arguments.count > 1 else {
    fputs("Usage: swift generate-icon.swift <output.iconset>\n", stderr)
    exit(1)
}
let iconsetPath = CommandLine.arguments[1]
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try! fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

func renderIcon(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    // macOS squircle padding (~9.8%)
    let pad = s * 0.098
    let rect = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let radius = rect.width * 0.225
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Deep indigo-to-cyan gradient background
    cg.saveGState()
    path.addClip()
    let cs = CGColorSpaceCreateDeviceRGB()
    let colors = [
        CGColor(red: 0.08, green: 0.11, blue: 0.26, alpha: 1.0),
        CGColor(red: 0.18, green: 0.26, blue: 0.56, alpha: 1.0),
        CGColor(red: 0.07, green: 0.58, blue: 0.72, alpha: 1.0),
    ] as CFArray
    let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0.0, 0.55, 1.0])!
    cg.drawLinearGradient(
        grad,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: []
    )
    cg.restoreGState()

    // Subtle inner highlight border
    NSColor.white.withAlphaComponent(0.18).setStroke()
    path.lineWidth = max(1.0, s * 0.012)
    path.stroke()

    // Draw stylized hub nodes & branches (representing OpenSource Hub)
    let cx = s * 0.5
    let cy = s * 0.5
    let r = rect.width * 0.24

    let nodes: [CGPoint] = [
        CGPoint(x: cx, y: cy + r * 0.92),
        CGPoint(x: cx - r * 0.88, y: cy - r * 0.52),
        CGPoint(x: cx + r * 0.88, y: cy - r * 0.52),
    ]

    // Connecting lines
    cg.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
    cg.setLineWidth(max(1.5, s * 0.048))
    cg.setLineCap(.round)
    for n in nodes {
        cg.move(to: CGPoint(x: cx, y: cy))
        cg.addLine(to: n)
    }
    cg.strokePath()

    // Outer ring connecting satellite nodes softly
    cg.setStrokeColor(CGColor(red: 0.65, green: 0.92, blue: 1.0, alpha: 0.35))
    cg.setLineWidth(max(1.0, s * 0.022))
    cg.addEllipse(in: CGRect(x: cx - r * 0.92, y: cy - r * 0.92, width: r * 1.84, height: r * 1.84))
    cg.strokePath()

    // Satellite nodes
    let satR = s * 0.072
    for n in nodes {
        cg.setFillColor(CGColor(red: 0.45, green: 0.92, blue: 0.98, alpha: 1.0))
        cg.fillEllipse(in: CGRect(x: n.x - satR, y: n.y - satR, width: satR * 2, height: satR * 2))
    }

    // Center hub circle
    let hubR = s * 0.115
    cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1.0))
    cg.fillEllipse(in: CGRect(x: cx - hubR, y: cy - hubR, width: hubR * 2, height: hubR * 2))
    let innerR = s * 0.052
    cg.setFillColor(CGColor(red: 0.15, green: 0.25, blue: 0.55, alpha: 1.0))
    cg.fillEllipse(in: CGRect(x: cx - innerR, y: cy - innerR, width: innerR * 2, height: innerR * 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (px, name) in sizes {
    let data = renderIcon(size: px)
    try! data.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(name)"))
}
