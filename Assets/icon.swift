// Renders BreakTime AppIcon.png (1024) with CoreGraphics: teal gradient +
// white pause-in-ring glyph. Usage: swift icon.swift && ./make_icns.sh
import AppKit

let size = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 0, y: 0, width: size, height: size)

// Rounded-square background with vertical gradient.
let path = NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: 230, yRadius: 230)
let grad = NSGradient(starting: NSColor(red: 0.10, green: 0.42, blue: 0.36, alpha: 1.0),
                      ending: NSColor(red: 0.04, green: 0.18, blue: 0.16, alpha: 1.0))!
NSGraphicsContext.saveGraphicsState()
path.addClip()
grad.draw(in: rect, angle: 90)
NSGraphicsContext.restoreGraphicsState()

// White ring.
NSColor.white.setStroke()
let ring = NSBezierPath()
ring.appendOval(in: NSRect(x: 232, y: 232, width: 560, height: 560))
ring.lineWidth = 64
ring.stroke()

// Pause bars.
NSColor.white.setFill()
NSBezierPath.fill(NSRect(x: 422, y: 352, width: 72, height: 320))
NSBezierPath.fill(NSRect(x: 530, y: 352, width: 72, height: 320))

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "AppIcon.png"))
print("wrote AppIcon.png")
