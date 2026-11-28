// Crop a region to JPEG: swift crop.swift in.png out.jpg x y w h (pixels, top-left origin)
// (tools/qa/analyze: QA image measurements; docs/QA.md "Measuring images")
import AppKit
let a = CommandLine.arguments
let img = NSImage(contentsOfFile: a[1])!; var r = NSRect(origin: .zero, size: img.size)
let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil)!
let c = cg.cropping(to: CGRect(x: Int(a[3])!, y: Int(a[4])!, width: Int(a[5])!, height: Int(a[6])!))!
let rep = NSBitmapImageRep(cgImage: c)
try! rep.representation(using: .jpeg, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
