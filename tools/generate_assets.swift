#!/usr/bin/env swift
// Procedural art generator for the 1.2 "AAA" visual overhaul.
// Regenerates every game texture/sprite from code (neon arena art direction):
//   swift tools/generate_assets.swift
// Outputs into mevsmusic/GameAssets/ and the app icon set. Deterministic (seeded LCG).

import AppKit
import CoreText

let assetsDir = "mevsmusic/GameAssets"
let iconPath = "mevsmusic/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

// MARK: - Core helpers

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("context \(w)x\(h)")
    }
    return ctx
}

func save(_ ctx: CGContext, _ path: String) {
    guard let image = ctx.makeImage() else { fatalError("image \(path)") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png \(path)") }
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    do { try data.write(to: URL(fileURLWithPath: path)) } catch { fatalError("write \(path): \(error)") }
    print("wrote \(path)")
}

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func hsba(_ h: CGFloat, _ s: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
    NSColor(hue: h, saturation: s, brightness: b, alpha: a).cgColor
}

struct Rand {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) & 0x7FFF_FFFF) / CGFloat(0x7FFF_FFFF)
    }
    mutating func range(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { lo + next() * (hi - lo) }
}

// Fill a path with an outer glow (repeated shadowed fills), then a crisp core fill.
func glowFill(_ ctx: CGContext, _ path: CGPath, fill: CGColor, glow: CGColor,
              blur: CGFloat, passes: Int = 2) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: blur, color: glow)
    ctx.setFillColor(fill)
    for _ in 0..<passes {
        ctx.addPath(path)
        ctx.fillPath()
    }
    ctx.restoreGState()
    ctx.addPath(path)
    ctx.setFillColor(fill)
    ctx.fillPath()
}

func glowStroke(_ ctx: CGContext, _ path: CGPath, stroke: CGColor, glow: CGColor,
                width: CGFloat, blur: CGFloat, passes: Int = 2) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: blur, color: glow)
    ctx.setStrokeColor(stroke)
    ctx.setLineWidth(width)
    for _ in 0..<passes {
        ctx.addPath(path)
        ctx.strokePath()
    }
    ctx.restoreGState()
}

func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
    return (NSFont(descriptor: descriptor, size: size) ?? base) as CTFont
}

func textLine(_ string: String, _ font: CTFont, _ color: CGColor, tracking: CGFloat = 0) -> CTLine {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font as NSFont,
        .foregroundColor: NSColor(cgColor: color) ?? .white,
        .kern: tracking,
    ]
    return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
}

func lineWidth(_ line: CTLine) -> CGFloat {
    CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
}

// Draws a CTLine centered at `center` (baseline math from glyph bounds), optional glow + italic skew.
func drawText(_ ctx: CGContext, _ string: String, font: CTFont, color: CGColor,
              center: CGPoint, glow: (CGColor, CGFloat)? = nil, skew: CGFloat = 0, tracking: CGFloat = 0) {
    let line = textLine(string, font, color, tracking: tracking)
    let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: skew, d: 1, tx: 0, ty: 0))
    let passes = glow == nil ? 1 : 3
    if let (glowColor, blur) = glow {
        ctx.setShadow(offset: .zero, blur: blur, color: glowColor)
    }
    for _ in 0..<passes {
        ctx.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
        CTLineDraw(line, ctx)
    }
    ctx.restoreGState()
}

func radialGlow(_ ctx: CGContext, center: CGPoint, radius: CGFloat, colors: [CGColor], locations: [CGFloat]) {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) else { return }
    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: radius, options: [])
}

func linearGradient(_ ctx: CGContext, rect: CGRect, colors: [CGColor], locations: [CGFloat], vertical: Bool = true) {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) else { return }
    ctx.saveGState()
    ctx.clip(to: rect)
    let start = CGPoint(x: rect.minX, y: rect.minY)
    let end = vertical ? CGPoint(x: rect.minX, y: rect.maxY) : CGPoint(x: rect.maxX, y: rect.minY)
    ctx.drawLinearGradient(gradient, start: start, end: end, options: [])
    ctx.restoreGState()
}

// MARK: - Shared shapes

// Fighter silhouette, nose up, in a 0...100 box (y-up).
func shipGlyphPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 50, y: 98))              // nose
    p.addLine(to: CGPoint(x: 60, y: 62))
    p.addLine(to: CGPoint(x: 92, y: 28))           // right wing tip
    p.addLine(to: CGPoint(x: 88, y: 18))
    p.addLine(to: CGPoint(x: 62, y: 30))
    p.addLine(to: CGPoint(x: 58, y: 10))           // right engine
    p.addLine(to: CGPoint(x: 42, y: 10))           // left engine
    p.addLine(to: CGPoint(x: 38, y: 30))
    p.addLine(to: CGPoint(x: 12, y: 18))
    p.addLine(to: CGPoint(x: 8, y: 28))            // left wing tip
    p.addLine(to: CGPoint(x: 40, y: 62))
    p.closeSubpath()
    return p
}

