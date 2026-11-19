#!/usr/bin/env swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Assets.xcassets/AppIcon.appiconset"
let fm = FileManager.default
try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let size = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fputs("Failed to create CGContext\n", stderr)
    exit(1)
}

let rect = CGRect(x: 0, y: 0, width: size, height: size)

// Emerald gradient background (matches LCSign-inspired warm emerald theme)
let colors = [
    CGColor(red: 0.145, green: 0.486, blue: 0.376, alpha: 1.0),
    CGColor(red: 0.086, green: 0.310, blue: 0.243, alpha: 1.0),
] as CFArray
if let grad = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: CGFloat(size), y: 0), options: [])
}

// Subtle decorative light rings
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
ctx.fillEllipse(in: CGRect(x: 560, y: 580, width: 520, height: 520))
ctx.fillEllipse(in: CGRect(x: -140, y: -120, width: 460, height: 460))

// Stylized Hub / Package emblem (center isometric cube + orbit node)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
ctx.setLineWidth(44)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

let cx: CGFloat = 512
let cy: CGFloat = 512
let r: CGFloat = 250

let top = CGPoint(x: cx, y: cy + r)
let tr = CGPoint(x: cx + r * 0.866, y: cy + r * 0.5)
let br = CGPoint(x: cx + r * 0.866, y: cy - r * 0.5)
let bottom = CGPoint(x: cx, y: cy - r)
let bl = CGPoint(x: cx - r * 0.866, y: cy - r * 0.5)
let tl = CGPoint(x: cx - r * 0.866, y: cy + r * 0.5)
let center = CGPoint(x: cx, y: cy)

// Outer hexagon
ctx.beginPath()
ctx.move(to: top)
ctx.addLine(to: tr)
ctx.addLine(to: br)
ctx.addLine(to: bottom)
ctx.addLine(to: bl)
ctx.addLine(to: tl)
ctx.closePath()
ctx.strokePath()

// Inner Y edges
ctx.beginPath()
ctx.move(to: tl)
ctx.addLine(to: center)
ctx.addLine(to: tr)
ctx.move(to: center)
ctx.addLine(to: bottom)
ctx.strokePath()

// Center dot accent
ctx.setFillColor(CGColor(red: 0.65, green: 0.96, blue: 0.82, alpha: 1.0))
ctx.fillEllipse(in: CGRect(x: cx - 38, y: cy - 38, width: 76, height: 76))

guard let image = ctx.makeImage() else { exit(1) }
let iconPath = (outDir as NSString).appendingPathComponent("AppIcon-1024.png")
let destURL = URL(fileURLWithPath: iconPath)
guard let dest = CGImageDestinationCreateWithURL(destURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)

let contentsJSON = """
{
  "images" : [
    {
      "filename" : "AppIcon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
try contentsJSON.write(toFile: (outDir as NSString).appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

let assetsContents = """
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
let assetsRoot = (outDir as NSString).deletingLastPathComponent
try assetsContents.write(toFile: (assetsRoot as NSString).appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

print("Generated iOS AppIcon at \(iconPath)")
