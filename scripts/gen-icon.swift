#!/usr/bin/env swift
// Generates the Perch app icon: a geometric bird perched on a notch bar.
// Usage: swift scripts/gen-icon.swift <output-1024.png>
// Deterministic vector drawing — re-run any time, no design tools needed.

import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let size = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
    fatalError("bitmap alloc failed")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Background squircle (macOS icon grid: ~900pt centered).
let bg = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900),
                      xRadius: 200, yRadius: 200)
NSGradient(starting: rgb(0x232741), ending: rgb(0x0B0C14))!.draw(in: bg, angle: -90)
rgb(0xFFFFFF, 0.07).setStroke()
bg.lineWidth = 4
bg.stroke()

// The perch: a notch-shaped bar.
let bar = NSBezierPath(roundedRect: NSRect(x: 282, y: 385, width: 460, height: 90),
                       xRadius: 45, yRadius: 45)
rgb(0x05060A).setFill()
bar.fill()
rgb(0xFFFFFF, 0.10).setStroke()
bar.lineWidth = 3
bar.stroke()

// Amber attention dot on the bar.
let dot = NSBezierPath(ovalIn: NSRect(x: 682, y: 414, width: 32, height: 32))
rgb(0xFFB020).setFill()
dot.fill()

// Bird silhouette: tail + body + head + beak, one gradient fill.
let bird = NSBezierPath()
// tail (back-left, angled down toward the bar)
bird.move(to: NSPoint(x: 395, y: 585))
bird.line(to: NSPoint(x: 268, y: 503))
bird.line(to: NSPoint(x: 400, y: 491))
bird.close()
// body
bird.appendOval(in: NSRect(x: 360, y: 460, width: 280, height: 230))
// head
bird.appendOval(in: NSRect(x: 535, y: 610, width: 150, height: 150))
// beak — wound counterclockwise to match the ovals; opposite winding would
// cancel under the nonzero fill rule and punch a hole at the overlap
bird.move(to: NSPoint(x: 668, y: 652))
bird.line(to: NSPoint(x: 748, y: 675))
bird.line(to: NSPoint(x: 674, y: 700))
bird.close()
NSGradient(starting: rgb(0xFFB84D), ending: rgb(0xF5731A))!.draw(in: bird, angle: -90)

// Wing hint.
let wing = NSBezierPath(ovalIn: NSRect(x: 392, y: 500, width: 175, height: 120))
rgb(0xD95A0E, 0.38).setFill()
wing.fill()

// Eye.
let eye = NSBezierPath(ovalIn: NSRect(x: 618, y: 690, width: 24, height: 24))
rgb(0x14161F).setFill()
eye.fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("png encode failed")
}
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
