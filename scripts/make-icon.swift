// Zeichnet das App-Icon von Klarschiff 2 (1024 px) und alle macOS-Größen ins Asset-Katalog.
// Aufruf: swift scripts/make-icon.swift
import AppKit

let out = URL(filePath: "App/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // Körper nach Apples macOS-Raster: 824 × 824, Rand 100, abgerundet.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Schatten unter dem Körper.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28))
    ctx.addPath(shape); ctx.setFillColor(color(0x2EC4B6)); ctx.fillPath()
    ctx.restoreGState()

    // Verlauf Türkis → Violett (unten links → oben rechts), wie die Wortmarke.
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [color(0x2EC4B6), color(0x4F93E0), color(0x7B61FF)] as CFArray,
                          locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 924, y: 924), options: [])
    // Sanfter Glanz oben.
    let gloss = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    // Steuerrad in Weiß.
    let c = CGPoint(x: 512, y: 512)
    let white = color(0xFFFFFF)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x1B1446, 0.30))
    ctx.setStrokeColor(white); ctx.setFillColor(white); ctx.setLineCap(.round)
    // Speichen mit Griffen.
    for i in 0..<8 {
        let a = CGFloat(i) * .pi / 4 + .pi / 8
        let dir = CGPoint(x: cos(a), y: sin(a))
        ctx.setLineWidth(34)
        ctx.move(to: CGPoint(x: c.x + dir.x * 90, y: c.y + dir.y * 90))
        ctx.addLine(to: CGPoint(x: c.x + dir.x * 330, y: c.y + dir.y * 330))
        ctx.strokePath()
        let knob = CGPoint(x: c.x + dir.x * 330, y: c.y + dir.y * 330)
        ctx.fillEllipse(in: CGRect(x: knob.x - 30, y: knob.y - 30, width: 60, height: 60))
    }
    // Radkranz.
    ctx.setLineWidth(46)
    ctx.strokeEllipse(in: CGRect(x: c.x - 235, y: c.y - 235, width: 470, height: 470))
    // Nabe.
    ctx.fillEllipse(in: CGRect(x: c.x - 118, y: c.y - 118, width: 236, height: 236))
    ctx.restoreGState()

    // „2“ in der Nabe, im Verlauf.
    let font = NSFont.systemFont(ofSize: 170, weight: .heavy)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "2", attributes: [.font: font]))
    let b = CTLineGetImageBounds(line, ctx)
    ctx.saveGState()
    ctx.textPosition = CGPoint(x: c.x - b.midX, y: c.y - b.midY)
    ctx.setTextDrawingMode(.clip)
    CTLineDraw(line, ctx)
    ctx.drawLinearGradient(grad, start: CGPoint(x: c.x - 100, y: c.y - 100), end: CGPoint(x: c.x + 100, y: c.y + 100), options: [])
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

var images: [String] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try! draw(pt * scale).write(to: out.appending(path: name))
        images.append("""
            { "idiom" : "mac", "size" : "\(pt)x\(pt)", "scale" : "\(scale)x", "filename" : "\(name)" }
        """)
    }
}
let contents = "{\n  \"images\" : [\n" + images.joined(separator: ",\n") + "\n  ],\n  \"info\" : { \"version\" : 1, \"author\" : \"xcode\" }\n}\n"
try! contents.write(to: out.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
try! "{\n  \"info\" : { \"version\" : 1, \"author\" : \"xcode\" }\n}\n".write(
    to: out.deletingLastPathComponent().appending(path: "Contents.json"), atomically: true, encoding: .utf8)
print("AppIcon geschrieben: \(out.path)")
