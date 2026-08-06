// Renders the app icon at 1024x1024 as a PNG.
//
//   swift Tools/render-icon.swift Resources/icon-1024.png
//
// Drawn with CoreGraphics rather than exported from a design tool so the icon
// lives in version control as code and stays crisp at every size. Motif:
// an upload arrow rising into a cloud — local iPhone backup going to OneDrive.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let side = 1024
let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/icon-1024.png"

guard let ctx = CGContext(
    data: nil,
    width: side,
    height: side,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write(Data("could not create bitmap context\n".utf8))
    exit(1)
}

// MARK: - Rounded-square plate
//
// macOS icons do not fill their canvas: the plate is inset so the grid stays
// consistent across apps. ~8% inset with a ~22% corner radius matches the
// current Big Sur onwards template closely enough.

let inset: CGFloat = 82
let plate = CGRect(x: inset, y: inset,
                   width: CGFloat(side) - inset * 2,
                   height: CGFloat(side) - inset * 2)
let corner = plate.width * 0.2237

let platePath = CGPath(roundedRect: plate,
                       cornerWidth: corner,
                       cornerHeight: corner,
                       transform: nil)

ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()

let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0.33, green: 0.66, blue: 1.00, alpha: 1.0),   // top
        CGColor(red: 0.05, green: 0.31, blue: 0.86, alpha: 1.0),   // bottom
    ] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: plate.maxY),
    end: CGPoint(x: 0, y: plate.minY),
    options: []
)
ctx.restoreGState()

// MARK: - Glyphs
//
// Cloud on top, upload arrow below it, both solid white. Kept as two separate
// silhouettes with a clear gap so the shape still reads at 16x16, where an
// arrow drawn *inside* the cloud would smear into one blob.

let midX: CGFloat = 512

// The lobes are positioned so the union is smooth without any trimming:
// both side lobes sit tangent to the base's bottom edge and are centred exactly
// on its top edge, so each lobe's widest point meets the base flush. Getting
// this wrong is what produces notched shoulders or a boxy underside.
let baseRect = CGRect(x: 290, y: 502, width: 444, height: 110)
let lobeR: CGFloat = 110
let lobeY = baseRect.maxY                       // 612 — lobe centres on the base's top edge

let cloud = CGMutablePath()
cloud.addPath(CGPath(roundedRect: baseRect, cornerWidth: 40, cornerHeight: 40, transform: nil))
cloud.addEllipse(in: CGRect(x: baseRect.minX, y: lobeY - lobeR,
                            width: lobeR * 2, height: lobeR * 2))
cloud.addEllipse(in: CGRect(x: baseRect.maxX - lobeR * 2, y: lobeY - lobeR,
                            width: lobeR * 2, height: lobeR * 2))
cloud.addEllipse(in: CGRect(x: midX - 145, y: 667 - 145, width: 290, height: 290))

let arrow = CGMutablePath()
let tipY: CGFloat = 462
let headBaseY: CGFloat = 334
let headHalf: CGFloat = 132
let shaftHalf: CGFloat = 45
let shaftBottomY: CGFloat = 188

arrow.move(to: CGPoint(x: midX, y: tipY))
arrow.addLine(to: CGPoint(x: midX + headHalf, y: headBaseY))
arrow.addLine(to: CGPoint(x: midX + shaftHalf, y: headBaseY))
arrow.addLine(to: CGPoint(x: midX + shaftHalf, y: shaftBottomY))
arrow.addLine(to: CGPoint(x: midX - shaftHalf, y: shaftBottomY))
arrow.addLine(to: CGPoint(x: midX - shaftHalf, y: headBaseY))
arrow.addLine(to: CGPoint(x: midX - headHalf, y: headBaseY))
arrow.closeSubpath()

// Soft shadow so the white lifts off the blue instead of looking pasted on.
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26,
              color: CGColor(red: 0, green: 0.12, blue: 0.38, alpha: 0.35))
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.addPath(cloud)
ctx.fillPath(using: .winding)   // overlapping circles union instead of cancelling
ctx.addPath(arrow)
ctx.fillPath()

// MARK: - Write PNG

guard let image = ctx.makeImage() else {
    FileHandle.standardError.write(Data("could not snapshot context\n".utf8))
    exit(1)
}

let url = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

guard let dest = CGImageDestinationCreateWithURL(
    url as CFURL, UTType.png.identifier as CFString, 1, nil
) else {
    FileHandle.standardError.write(Data("could not create \(outputPath)\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write(Data("could not write \(outputPath)\n".utf8))
    exit(1)
}

print("wrote \(outputPath) (\(side)x\(side))")
