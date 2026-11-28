// Sharpness (Laplacian variance, central region) and mean difference to the first image: swift sharp.swift reference.png other.png ...
// (tools/qa/analyze: QA image measurements; docs/QA.md "Measuring images")
import AppKit
func load(_ p: String) -> (Int, Int, [UInt8]) {
    let img = NSImage(contentsOfFile: p)!; var r = NSRect(origin: .zero, size: img.size)
    let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil)!
    let w = cg.width, h = cg.height; var px = [UInt8](repeating: 0, count: w*h*4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); return (w, h, px)
}
let args = Array(CommandLine.arguments.dropFirst())
let (w, h, ref) = load(args[0])
func lum(_ p: [UInt8], _ x: Int, _ y: Int) -> Double { let i = (y*w+x)*4; return 0.2126*Double(p[i])+0.7152*Double(p[i+1])+0.0722*Double(p[i+2]) }
for f in args {
    let (_, _, p) = load(f); var lap = 0.0, diff = 0.0, n = 0.0
    for y in stride(from: h/4, to: h*3/4, by: 1) { for x in stride(from: w/8, to: w*7/8, by: 1) {
        let l = 4*lum(p,x,y) - lum(p,x-1,y) - lum(p,x+1,y) - lum(p,x,y-1) - lum(p,x,y+1)
        lap += l*l; diff += abs(lum(p,x,y) - lum(ref,x,y)); n += 1 } }
    print(String(format: "%@  sharpness %.1f  meanDiffToNative %.2f", (f as NSString).deletingLastPathComponent.components(separatedBy: "/").last!, lap/n, diff/n))
}
