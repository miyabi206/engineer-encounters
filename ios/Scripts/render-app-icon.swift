import CoreGraphics
import Foundation
import ImageIO

// Run on macOS; the output is an opaque sRGB canvas for the system icon mask.
let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [
        CGFloat((hex >> 16) & 255) / 255,
        CGFloat((hex >> 8) & 255) / 255,
        CGFloat(hex & 255) / 255, alpha
    ])!
}

enum RenderError: Error {
    case usage, context, gradient, image, destination, write
}

func figure(in context: CGContext, x: CGFloat, y: CGFloat, fill: CGColor) {
    // EncounterMark's proportions: 0.26 head, 0.06 gap, 0.56 x 0.28 body.
    context.setFillColor(fill)
    context.fillEllipse(in: CGRect(x: x - 0.13, y: y - 0.30, width: 0.26, height: 0.26))
    let center = CGPoint(x: x, y: y + 0.30)
    let outer: CGFloat = 0.28
    let inner = outer * 0.45
    let body = CGMutablePath()
    body.addArc(center: center, radius: outer, startAngle: .pi, endAngle: 0, clockwise: false)
    body.addLine(to: CGPoint(x: x + inner, y: center.y))
    body.addArc(center: center, radius: inner, startAngle: 0, endAngle: .pi, clockwise: true)
    body.closeSubpath()
    context.addPath(body)
    context.fillPath()
}

func render(to url: URL, background: UInt32, gradientEnd: UInt32? = nil,
            foreground: UInt32, backAlpha: CGFloat) throws {
    guard let context = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        throw RenderError.context
    }
    // Use the same downward y-axis as SwiftUI's EncounterMark.
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(color(background))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    if let gradientEnd {
        guard let gradient = CGGradient(colorsSpace: colorSpace,
                                        colors: [color(background), color(gradientEnd)] as CFArray,
                                        locations: [0, 1]) else { throw RenderError.gradient }
        context.drawLinearGradient(gradient, start: .zero,
                                   end: CGPoint(x: 0, y: size), options: [])
    }
    context.translateBy(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
    // The combined mark spans one unit horizontally: 18% margin on each side.
    let markWidth = CGFloat(size) * 0.64
    context.scaleBy(x: markWidth, y: markWidth)
    // Center the union of the figures, including the back figure's 0.04 offset.
    figure(in: context, x: 0.22, y: 0.02, fill: color(foreground, alpha: backAlpha))
    figure(in: context, x: -0.22, y: -0.02, fill: color(foreground))
    guard let image = context.makeImage() else { throw RenderError.image }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString,
                                                           1, nil) else {
        throw RenderError.destination
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw RenderError.write }
}

do {
    guard CommandLine.arguments.count == 2 else { throw RenderError.usage }
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try render(to: directory.appendingPathComponent("AppIcon.png"),
               background: 0x13777B, gradientEnd: 0x1E9A9A,
               foreground: 0xFFFFFF, backAlpha: 0.55)
    try render(to: directory.appendingPathComponent("AppIcon-Dark.png"),
               background: 0x0B2224, foreground: 0x5CC8C2, backAlpha: 0.45)
    // White at 60% over black produces a 60% grey back figure.
    try render(to: directory.appendingPathComponent("AppIcon-Tinted.png"),
               background: 0x000000, foreground: 0xFFFFFF, backAlpha: 0.60)
} catch {
    FileHandle.standardError.write(Data("Icon rendering failed: \(error)\nUsage: render-app-icon <output-directory>\n".utf8))
    exit(1)
}
