import AppKit
import Foundation
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let p = CGFloat(pixels)
        NSColor(calibratedRed: 0.075, green: 0.10, blue: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: p*0.04, y: p*0.04, width: p*0.92, height: p*0.92), xRadius: p*0.21, yRadius: p*0.21).fill()
        NSColor(calibratedRed: 0.66, green: 0.93, blue: 0.35, alpha: 1).setStroke()
        let wave = NSBezierPath()
        wave.lineWidth = p * 0.043; wave.lineCapStyle = .round; wave.lineJoinStyle = .round
        wave.move(to: NSPoint(x: p*0.20, y: p*0.50))
        for (x,y) in [(0.29,0.50),(0.36,0.70),(0.44,0.30),(0.52,0.62),(0.59,0.50),(0.79,0.50)] {
            wave.line(to: NSPoint(x: p*x,y: p*y))
        }
        wave.move(to: NSPoint(x:p*0.69,y:p*0.61));wave.line(to:NSPoint(x:p*0.80,y:p*0.50));wave.line(to:NSPoint(x:p*0.69,y:p*0.39))
        wave.stroke()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
// ICNS is a big-endian chunk container. Embedding PNG representations avoids
// iconutil's dependency on the system image conversion service at build time.
func bigEndian(_ value: UInt32) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
var chunks = Data()
for (type, name) in [
    ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"), ("ic13", "icon_128x128@2x.png"),
    ("ic14", "icon_256x256@2x.png")
] {
    let png = try Data(contentsOf: directory.appendingPathComponent(name))
    chunks.append(Data(type.utf8)); chunks.append(bigEndian(UInt32(png.count + 8))); chunks.append(png)
}
var icns = Data("icns".utf8)
icns.append(bigEndian(UInt32(chunks.count + 8))); icns.append(chunks)
try icns.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
