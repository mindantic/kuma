import AppKit
import SwiftUI

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: render-icon.swift <icon.svg> <AppIcon.iconset>\n".data(using: .utf8)!)
    exit(1)
}
let svgURL = URL(fileURLWithPath: args[1])
let iconset = URL(fileURLWithPath: args[2])
let work = FileManager.default.temporaryDirectory.appendingPathComponent("kuma-icon-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

let source = try String(contentsOf: svgURL, encoding: .utf8)
let fullBleed = source.replacingOccurrences(of: #"<rect([^>]*?) rx="[^"]*""#, with: "<rect$1", options: .regularExpression)
let fullBleedURL = work.appendingPathComponent("full.svg")
try fullBleed.write(to: fullBleedURL, atomically: true, encoding: .utf8)

func rasterize(_ pixels: Int) throws -> CGImage {
    let out = work.appendingPathComponent("art-\(pixels).png")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["rsvg-convert", "-w", "\(pixels)", "-h", "\(pixels)", fullBleedURL.path, "-o", out.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let image = NSImage(contentsOf: out)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw NSError(domain: "render-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "rsvg-convert failed"])
    }
    return image
}

func render(_ size: Int) throws -> Data {
    let scale = CGFloat(size) / 1024
    let body = (824 * scale).rounded()
    let inset = ((CGFloat(size) - body) / 2).rounded()
    let rect = CGRect(x: inset, y: inset, width: body, height: body)
    let art = try rasterize(Int(body))
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    context.addPath(RoundedRectangle(cornerRadius: body * 0.225, style: .continuous).path(in: rect).cgPath)
    context.clip()
    context.draw(art, in: rect)
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
