import Foundation

/// Automatic backup never inherits permission from a connection. Each remote
/// account starts disabled and must be enabled by the user on this device.
enum PhotoBackupAutomaticNetworkPolicy: String, CaseIterable, Codable, Sendable {
    case wifiOnly
    case anyNetwork

    var title: String {
        switch self {
        case .wifiOnly: "仅 Wi‑Fi"
        case .anyNetwork: "允许蜂窝数据"
        }
    }

    var detail: String {
        switch self {
        case .wifiOnly: "仅在 Wi‑Fi 下自动上传，避免意外消耗蜂窝流量。"
        case .anyNetwork: "在 Wi‑Fi 或蜂窝网络下都可以自动上传。"
        }
    }
}

/// The stored identity fields make an accidental account-ID collision fail
/// closed instead of applying one MyNAS account's policy to another account.
struct PhotoBackupAutomationPolicy: Codable, Equatable, Sendable {
    let accountID: String
    let serverID: String
    let userID: String
    var isEnabled: Bool
    var networkPolicy: PhotoBackupAutomaticNetworkPolicy
    var pausesInLowPowerMode: Bool
    var updatedAt: Date

    static func disabled(for account: AccountContext) -> PhotoBackupAutomationPolicy {
        PhotoBackupAutomationPolicy(
            accountID: account.accountID,
            serverID: account.serverID,
            userID: account.userID,
            isEnabled: false,
            networkPolicy: .wifiOnly,
            pausesInLowPowerMode: true,
            updatedAt: Date()
        )
    }

    nonisolated func applies(to account: AccountContext) -> Bool {
        accountID == account.accountID
            && serverID == account.serverID
            && userID == account.userID
            && !account.isLocalOnly
    }
}

enum PhotoBackupAutomationStatus: Equatable, Sendable {
    case disabled
    case waitingForForeground
    case checkingNetwork
    case waitingForNetwork
    case waitingForWiFi
    case pausedForLowPower
    case needsVolume
    case waitingForCurrentBackup
    case waitingForSelectedAccount
    case verifyingExistingBackups
    case waitingToVerifyExistingBackups
    case discovering
    case uploading
    case backgroundTransferActive
    case watchingForeground

    var title: String {
        switch self {
        case .disabled: "自动备份已关闭"
        case .waitingForForeground: "等待回到前台"
        case .checkingNetwork: "正在检查网络条件"
        case .waitingForNetwork: "等待网络连接"
        case .waitingForWiFi: "等待 Wi‑Fi"
        case .pausedForLowPower: "低电量模式已暂停"
        case .needsVolume: "等待选择备份硬盘"
        case .waitingForCurrentBackup: "等待当前备份完成"
        case .waitingForSelectedAccount: "等待切回此账号"
        case .verifyingExistingBackups: "正在核验已有备份"
        case .waitingToVerifyExistingBackups: "等待核验已有备份"
        case .discovering: "正在发现新项目"
        case .uploading: "正在自动上传"
        case .backgroundTransferActive: "iOS 正在处理后台传输"
        case .watchingForeground: "前台自动发现中"
        }
    }

    var detail: String {
        switch self {
        case .disabled:
            "此账号不会因图库变化而自动上传。"
        case .waitingForForeground:
            "当前版本只在 App 前台检查图库；回到 App 后会再次判断条件。"
        case .checkingNetwork:
            "正在读取 iPhone 当前的网络状态。"
        case .waitingForNetwork:
            "连接网络后，App 在前台会继续检查待备份项目。"
        case .waitingForWiFi:
            "当前策略只允许 Wi‑Fi 自动上传。"
        case .pausedForLowPower:
            "关闭低电量模式或允许此账号在低电量时继续后，会再次检查。"
        case .needsVolume:
            "请先为这个 MyNAS 账号选择备份硬盘。"
        case .waitingForCurrentBackup:
            "另一个前台备份正在使用上传队列；完成后会重新检查此账号的自动策略。"
        case .waitingForSelectedAccount:
            "已切换到其他 MyNAS 账号；自动上传会在切回后才继续。"
        case .verifyingExistingBackups:
            "自动上传会先向 MyNAS 核验此设备已确认的备份记录，避免重复排队。"
        case .waitingToVerifyExistingBackups:
            "上次核验未完成；App 会在前台下次检查时重试，期间不会自动上传。"
        case .discovering:
            "正在比较当前图库与该账号已验证的备份记录。"
        case .uploading:
            "自动发现的项目正在以前台队列上传。"
        case .backgroundTransferActive:
            "iOS 已接管已准备好的上传文件；网络、电量和系统调度仍可能延后传输。"
        case .watchingForeground:
            "满足条件时，新的或已修改项目会加入自动队列。"
        }
    }

