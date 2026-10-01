// Makes the app icon from square artwork that runs to its edges:
//
//     swift Support/icon.swift Support/AppIcon.png Support/AppIcon.icns
//
// The artwork is cut to the shape macOS icons have and set on Apple's grid,
// an 824 point tile in a 1024 point canvas with a shadow under it.
import AppKit
import SwiftUI

let arguments = CommandLine.arguments
guard arguments.count == 3, let art = NSImage(contentsOfFile: arguments[1]) else {
    print("usage: swift icon.swift <artwork.png> <AppIcon.icns>")
    exit(1)
}

func tile(pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high

    let scale = CGFloat(pixels) / 1024
    let frame = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let shape = NSBezierPath(
        cgPath: RoundedRectangle(cornerRadius: 185.4 * scale, style: .continuous).path(in: frame).cgPath
    )

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 10 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    shape.addClip()
    art.draw(in: frame)
    return bitmap.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try tile(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try tile(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", arguments[2]]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(iconutil.terminationStatus)
