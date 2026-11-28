// Animated GIF of a burst region: swift gif.swift out.gif <seconds per frame> x y w h frame0.png frame1.png ... (in order)
// (tools/qa/analyze: QA image measurements; docs/QA.md "Measuring images")
import AppKit
import ImageIO
import UniformTypeIdentifiers
let a = Array(CommandLine.arguments.dropFirst())
let out = URL(fileURLWithPath: a[0]); let delay = Double(a[1])!
let x = Int(a[2])!, y = Int(a[3])!, w = Int(a[4])!, h = Int(a[5])!
let files = Array(a[6...])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, files.count, nil)!
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for f in files {
    let img = NSImage(contentsOfFile: f)!; var r = NSRect(origin: .zero, size: img.size)
    let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil)!.cropping(to: CGRect(x: x, y: y, width: w, height: h))!
    CGImageDestinationAddImage(dest, cg, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
}
CGImageDestinationFinalize(dest)
