// Luminance percentiles (p1/p10/p50/p90/p99, 0-255) and mean saturation per image: swift stats.swift a.png b.png ...
// (tools/qa/analyze: QA image measurements; docs/QA.md "Measuring images")
import AppKit
for f in CommandLine.arguments.dropFirst() {
    let img = NSImage(contentsOfFile: f)!; var r = NSRect(origin: .zero, size: img.size)
    let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil)!
    let w = cg.width, h = cg.height; var px = [UInt8](repeating: 0, count: w*h*4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var lum = [Double](); var sat = 0.0; lum.reserveCapacity(w*h/16)
    for y in stride(from: 0, to: h, by: 4) { for x in stride(from: 0, to: w, by: 4) {
        let i = (y*w+x)*4; let R = Double(px[i]), G = Double(px[i+1]), B = Double(px[i+2])
        lum.append(0.2126*R+0.7152*G+0.0722*B); let mx = max(R,G,B), mn = min(R,G,B); sat += mx > 0 ? (mx-mn)/mx : 0 } }
    lum.sort(); let n = Double(lum.count)
    func p(_ q: Double) -> Int { Int(lum[min(lum.count-1, Int(q*n))]) }
    print(String(format: "%@  p1 %d  p10 %d  p50 %d  p90 %d  p99 %d  meanSat %.2f", (f as NSString).lastPathComponent, p(0.01), p(0.1), p(0.5), p(0.9), p(0.99), sat/n))
}
