// precompose.swift — renders AppIconLegacy.png / AppIconLegacy@2x.png, the
// pre-rendered home-screen icon iOS 5/6 shows for a CYDIA install.
//
//   swiftc -O precompose.swift -o /tmp/precompose
//   /tmp/precompose <icon-1024.png> <output dir>
//
// Run from anywhere; regenerate whenever the app icon changes. The source is
// oldpipe/oldpipe/Assets.xcassets/AppIcon.appiconset/icon-1024.png (opaque, square).
//
// Why this exists: add-legacy-icon.sh explains it. In short, iOS 5/6 draws the icon
// of an app in /Applications verbatim (no mask, no gloss, no shadow), choosing the
// file closest to 59x60 pt. So that file has to arrive already rounded and shadowed,
// the way Apple's own Safari and Cydia icons do.
//
// The layout copies those icons, measured pixel by pixel on iOS 5.1.1: a 59x60 pt
// canvas, the 57 pt icon at (1, 0.5) pt from the top-left, circular corners of
// radius 10 pt (the pre-iOS 7 mask — measured at 20 px on a 114 px icon), and a soft
// shadow under the bottom edge. Corners are transparent, which is correct HERE and
// only here — iOS 7+ never loads this file.

import Foundation
import CoreGraphics
import ImageIO

let args = CommandLine.arguments
guard args.count == 3,
      let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let icon = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write("usage: precompose <icon-1024.png> <output dir>\n".data(using: .utf8)!)
    exit(1)
}

func render(scale s: CGFloat, to path: String) {
    let w = Int(59 * s), h = Int(60 * s)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    // CoreGraphics' origin is bottom-left: the icon's top edge sits 0.5 pt below the canvas top.
    let rect = CGRect(x: 1 * s, y: CGFloat(h) - 0.5 * s - 57 * s, width: 57 * s, height: 57 * s)
    let shape = CGPath(roundedRect: rect, cornerWidth: 10 * s, cornerHeight: 10 * s, transform: nil)

    ctx.saveGState()                       // the shadow, cast by a filled copy of the shape
    ctx.setShadow(offset: CGSize(width: 0, height: -1 * s), blur: 2 * s,
                  color: CGColor(gray: 0, alpha: 0.55))
    ctx.addPath(shape); ctx.setFillColor(gray: 0, alpha: 1); ctx.fillPath()
    ctx.restoreGState()

    ctx.addPath(shape); ctx.clip()         // the icon itself, covering that copy exactly
    ctx.draw(icon, in: rect)

    let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                              "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dst) else { print("failed: \(path)"); exit(1) }
    print("\(path)  \(w)x\(h)")
}

render(scale: 1, to: args[2] + "/AppIconLegacy.png")
render(scale: 2, to: args[2] + "/AppIconLegacy@2x.png")
