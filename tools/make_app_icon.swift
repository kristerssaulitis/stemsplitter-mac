// Run: swift tools/make_app_icon.swift
import AppKit
import CoreGraphics

let S: CGFloat = 1024
let margin: CGFloat = 100
let shape = S - 2 * margin              // macOS Big Sur grid
let radius: CGFloat = 186

let stems: [(CGColor, String)] = [
    (#colorLiteral(red: 1.00, green: 0.43, blue: 0.66, alpha: 1).cgColor, "vocals"),
    (#colorLiteral(red: 1.00, green: 0.66, blue: 0.30, alpha: 1).cgColor, "drums"),
    (#colorLiteral(red: 0.35, green: 0.66, blue: 1.00, alpha: 1).cgColor, "bass"),
    (#colorLiteral(red: 0.32, green: 0.88, blue: 0.63, alpha: 1).cgColor, "other"),
]

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

let rect = CGRect(x: margin, y: margin, width: shape, height: shape)
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.addPath(path)
ctx.clip()

let bg = CGGradient(colorsSpace: cs,
                    colors: [#colorLiteral(red: 0.16, green: 0.16, blue: 0.26, alpha: 1).cgColor,
                             #colorLiteral(red: 0.055, green: 0.055, blue: 0.10, alpha: 1).cgColor] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])

// Deterministic waveform heights (seeded LCG)
var seed: UInt64 = 0x5EED_5EED_5EED_5EED
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat((seed >> 33) & 0xFFFF) / 65535.0 }

let barW: CGFloat = 17
let pitch: CGFloat = 29
let x0 = margin + 96
let x1 = S - margin - 96
let laneH: CGFloat = 108

for (i, stem) in stems.enumerated() {
    let yc = margin + shape * CGFloat(0.155 + 0.23 * Double(i))
    let (color, _) = stem
    var x = x0
    while x <= x1 {
        let t = (x - x0) / (x1 - x0)
        let envelope = 0.35 + 0.65 * sin(.pi * t)          // quieter at edges
        let h = laneH * (0.18 + 0.82 * rnd()) * envelope
        let bar = CGRect(x: x - barW / 2, y: yc - h / 2, width: barW, height: h)
        ctx.setStrokeColor(color.copy(alpha: 0.22)!)
        ctx.setLineWidth(barW + 10)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: bar.midX, y: bar.minY + barW / 2))
        ctx.addLine(to: CGPoint(x: bar.midX, y: bar.maxY - barW / 2))
        ctx.strokePath()
        ctx.setStrokeColor(color.copy(alpha: 0.95)!)
        ctx.setLineWidth(barW)
        ctx.move(to: CGPoint(x: bar.midX, y: bar.minY + barW / 2))
        ctx.addLine(to: CGPoint(x: bar.midX, y: bar.maxY - barW / 2))
        ctx.strokePath()
        x += pitch
    }
}

let sheen = CGGradient(colorsSpace: cs,
                       colors: [NSColor.white.withAlphaComponent(0.07).cgColor,
                                NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: S * 0.45), options: [])
ctx.restoreGState()

ctx.addPath(path)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
ctx.setLineWidth(3)
ctx.strokePath()

let img = ctx.makeImage()!
let out = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
    .write(to: out)
print("wrote \(out.path)")
