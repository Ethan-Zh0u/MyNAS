import Foundation
import SwiftUI
import UIKit

/// XCTest uses the production app bundle as its host on iOS. Keep that host
/// from constructing the normal root view: doing so would create PhotoKit
/// observers and could resume a persisted foreground backup while a pure
/// local-integrity test is running.
nonisolated enum MyPhotosRuntime {
    static let isRunningXCTest = ProcessInfo.processInfo.environment[
        "XCTestConfigurationFilePath"
    ] != nil
}

@main
struct MyNASPhotosApp: App {
    @UIApplicationDelegateAdaptor(MyPhotosBackgroundTransferAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        WindowGroup {
            if MyPhotosRuntime.isRunningXCTest {
                Color.clear
                    .accessibilityIdentifier("myphotos-xctest-host")
            } else {
                MyPhotosProductionRoot()
            }
        }
    }
}

/// Background URLSession callbacks are delivered through UIKit even though the
/// rest of the App uses SwiftUI. The delegate contains no PhotoKit, account or
/// UI lifecycle work; it only reconnects iOS's task callbacks to the durable
/// G2 journal and returns the system completion handler at the right time.
@MainActor
final class MyPhotosBackgroundTransferAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Registration itself creates no task, accesses no PhotoKit data and
        // does not resume a queue. It only lets iOS deliver a future, already
        // authorized processing opportunity to this process.
        PhotoBackupBackgroundProcessingScheduler.shared.register()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        PhotoBackupBackgroundProcessingScheduler.shared.scheduleIfEligible(
            engine: .shared
        )
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        let engine = PhotoBackupBackgroundTransferEngine.shared
        guard engine.reconnectForBackgroundEvents(
            identifier: identifier,
            completionHandler: completionHandler
        ) else {
            completionHandler()
            return
        }
    }
}

private struct MyPhotosProductionRoot: View {
    @StateObject private var accountStore = AccountStore()
    private let remotePhotoCacheManager = RemotePhotoCacheManager()

    var body: some View {
        ContentView()
            .environmentObject(accountStore)
            .task {
                // Import/share work cannot outlive a cold process launch.
                // Recover only abandoned account-scoped temporary originals;
                // all reusable cache classes remain available.
                for account in accountStore.accounts where !account.isLocalOnly {
                    _ = try? await remotePhotoCacheManager
                        .discardOrphanedTemporaryDownloads(account: account)
                }
            }
    }
}
