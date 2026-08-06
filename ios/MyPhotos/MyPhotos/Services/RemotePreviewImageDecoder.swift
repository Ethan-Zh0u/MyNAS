import CoreGraphics
import Foundation
import ImageIO
import UIKit

/// Keeps a remote preview card aligned with the actual derivative that will be
/// drawn. PhotoKit's source dimensions and the server's disposable JPEG can
/// legitimately differ after rotation or a fallback derivative is selected.
/// The view therefore starts with the advertised derivative dimensions and
/// replaces them with the decoded bitmap dimensions as soon as it is ready.
nonisolated enum RemotePreviewLayout {
    static func aspectRatio(
        preferredWidth: Int,
        preferredHeight: Int,
        fallbackWidth: Int,
        fallbackHeight: Int
    ) -> CGFloat {
        let width = preferredWidth > 0 ? preferredWidth : fallbackWidth
        let height = preferredHeight > 0 ? preferredHeight : fallbackHeight
        guard width > 0, height > 0 else { return 1 }
        return min(max(CGFloat(width) / CGFloat(height), 0.45), 2.4)
    }
}

/// Decodes MyNAS JPEG derivatives away from SwiftUI's main executor.
///
/// A remote derivative can be a 24-bit JPEG. Passing it straight to
/// `UIImage(data:)` leaves ImageIO to choose the render surface's BGRx format,
/// which is rejected for some 24-bpp inputs on iOS 27. Downsampling and then
/// drawing into an explicit 32-bit RGBA bitmap makes the image safe for SwiftUI
/// to render while capping its decoded memory use.
nonisolated enum RemotePreviewImageDecoder {
    private static let queue = DispatchQueue(
        label: "com.mynas.photos.remote-preview-decoder",
        qos: .userInitiated
    )

    static func decode(
        _ data: Data,
        maximumPixelSize: Int
    ) async -> UIImage? {
        guard maximumPixelSize > 0 else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(
                    returning: decodeSynchronously(
                        data,
                        maximumPixelSize: maximumPixelSize
                    )
                )
            }
        }
    }

    static func decodeSynchronously(
        _ data: Data,
        maximumPixelSize: Int
    ) -> UIImage? {
        guard maximumPixelSize > 0 else { return nil }
        let sourceOptions = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions
        ), let compatibleImage = rgbaImage(from: thumbnail) else {
            return nil
        }
        return UIImage(cgImage: compatibleImage)
    }

    private static func rgbaImage(from image: CGImage) -> CGImage? {
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        return context.makeImage()
    }
}
