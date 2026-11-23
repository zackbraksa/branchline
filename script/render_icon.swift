import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let symbolSourceURL = output.appendingPathComponent("AppIcon.icon/Assets/MonoForeground.png")
let symbolSource = try Data(contentsOf: symbolSourceURL)
let foregroundBitmap = NSBitmapImageRep(data: symbolSource)!
let pixels = foregroundBitmap.bitmapData!
let edge = [167.0, 126.0, 201.0]
let body = [216.0, 185.0, 244.0]
let highlight = [255.0, 247.0, 255.0]
for y in 0..<foregroundBitmap.pixelsHigh {
    for x in 0..<foregroundBitmap.pixelsWide {
        let offset = y * foregroundBitmap.bytesPerRow + x * 4
        let luminance = (0.2126 * Double(pixels[offset]) + 0.7152 * Double(pixels[offset + 1]) + 0.0722 * Double(pixels[offset + 2])) / 255
        let lower = luminance < 0.608 ? edge : body
        let upper = luminance < 0.608 ? body : highlight
        let amount = luminance < 0.608 ? min(1, max(0, (luminance - 0.25) / 0.358)) : min(1, (luminance - 0.608) / 0.392)
        for channel in 0..<3 {
            pixels[offset + channel] = UInt8((lower[channel] + (upper[channel] - lower[channel]) * amount).rounded())
        }
    }
}
let foregroundPNG = foregroundBitmap.representation(using: .png, properties: [:])!
try foregroundPNG.write(to: output.appendingPathComponent("AppIcon.icon/Assets/Foreground.png"))
let foreground = NSImage(data: foregroundPNG)!

let master = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: master)
let canvas = NSRect(x: 0, y: 0, width: 1024, height: 1024)
let gradient = NSGradient(starting: NSColor(srgbRed: 160 / 255, green: 68 / 255, blue: 244 / 255, alpha: 1), ending: NSColor(srgbRed: 100 / 255, green: 36 / 255, blue: 199 / 255, alpha: 1))!
gradient.draw(from: NSPoint(x: 0, y: 1024), to: NSPoint(x: 1024, y: 0), options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
foreground.draw(in: canvas, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
let masterPNG = master.converting(to: .sRGB, renderingIntent: .default)!.representation(using: .png, properties: [:])!
try masterPNG.write(to: output.appendingPathComponent("PorcelainGlassIcon.png"))
try masterPNG.write(to: output.appendingPathComponent("AppIcon.icon/Assets/Default.png"))
let source = NSImage(data: masterPNG)!

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Branchline-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

func render(_ size: Int) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 184, yRadius: 184)
    tile.addClip()
    source.draw(in: tile.bounds,
                from: .zero,
                operation: .copy,
                fraction: 1,
                respectFlipped: false,
                hints: [.interpolation: NSImageInterpolation.high])

    NSGraphicsContext.restoreGraphicsState()
    let png = bitmap.representation(using: .png, properties: [:])!
    let names: [Int: [String]] = [
        16: ["icon_16x16.png"], 32: ["icon_16x16@2x.png", "icon_32x32.png"],
        64: ["icon_32x32@2x.png"], 128: ["icon_128x128.png"],
        256: ["icon_128x128@2x.png", "icon_256x256.png"],
        512: ["icon_256x256@2x.png", "icon_512x512.png"], 1024: ["icon_512x512@2x.png"]
    ]
    for name in names[size]! { try png.write(to: iconset.appendingPathComponent(name)) }
    if size == 1024 { try png.write(to: output.appendingPathComponent("AppIcon.png")) }
}

for size in [16, 32, 64, 128, 256, 512, 1024] { try render(size) }

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["--convert", "icns", "--output", output.appendingPathComponent("Branchline.icns").path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
