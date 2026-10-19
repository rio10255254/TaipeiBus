// A permanent, separate caption strip; native recording pixels are not altered.
import AppKit

let width = Double(CommandLine.arguments[1])!
let size = NSSize(width: width, height: 96)
let image = NSImage(size: size)
image.lockFocus()
NSColor.black.setFill()
NSRect(origin: .zero, size: size).fill()
let style = NSMutableParagraphStyle()
style.alignment = .center
let text = "iOS SIMULATOR · simulated location & test purchase · not physical-device footage" as NSString
text.draw(in: NSRect(x: 16, y: 32, width: width - 32, height: 40), withAttributes: [
    .font: NSFont.systemFont(ofSize: 24, weight: .medium),
    .foregroundColor: NSColor.white,
    .paragraphStyle: style
])
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
