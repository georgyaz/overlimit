import AppKit
import CoreGraphics

// make-icon.swift — рисует иконку «три полосы» во все нужные размеры
// и складывает в AppIcon.iconset для сборки через iconutil.

let bg    = NSColor(srgbRed: 0.106, green: 0.106, blue: 0.098, alpha: 1)  // #1B1B19
let track = NSColor(srgbRed: 0.227, green: 0.227, blue: 0.216, alpha: 1)  // #3A3A37
let green = NSColor(srgbRed: 0.290, green: 0.871, blue: 0.502, alpha: 1)  // #4ADE80
let amber = NSColor(srgbRed: 0.980, green: 0.800, blue: 0.082, alpha: 1)  // #FACC15

// доли от стороны иконки: ширина дорожки, заполнение, цвет
let bars: [(fill: CGFloat, color: NSColor)] = [
    (0.354, green),   // 5ч
    (0.635, green),   // Все
    (0.750, amber),   // Fable — жёлтый, как сейчас
]

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!
    ctx.imageInterpolation = .high

    let inset = size * 0.055
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    bg.setFill()
    NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225,
                 yRadius: rect.width * 0.225).fill()

    let barW = rect.width * 0.60
    let barH = rect.height * 0.106
    let barX = rect.minX + (rect.width - barW) / 2
    let gap  = rect.height * 0.113
    let total = barH * 3 + gap * 2
    var y = rect.midY + total / 2 - barH

    for b in bars {
        track.setFill()
        NSBezierPath(roundedRect: NSRect(x: barX, y: y, width: barW, height: barH),
                     xRadius: barH / 2, yRadius: barH / 2).fill()
        b.color.setFill()
        NSBezierPath(roundedRect: NSRect(x: barX, y: y, width: barW * b.fill, height: barH),
                     xRadius: barH / 2, yRadius: barH / 2).fill()
        y -= barH + gap
    }
    img.unlockFocus()
    return img
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

let variants: [(name: String, px: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for v in variants {
    let img = drawIcon(size: v.px)
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(out)/\(v.name).png"))
    print("✓ \(v.name).png  \(Int(v.px))px")
}