func rotatedEllipse(center: CGPoint, rx: CGFloat, ry: CGFloat, angle: CGFloat) -> CGPath {
    var transform = CGAffineTransform(translationX: center.x, y: center.y)
        .rotated(by: angle)
    return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2), transform: &transform)
}

// Musical note glyphs drawn as paths in a 100x140 (y-up) box, centered at (50,70).
// variant 0: single eighth note; 1: beamed pair; 2: beamed sixteenth pair.
func notePath(variant: Int) -> CGPath {
    let path = CGMutablePath()
    let tilt: CGFloat = -0.32
    if variant == 0 {
        path.addPath(rotatedEllipse(center: CGPoint(x: 32, y: 20), rx: 22, ry: 15, angle: tilt))
        path.addRect(CGRect(x: 46, y: 24, width: 9, height: 102))
        // Flag sweeping right off the stem top.
        path.move(to: CGPoint(x: 55, y: 126))
        path.addCurve(to: CGPoint(x: 88, y: 78),
                      control1: CGPoint(x: 84, y: 116), control2: CGPoint(x: 92, y: 96))
        path.addCurve(to: CGPoint(x: 70, y: 42),
                      control1: CGPoint(x: 85, y: 62), control2: CGPoint(x: 78, y: 50))
        path.addCurve(to: CGPoint(x: 74, y: 74),
                      control1: CGPoint(x: 76, y: 54), control2: CGPoint(x: 78, y: 64))
        path.addCurve(to: CGPoint(x: 55, y: 104),
                      control1: CGPoint(x: 70, y: 88), control2: CGPoint(x: 62, y: 98))
        path.closeSubpath()
        return path
    }
    // Beamed pair shared by variants 1 and 2.
    path.addPath(rotatedEllipse(center: CGPoint(x: 22, y: 16), rx: 18, ry: 12, angle: tilt))
    path.addPath(rotatedEllipse(center: CGPoint(x: 76, y: 24), rx: 18, ry: 12, angle: tilt))
    path.addRect(CGRect(x: 30, y: 18, width: 8, height: 102))
    path.addRect(CGRect(x: 84, y: 26, width: 8, height: 102))
    func beam(_ yLeft: CGFloat, _ thickness: CGFloat) {
        path.move(to: CGPoint(x: 30, y: yLeft))
        path.addLine(to: CGPoint(x: 92, y: yLeft + 8))
        path.addLine(to: CGPoint(x: 92, y: yLeft + 8 + thickness))
        path.addLine(to: CGPoint(x: 30, y: yLeft + thickness))
        path.closeSubpath()
    }
    beam(104, 16)
    if variant == 2 { beam(80, 12) }
    return path
}

// A 4-point sparkle star.
func sparklePath(center: CGPoint, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let inner = radius * 0.22
    for i in 0..<4 {
        let a = CGFloat(i) * .pi / 2
        let a1 = a + .pi / 4, a2 = a - .pi / 4
        p.move(to: CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius))
        p.addLine(to: CGPoint(x: center.x + cos(a1) * inner, y: center.y + sin(a1) * inner))
        p.addLine(to: CGPoint(x: center.x + cos(a2) * inner, y: center.y + sin(a2) * inner))
        p.closeSubpath()
    }
    return p
}

func hexPath(center: CGPoint, radius: CGFloat, xScale: CGFloat = 1) -> CGPath {
    let p = CGMutablePath()
    for i in 0..<6 {
        let a = CGFloat(i) * .pi / 3 + .pi / 6
        let point = CGPoint(x: center.x + cos(a) * radius * xScale, y: center.y + sin(a) * radius)
        if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
    }
    p.closeSubpath()
    return p
}

// MARK: - Chord enemy sprite sheets (2048, 8x8; rows top->bottom: 8 born, 40 alive, 16 explode)

struct Palette {
    let core: CGColor       // bright fill
    let glow: CGColor       // saturated halo
    let deep: CGColor       // dark accent
}

