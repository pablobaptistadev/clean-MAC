// Gera Resources/AppIcon.png (1024 × 1024) do PrintScreen.
// Uso: swift Resources/make-icon.swift Resources/AppIcon.png
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Corpo no grid de ícones do macOS: 824 pt centrados, cantos arredondados e sombra leve.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.shadowBlurRadius = 28
shadow.set()
NSColor(red: 0.04, green: 0.36, blue: 0.90, alpha: 1).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

// Azul do sistema em degradê, mais claro em cima.
NSGradient(colors: [NSColor(red: 0.33, green: 0.66, blue: 1.0, alpha: 1), NSColor(red: 0.02, green: 0.38, blue: 0.93, alpha: 1)])!
    .draw(in: shape, angle: -90)
NSGraphicsContext.saveGraphicsState()
shape.setClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
    .draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Marcas de recorte nos quatro cantos (o "seletor" da captura).
NSColor.white.setStroke()
let inner = body.insetBy(dx: 170, dy: 170)
let arm: CGFloat = 150
let corners = NSBezierPath()
corners.lineWidth = 58
corners.lineCapStyle = .round
corners.lineJoinStyle = .round
corners.move(to: CGPoint(x: inner.minX, y: inner.maxY - arm)); corners.line(to: CGPoint(x: inner.minX, y: inner.maxY)); corners.line(to: CGPoint(x: inner.minX + arm, y: inner.maxY))
corners.move(to: CGPoint(x: inner.maxX - arm, y: inner.maxY)); corners.line(to: CGPoint(x: inner.maxX, y: inner.maxY)); corners.line(to: CGPoint(x: inner.maxX, y: inner.maxY - arm))
corners.move(to: CGPoint(x: inner.maxX, y: inner.minY + arm)); corners.line(to: CGPoint(x: inner.maxX, y: inner.minY)); corners.line(to: CGPoint(x: inner.maxX - arm, y: inner.minY))
corners.move(to: CGPoint(x: inner.minX + arm, y: inner.minY)); corners.line(to: CGPoint(x: inner.minX, y: inner.minY)); corners.line(to: CGPoint(x: inner.minX, y: inner.minY + arm))
corners.stroke()

// Seta de marcação no centro, em amarelo do sistema.
let arrowColor = NSColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1)
let from = CGPoint(x: body.midX - 120, y: body.midY - 120)
let to = CGPoint(x: body.midX + 95, y: body.midY + 95)
let angle = atan2(to.y - from.y, to.x - from.x)
let head: CGFloat = 120
let shaft = NSBezierPath()
shaft.lineWidth = 52
shaft.lineCapStyle = .round
shaft.move(to: from)
shaft.line(to: CGPoint(x: to.x - head * 0.6 * cos(angle), y: to.y - head * 0.6 * sin(angle)))
arrowColor.setStroke()
shaft.stroke()
let tip = NSBezierPath()
tip.move(to: to)
tip.line(to: CGPoint(x: to.x - head * cos(angle - .pi / 6), y: to.y - head * sin(angle - .pi / 6)))
tip.line(to: CGPoint(x: to.x - head * cos(angle + .pi / 6), y: to.y - head * sin(angle + .pi / 6)))
tip.close()
tip.lineJoinStyle = .round
tip.lineWidth = 18
arrowColor.setFill()
tip.fill()
tip.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("✓ \(output)")