    var systemImage: String {
        switch self {
        case .disabled: "pause.circle"
        case .waitingForForeground: "iphone.and.arrow.forward"
        case .checkingNetwork: "network"
        case .waitingForNetwork: "wifi.exclamationmark"
        case .waitingForWiFi: "wifi"
        case .pausedForLowPower: "battery.25percent"
        case .needsVolume: "externaldrive.badge.exclamationmark"
        case .waitingForCurrentBackup: "clock.arrow.circlepath"
        case .waitingForSelectedAccount: "person.crop.circle.badge.pause"
        case .verifyingExistingBackups, .waitingToVerifyExistingBackups: "checkmark.shield"
        case .discovering: "photo.on.rectangle.angled"
        case .uploading: "arrow.up.circle.fill"
        case .backgroundTransferActive: "arrow.triangle.2.circlepath"
        case .watchingForeground: "eye"
        }
    }
}

/// A side-effect-free representation of G1's foreground gate. Keeping this
/// order outside the coordinator makes it possible to test the conservative
/// decision before a PhotoKit export or network upload is ever considered.
nonisolated enum PhotoBackupAutomaticEligibility {
    static func pauseStatus(
        policy: PhotoBackupAutomationPolicy,
        account: AccountContext,
        isAppInForeground: Bool,
        isSelectedAccount: Bool,
        requiresDeviceMappingRecovery: Bool,
        isMappingRecoveryInProgress: Bool,
        hasRecoveredMappings: Bool,
        conditions: PhotoBackupAutomationConditionSnapshot
    ) -> PhotoBackupAutomationStatus? {
        guard policy.applies(to: account), policy.isEnabled else {
            return .disabled
        }
        guard isAppInForeground else { return .waitingForForeground }
        guard isSelectedAccount else { return .waitingForSelectedAccount }
        guard account.selectedVolumeID != nil else { return .needsVolume }

        if requiresDeviceMappingRecovery {
            if isMappingRecoveryInProgress {
                return .verifyingExistingBackups
            }
            if !hasRecoveredMappings {
                return .waitingToVerifyExistingBackups
            }
        }

        if policy.pausesInLowPowerMode, conditions.isLowPowerModeEnabled {
            return .pausedForLowPower
        }

        switch conditions.network {
        case .checking:
            return .checkingNetwork
        case .unavailable:
            return .waitingForNetwork
        case .available(let isWiFi):
            return policy.networkPolicy == .wifiOnly && !isWiFi
                ? .waitingForWiFi
                : nil
        }
    }
}

/// Kept separate from the queue so a failed queue write cannot silently enable
/// automatic uploads. The file has the same at-rest protection as the queue.
nonisolated struct PhotoBackupAutomationPolicyStore {
    private let fileManager: FileManager
    private let explicitURL: URL?

    init(fileManager: FileManager = .default, explicitURL: URL? = nil) {
        self.fileManager = fileManager
        self.explicitURL = explicitURL
    }

    func load() throws -> [PhotoBackupAutomationPolicy] {
        let url = try storageURL()
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([PhotoBackupAutomationPolicy].self, from: Data(contentsOf: url))
    }

    func save(_ policies: [PhotoBackupAutomationPolicy]) throws {
        let url = try storageURL()
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(policies)
        try data.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private func storageURL() throws -> URL {
        if let explicitURL { return explicitURL }
        guard let root = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return root
            .appendingPathComponent("BackupAutomation", isDirectory: true)
            .appendingPathComponent("policies.json", isDirectory: false)
    }
}
