// Draws the picture behind the icons in the disk image's window:
//
//     swift Support/dmg.swift Support/DiskImage.tiff
//
// It is clear apart from an arrow and two lines of words, in a grey that reads
// on the white window of a Mac in light mode and the dark one in dark mode.
// `build.sh` puts the app at `app` and the Applications folder at `folder`.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    print("usage: swift dmg.swift <DiskImage.tiff>")
    exit(1)
}

// In points, measured from the top left as Finder does.
let size = NSSize(width: 640, height: 400)
let app = NSPoint(x: 170, y: 170), folder = NSPoint(x: 470, y: 170)
let grey = NSColor(white: 0.5, alpha: 1)

func picture(scale: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    // An arrow from the app to the folder, between the two icons.
    let middle = (app.x + folder.x) / 2, level = size.height - app.y
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: middle - 38, y: level))
    arrow.line(to: NSPoint(x: middle + 38, y: level))
    arrow.move(to: NSPoint(x: middle + 16, y: level + 22))
    arrow.line(to: NSPoint(x: middle + 38, y: level))
    arrow.line(to: NSPoint(x: middle + 16, y: level - 22))
    arrow.lineWidth = 7
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    grey.setStroke()
    arrow.stroke()

    write("Drag Cortado onto the Applications folder", size: 17, weight: .semibold, top: 296)
    write("Then open it from Applications. It lives in the menu bar.", size: 14, weight: .regular, top: 324)
    return bitmap
}

func write(_ words: String, size points: CGFloat, weight: NSFont.Weight, top: CGFloat) {
    let line = NSAttributedString(string: words, attributes: [
        .font: NSFont.systemFont(ofSize: points, weight: weight),
        .foregroundColor: grey,
    ])
    let bounds = line.size()
    line.draw(at: NSPoint(x: (size.width - bounds.width) / 2, y: size.height - top - bounds.height))
}

// One file holding the picture at both sizes, so it is sharp on any display.
let image = NSImage(size: size)
image.addRepresentation(picture(scale: 1))
image.addRepresentation(picture(scale: 2))
try image.tiffRepresentation(using: .lzw, factor: 0)!.write(to: URL(fileURLWithPath: arguments[1]))
