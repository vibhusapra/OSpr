import AppKit
import Foundation

// Code-native identity matching the app's purple waveform mark.
let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform(); transform.scale(by: factor); transform.concat()
        let body = NSBezierPath(roundedRect: NSRect(x: 44, y: 44, width: 936, height: 936), xRadius: 215, yRadius: 215)
        let gradient = NSGradient(starting: NSColor(red: 0.53, green: 0.38, blue: 0.94, alpha: 1),
                                  ending: NSColor(red: 0.28, green: 0.16, blue: 0.64, alpha: 1))!
        gradient.draw(in: body, angle: -80)
        NSColor.white.setFill()
        let heights: [CGFloat] = [130, 290, 450, 580, 390, 240, 115]
        for (index, height) in heights.enumerated() {
            NSBezierPath(roundedRect: NSRect(x: 226 + CGFloat(index) * 84, y: 512 - height / 2, width: 58, height: height), xRadius: 29, yRadius: 29).fill()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let data = bitmap.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: URL(fileURLWithPath: destination).appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
