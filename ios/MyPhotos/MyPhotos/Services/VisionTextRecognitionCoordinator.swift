@preconcurrency import Vision
import ImageIO
import UIKit

/// The only I3 component that receives a rendered local image. It is kept out
/// of the persistence actor so storage APIs cannot request pixels themselves.
@MainActor
final class VisionTextRecognitionCoordinator {
    private let recognizer: VisionTextRecognizer

    init(recognizer: VisionTextRecognizer = VisionTextRecognizer()) {
        self.recognizer = recognizer
    }

    /// Processes one image at a time. The caller supplies only I3's explicit
    /// candidates; `PhotoLibraryClient` enforces `isNetworkAccessAllowed=false`
    /// for every image request, so iCloud-only originals are left deferred.
    func recognize(
        assets: [LocalPhotoAsset],
        photoClient: PhotoLibraryClient
    ) async -> [PhotoTextRecognitionOutput] {
        var outputs: [PhotoTextRecognitionOutput] = []
        outputs.reserveCapacity(assets.count)

        for asset in assets where !Task.isCancelled {
            let imageResult = await photoClient.textRecognitionImage(for: asset.localIdentifier)
            guard let image = imageResult.image else { continue }
            guard let recognizedText = try? await recognizer.recognizeText(in: image) else { continue }
            outputs.append(
                PhotoTextRecognitionOutput(
                    assetID: asset.localIdentifier,
                    recognizedText: recognizedText
                )
            )
        }
        return outputs
    }
}

/// Actor isolation keeps synchronous Vision work off the UI actor and makes
/// the first I3 release intentionally serial, which bounds memory and thermal
/// pressure on the device.
actor VisionTextRecognizer {
    func recognizeText(in image: UIImage) throws -> String {
        guard let cgImage = image.cgImage else {
            throw VisionTextRecognizerError.unsupportedImage
        }

        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(iOS 16.0, *) {
            request.automaticallyDetectsLanguage = true
        }

        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: Self.orientation(for: image.imageOrientation)
        )
        try handler.perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    private static func orientation(for orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: .up
        case .upMirrored: .upMirrored
        case .down: .down
        case .downMirrored: .downMirrored
        case .left: .left
        case .leftMirrored: .leftMirrored
        case .right: .right
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}

private enum VisionTextRecognizerError: LocalizedError {
    case unsupportedImage

    var errorDescription: String? {
        switch self {
        case .unsupportedImage:
            "当前照片无法提供给本地 OCR。"
        }
    }
}
