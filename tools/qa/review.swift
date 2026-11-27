// A small contact sheet for reviewing QA exports.
import AppKit

let paths = Array(CommandLine.arguments.dropFirst(2))
let columns = min(paths.count, 3)
let rows = (paths.count + columns - 1) / columns
let tileWidth = 256
let tileHeight = 165
let sheet = NSImage(size: NSSize(width: columns * tileWidth, height: rows * tileHeight))
let paragraph = NSMutableParagraphStyle()
paragraph.lineBreakMode = .byTruncatingTail
let labelStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12),
    .foregroundColor: NSColor.white,
    .paragraphStyle: paragraph
]

sheet.lockFocus()
NSColor(white: 0.085, alpha: 1).setFill()
NSRect(origin: .zero, size: sheet.size).fill()
for (index, path) in paths.enumerated() {
    guard let image = NSImage(contentsOfFile: path) else {
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: path])
    }
    let x = CGFloat(index % columns * tileWidth)
    let y = CGFloat((rows - 1 - index / columns) * tileHeight)
    let scale = min(CGFloat(tileWidth - 8) / image.size.width, CGFloat(tileHeight - 22) / image.size.height)
    let width = image.size.width * scale
    let height = image.size.height * scale
    let rect = NSRect(x: x + (CGFloat(tileWidth) - width) / 2, y: y + 19, width: width, height: height)
    image.draw(in: rect)
    let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    name.draw(in: NSRect(x: x + 5, y: y + 2, width: CGFloat(tileWidth - 10), height: 15), withAttributes: labelStyle)
}
sheet.unlockFocus()

guard let tiff = sheet.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.86]) else {
    throw CocoaError(.fileWriteUnknown)
}
try jpeg.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