func generateChordSheet(file: String, variant: Int, palette: Palette, seed: UInt64) {
    let sheet = 2048, tile = 256
    let ctx = makeContext(sheet, sheet)
    var rand = Rand(seed)
    let shardAngles: [CGFloat] = (0..<14).map { _ in rand.range(0, 2 * .pi) }
    let shardSpeeds: [CGFloat] = (0..<14).map { _ in rand.range(0.55, 1.0) }

    func withTile(_ frame: Int, _ body: (CGPoint) -> Void) {
        let row = frame / 8, col = frame % 8
        ctx.saveGState()
        ctx.clip(to: CGRect(x: col * tile, y: sheet - (row + 1) * tile, width: tile, height: tile))
        body(CGPoint(x: CGFloat(col * tile + tile / 2), y: CGFloat(sheet - row * tile - tile / 2)))
        ctx.restoreGState()
    }

    // Born: an energy ring blooming outward, note core fading in.
    for k in 0..<8 {
        withTile(k) { c in
            let t = CGFloat(k + 1) / 8
            let radius = 18 + t * 86
            let ring = CGPath(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius,
                                                width: radius * 2, height: radius * 2), transform: nil)
            glowStroke(ctx, ring, stroke: palette.core, glow: palette.glow,
                       width: 10 - t * 6, blur: 18 + t * 10)
            let inner = radius * 0.62
            let ring2 = CGPath(ellipseIn: CGRect(x: c.x - inner, y: c.y - inner,
                                                 width: inner * 2, height: inner * 2), transform: nil)
            glowStroke(ctx, ring2, stroke: palette.glow, glow: palette.glow,
                       width: 3, blur: 10, passes: 1)
            radialGlow(ctx, center: c, radius: radius,
                       colors: [rgba(1, 1, 1, 0.55 * t), palette.glow.copy(alpha: 0.25 * t) ?? palette.glow, rgba(0, 0, 0, 0)],
                       locations: [0, 0.35, 1])
            // Spinning charge motes on the ring.
            for m in 0..<6 {
                let a = CGFloat(m) * .pi / 3 + t * 2.4
                let mote = CGPoint(x: c.x + cos(a) * radius, y: c.y + sin(a) * radius)
                let dot = CGPath(ellipseIn: CGRect(x: mote.x - 5, y: mote.y - 5, width: 10, height: 10), transform: nil)
                glowFill(ctx, dot, fill: palette.core, glow: palette.glow, blur: 8, passes: 1)
            }
        }
    }

    // Alive: the note tumbling in fake-3D (x squash) with a pulsing halo.
    let glyph = notePath(variant: variant)
    for k in 0..<40 {
        withTile(8 + k) { c in
            let phase = CGFloat(k) / 40
            let yaw = phase * 2 * .pi
            var sx = cos(yaw)
            if abs(sx) < 0.16 { sx = sx < 0 ? -0.16 : 0.16 }
            let tiltAngle = sin(yaw * 2) * 0.20
            let pulse = 0.8 + 0.2 * sin(yaw * 2)
            radialGlow(ctx, center: c, radius: 110,
                       colors: [palette.glow.copy(alpha: 0.30 * pulse) ?? palette.glow, rgba(0, 0, 0, 0)],
                       locations: [0, 1])
            var transform = CGAffineTransform(translationX: c.x, y: c.y)
                .rotated(by: tiltAngle)
                .scaledBy(x: sx * 1.35, y: 1.35)
                .translatedBy(x: -50, y: -70)
            if let placed = glyph.copy(using: &transform) {
                glowFill(ctx, placed, fill: palette.core, glow: palette.glow, blur: 22 * pulse, passes: 2)
                // Hot inner highlight.
                var highlightTransform = CGAffineTransform(translationX: c.x, y: c.y)
                    .rotated(by: tiltAngle)
                    .scaledBy(x: sx * 1.35 * 0.72, y: 1.35 * 0.72)
                    .translatedBy(x: -50, y: -70)
                if let hot = glyph.copy(using: &highlightTransform) {
                    ctx.addPath(hot)
                    ctx.setFillColor(rgba(1, 1, 1, 0.55))
                    ctx.fillPath()
                }
            }
        }
    }

    // Explode: white flash, shockwave ring, glowing shards flying out.
    for k in 0..<16 {
        withTile(48 + k) { c in
            let t = CGFloat(k) / 15
            let fade = pow(1 - t, 1.4)
            radialGlow(ctx, center: c, radius: 40 + 60 * t,
                       colors: [rgba(1, 1, 1, fade), palette.core.copy(alpha: fade * 0.7) ?? palette.core, rgba(0, 0, 0, 0)],
                       locations: [0, 0.3, 1])
            let radius = 22 + 96 * t
            let ring = CGPath(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius,
                                                width: radius * 2, height: radius * 2), transform: nil)
            glowStroke(ctx, ring, stroke: palette.core.copy(alpha: fade) ?? palette.core,
                       glow: palette.glow, width: 2 + 7 * (1 - t), blur: 14, passes: 1)
            for s in 0..<14 {
                let distance = (16 + 100 * t) * shardSpeeds[s]
                let a = shardAngles[s]
                let p = CGPoint(x: c.x + cos(a) * distance, y: c.y + sin(a) * distance)
                let size = (4 + 12 * (1 - t)) * shardSpeeds[s]
                let shard = CGMutablePath()
                shard.move(to: CGPoint(x: p.x + cos(a) * size * 1.8, y: p.y + sin(a) * size * 1.8))
                shard.addLine(to: CGPoint(x: p.x + cos(a + 2.4) * size, y: p.y + sin(a + 2.4) * size))
                shard.addLine(to: CGPoint(x: p.x + cos(a - 2.4) * size, y: p.y + sin(a - 2.4) * size))
                shard.closeSubpath()
                let color = s % 3 == 0 ? rgba(1, 1, 1, fade) : (palette.core.copy(alpha: fade) ?? palette.core)
                glowFill(ctx, shard, fill: color, glow: palette.glow, blur: 8, passes: 1)
            }
        }
    }
    save(ctx, "\(assetsDir)/\(file)")
}

