// Renders the app icon at 1024x1024 as a PNG.
//
//   swift Tools/render-icon.swift [variant] [output.png]
//
//   variant: triangle (default) | arrow | inverted
//
// Drawn with CoreGraphics rather than exported from a design tool so the icon
// lives in version control as code and stays crisp at every size.
//
// Cloud construction — the important part. Every lobe is a circle whose centre
// sits at (x, bottom + radius), i.e. tangent to the bottom line from above. That
// single constraint guarantees a flat underside with no dips, and lobes meeting
// the base with matching horizontal tangents instead of visible seams. The
// filler rect's top corners are placed *inside* the end lobes, so the union has
// no notch anywhere. Lobe radii and positions are deliberately unequal to get
// an asymmetric, iCloud-like silhouette rather than a mirrored blob.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Arguments

let variant = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "triangle"
let outputPath = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : "Resources/icon-1024.png"

guard ["triangle", "arrow", "inverted"].contains(variant) else {
    FileHandle.standardError.write(Data("unknown variant '\(variant)'\n".utf8))
    exit(2)
}

// MARK: - Palette (flat, no gradients)

let blue = CGColor(red: 0.11, green: 0.55, blue: 0.95, alpha: 1)
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

let plateColor = variant == "inverted" ? white : blue
let cloudColor = variant == "inverted" ? blue : white
let glyphColor = plateColor          // same flat colour as the plate reads as a knockout

// MARK: - Geometry, in design space

let bottom: CGFloat = 322            // the flat underside
let flatL: CGFloat = 300             // flat bottom runs from here…
let flatR: CGFloat = 790             // …to here; lobes curve up beyond both ends

/// A lobe tangent to `bottom`: give it a centre x and a radius.
func lobe(_ cx: CGFloat, _ r: CGFloat) -> CGRect {
    CGRect(x: cx - r, y: bottom, width: r * 2, height: r * 2)
}

// Deliberately lopsided: one tall dome sitting left of centre, then a long
// shoulder cascading down and out to the right, and only a small stub on the
// left. Reading the crest heights left→right gives 522 · 752 · 622 · 486 — a
// staircase, not a mirror, which is what keeps it from looking like a blob.
let cloud = CGMutablePath()
cloud.addEllipse(in: lobe(flatL, 100))       // left end, small stub
cloud.addEllipse(in: lobe(455, 215))         // the dome, left of centre and tallest
cloud.addEllipse(in: lobe(640, 150))         // right shoulder, wide and lower
cloud.addEllipse(in: lobe(flatR, 82))        // right end, smallest — the long taper

// The rect's left and right edges sit exactly on the two END lobe centres, i.e.
// on their tangent points. That is what keeps the underside corners inside the
// circles; move an edge off a centre and a notch appears at the base. Its height
// stays below 2×the smaller end radius (164) so it never breaks the silhouette.
cloud.addRect(CGRect(x: flatL, y: bottom, width: flatR - flatL, height: 130))

// MARK: - Glyph, in the same design space

/// Triangle with rounded corners, drawn via tangent arcs.
func roundedTriangle(apex: CGPoint, left: CGPoint, right: CGPoint,
                     radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: (left.x + apex.x) / 2, y: (left.y + apex.y) / 2))
    p.addArc(tangent1End: apex, tangent2End: right, radius: radius)
    p.addArc(tangent1End: right, tangent2End: left, radius: radius)
    p.addArc(tangent1End: left, tangent2End: apex, radius: radius)
    p.closeSubpath()
    return p
}

let glyph = CGMutablePath()

// The glyph centres on the DOME (x≈490), not on the cloud's bounding box (x=536).
// With a lopsided silhouette those two differ, and the bounding-box centre reads
// as off to the right because the eye anchors on the tall lobe, not the taper.
switch variant {
case "arrow":
    glyph.addPath(roundedTriangle(
        apex: CGPoint(x: 490, y: 665),
        left: CGPoint(x: 375, y: 495),
        right: CGPoint(x: 605, y: 495),
        radius: 26))
    glyph.addPath(CGPath(
        roundedRect: CGRect(x: 448, y: 380, width: 84, height: 125),
        cornerWidth: 42, cornerHeight: 42, transform: nil))

default:   // triangle, inverted
    glyph.addPath(roundedTriangle(
        apex: CGPoint(x: 490, y: 650),
        left: CGPoint(x: 375, y: 450),
        right: CGPoint(x: 605, y: 450),
        radius: 30))
}

// MARK: - Canvas

let side = 1024
guard let ctx = CGContext(
    data: nil, width: side, height: side,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write(Data("could not create bitmap context\n".utf8))
    exit(1)
}

// Rounded plate. macOS icons do not fill their canvas — the plate is inset so
// the grid stays consistent across apps.
let inset: CGFloat = 82
let plate = CGRect(x: inset, y: inset,
                   width: CGFloat(side) - inset * 2,
                   height: CGFloat(side) - inset * 2)
let cornerR = plate.width * 0.2237

ctx.setFillColor(plateColor)
ctx.addPath(CGPath(roundedRect: plate, cornerWidth: cornerR, cornerHeight: cornerR,
                   transform: nil))
ctx.fillPath()

// Scale the cloud to fill the plate with gentle padding. The glyph gets the
// identical transform so it stays locked to the cloud.
let padding: CGFloat = 80
let target = plate.insetBy(dx: padding, dy: padding)
let box = cloud.boundingBoxOfPath
let scale = min(target.width / box.width, target.height / box.height)

var fit = CGAffineTransform.identity
    .translatedBy(x: target.midX - box.midX * scale, y: target.midY - box.midY * scale)
    .scaledBy(x: scale, y: scale)

guard let cloudFitted = cloud.copy(using: &fit),
      let glyphFitted = glyph.copy(using: &fit) else {
    FileHandle.standardError.write(Data("could not transform paths\n".utf8))
    exit(1)
}

// .winding unions the overlapping lobes; .evenOdd would cancel them into holes.
ctx.setFillColor(cloudColor)
ctx.addPath(cloudFitted)
ctx.fillPath(using: .winding)

// On a flat background, filling the glyph in the plate colour is pixel-identical
// to knocking it out — and far simpler than a transparency layer.
ctx.setFillColor(glyphColor)
ctx.addPath(glyphFitted)
ctx.fillPath(using: .winding)

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

print("wrote \(outputPath) — variant '\(variant)', \(side)x\(side)")
