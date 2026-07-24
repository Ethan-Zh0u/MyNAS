import SwiftUI
import Vision
import VisionKit

struct MyNASQRCodeScannerView: View {
    let onScan: (String) -> Void
    let onCancel: () -> Void
    let onFailure: (String) -> Void

    static var isSupported: Bool {
        DataScannerViewController.isSupported
    }

    static var isAvailable: Bool {
        DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            ZStack {
                MyNASDataScanner(
                    onScan: onScan,
                    onFailure: onFailure
                )
                .ignoresSafeArea()

                VStack {
                    Spacer()
                    Label(
                        "将 MyNAS 网页中的二维码放入取景框",
                        systemImage: "qrcode.viewfinder"
                    )
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .scannerInstructionSurface()
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("扫描配对二维码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
            }
        }
    }
}

private struct MyNASDataScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onFailure: onFailure)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(
        _ scanner: DataScannerViewController,
        context: Context
    ) {
        guard !scanner.isScanning else { return }
        do {
            try scanner.startScanning()
        } catch {
            context.coordinator.reportFailure(
                "无法启动相机扫码，请检查相机权限，或手动输入地址。"
            )
        }
    }

    static func dismantleUIViewController(
        _ scanner: DataScannerViewController,
        coordinator: Coordinator
    ) {
        scanner.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        private let onFailure: (String) -> Void
        private var didFinish = false

        init(
            onScan: @escaping (String) -> Void,
            onFailure: @escaping (String) -> Void
        ) {
            self.onScan = onScan
            self.onFailure = onFailure
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !didFinish else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let value = barcode.payloadStringValue else { continue }
                didFinish = true
                dataScanner.stopScanning()
                onScan(value)
                return
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            reportFailure("相机扫码当前不可用，请检查相机权限，或手动输入地址。")
        }

        func reportFailure(_ message: String) {
            guard !didFinish else { return }
            didFinish = true
            onFailure(message)
        }
    }
}

private extension View {
    @ViewBuilder
    func scannerInstructionSurface() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }
}