// MARK: - Bonus pickup sheets (1024, 8x8, 64 spinning frames)

enum BonusSymbol {
    case text(String)
    case ship
    case rings
}

func generateBonusSheet(file: String, symbol: BonusSymbol, palette: Palette, seed: UInt64) {
    let sheet = 1024, tile = 128
    let ctx = makeContext(sheet, sheet)
    var rand = Rand(seed)
    let sparkleOffset = rand.range(0, 2 * .pi)

    for frame in 0..<64 {
        let row = frame / 8, col = frame % 8
        ctx.saveGState()
        ctx.clip(to: CGRect(x: col * tile, y: sheet - (row + 1) * tile, width: tile, height: tile))
        let c = CGPoint(x: CGFloat(col * tile + tile / 2), y: CGFloat(sheet - row * tile - tile / 2))
        let phase = CGFloat(frame) / 64
        var sx = cos(phase * 2 * .pi)
        if abs(sx) < 0.18 { sx = sx < 0 ? -0.18 : 0.18 }
        let pulse = 0.8 + 0.2 * sin(phase * 4 * .pi)

        radialGlow(ctx, center: c, radius: 60,
                   colors: [palette.glow.copy(alpha: 0.35 * pulse) ?? palette.glow, rgba(0, 0, 0, 0)],
                   locations: [0, 1])

        // Spinning hex "coin".
        let hex = hexPath(center: c, radius: 46, xScale: abs(sx))
        ctx.addPath(hex)
        ctx.setFillColor(rgba(0.05, 0.07, 0.15, 0.9))
        ctx.fillPath()
        glowStroke(ctx, hex, stroke: palette.core, glow: palette.glow, width: 4.5, blur: 12 * pulse)
        let hexInner = hexPath(center: c, radius: 37, xScale: abs(sx))
        glowStroke(ctx, hexInner, stroke: palette.glow.copy(alpha: 0.5) ?? palette.glow,
                   glow: palette.glow, width: 1.5, blur: 4, passes: 1)

        // The symbol stays upright and readable while the coin spins.
        switch symbol {
        case .text(let string):
            let font = roundedFont(string.count > 2 ? 34 : 44, .black)
            drawText(ctx, string, font: font, color: rgba(1, 1, 1, 1),
                     center: c, glow: (palette.glow, 10))
        case .ship:
            var transform = CGAffineTransform(translationX: c.x - 29, y: c.y - 29).scaledBy(x: 0.58, y: 0.58)
            if let glyph = shipGlyphPath().copy(using: &transform) {
                glowFill(ctx, glyph, fill: rgba(1, 1, 1, 1), glow: palette.glow, blur: 9, passes: 2)
            }
        case .rings:
            for (i, hue) in [CGFloat(0.5), 0.85, 0.09].enumerated() {
                let a = CGFloat(i) * 2 * .pi / 3 + .pi / 2
                let ringCenter = CGPoint(x: c.x + cos(a) * 11, y: c.y + sin(a) * 11)
                let ring = CGPath(ellipseIn: CGRect(x: ringCenter.x - 14, y: ringCenter.y - 14,
                                                    width: 28, height: 28), transform: nil)
                glowStroke(ctx, ring, stroke: hsba(hue, 0.7, 1, 1), glow: hsba(hue, 0.9, 1, 0.9),
                           width: 4, blur: 7, passes: 1)
            }
        }

        // Orbiting sparkle.
        let sparkleAngle = phase * 2 * .pi + sparkleOffset
        let sparkleCenter = CGPoint(x: c.x + cos(sparkleAngle) * 50, y: c.y + sin(sparkleAngle) * 50)
        glowFill(ctx, sparklePath(center: sparkleCenter, radius: 8 * pulse),
                 fill: rgba(1, 1, 1, 0.9), glow: palette.glow, blur: 6, passes: 1)
        ctx.restoreGState()
    }
    save(ctx, "\(assetsDir)/\(file)")
}

// MARK: - Simple textures

func generateFlare() {
    let size = 512
    let ctx = makeContext(size, size)
    let c = CGPoint(x: 256, y: 256)
    radialGlow(ctx, center: c, radius: 250,
               colors: [rgba(1, 1, 1, 1), rgba(0.65, 0.85, 1, 0.6), rgba(0.4, 0.6, 1, 0.18), rgba(0, 0, 0, 0)],
               locations: [0, 0.12, 0.4, 1])
    // Star streaks.
    for i in 0..<4 {
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: CGFloat(i) * .pi / 4)
        ctx.scaleBy(x: i % 2 == 0 ? 1 : 0.45, y: 1)
        radialGlow(ctx, center: .zero, radius: 240,
                   colors: [rgba(1, 1, 1, 0.5), rgba(0, 0, 0, 0)], locations: [0, 1])
        ctx.restoreGState()
    }
    save(ctx, "\(assetsDir)/flare.png")
}

