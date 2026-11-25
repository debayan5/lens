import CoreGraphics
import ImageIO
import Foundation

let S = 1024
let rgb = CGColorSpaceCreateDeviceRGB()
let c = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                  space: rgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
func grad(_ cols: [CGColor], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: rgb, colors: cols as CFArray, locations: locs)!
}
func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGRect { CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2) }
let m = CGFloat(S) / 2

// background
c.drawLinearGradient(grad([col(0.16, 0.16, 0.19), col(0.03, 0.03, 0.04)], [0, 1]),
                     start: CGPoint(x: m, y: CGFloat(S)), end: CGPoint(x: m, y: 0), options: [])
// outer metal ring
c.saveGState(); c.addEllipse(in: circle(m, m, 400)); c.clip()
c.drawLinearGradient(grad([col(0.85, 0.85, 0.9), col(0.25, 0.25, 0.3), col(0.6, 0.6, 0.66)], [0, 0.55, 1]),
                     start: CGPoint(x: m, y: m + 400), end: CGPoint(x: m, y: m - 400), options: [])
c.restoreGState()
c.setFillColor(col(0.02, 0.02, 0.03)); c.fillEllipse(in: circle(m, m, 368))
// glass
c.saveGState(); c.addEllipse(in: circle(m, m, 340)); c.clip()
c.drawRadialGradient(grad([col(0.10, 0.16, 0.45), col(0.03, 0.04, 0.16), col(0.0, 0.0, 0.03)], [0, 0.55, 1]),
                     startCenter: CGPoint(x: m - 60, y: m + 70), startRadius: 0,
                     endCenter: CGPoint(x: m, y: m), endRadius: 340, options: [.drawsAfterEndLocation])
c.restoreGState()
// iris rings
c.setStrokeColor(col(1, 1, 1, 0.14)); c.setLineWidth(6)
c.strokeEllipse(in: circle(m, m, 235)); c.strokeEllipse(in: circle(m, m, 150))
c.saveGState(); c.addEllipse(in: circle(m, m, 120)); c.clip()
c.drawRadialGradient(grad([col(0.45, 0.25, 0.85, 0.9), col(0.05, 0.02, 0.2, 1)], [0, 1]),
                     startCenter: CGPoint(x: m - 25, y: m + 30), startRadius: 0,
                     endCenter: CGPoint(x: m, y: m), endRadius: 120, options: [.drawsAfterEndLocation])
c.restoreGState()
// highlights
c.setFillColor(col(1, 1, 1, 0.32))
c.fillEllipse(in: CGRect(x: m - 210, y: m + 90, width: 130, height: 70))
c.setFillColor(col(0.4, 0.9, 1, 0.55)); c.fillEllipse(in: circle(m + 150, m - 150, 22))

let dir = "Assets.xcassets/AppIcon.appiconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let url = URL(fileURLWithPath: dir + "/icon.png") as CFURL
let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, c.makeImage()!, nil)
CGImageDestinationFinalize(dest)
try! #"{"images":[{"filename":"icon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}"#
    .write(toFile: dir + "/Contents.json", atomically: true, encoding: .utf8)
try! #"{"info":{"author":"xcode","version":1}}"#.write(toFile: "Assets.xcassets/Contents.json", atomically: true, encoding: .utf8)
