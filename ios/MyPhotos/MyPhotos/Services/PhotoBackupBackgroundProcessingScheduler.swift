import BackgroundTasks
import Foundation

/// Schedules only a narrow recovery opportunity for already-journaled G2
/// transfers. It is not a periodic PhotoKit scan and it does not guarantee
/// that iOS will run the handler at a particular time.
@MainActor
final class PhotoBackupBackgroundProcessingScheduler {
    static let shared = PhotoBackupBackgroundProcessingScheduler()

    static let taskIdentifier = "com.ethanzhou.MyPhotos.photo-backup-processing"

    private var hasRegistered = false

    func register() {
        guard !hasRegistered else { return }
        hasRegistered = true
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            Task { @MainActor [weak self] in
                self?.handle(task: task)
            }
        }
        assert(registered, "Background processing task must be registered before application launch completes.")
    }

    /// The system accepts at most one pending request for an identifier. A
    /// duplicate submit simply means an earlier opportunity is already queued;
    /// it does not widen the user's permission or create another upload.
    func scheduleIfEligible(engine: PhotoBackupBackgroundTransferEngine) {
        guard engine.hasEligiblePersistedTransferForBackgroundProcessing() else { return }
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handle(task: BGTask) {
        guard let processingTask = task as? BGProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        let work = Task { @MainActor [weak self] in
            let disposition = await PhotoBackupBackgroundTransferEngine.shared
                .continueOnePersistedTransferFromBackgroundProcessing()
            if disposition == .deferredForLowPower {
                self?.scheduleIfEligible(engine: .shared)
            }
            processingTask.setTaskCompleted(
                success: disposition == .continued || disposition == .noEligibleTransfer
            )
        }
        processingTask.expirationHandler = {
            work.cancel()
        }
    }
}