func generateJoystick() {
    let size = 512
    let ctx = makeContext(size, size)
    let c = CGPoint(x: 256, y: 256)
    let cyan = rgba(0.3, 0.9, 1, 0.95)
    let glow = rgba(0, 0.75, 1, 0.8)

    ctx.addPath(CGPath(ellipseIn: CGRect(x: 16, y: 16, width: 480, height: 480), transform: nil))
    ctx.setFillColor(rgba(0.03, 0.05, 0.12, 0.45))
    ctx.fillPath()
    let outer = CGPath(ellipseIn: CGRect(x: 22, y: 22, width: 468, height: 468), transform: nil)
    glowStroke(ctx, outer, stroke: cyan, glow: glow, width: 6, blur: 14)

    // Tick marks.
    for i in 0..<24 {
        let a = CGFloat(i) * .pi / 12
        let isMajor = i % 6 == 0
        let r1: CGFloat = isMajor ? 200 : 214
        let tick = CGMutablePath()
        tick.move(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
        tick.addLine(to: CGPoint(x: c.x + cos(a) * 228, y: c.y + sin(a) * 228))
        glowStroke(ctx, tick, stroke: rgba(1, 1, 1, isMajor ? 0.8 : 0.35), glow: glow,
                   width: isMajor ? 7 : 3, blur: 4, passes: 1)
    }

    // Thumb pad.
    radialGlow(ctx, center: c, radius: 130,
               colors: [rgba(0.2, 0.5, 0.8, 0.5), rgba(0.05, 0.1, 0.25, 0.55), rgba(0, 0, 0, 0)],
               locations: [0, 0.75, 1])
    let inner = CGPath(ellipseIn: CGRect(x: c.x - 108, y: c.y - 108, width: 216, height: 216), transform: nil)
    glowStroke(ctx, inner, stroke: rgba(1, 1, 1, 0.55), glow: glow, width: 3, blur: 8, passes: 1)

    // Directional chevrons.
    for i in 0..<4 {
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: CGFloat(i) * .pi / 2)
        let chevron = CGMutablePath()
        chevron.move(to: CGPoint(x: -26, y: 138))
        chevron.addLine(to: CGPoint(x: 0, y: 168))
        chevron.addLine(to: CGPoint(x: 26, y: 138))
        glowStroke(ctx, chevron, stroke: rgba(1, 1, 1, 0.85), glow: glow, width: 10, blur: 6, passes: 1)
        ctx.restoreGState()
    }
    save(ctx, "\(assetsDir)/joystick.png")
}

func generateShipLifeIcon() {
    let size = 128
    let ctx = makeContext(size, size)
    var transform = CGAffineTransform(translationX: 14, y: 14).scaledBy(x: 1, y: 1)
    guard let glyph = shipGlyphPath().copy(using: &transform) else { return }
    glowFill(ctx, glyph, fill: rgba(0.85, 0.97, 1, 1), glow: rgba(0, 0.8, 1, 0.9), blur: 10, passes: 2)
    save(ctx, "\(assetsDir)/ship_life.png")
}

func generateFloorGrid() {
    let size = 1024
    let ctx = makeContext(size, size)
    ctx.setFillColor(rgba(0.015, 0.02, 0.06, 1))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    // Minor grid.
    for i in stride(from: 0, through: size, by: 64) {
        let alpha: CGFloat = i % 256 == 0 ? 0 : 0.16
        guard alpha > 0 else { continue }
        ctx.setStrokeColor(rgba(0.1, 0.7, 0.9, alpha))
        ctx.setLineWidth(2)
        ctx.stroke(CGRect(x: CGFloat(i), y: -2, width: 0, height: CGFloat(size) + 4))
        ctx.stroke(CGRect(x: -2, y: CGFloat(i), width: CGFloat(size) + 4, height: 0))
    }
    // Major glowing lines.
    for i in stride(from: 0, through: size, by: 256) {
        for (line, isVertical) in [(CGFloat(i), true), (CGFloat(i), false)] {
            let path = CGMutablePath()
            if isVertical {
                path.move(to: CGPoint(x: line, y: 0)); path.addLine(to: CGPoint(x: line, y: CGFloat(size)))
            } else {
                path.move(to: CGPoint(x: 0, y: line)); path.addLine(to: CGPoint(x: CGFloat(size), y: line))
            }
            glowStroke(ctx, path, stroke: rgba(0.15, 0.85, 1, 0.55), glow: rgba(0, 0.7, 1, 0.5),
                       width: 3, blur: 8, passes: 1)
        }
    }
    save(ctx, "\(assetsDir)/floor_grid.png")
}

