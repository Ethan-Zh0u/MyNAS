import SwiftUI
import UIKit

struct PhotoPermissionView: View {
    let authorization: PhotoAuthorizationState
    let requestAuthorization: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            if authorization == .notDetermined {
                Button("允许访问照片", action: requestAuthorization)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("前往系统设置") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    private var title: String {
        authorization == .notDetermined ? "允许访问你的照片" : "照片访问已关闭"
    }

    private var symbol: String {
        authorization == .notDetermined ? "photo.badge.plus" : "photo.badge.exclamationmark"
    }

    private var message: String {
        authorization == .notDetermined
            ? "MyNAS Photos 需要 PhotoKit 权限，才能显示你允许访问的本地照片和视频。"
            : "你可以在系统设置中允许完整访问，或选择部分照片。MyNAS Photos 不会自动下载 iCloud 原始资源。"
    }
}
