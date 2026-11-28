// Labelled contact sheet, 3 columns: swift montage.swift out.jpg a.jpg b.jpg ... (inputs the same size; shrink with sips -Z first)
// (tools/qa/analyze: QA image measurements; docs/QA.md "Measuring images")
import AppKit
let args = CommandLine.arguments.dropFirst()
let out = args.first!; let files = Array(args.dropFirst())
let imgs = files.map { NSImage(contentsOfFile: $0)! }
let w = imgs[0].size.width, h = imgs[0].size.height
let cols = 3, rows = (imgs.count + cols - 1) / cols
let canvas = NSImage(size: NSSize(width: w * CGFloat(cols), height: (h + 18) * CGFloat(rows)))
canvas.lockFocus()
NSColor.black.setFill(); NSRect(origin: .zero, size: canvas.size).fill()
for (i, img) in imgs.enumerated() {
  let x = CGFloat(i % cols) * w, y = canvas.size.height - CGFloat(i / cols + 1) * (h + 18)
  img.draw(in: NSRect(x: x, y: y, width: w, height: h))
  (files[i] as NSString).lastPathComponent.draw(at: NSPoint(x: x + 4, y: y + h + 2), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12)])
}
canvas.unlockFocus()
let rep = NSBitmapImageRep(data: canvas.tiffRepresentation!)!
try! rep.representation(using: .jpeg, properties: [:])!.write(to: URL(fileURLWithPath: out))