func generateWallSkyline() {
    let w = 2048, h = 512
    let ctx = makeContext(w, h)
    // Night sky gradient with a synth horizon glow at the base.
    linearGradient(ctx, rect: CGRect(x: 0, y: 0, width: w, height: h),
                   colors: [rgba(0.16, 0.04, 0.24, 1), rgba(0.07, 0.03, 0.16, 1), rgba(0.01, 0.01, 0.05, 1)],
                   locations: [0, 0.35, 1])
    linearGradient(ctx, rect: CGRect(x: 0, y: 0, width: w, height: 170),
                   colors: [rgba(1, 0.25, 0.75, 0.4), rgba(0.6, 0.2, 0.9, 0.15), rgba(0, 0, 0, 0)],
                   locations: [0, 0.5, 1])

    var rand = Rand(77)
    // Stars.
    for _ in 0..<420 {
        let x = rand.range(0, CGFloat(w))
        let y = rand.range(120, CGFloat(h))
        let r = rand.range(0.6, 2.2)
        let a = rand.range(0.25, 0.95)
        ctx.setFillColor(rand.next() < 0.85 ? rgba(1, 1, 1, a) : rgba(0.6, 0.85, 1, a))
        ctx.fillEllipse(in: CGRect(x: x, y: y, width: r * 2, height: r * 2))
    }
    // A few bright glow stars.
    for _ in 0..<14 {
        let p = CGPoint(x: rand.range(0, CGFloat(w)), y: rand.range(200, CGFloat(h) - 20))
        radialGlow(ctx, center: p, radius: rand.range(8, 18),
                   colors: [rgba(1, 1, 1, 0.9), rgba(0.6, 0.85, 1, 0.3), rgba(0, 0, 0, 0)],
                   locations: [0, 0.3, 1])
    }

    // Distant city silhouette with lit windows.
    var x: CGFloat = 0
    while x < CGFloat(w) {
        let width = rand.range(38, 110)
        let height = rand.range(36, 128)
        ctx.setFillColor(rgba(0.008, 0.01, 0.03, 1))
        ctx.fill(CGRect(x: x, y: 0, width: width, height: height))
        // Antenna on some towers.
        if rand.next() < 0.25 {
            ctx.fill(CGRect(x: x + width / 2 - 1.5, y: height, width: 3, height: rand.range(10, 26)))
        }
        // Windows.
        var wy: CGFloat = 8
        while wy < height - 10 {
            var wx = x + 6
            while wx < x + width - 8 {
                if rand.next() < 0.16 {
                    let warm = rand.next() < 0.5
                    ctx.setFillColor(warm ? rgba(1, 0.75, 0.35, 0.85) : rgba(0.4, 0.9, 1, 0.85))
                    ctx.fill(CGRect(x: wx, y: wy, width: 3.4, height: 4.6))
                }
                wx += 9
            }
            wy += 12
        }
        x += width + rand.range(2, 16)
    }
    save(ctx, "\(assetsDir)/wall_skyline.png")
}

func generateCeilingStars() {
    let size = 1024
    let ctx = makeContext(size, size)
    ctx.setFillColor(rgba(0.008, 0.008, 0.035, 1))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    var rand = Rand(99)
    // Nebula wisps.
    for _ in 0..<7 {
        let p = CGPoint(x: rand.range(0, 1024), y: rand.range(0, 1024))
        let hue = rand.next() < 0.5 ? CGFloat(0.55) : 0.8
        radialGlow(ctx, center: p, radius: rand.range(180, 420),
                   colors: [hsba(hue, 0.8, 0.5, 0.10), rgba(0, 0, 0, 0)], locations: [0, 1])
    }
    // Milky-way band.
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 512)
    ctx.rotate(by: 0.6)
    ctx.scaleBy(x: 1, y: 0.28)
    radialGlow(ctx, center: .zero, radius: 700,
               colors: [rgba(0.7, 0.75, 1, 0.12), rgba(0, 0, 0, 0)], locations: [0, 1])
    ctx.restoreGState()
    for _ in 0..<800 {
        let x = rand.range(0, 1024), y = rand.range(0, 1024)
        let r = rand.range(0.5, 1.9)
        ctx.setFillColor(rgba(1, 1, 1, rand.range(0.2, 1)))
        ctx.fillEllipse(in: CGRect(x: x, y: y, width: r * 2, height: r * 2))
    }
    for _ in 0..<10 {
        let p = CGPoint(x: rand.range(0, 1024), y: rand.range(0, 1024))
        radialGlow(ctx, center: p, radius: rand.range(6, 14),
                   colors: [rgba(1, 1, 1, 1), rgba(0, 0, 0, 0)], locations: [0, 1])
    }
    save(ctx, "\(assetsDir)/ceiling_stars.png")
}

