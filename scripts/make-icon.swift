import AppKit

let output = CommandLine.arguments[1]
let artworkURL = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("packaging/Kiln.png")
guard let artwork = NSImage(contentsOf: artworkURL) else {
  fatalError("Couldn't read the Kiln icon artwork at \(artworkURL.path)")
}
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
  UUID().uuidString + ".iconset")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = size * scale
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    artwork.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    try bitmap.representation(using: .png, properties: [:])!.write(
      to: temporary.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
  }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", temporary.path, "-o", output]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
