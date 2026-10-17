// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
// Draws MacGaming's app icon: an original game pad, in the app's teal, on a dark macOS-style tile.
// (SF Symbols may not be used in app icons, so the header's symbol is not reused here.)
// Usage: swift make-icon.swift <output.png>   — writes a 1024×1024 PNG; source/build.sh icon makes the .icns.
import AppKit

let size: CGFloat = 1024
guard CommandLine.arguments.count == 2 else { fputs("usage: make-icon.swift <output.png>\n", stderr); exit(2) }
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Tile: the 824-point content square of the macOS icon grid.
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = color(0x000000, 0.35); shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
color(0x1B1F25).setFill(); tile.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: color(0x323844), ending: color(0x14171C))!.draw(in: tile, angle: -90)
color(0xFFFFFF, 0.08).setStroke(); tile.lineWidth = 4; tile.stroke()

// Pad body: a wide rounded bar with two round grips below it, filled as one shape.
let body = NSBezierPath()
body.append(NSBezierPath(roundedRect: NSRect(x: 222, y: 440, width: 580, height: 240), xRadius: 120, yRadius: 120))
body.append(NSBezierPath(ovalIn: NSRect(x: 214, y: 300, width: 250, height: 290)))
body.append(NSBezierPath(ovalIn: NSRect(x: 560, y: 300, width: 250, height: 290)))
body.windingRule = .nonZero
NSGraphicsContext.saveGraphicsState()
let padShadow = NSShadow()
padShadow.shadowColor = color(0x000000, 0.45); padShadow.shadowBlurRadius = 30; padShadow.shadowOffset = NSSize(width: 0, height: -14)
padShadow.set()
color(0x2FB3C6).setFill(); body.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
body.addClip()
NSGradient(starting: color(0x5ED6E6), ending: color(0x1E93A6))!.draw(in: NSRect(x: 200, y: 290, width: 624, height: 400), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Controls, cut in the tile's colour: a cross on the left, four buttons on the right, two small keys in the middle.
let hole = color(0x1A1E24)
hole.setFill()
let cross = NSPoint(x: 348, y: 540)
NSBezierPath(roundedRect: NSRect(x: cross.x - 70, y: cross.y - 22, width: 140, height: 44), xRadius: 12, yRadius: 12).fill()
NSBezierPath(roundedRect: NSRect(x: cross.x - 22, y: cross.y - 70, width: 44, height: 140), xRadius: 12, yRadius: 12).fill()
let buttons = NSPoint(x: 676, y: 540)
for (dx, dy) in [(0.0, 52.0), (0.0, -52.0), (52.0, 0.0), (-52.0, 0.0)] {
    NSBezierPath(ovalIn: NSRect(x: buttons.x + dx - 25, y: buttons.y + dy - 25, width: 50, height: 50)).fill()
}
for x in [470.0, 554.0] {
    NSBezierPath(roundedRect: NSRect(x: x - 26, y: 588, width: 52, height: 20), xRadius: 10, yRadius: 10).fill()
}

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