func generateBarGradient() {
    let w = 64, h = 256
    let ctx = makeContext(w, h)
    linearGradient(ctx, rect: CGRect(x: 0, y: 0, width: w, height: h),
                   colors: [rgba(1, 1, 1, 0.30), rgba(1, 1, 1, 0.75), rgba(1, 1, 1, 1)],
                   locations: [0, 0.7, 1])
    // Hot cap at the top.
    ctx.setFillColor(rgba(1, 1, 1, 1))
    ctx.fill(CGRect(x: 0, y: h - 10, width: w, height: 10))
    // Bright edge rails.
    ctx.setFillColor(rgba(1, 1, 1, 0.9))
    ctx.fill(CGRect(x: 0, y: 0, width: 4, height: h))
    ctx.fill(CGRect(x: w - 4, y: 0, width: 4, height: h))
    save(ctx, "\(assetsDir)/bar_gradient.png")
}

// MARK: - Logo / loading / app icon

func drawEqualizer(_ ctx: CGContext, rect: CGRect, barCount: Int, alpha: CGFloat, seed: UInt64) {
    var rand = Rand(seed)
    let step = rect.width / CGFloat(barCount)
    for i in 0..<barCount {
        let t = CGFloat(i) / CGFloat(barCount - 1)
        let height = rect.height * (0.25 + 0.75 * abs(sin(CGFloat(i) * 0.9 + 1)) * rand.range(0.55, 1))
        let barRect = CGRect(x: rect.minX + CGFloat(i) * step + step * 0.18,
                             y: rect.minY, width: step * 0.64, height: height)
        let hue = 0.5 + t * 0.37   // cyan -> magenta
        let path = CGPath(roundedRect: barRect, cornerWidth: step * 0.3, cornerHeight: step * 0.3, transform: nil)
        glowFill(ctx, path, fill: hsba(hue, 0.85, 1, alpha), glow: hsba(hue, 1, 1, alpha * 0.9),
                 blur: step * 0.5, passes: 1)
    }
}

func generateLogo() {
    let w = 1536, h = 512
    let ctx = makeContext(w, h)

    drawEqualizer(ctx, rect: CGRect(x: 120, y: 30, width: CGFloat(w) - 240, height: 150),
                  barCount: 26, alpha: 0.5, seed: 5)

    let cyanGlow = rgba(0, 0.8, 1, 0.95)
    let magentaGlow = rgba(1, 0.2, 0.85, 0.95)
    let big = roundedFont(215, .black)
    let vsFont = roundedFont(110, .heavy)

    let meLine = textLine("ME", big, rgba(1, 1, 1, 1), tracking: 2)
    let vsLine = textLine("VS", vsFont, rgba(1, 1, 1, 1), tracking: 2)
    let musicLetters = Array("MUSIC")
    let letterLines = musicLetters.enumerated().map { (i, ch) -> CTLine in
        let hue = 0.5 + CGFloat(i) / CGFloat(musicLetters.count - 1) * 0.37
        return textLine(String(ch), big, hsba(hue, 0.75, 1, 1))
    }
    let gap: CGFloat = 46
    let musicWidth = letterLines.reduce(CGFloat(0)) { $0 + lineWidth($1) } + CGFloat(musicLetters.count - 1) * 6
    let total = lineWidth(meLine) + gap + lineWidth(vsLine) + gap + musicWidth
    var cursor = (CGFloat(w) - total) / 2
    let baseline: CGFloat = 210
    let skew: CGFloat = 0.16

    func draw(_ line: CTLine, _ glowColor: CGColor, _ blur: CGFloat, dy: CGFloat = 0) {
        ctx.saveGState()
        ctx.translateBy(x: cursor, y: baseline + dy)
        ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: skew, d: 1, tx: 0, ty: 0))
        ctx.setShadow(offset: .zero, blur: blur, color: glowColor)
        for _ in 0..<3 {
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
        cursor += lineWidth(line)
    }

    draw(meLine, cyanGlow, 26)
    cursor += gap
    draw(vsLine, rgba(1, 0.65, 0.1, 0.95), 20, dy: 40)
    cursor += gap
    for (i, line) in letterLines.enumerated() {
        let hue = 0.5 + CGFloat(i) / CGFloat(musicLetters.count - 1) * 0.37
        draw(line, hsba(hue, 1, 1, 0.95), 26)
        cursor += 6
    }

    // Speed swoosh under the wordmark.
    let swoosh = CGMutablePath()
    swoosh.move(to: CGPoint(x: 190, y: 152))
    swoosh.addLine(to: CGPoint(x: CGFloat(w) - 150, y: 168))
    glowStroke(ctx, swoosh, stroke: rgba(1, 1, 1, 0.7), glow: magentaGlow, width: 7, blur: 14)
    save(ctx, "\(assetsDir)/logo.png")
}

func generateLoading() {
    let w = 1024, h = 256
    let ctx = makeContext(w, h)
    drawText(ctx, "LOADING...", font: roundedFont(120, .black), color: rgba(0.9, 0.98, 1, 1),
             center: CGPoint(x: 512, y: 128), glow: (rgba(0, 0.8, 1, 0.95), 24), skew: 0.14, tracking: 10)
    save(ctx, "\(assetsDir)/loading.png")
}

