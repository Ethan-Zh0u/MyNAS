import Combine
import Foundation
import Network

struct PhotoBackupAutomationConditionSnapshot: Equatable, Sendable {
    enum NetworkState: Equatable, Sendable {
        case checking
        case unavailable
        case available(isWiFi: Bool)
    }

    var network: NetworkState
    var isLowPowerModeEnabled: Bool
}

/// Represents only conditions that iOS exposes to the foreground app. It does
/// not schedule or claim a background execution window.
@MainActor
final class PhotoBackupAutomationConditions: ObservableObject {
    @Published private(set) var snapshot: PhotoBackupAutomationConditionSnapshot

    private let pathMonitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "com.ethanzhou.MyPhotos.backup-conditions")
    private var powerStateObserver: NSObjectProtocol?

    init(processInfo: ProcessInfo = .processInfo) {
        snapshot = PhotoBackupAutomationConditionSnapshot(
            network: .checking,
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled
        )
        pathMonitor = NWPathMonitor()

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let network: PhotoBackupAutomationConditionSnapshot.NetworkState
            if path.status == .satisfied {
                network = .available(isWiFi: path.usesInterfaceType(.wifi))
            } else {
                network = .unavailable
            }
            Task { @MainActor [weak self] in
                self?.snapshot.network = network
            }
        }
        pathMonitor.start(queue: monitorQueue)

        powerStateObserver = NotificationCenter.default.addObserver(
            // The Objective-C notification constant remains available on iOS
            // 18–25; the typed ProcessInfo message API starts only with iOS 26.
            forName: Notification.Name("NSProcessInfoPowerStateDidChangeNotification"),
            object: processInfo,
            queue: .main
        ) { [weak self, processInfo] _ in
            Task { @MainActor [weak self] in
                self?.snapshot.isLowPowerModeEnabled = processInfo.isLowPowerModeEnabled
            }
        }
    }

    deinit {
        pathMonitor.cancel()
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
        }
    }
}
