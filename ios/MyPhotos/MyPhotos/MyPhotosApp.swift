import SwiftUI

@main
struct MyNASPhotosApp: App {
    @StateObject private var accountStore = AccountStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(accountStore)
        }
    }
}