func generateAppIcon() {
    let size = 1024
    let ctx = makeContext(size, size)
    linearGradient(ctx, rect: CGRect(x: 0, y: 0, width: size, height: size),
                   colors: [rgba(0.10, 0.05, 0.28, 1), rgba(0.03, 0.02, 0.10, 1)],
                   locations: [1, 0])
    var rand = Rand(31)
    for _ in 0..<90 {
        let x = rand.range(0, 1024), y = rand.range(380, 1024)
        ctx.setFillColor(rgba(1, 1, 1, rand.range(0.2, 0.8)))
        let r = rand.range(1.2, 3.2)
        ctx.fillEllipse(in: CGRect(x: x, y: y, width: r * 2, height: r * 2))
    }
    // Neon equalizer.
    let heights: [CGFloat] = [240, 420, 330, 560, 470, 360, 260]
    let barWidth: CGFloat = 92, gapWidth: CGFloat = 34
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gapWidth
    var x = (CGFloat(size) - totalWidth) / 2
    for (i, height) in heights.enumerated() {
        let hue = 0.5 + CGFloat(i) / CGFloat(heights.count - 1) * 0.37
        let rect = CGRect(x: x, y: 128, width: barWidth, height: height)
        let path = CGPath(roundedRect: rect, cornerWidth: 30, cornerHeight: 30, transform: nil)
        glowFill(ctx, path, fill: hsba(hue, 0.8, 1, 1), glow: hsba(hue, 1, 1, 0.9), blur: 40, passes: 2)
        x += barWidth + gapWidth
    }
    // The ship sweeping over the bars.
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 700)
    ctx.rotate(by: 0.5)
    ctx.scaleBy(x: 3.4, y: 3.4)
    ctx.translateBy(x: -50, y: -50)
    let glyph = shipGlyphPath()
    glowFill(ctx, glyph, fill: rgba(0.95, 0.99, 1, 1), glow: rgba(0.2, 0.85, 1, 1), blur: 14, passes: 2)
    ctx.restoreGState()
    // Motion streaks behind the ship.
    for i in 0..<3 {
        let streak = CGMutablePath()
        let y = 620 + CGFloat(i) * 55
        streak.move(to: CGPoint(x: 120, y: y))
        streak.addLine(to: CGPoint(x: 430 - CGFloat(i) * 40, y: y + 130))
        glowStroke(ctx, streak, stroke: rgba(0.5, 0.9, 1, 0.5), glow: rgba(0, 0.8, 1, 0.5),
                   width: 12 - CGFloat(i) * 3, blur: 12, passes: 1)
    }
    save(ctx, iconPath)
}

// MARK: - Run

let cyan = Palette(core: rgba(0.62, 0.95, 1, 1), glow: rgba(0, 0.8, 1, 0.95), deep: rgba(0, 0.25, 0.4, 1))
let magenta = Palette(core: rgba(1, 0.62, 0.95, 1), glow: rgba(1, 0.15, 0.85, 0.95), deep: rgba(0.3, 0, 0.25, 1))
let amber = Palette(core: rgba(1, 0.88, 0.6, 1), glow: rgba(1, 0.62, 0.1, 0.95), deep: rgba(0.35, 0.18, 0, 1))
let lime = Palette(core: rgba(0.8, 1, 0.65, 1), glow: rgba(0.45, 1, 0.15, 0.95), deep: rgba(0.1, 0.3, 0, 1))
let white = Palette(core: rgba(1, 1, 1, 1), glow: rgba(0.4, 0.85, 1, 0.95), deep: rgba(0.1, 0.2, 0.3, 1))

generateChordSheet(file: "chord_cyan.png", variant: 0, palette: cyan, seed: 11)
generateChordSheet(file: "chord_magenta.png", variant: 1, palette: magenta, seed: 22)
generateChordSheet(file: "chord_amber.png", variant: 2, palette: amber, seed: 33)

generateBonusSheet(file: "bonus_rings.png", symbol: .rings, palette: white, seed: 1)
generateBonusSheet(file: "bonus_1k.png", symbol: .text("1K"), palette: lime, seed: 2)
generateBonusSheet(file: "bonus_5k.png", symbol: .text("5K"), palette: cyan, seed: 3)
generateBonusSheet(file: "bonus_40k.png", symbol: .text("40K"), palette: magenta, seed: 4)
generateBonusSheet(file: "bonus_ship.png", symbol: .ship, palette: white, seed: 5)
generateBonusSheet(file: "bonus_25k.png", symbol: .text("25K"), palette: amber, seed: 6)

generateFlare()
generateJoystick()
generateShipLifeIcon()
generateFloorGrid()
generateWallSkyline()
generateCeilingStars()
generateBarGradient()
generateLogo()
generateLoading()
generateAppIcon()
print("done")
