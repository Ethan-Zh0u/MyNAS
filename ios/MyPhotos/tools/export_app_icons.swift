import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct IconOutput {
    let filename: String
    let pixels: Int
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: export_app_icons.swift <source-png> <output-directory>")
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

guard
    let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
    let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    fail("unable to read \(sourceURL.path)")
}

guard sourceImage.width == 1024, sourceImage.height == 1024 else {
    fail("source image must be 1024×1024 pixels")
}

try FileManager.default.createDirectory(
    at: outputURL,
    withIntermediateDirectories: true
)

let outputs = [
    IconOutput(filename: "AppIcon-20@2x.png", pixels: 40),
    IconOutput(filename: "AppIcon-20@3x.png", pixels: 60),
    IconOutput(filename: "AppIcon-29@2x.png", pixels: 58),
    IconOutput(filename: "AppIcon-29@3x.png", pixels: 87),
    IconOutput(filename: "AppIcon-40@2x.png", pixels: 80),
    IconOutput(filename: "AppIcon-40@3x.png", pixels: 120),
    IconOutput(filename: "AppIcon-60@2x.png", pixels: 120),
    IconOutput(filename: "AppIcon-60@3x.png", pixels: 180),
    IconOutput(filename: "AppIcon-1024.png", pixels: 1024),
]

let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo =
    CGBitmapInfo.byteOrder32Big.rawValue |
    CGImageAlphaInfo.noneSkipLast.rawValue

for output in outputs {
    let pixels = output.pixels
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: pixels * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        fail("unable to create \(pixels)×\(pixels) render context")
    }

    context.interpolationQuality = .high
    context.draw(
        sourceImage,
        in: CGRect(x: 0, y: 0, width: pixels, height: pixels)
    )

    guard let renderedImage = context.makeImage() else {
        fail("unable to render \(output.filename)")
    }

    let destinationURL = outputURL.appendingPathComponent(output.filename)
    guard let destination = CGImageDestinationCreateWithURL(
        destinationURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fail("unable to create \(destinationURL.path)")
    }

    CGImageDestinationAddImage(destination, renderedImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        fail("unable to write \(destinationURL.path)")
    }
}

print("Exported \(outputs.count) opaque PNG files to \(outputURL.path)")
