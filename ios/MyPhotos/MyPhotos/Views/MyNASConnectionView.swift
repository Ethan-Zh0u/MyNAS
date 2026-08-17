import SwiftUI

struct MyNASConnectionView: View {
    @EnvironmentObject private var accountStore: AccountStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var addressIsFocused: Bool
    @State private var currentStep: ConnectionWizardStep = .install
    @State private var furthestStep: ConnectionWizardStep = .install
    @State private var address = ""
    @State private var addressError: String?
    @State private var isConnecting = false
    @State private var connectionError: String?
    @State private var isScannerPresented = false
    @State private var scannedServerURL: String?
    @State private var expectedServerID: String?
    private let connectionService = MyNASConnectionService()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    introduction
                    ConnectionProgress(currentStep: currentStep)
                }

                Section("连接步骤") {
                    ForEach(ConnectionWizardStep.allCases) { step in
                        stepRow(step)
                    }
                }

                Section(currentStep.title) {
                    stepContent(currentStep)
                        .padding(.vertical, 4)
                }

                Section {
                    Label(
                        "Tailscale 登录由官方 App 管理。MyNAS Photos 不会读取或保存你的密码。",
                        systemImage: "lock.shield"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("连接 MyNAS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isConnecting)
                }
            }
            .interactiveDismissDisabled(isConnecting)
            .sheet(isPresented: $isScannerPresented) {
                MyNASQRCodeScannerView(
                    onScan: handleScannedValue,
                    onCancel: { isScannerPresented = false },
                    onFailure: handleScannerFailure
                )
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: MyPhotosMetrics.compactSpacing) {
            Text("跟着四步完成连接")
                .font(.title2.bold())
            Text("每一步完成后再继续。最后一步会同时验证 Tailscale 身份、MyNAS 版本和可用硬盘。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func stepRow(_ step: ConnectionWizardStep) -> some View {
        Button {
            revisit(step)
        } label: {
            HStack(spacing: MyPhotosMetrics.standardSpacing) {
                Image(systemName: statusSymbol(for: step))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(statusColor(for: step))
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.body.weight(step == currentStep ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    Text("第 \(step.rawValue + 1) 步 · \(stepStateText(for: step))")
                        .font(.caption)
                        .foregroundStyle(
                            step == currentStep ? Color.accentColor : Color.secondary
                        )
                }

                Spacer()

                if step.rawValue <= furthestStep.rawValue, step != currentStep {
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(step.rawValue > furthestStep.rawValue || isConnecting)
        .accessibilityLabel("第 \(step.rawValue + 1) 步，\(step.title)")
        .accessibilityValue(stepStateText(for: step))
    }

    @ViewBuilder
    private func stepContent(_ step: ConnectionWizardStep) -> some View {
        switch step {
        case .install:
            VStack(alignment: .leading, spacing: 14) {
                Text("从 App Store 安装官方 Tailscale。已经安装可以直接继续。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                tailscaleDownloadLink

                primaryButton("已经安装，下一步", systemImage: "arrow.right") {
                    advance(to: .signIn)
                }
            }

        case .signIn:
            VStack(alignment: .leading, spacing: 13) {
                WizardChecklistRow(
                    symbol: "app.badge.checkmark",
                    text: "打开 Tailscale，点击 Get Started"
                )
                WizardChecklistRow(
                    symbol: "network.badge.shield.half.filled",
                    text: "允许 iOS 添加 VPN 配置"
                )
                WizardChecklistRow(
                    symbol: "person.badge.key",
                    text: "登录与 MyNAS 相同的 tailnet，或使用已获授权的账号"
                )
                WizardChecklistRow(
                    symbol: "checkmark.circle",
                    text: "确认 Tailscale 页面显示已连接"
                )

                Text("如果另一款 VPN 正在运行，iOS 可能会暂停 Tailscale。连接失败时先回到 Tailscale 检查状态。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                primaryButton("已登录并连接，下一步", systemImage: "arrow.right") {
                    advance(to: .address)
                }
            }

        case .address:
            VStack(alignment: .leading, spacing: 12) {
                Text("推荐扫描 MyNAS 网页“设置”中的配对二维码，也可以继续手动输入私有地址。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                scanButton

                HStack(spacing: 10) {
                    Divider()
                    Text("或手动输入")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Divider()
                }

                TextField("https://mynas.example.ts.net", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .submitLabel(.continue)
                    .focused($addressIsFocused)
                    .onSubmit(validateAddressAndContinue)
                    .onChange(of: address) {
                        addressError = nil
                        guard address != scannedServerURL else { return }
                        scannedServerURL = nil
                        expectedServerID = nil
                        invalidateAddressVerification()
                    }
                    .textFieldStyle(.roundedBorder)
                    .myPhotosMinimumTouchTarget()

                Text("只填写 `https://设备名.tailnet名.ts.net` 根地址，不要填写局域网 IP、端口或子路径。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if expectedServerID != nil {
                    MyPhotosInlineNotice(
                        title: "二维码已读取",
                        message: "连接时会同时核对服务器身份。",
                        systemImage: "checkmark.seal.fill",
                        tone: .success
                    )
                }

                if let addressError {
                    MyPhotosInlineNotice(
                        title: "地址不可用",
                        message: addressError,
                        systemImage: "exclamationmark.triangle.fill",
                        tone: .danger
                    )
                    .transition(.opacity)
                }

                primaryButton("检查地址，下一步", systemImage: "arrow.right") {
                    validateAddressAndContinue()
                }
            }
            .onAppear {
                addressIsFocused = true
            }

        case .verify:
            VStack(alignment: .leading, spacing: 14) {
                VerificationRow(
                    title: "Tailscale",
                    value: "由连接请求验证",
                    symbol: "checkmark.shield"
                )
                VerificationRow(
                    title: "MyNAS 地址",
                    value: normalizedAddressDescription,
                    symbol: "externaldrive.connected.to.line.below"
                )
                VerificationRow(
                    title: "连接后",
                    value: "读取身份与可用硬盘",
                    symbol: "person.crop.circle.badge.checkmark"
                )

                if let connectionError {
                    MyPhotosInlineNotice(
                        title: "未能连接",
                        message: connectionError,
                        systemImage: "exclamationmark.triangle.fill",
                        tone: .danger
                    )
                }

                connectButton

                Button("返回修改地址") {
                    revisit(.address)
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .myPhotosMinimumTouchTarget()
                .disabled(isConnecting)
            }
        }
    }

    @ViewBuilder
    private var tailscaleDownloadLink: some View {
        let link = Link(
            destination: URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!
        ) {
            Label("在 App Store 查看 Tailscale", systemImage: "arrow.up.right.square")
                .frame(maxWidth: .infinity)
        }

        if #available(iOS 26.0, *) {
            link
                .buttonStyle(.glass)
                .controlSize(.large)
                .myPhotosMinimumTouchTarget()
        } else {
            link
                .buttonStyle(.bordered)
                .controlSize(.large)
                .myPhotosMinimumTouchTarget()
        }
    }

    @ViewBuilder
    private var scanButton: some View {
        let button = Button {
            openScanner()
        } label: {
            Label("扫描 MyNAS 配对二维码", systemImage: "qrcode.viewfinder")
                .frame(maxWidth: .infinity)
        }

        if #available(iOS 26.0, *) {
            button
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .myPhotosMinimumTouchTarget()
        } else {
            button
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .myPhotosMinimumTouchTarget()
        }
    }

    @ViewBuilder
    private func primaryButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }

        if #available(iOS 26.0, *) {
            button
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .myPhotosMinimumTouchTarget()
        } else {
            button
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .myPhotosMinimumTouchTarget()
        }
    }

    @ViewBuilder
    private var connectButton: some View {
        let button = Button {
            connect()
        } label: {
            HStack {
                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在验证身份与存储盘…")
                } else {
                    Label("验证并连接", systemImage: "checkmark.shield")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(isConnecting)

        if #available(iOS 26.0, *) {
            button
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .myPhotosMinimumTouchTarget()
        } else {
            button
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .myPhotosMinimumTouchTarget()
        }
    }

    private var normalizedAddressDescription: String {
        (try? MyNASConnectionService.normalizedBaseURL(from: address).host()) ?? address
    }

    private func advance(to step: ConnectionWizardStep) {
        connectionError = nil
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.32)) {
            if step.rawValue > furthestStep.rawValue {
                furthestStep = step
            }
            currentStep = step
        }
    }

    private func revisit(_ step: ConnectionWizardStep) {
        guard step.rawValue <= furthestStep.rawValue, !isConnecting else { return }
        addressError = nil
        connectionError = nil
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.32)) {
            currentStep = step
        }
    }

    private func validateAddressAndContinue() {
        do {
            let normalizedURL = try MyNASConnectionService.normalizedBaseURL(from: address)
            address = normalizedURL.absoluteString
            addressError = nil
            addressIsFocused = false
            advance(to: .verify)
        } catch {
            addressError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// A changed manual address must pass the address validator again before
    /// the verification screen can be revisited. A scanned value retains its
    /// pairing identity and advances through its dedicated path below.
    private func invalidateAddressVerification() {
        guard furthestStep.rawValue > ConnectionWizardStep.address.rawValue else { return }
        furthestStep = .address
        if currentStep == .verify {
            currentStep = .address
        }
    }

    private func openScanner() {
        addressIsFocused = false
        addressError = nil
        guard MyNASQRCodeScannerView.isSupported else {
            addressError = "此设备无法使用相机扫码，请粘贴或手动输入 MyNAS 地址。"
            return
        }
        guard MyNASQRCodeScannerView.isAvailable else {
            addressError = "相机当前不可用于扫码，请检查相机权限，或手动输入地址。"
            return
        }
        isScannerPresented = true
    }

    private func handleScannedValue(_ value: String) {
        do {
            let payload = try MyNASConnectionService.pairingPayload(from: value)
            scannedServerURL = payload.serverURL
            expectedServerID = payload.serverID
            address = payload.serverURL
            addressError = nil
            isScannerPresented = false
            advance(to: .verify)
        } catch {
            addressError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isScannerPresented = false
        }
    }

    private func handleScannerFailure(_ message: String) {
        addressError = message
        isScannerPresented = false
    }

    private func connect() {
        connectionError = nil
        isConnecting = true
        Task {
            do {
                let serverID = address == scannedServerURL ? expectedServerID : nil
                let result = try await connectionService.connect(
                    address: address,
                    expectedServerID: serverID
                )
                accountStore.saveConnectedAccount(result.account)
                dismiss()
            } catch {
                connectionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                isConnecting = false
            }
        }
    }

    private func statusSymbol(for step: ConnectionWizardStep) -> String {
        if step != currentStep, step.rawValue < furthestStep.rawValue {
            return "checkmark.circle.fill"
        }
        return step == currentStep ? "\(step.rawValue + 1).circle.fill" : "\(step.rawValue + 1).circle"
    }

    private func statusColor(for step: ConnectionWizardStep) -> Color {
        step.rawValue <= furthestStep.rawValue ? .accentColor : .secondary
    }

    private func stepStateText(for step: ConnectionWizardStep) -> String {
        if step == currentStep { return "当前步骤" }
        if step.rawValue < furthestStep.rawValue { return "已完成，可返回修改" }
        if step == furthestStep { return "已到达，可继续" }
        return "等待前一步完成"
    }
}

private enum ConnectionWizardStep: Int, CaseIterable, Identifiable {
    case install
    case signIn
    case address
    case verify

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .install: "安装 Tailscale"
        case .signIn: "登录并开启 VPN"
        case .address: "填写 MyNAS 地址"
        case .verify: "验证并完成连接"
        }
    }
}

private struct ConnectionProgress: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let currentStep: ConnectionWizardStep

    var body: some View {
        VStack(alignment: .leading, spacing: MyPhotosMetrics.compactSpacing) {
            HStack {
                Text("连接进度")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(currentStep.rawValue + 1) / \(ConnectionWizardStep.allCases.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(
                value: Double(currentStep.rawValue + 1),
                total: Double(ConnectionWizardStep.allCases.count)
            )
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.32), value: currentStep)
        .accessibilityLabel("连接进度，第 \(currentStep.rawValue + 1) 步，共 4 步")
    }
}

private struct WizardChecklistRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
        }
    }
}

private struct VerificationRow: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
            }
        }
    }
}
