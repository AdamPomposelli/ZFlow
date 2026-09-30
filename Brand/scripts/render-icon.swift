// Draws the ZFlow app icon from the mark, at any size.
//
// The geometry is the one in Brand/logo/zflow-mark.svg, on the same 32-unit
// grid, so the icon and the SVG cannot drift apart. Run it through
// `make icon` after changing the mark.
//
//   swift Brand/scripts/render-icon.swift <output.png> <size> [dev]

import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3, let size = Int(arguments[2]) else {
    FileHandle.standardError.write(Data("usage: render-icon.swift <output.png> <size> [dev]\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])
let isDev = arguments.count > 3 && arguments[3] == "dev"

let ink = CGColor(red: 0x17 / 255.0, green: 0x17 / 255.0, blue: 0x17 / 255.0, alpha: 1)
let purple = CGColor(red: 0x6D / 255.0, green: 0x28 / 255.0, blue: 0xD9 / 255.0, alpha: 1)
let paper = CGColor(red: 0xF7 / 255.0, green: 0xF6 / 255.0, blue: 0xF3 / 255.0, alpha: 1)
// The development build is the same mark on ink, so the two are never
// confused in a Dock that holds both.
let ground = isDev ? ink : paper
let marks = isDev ? paper : ink

guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)
context.setAllowsAntialiasing(true)

let side = CGFloat(size)
// Rounded square, macOS proportions.
let groundPath = CGPath(
    roundedRect: CGRect(x: 0, y: 0, width: side, height: side),
    cornerWidth: side * 0.2227,
    cornerHeight: side * 0.2227,
    transform: nil
)
context.setFillColor(ground)
context.addPath(groundPath)
context.fillPath()

// The mark on its 32-unit grid, inset so it breathes inside the tile.
let unit = side * 0.625 / 32
let originX = side * 0.1875
let originY = side * 0.1875
func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: originX + x * unit, y: originY + y * unit)
}

let stroke = CGMutablePath()
stroke.move(to: point(12, 8))
stroke.addLine(to: point(26, 8))
stroke.addCurve(to: point(6, 24), control1: point(22, 14), control2: point(10, 18))
stroke.addLine(to: point(20, 24))
context.setStrokeColor(purple)
context.setLineWidth(2.5 * unit)
context.setLineCap(.round)
context.setLineJoin(.round)
context.addPath(stroke)
context.strokePath()

context.setFillColor(marks)
for corner in [(CGFloat(4), CGFloat(4)), (CGFloat(20), CGFloat(20))] {
    let origin = point(corner.0, corner.1)
    let square = CGPath(
        roundedRect: CGRect(x: origin.x, y: origin.y, width: 8 * unit, height: 8 * unit),
        cornerWidth: 2 * unit,
        cornerHeight: 2 * unit,
        transform: nil
    )
    context.addPath(square)
    context.fillPath()
}

guard let image = context.makeImage() else { exit(1) }
let bitmap = NSBitmapImageRep(cgImage: image)
guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: output)
print("wrote \(output.lastPathComponent) at \(size)px")
