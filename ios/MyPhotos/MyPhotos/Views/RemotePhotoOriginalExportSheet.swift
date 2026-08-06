import SwiftUI
import UIKit

/// Keeps a verified H2 export inside the native iOS share surface. The caller
/// retains and removes the temporary files only after this sheet has finished
/// handing them to the chosen activity.
struct RemotePhotoOriginalExportSheet: UIViewControllerRepresentable {
    let fileURLs: [URL]
    let completed: (_ didComplete: Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: fileURLs,
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, didComplete, _, _ in
            completed(didComplete)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
