import AppKit

// Renders the CPL app icon at a given pixel size. Usage: make-icon <size> <out.png>
// Source of the icon; the prebuilt CPL.icns (committed alongside) is what sync installs.

let args = CommandLine.arguments
guard args.count == 3, let size = Int(args[1]) else {
    FileHandle.standardError.write("Usage: make-icon <size> <out.png>\n".data(using: .utf8)!)
    exit(1)
}
let outPath = args[2]
let px = CGFloat(size)

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Rounded-square background with a vertical blue gradient.
let inset = px * 0.06
let rect = NSRect(x: inset, y: inset, width: px - 2 * inset, height: px - 2 * inset)
let radius = (px - 2 * inset) * 0.225
let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
let grad = NSGradient(starting: NSColor(calibratedRed: 0.22, green: 0.48, blue: 0.98, alpha: 1.0),
                      ending: NSColor(calibratedRed: 0.09, green: 0.18, blue: 0.52, alpha: 1.0))!
grad.draw(in: path, angle: -90)

// "CPL" wordmark, centered.
let text = "CPL" as NSString
let font = NSFont.systemFont(ofSize: px * 0.30, weight: .heavy)
let pstyle = NSMutableParagraphStyle()
pstyle.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: pstyle]
let tsize = text.size(withAttributes: attrs)
let tRect = NSRect(x: 0, y: (px - tsize.height) / 2, width: px, height: tsize.height)
text.draw(in: tRect, withAttributes: attrs)

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
do { try data.write(to: URL(fileURLWithPath: outPath)) } catch { exit(1) }
