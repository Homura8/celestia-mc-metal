// How much a region changes between consecutive frames (mean |green| difference, 0-255): swift motion.swift x y w h frames... (in order)
// (tools/qa/analyze: QA image measurements; docs/QA.md "Measuring images")
import AppKit
func load(_ p: String) -> (Int, [UInt8]) {
    let img = NSImage(contentsOfFile: p)!; var r = NSRect(origin: .zero, size: img.size)
    let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil)!
    let w = cg.width, h = cg.height; var px = [UInt8](repeating: 0, count: w*h*4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); return (w, px)
}
let a = Array(CommandLine.arguments.dropFirst()); let x0 = Int(a[0])!, y0 = Int(a[1])!, w0 = Int(a[2])!, h0 = Int(a[3])!
var prev: [UInt8]? = nil; var total = 0.0, n = 0.0; var width = 0
for f in a[4...] { let (w, p) = load(f); width = w
    if let q = prev { var d = 0.0; for y in y0..<(y0+h0) { for x in x0..<(x0+w0) { let i = (y*w+x)*4; d += abs(Double(p[i+1]) - Double(q[i+1])) } }; total += d / Double(w0*h0); n += 1 }
    prev = p }
print(String(format: "%.3f", total / n))
