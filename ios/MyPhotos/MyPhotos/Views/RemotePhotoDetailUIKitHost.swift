import AVKit
import SwiftUI
import UIKit

/// Keeps MyNAS detail presentation out of SwiftUI's generic view builder on
/// iOS 27. The system SwiftUI runtime can crash while resolving metadata for
/// the former, deeply composed detail view before it has fetched any media.
struct RemotePhotoDetailUIKitHost: UIViewControllerRepresentable {
    let asset: ServerPhotoAsset
    let account: AccountContext
    let client: RemotePhotoLibraryClient
    let localClient: PhotoLibraryClient
    let localAssets: [LocalPhotoAsset]
    /// A current local source version that this app has already confirmed as
    /// the same server asset. It is never inferred from visual metadata.
    let confirmedLocalCopy: LocalPhotoAsset?
    let onVerifiedLocalCopies: ((ServerPhotoAsset, [LocalPhotoAsset]) -> PhotoBackupVerifiedLocalAssociationResult)?
    let onRemoteDeleted: (String, PhotoBackupRemoteDeletionLocalDisposition) -> Void
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(
            rootViewController: RemotePhotoDetailUIKitController(
                asset: asset,
                account: account,
                client: client,
                localClient: localClient,
                localAssets: localAssets,
                confirmedLocalCopy: confirmedLocalCopy,
                onVerifiedLocalCopies: onVerifiedLocalCopies,
                onRemoteDeleted: onRemoteDeleted,
                onDismiss: onDismiss
            )
        )
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}

@MainActor
private final class RemotePhotoDetailUIKitController: UIViewController {
    private let asset: ServerPhotoAsset
    private let account: AccountContext
    private let client: RemotePhotoLibraryClient
    private let localClient: PhotoLibraryClient
    private let localAssets: [LocalPhotoAsset]
    private let confirmedLocalCopy: LocalPhotoAsset?
    private let onVerifiedLocalCopies: ((ServerPhotoAsset, [LocalPhotoAsset]) -> PhotoBackupVerifiedLocalAssociationResult)?
    private let onRemoteDeleted: (String, PhotoBackupRemoteDeletionLocalDisposition) -> Void
    private let onDismiss: () -> Void

    private let imageView = UIImageView()
    private let previewContainer = UIView()
    private var previewAspectConstraint: NSLayoutConstraint?
    private var previewAspectRatio: CGFloat = 1
    private let previewButton = UIButton(type: .system)
    private let playbackButton = UIButton(type: .system)
    private let downloadButton = UIButton(type: .system)
    private let exportButton = UIButton(type: .system)
    private let downloadProgressContainer = UIView()
    private let downloadProgressView = UIProgressView(progressViewStyle: .default)
    private let downloadProgressLabel = UILabel()
    private let associateButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let deletionAvailabilityIcon = UIImageView()
    private let deletionAvailabilityLabel = UILabel()
    private let deletionAvailabilityNotice = UIView()
    private let remoteMutationPreflight = MyNASRemoteMutationPreflight()
    private var connectionRefreshTask: Task<Void, Never>?
    private weak var activeDeletionAlert: UIAlertController?
    private var activeDeletionAlertConnectedMessage: String?
    private var remoteMutationAvailability: MyNASRemoteMutationAvailability = .checking {
        didSet {
            guard isViewLoaded else { return }
            updateDeletionAvailabilityNotice()
            updatePresentedDeletionAlertAvailability()
            updateActionAvailability()
        }
    }
    private var completionToast: UIView?
    /// The share activity receives files, not network URLs. Retain their
    /// verified temporary group until iOS reports that the activity finished.
    private var activeExportDownload: RemotePhotoOriginalDownload?
    private var isPerformingAction = false {
        didSet { updateActionAvailability() }
    }
    private var isLoadingPreview = false
    private var hasRequestedPreview = false
    private var isPreparingPlayback = false
    private var player: AVPlayer?
    private var playerViewController: AVPlayerViewController?
    private var mediaResourceLoader: MyNASMediaResourceLoader?
    private var automaticVerificationCompleted = false
    private var automaticallyVerifiedLocalCopy = false

    init(
        asset: ServerPhotoAsset,
        account: AccountContext,
        client: RemotePhotoLibraryClient,
        localClient: PhotoLibraryClient,
        localAssets: [LocalPhotoAsset],
        confirmedLocalCopy: LocalPhotoAsset?,
        onVerifiedLocalCopies: ((ServerPhotoAsset, [LocalPhotoAsset]) -> PhotoBackupVerifiedLocalAssociationResult)?,
        onRemoteDeleted: @escaping (String, PhotoBackupRemoteDeletionLocalDisposition) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.asset = asset
        self.account = account
        self.client = client
        self.localClient = localClient
        self.localAssets = localAssets
        self.confirmedLocalCopy = confirmedLocalCopy
        self.onVerifiedLocalCopies = onVerifiedLocalCopies
        self.onRemoteDeleted = onRemoteDeleted
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        connectionRefreshTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        activeExportDownload?.removeTemporaryFiles()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "远端详情"
        view.backgroundColor = .systemGroupedBackground
        navigationController?.navigationBar.prefersLargeTitles = false
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            style: .plain,
            target: self,
            action: #selector(close)
        )
        configureLayout()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        updateDeletionAvailabilityNotice()
        updateActionAvailability()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshRemoteMutationAvailability()
        // UIActivityViewController normally invokes its completion handler.
        // If iOS dismisses it through an interruption without doing so, the
        // detail becoming visible again is proof that no activity still owns
        // these temporary originals.
        if let activeExportDownload,
           presentedViewController == nil {
            activeExportDownload.removeTemporaryFiles()
            self.activeExportDownload = nil
            updateActionAvailability()
        }
        if !hasRequestedPreview {
            loadPreview()
        }
        if asset.mediaType == .video || asset.mediaType == .livePhoto {
            startRemotePlayback()
        }
        if canAssociateLocalCopy && !hasConfirmedLocalCopy {
            verifyAndAssociateLocalCopy(presentsResult: false)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        stopRemotePlayback()
        super.viewWillDisappear(animated)
    }

    private func configureLayout() {
        let scrollView = UIScrollView()
        let contentView = UIView()
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14
        stack.isLayoutMarginsRelativeArrangement = false

        view.addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(stack)
        [scrollView, contentView, stack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -30)
        ])

        stack.addArrangedSubview(makePreviewCard())
        stack.addArrangedSubview(makeTitleBlock())

        stack.addArrangedSubview(makeMetadataCard())
        stack.addArrangedSubview(makeResourceCard())
        stack.addArrangedSubview(makeActions())

        let footnote = UILabel()
        footnote.text = hasConfirmedLocalCopy
            ? "原件同时保存在本机和 MyNAS；预览来自 MyNAS。"
            : "预览来自 MyNAS；下载原件会先核验资源大小和 SHA-256，再导入系统照片。"
        footnote.font = .preferredFont(forTextStyle: .caption1)
        footnote.textColor = .secondaryLabel
        footnote.numberOfLines = 0
        footnote.textAlignment = .center
        footnote.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
        stack.addArrangedSubview(footnote)
    }

    private func makePreviewCard() -> UIView {
        previewContainer.backgroundColor = .secondarySystemGroupedBackground
        previewContainer.layer.cornerCurve = .continuous
        previewContainer.layer.cornerRadius = 18
        previewContainer.clipsToBounds = true

        imageView.contentMode = .center
        imageView.tintColor = .tertiaryLabel
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 28,
            weight: .regular
        )
        imageView.image = UIImage(systemName: asset.mediaType.systemImage)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(imageView)

        let badge = makePreviewBadge()
        previewContainer.addSubview(badge)

        var configuration = UIButton.Configuration.tinted()
        configuration.title = "正在加载预览…"
        configuration.image = UIImage(systemName: "arrow.down.circle")
        configuration.imagePadding = 7
        configuration.baseForegroundColor = .white
        configuration.baseBackgroundColor = .white
        configuration.cornerStyle = .capsule
        previewButton.configuration = configuration
        previewButton.addTarget(self, action: #selector(loadPreview), for: .touchUpInside)
        previewButton.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewButton)

        var playbackConfiguration = UIButton.Configuration.filled()
        playbackConfiguration.title = asset.mediaType == .livePhoto ? "播放实况" : "播放视频"
        playbackConfiguration.image = UIImage(
            systemName: asset.mediaType == .livePhoto ? "livephoto.play" : "play.fill"
        )
        playbackConfiguration.imagePadding = 8
        playbackConfiguration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 14,
            weight: .semibold
        )
        playbackConfiguration.cornerStyle = .capsule
        playbackButton.configuration = playbackConfiguration
        playbackButton.addTarget(self, action: #selector(startRemotePlayback), for: .touchUpInside)
        playbackButton.translatesAutoresizingMaskIntoConstraints = false
        playbackButton.isHidden = true
        previewContainer.addSubview(playbackButton)

        let derivative = asset.derivative("preview") ?? asset.derivative("grid")
        previewAspectRatio = RemotePreviewLayout.aspectRatio(
            preferredWidth: derivative?.pixelWidth ?? 0,
            preferredHeight: derivative?.pixelHeight ?? 0,
            fallbackWidth: asset.pixelWidth,
            fallbackHeight: asset.pixelHeight
        )
        let aspectConstraint = makePreviewAspectConstraint(ratio: previewAspectRatio)
        previewAspectConstraint = aspectConstraint

        NSLayoutConstraint.activate([
            aspectConstraint,
            previewContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            imageView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            badge.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 12),
            badge.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 12),
            previewButton.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            previewButton.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            playbackButton.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            playbackButton.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor)
        ])
        return previewContainer
    }

    private func makePreviewBadge() -> UIView {
        let effect = UIBlurEffect(style: .systemChromeMaterialDark)
        let badge = UIVisualEffectView(effect: effect)
        badge.layer.cornerCurve = .continuous
        badge.layer.cornerRadius = 14
        badge.clipsToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: "externaldrive.fill"))
        icon.tintColor = .white
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let label = UILabel()
        label.text = "MyNAS 远端预览"
        label.font = preferredFont(.caption1, weight: .semibold)
        label.textColor = .white
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        badge.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: badge.contentView.leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: badge.contentView.trailingAnchor, constant: -11),
            stack.topAnchor.constraint(equalTo: badge.contentView.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: badge.contentView.bottomAnchor, constant: -7)
        ])
        return badge
    }

    private func makeTitleBlock() -> UIView {
        let title = UILabel()
        title.text = asset.displayMediaName
        title.font = preferredFont(.title2, weight: .bold)
        return title
    }

    private func makeMetadataCard() -> UIView {
        let card = makeSurface()
        let content = UIStackView()
        content.axis = .vertical
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate(pin(content, to: card, inset: 14))

        content.addArrangedSubview(makeSectionHeader("媒体信息", symbol: "info.circle"))
        let firstRow = makeMetadataRow(
            makeMetadataItem("分辨率", value: "\(asset.pixelWidth) × \(asset.pixelHeight)", symbol: "viewfinder"),
            makeMetadataItem(
                "原始大小",
                value: ByteCountFormatter.string(
                    fromByteCount: asset.resources.reduce(0) { $0 + $1.byteSize },
                    countStyle: .file
                ),
                symbol: "internaldrive"
            )
        )
        content.addArrangedSubview(firstRow)

        if let captureDate = formattedCaptureDate {
            content.addArrangedSubview(makeInfoRow("拍摄于 \(captureDate)", symbol: "calendar"))
        }
        if let description = asset.exactContentRelationshipDescription {
            content.addArrangedSubview(makeInfoRow(description, symbol: "link"))
        }
        if let description = asset.versionTransitionRelationshipDescription {
            content.addArrangedSubview(makeInfoRow(description, symbol: "arrow.triangle.2.circlepath"))
        }
        return card
    }

    private func makeResourceCard() -> UIView {
        let card = makeSurface()
        let content = UIStackView()
        content.axis = .vertical
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate(pin(content, to: card, inset: 14))
        content.addArrangedSubview(makeSectionHeader("原始资源", symbol: "shippingbox"))
        for (index, resource) in asset.resources.enumerated() {
            content.addArrangedSubview(makeResourceRow(resource))
            if index < asset.resources.count - 1 {
                let line = UIView()
                line.backgroundColor = .separator
                line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
                content.addArrangedSubview(line)
            }
        }
        return card
    }

    private func makeSurface() -> UIView {
        let surface = UIView()
        surface.backgroundColor = .secondarySystemGroupedBackground
        surface.layer.cornerCurve = .continuous
        surface.layer.cornerRadius = 20
        return surface
    }

    private func makeSectionHeader(_ title: String, symbol: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = .systemBlue
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .headline)
        let stack = UIStackView(arrangedSubviews: [icon, label, UIView()])
        stack.alignment = .center
        stack.spacing = 8
        return stack
    }

    private func makeMetadataRow(_ leading: UIView, _ trailing: UIView) -> UIView {
        let row = UIStackView(arrangedSubviews: [leading, trailing])
        row.axis = .horizontal
        row.spacing = 10
        row.distribution = .fillEqually
        return row
    }

    private func makeMetadataItem(_ title: String, value: String, symbol: String) -> UIView {
        let surface = UIView()
        surface.backgroundColor = .tertiarySystemFill
        surface.layer.cornerCurve = .continuous
        surface.layer.cornerRadius = 14
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = .secondaryLabel
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .caption2)
        label.textColor = .secondaryLabel
        let header = UIStackView(arrangedSubviews: [icon, label, UIView()])
        header.alignment = .center
        header.spacing = 5
        let valueLabel = UILabel()
        valueLabel.text = value
        valueLabel.font = preferredFont(.subheadline, weight: .semibold)
        valueLabel.numberOfLines = 2
        let stack = UIStackView(arrangedSubviews: [header, valueLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)
        NSLayoutConstraint.activate(pin(stack, to: surface, inset: 12))
        return surface
    }

    private func makeInfoRow(_ text: String, symbol: String) -> UIView {
        let image = UIImageView(image: UIImage(systemName: symbol))
        image.tintColor = .secondaryLabel
        image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [image, label])
        stack.alignment = .top
        stack.spacing = 9
        return stack
    }

    private func makeResourceRow(_ resource: ServerPhotoResource) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: resource.isVideo ? "video.fill" : "photo.fill"))
        icon.tintColor = .systemBlue
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let title = UILabel()
        title.text = resource.displayRole
        title.font = preferredFont(.subheadline, weight: .semibold)
        let subtitle = UILabel()
        subtitle.text = "\(resource.originalFilename) · \(ByteCountFormatter.string(fromByteCount: resource.byteSize, countStyle: .file))"
        subtitle.font = .preferredFont(forTextStyle: .caption1)
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 2
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 2
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)
        let row = UIStackView(arrangedSubviews: [icon, stack])
        row.alignment = .top
        row.spacing = 8
        return row
    }

    private func makeActions() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 9
        configureButton(
            downloadButton,
            title: restingDownloadButtonTitle,
            image: "arrow.down.to.line.compact",
            style: .primary,
            action: #selector(downloadOriginals)
        )
        configureButton(
            exportButton,
            title: "导出已核验原件…",
            image: "square.and.arrow.up",
            style: .secondary,
            action: #selector(exportOriginals)
        )
        if hasConfirmedLocalCopy {
            stack.addArrangedSubview(makeConfirmedLocalCopyNotice())
        } else if canAssociateLocalCopy {
            stack.addArrangedSubview(makeLocalCandidateNotice())
        }
        if canAssociateLocalCopy {
            // Exact comparison is automatic. There is intentionally no action
            // that asks the user to repair every historical duplicate by hand.
        }
        configureButton(
            deleteButton,
            title: "删除 MyNAS 项目…",
            image: "trash",
            style: .destructive,
            action: #selector(prepareRemoteDeletion)
        )
        stack.addArrangedSubview(downloadButton)
        downloadButton.isHidden = !RemotePhotoDownloadPolicy.offersOriginalDownload(
            hasConfirmedLocalCopy: hasConfirmedLocalCopy
        )
        stack.addArrangedSubview(makeDownloadProgress())
        stack.addArrangedSubview(exportButton)
        stack.addArrangedSubview(makeDeletionAvailabilityNotice())
        stack.addArrangedSubview(deleteButton)
        return stack
    }

    private func makeDeletionAvailabilityNotice() -> UIView {
        deletionAvailabilityNotice.backgroundColor = .secondarySystemFill
        deletionAvailabilityNotice.layer.cornerCurve = .continuous
        deletionAvailabilityNotice.layer.cornerRadius = 12

        deletionAvailabilityIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 15,
            weight: .semibold
        )
        deletionAvailabilityIcon.setContentHuggingPriority(.required, for: .horizontal)

        deletionAvailabilityLabel.font = .preferredFont(forTextStyle: .footnote)
        deletionAvailabilityLabel.numberOfLines = 0

        let row = UIStackView(arrangedSubviews: [deletionAvailabilityIcon, deletionAvailabilityLabel])
        row.alignment = .top
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        deletionAvailabilityNotice.addSubview(row)
        NSLayoutConstraint.activate(pin(row, to: deletionAvailabilityNotice, inset: 11))
        return deletionAvailabilityNotice
    }

    private func updateDeletionAvailabilityNotice() {
        switch remoteMutationAvailability {
        case .checking:
            deletionAvailabilityIcon.image = UIImage(systemName: "network")
            deletionAvailabilityIcon.tintColor = .secondaryLabel
            deletionAvailabilityLabel.textColor = .secondaryLabel
            deletionAvailabilityNotice.backgroundColor = .secondarySystemFill
            deletionAvailabilityNotice.isHidden = false
        case .available:
            deletionAvailabilityNotice.isHidden = true
        case .tailscaleUnavailable:
            deletionAvailabilityIcon.image = UIImage(systemName: "wifi.exclamationmark")
            deletionAvailabilityIcon.tintColor = .systemOrange
            deletionAvailabilityLabel.textColor = .systemOrange
            deletionAvailabilityNotice.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.12)
            deletionAvailabilityNotice.isHidden = false
        }
        deletionAvailabilityLabel.text = remoteMutationAvailability.statusText
    }

    private func trackDeletionAlert(
        _ alert: UIAlertController,
        connectedMessage: String
    ) {
        activeDeletionAlert = alert
        activeDeletionAlertConnectedMessage = connectedMessage
        updatePresentedDeletionAlertAvailability()
    }

    private func updatePresentedDeletionAlertAvailability() {
        guard let alert = activeDeletionAlert else { return }
        let isEnabled = remoteMutationAvailability.allowsRemoteMutation
        for action in alert.actions where action.style != .cancel {
            action.isEnabled = isEnabled
        }
        switch remoteMutationAvailability {
        case .available:
            alert.message = activeDeletionAlertConnectedMessage
        case .checking:
            alert.message = "正在检查 Tailscale 连接；确认完成前不能删除 MyNAS 文件。"
        case .tailscaleUnavailable:
            alert.message = MyNASRemoteMutationPreflightError
                .tailscaleUnavailable.localizedDescription
        }
    }

    private func makeConfirmedLocalCopyNotice() -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        icon.tintColor = .systemGreen
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20)
        ])
        let title = UILabel()
        title.text = "本机已有同一原件"
        title.font = preferredFont(.footnote, weight: .semibold)
        let subtitle = UILabel()
        subtitle.text = "原件同时保存在本机和 MyNAS。"
        subtitle.font = .preferredFont(forTextStyle: .caption2)
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 0
        let labels = UIStackView(arrangedSubviews: [title, subtitle])
        labels.axis = .vertical
        labels.spacing = 2
        let row = UIStackView(arrangedSubviews: [icon, labels])
        row.alignment = .top
        row.spacing = 8
        let surface = UIView()
        surface.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.12)
        surface.layer.cornerCurve = .continuous
        surface.layer.cornerRadius = 13
        row.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(row)
        NSLayoutConstraint.activate(pin(row, to: surface, inset: 12))
        return surface
    }

    private func makeLocalCandidateNotice() -> UIView {
        let candidateCount = RemotePhotoLocalCopyVerification.candidates(
            for: asset,
            in: localAssets
        ).count
        let icon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        icon.tintColor = .systemBlue
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let title = UILabel()
        title.text = "发现 \(candidateCount) 个本机候选原件"
        title.font = preferredFont(.footnote, weight: .semibold)
        let subtitle = UILabel()
        subtitle.text = "正在后台比对完整资源的角色、大小和 SHA-256；无需逐项操作。"
        subtitle.font = .preferredFont(forTextStyle: .caption2)
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 0
        let labels = UIStackView(arrangedSubviews: [title, subtitle])
        labels.axis = .vertical
        labels.spacing = 2
        let row = UIStackView(arrangedSubviews: [icon, labels])
        row.alignment = .top
        row.spacing = 8
        let surface = UIView()
        surface.backgroundColor = .secondarySystemFill
        surface.layer.cornerCurve = .continuous
        surface.layer.cornerRadius = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(row)
        NSLayoutConstraint.activate(pin(row, to: surface, inset: 11))
        return surface
    }

    private func makeDownloadProgress() -> UIView {
        downloadProgressContainer.backgroundColor = .secondarySystemFill
        downloadProgressContainer.layer.cornerCurve = .continuous
        downloadProgressContainer.layer.cornerRadius = 13
        downloadProgressContainer.isHidden = true

        downloadProgressLabel.font = .preferredFont(forTextStyle: .caption1)
        downloadProgressLabel.textColor = .secondaryLabel
        downloadProgressLabel.numberOfLines = 2

        downloadProgressView.progressTintColor = .systemBlue
        downloadProgressView.trackTintColor = .tertiarySystemFill

        let stack = UIStackView(arrangedSubviews: [downloadProgressLabel, downloadProgressView])
        stack.axis = .vertical
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        downloadProgressContainer.addSubview(stack)
        NSLayoutConstraint.activate(pin(stack, to: downloadProgressContainer, inset: 12))
        return downloadProgressContainer
    }

    private enum ActionStyle { case primary, secondary, destructive }

    private func configureButton(
        _ button: UIButton,
        title: String,
        image: String,
        style: ActionStyle,
        action: Selector
    ) {
        var configuration = style == .primary ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        configuration.title = title
        configuration.image = UIImage(systemName: image)
        configuration.imagePadding = 8
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 18, bottom: 13, trailing: 18)
        if style == .destructive {
            configuration.baseForegroundColor = .systemRed
            configuration.baseBackgroundColor = .systemRed
        }
        button.configuration = configuration
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private var canAssociateLocalCopy: Bool {
        onVerifiedLocalCopies != nil
            && !RemotePhotoLocalCopyVerification.candidates(
                for: asset,
                in: localAssets
            ).isEmpty
    }

    private var hasConfirmedLocalCopy: Bool {
        if automaticallyVerifiedLocalCopy { return true }
        guard let confirmedLocalCopy else { return false }
        return localClient.hasAccessibleAsset(localIdentifier: confirmedLocalCopy.localIdentifier)
    }

    private var formattedCaptureDate: String? {
        guard let captureDate = asset.captureDate else { return nil }
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: captureDate) else { return captureDate }
        return date.formatted(date: .long, time: .shortened)
    }

    private func pin(_ child: UIView, to parent: UIView, inset: CGFloat) -> [NSLayoutConstraint] {
        [
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ]
    }

    private func preferredFont(_ textStyle: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
        let preferred = UIFont.preferredFont(forTextStyle: textStyle)
        return UIFont.systemFont(ofSize: preferred.pointSize, weight: weight)
    }

    @objc private func close() {
        onDismiss()
    }

    @objc private func applicationDidBecomeActive() {
        refreshRemoteMutationAvailability()
    }

    private func refreshRemoteMutationAvailability() {
        connectionRefreshTask?.cancel()
        remoteMutationAvailability = .checking
        connectionRefreshTask = Task { [weak self, account, remoteMutationPreflight] in
            let availability = await remoteMutationPreflight.availability(for: account)
            guard !Task.isCancelled, let self else { return }
            self.remoteMutationAvailability = availability
        }
    }

    private func confirmRemoteMutationAvailability() async -> Bool {
        let availability = await remoteMutationPreflight.availability(for: account)
        guard !Task.isCancelled else { return false }
        remoteMutationAvailability = availability
        guard availability.allowsRemoteMutation else {
            showMessage(MyNASRemoteMutationPreflightError.tailscaleUnavailable.localizedDescription)
            return false
        }
        return true
    }

    @objc private func loadPreview() {
        guard !isLoadingPreview else { return }
        hasRequestedPreview = true
        guard let kind = previewKind else {
            previewButton.isHidden = true
            return
        }
        isLoadingPreview = true
        previewButton.isHidden = true
        previewButton.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await client.image(for: asset, kind: kind, account: account)
                guard !Task.isCancelled else { return }
                let image = await RemotePreviewImageDecoder.decode(result.data, maximumPixelSize: 1_920)
                guard !Task.isCancelled else { return }
                if let image {
                    imageView.preferredSymbolConfiguration = nil
                    imageView.contentMode = .scaleAspectFit
                    imageView.image = image
                    updatePreviewAspectRatio(for: image)
                } else {
                    showPreviewPlaceholder(systemName: "exclamationmark.icloud")
                }
                previewButton.isHidden = image != nil
                if image == nil {
                    previewButton.setTitle("预览无法显示，点按重试", for: .normal)
                    previewButton.isEnabled = true
                }
            } catch {
                previewButton.setTitle("预览加载失败，点按重试", for: .normal)
                previewButton.isHidden = false
                previewButton.isEnabled = true
            }
            isLoadingPreview = false
        }
    }

    private func showPreviewPlaceholder(systemName: String) {
        imageView.contentMode = .center
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 28,
            weight: .regular
        )
        imageView.image = UIImage(systemName: systemName)
    }

    private func makePreviewAspectConstraint(ratio: CGFloat) -> NSLayoutConstraint {
        let constraint = previewContainer.widthAnchor.constraint(
            equalTo: previewContainer.heightAnchor,
            multiplier: ratio
        )
        constraint.priority = .defaultHigh
        return constraint
    }

    /// The thumbnail decoder may apply orientation transforms that were not
    /// present in the source metadata. Replacing the high-priority ratio keeps
    /// the full preview visible instead of creating a tall white letterbox.
    private func updatePreviewAspectRatio(for image: UIImage) {
        let width = Int((image.size.width * image.scale).rounded())
        let height = Int((image.size.height * image.scale).rounded())
        let ratio = RemotePreviewLayout.aspectRatio(
            preferredWidth: width,
            preferredHeight: height,
            fallbackWidth: asset.pixelWidth,
            fallbackHeight: asset.pixelHeight
        )
        guard abs(previewAspectRatio - ratio) > 0.001 else { return }
        previewAspectConstraint?.isActive = false
        let constraint = makePreviewAspectConstraint(ratio: ratio)
        previewAspectConstraint = constraint
        previewAspectRatio = ratio
        constraint.isActive = true
        view.setNeedsLayout()
    }

    private var previewKind: String? {
        if asset.derivative("preview") != nil { return "preview" }
        if asset.derivative("grid") != nil { return "grid" }
        return asset.derivatives.first?.kind
    }

    @objc private func startRemotePlayback() {
        guard !isPreparingPlayback, player == nil else { return }
        let resource = asset.mediaType == .livePhoto
            ? asset.pairedVideoResource
            : asset.videoResource
        guard let resource else {
            updatePlaybackButton(title: "远端视频资源不可用", showsActivity: false)
            playbackButton.isHidden = false
            playbackButton.isEnabled = false
            return
        }

        isPreparingPlayback = true
        playbackButton.isHidden = false
        playbackButton.isEnabled = false
        updatePlaybackButton(
            title: asset.mediaType == .livePhoto ? "正在加载实况…" : "正在流式加载…",
            showsActivity: true
        )
        Task { [weak self] in
            guard let self else { return }
            defer { isPreparingPlayback = false }
            do {
                let sourceURL = try await client.streamingURL(
                    for: resource,
                    in: asset,
                    account: account
                )
                let loader = MyNASMediaResourceLoader(
                    sourceURL: sourceURL,
                    resource: resource,
                    asset: asset,
                    account: account,
                    client: client
                )
                let urlAsset = try loader.makeAsset()
                guard !Task.isCancelled else {
                    loader.invalidate()
                    return
                }

                let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: urlAsset))
                let playerController = AVPlayerViewController()
                playerController.player = newPlayer
                playerController.showsPlaybackControls = true
                playerController.videoGravity = .resizeAspect
                addChild(playerController)
                playerController.view.translatesAutoresizingMaskIntoConstraints = false
                previewContainer.addSubview(playerController.view)
                NSLayoutConstraint.activate(pin(playerController.view, to: previewContainer, inset: 0))
                playerController.didMove(toParent: self)

                mediaResourceLoader = loader
                player = newPlayer
                playerViewController = playerController
                playbackButton.isHidden = true
                newPlayer.play()
            } catch {
                guard !Task.isCancelled else { return }
                playbackButton.isHidden = false
                playbackButton.isEnabled = true
                updatePlaybackButton(
                    title: asset.mediaType == .livePhoto ? "重试播放实况" : "重试播放视频",
                    showsActivity: false
                )
            }
        }
    }

    private func updatePlaybackButton(title: String, showsActivity: Bool) {
        var configuration = playbackButton.configuration
        configuration?.title = title
        configuration?.showsActivityIndicator = showsActivity
        playbackButton.configuration = configuration
    }

    private func stopRemotePlayback() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerViewController?.willMove(toParent: nil)
        playerViewController?.view.removeFromSuperview()
        playerViewController?.removeFromParent()
        playerViewController = nil
        mediaResourceLoader?.invalidate()
        mediaResourceLoader = nil
    }

    /// Candidate type and dimensions only constrain PhotoKit work. A candidate
    /// becomes eligible for association exclusively after all original
    /// resources have matching roles, byte counts, and SHA-256 values.
    private func verifyAndAssociateLocalCopy(presentsResult: Bool) {
        guard !isPerformingAction,
              let onVerifiedLocalCopies else {
            return
        }
        let candidates = RemotePhotoLocalCopyVerification.candidates(
            for: asset,
            in: localAssets
        )
        guard !candidates.isEmpty else {
            automaticVerificationCompleted = true
            return
        }

        isPerformingAction = true
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isPerformingAction = false
                self.restoreAssociationButtonTitle()
                self.updateDownloadButton(
                    title: self.restingDownloadButtonTitle,
                    showsActivity: false
                )
            }
            do {
                var matchedCandidates: [LocalPhotoAsset] = []
                for (index, candidate) in candidates.enumerated() {
                    guard !Task.isCancelled else { return }
                    updateAssociationButtonTitle(
                        "正在核验本机原件 \(index + 1) / \(candidates.count)…"
                    )
                    let prepared = try await localClient.prepareBackupAsset(candidate)
                    defer { prepared.removeTemporaryFiles() }
                    guard RemotePhotoLocalCopyVerification.hasSameCompleteResourceGroup(
                        localResources: prepared.resources,
                        remoteResources: asset.resources
                    ) else {
                        continue
                    }
                    matchedCandidates.append(candidate)
                }
                guard !matchedCandidates.isEmpty else {
                    automaticVerificationCompleted = true
                    automaticallyVerifiedLocalCopy = false
                    if presentsResult {
                        showMessage("没有找到资源角色、大小和 SHA-256 均一致的本机原件，因此没有建立关联。")
                    }
                    return
                }

                automaticVerificationCompleted = true
                automaticallyVerifiedLocalCopy = true
                switch onVerifiedLocalCopies(asset, matchedCandidates) {
                case .started:
                    showDownloadCompletionToast("已自动核验；正在关联本机原件")
                case .alreadyAssociated:
                    if presentsResult {
                        showDownloadCompletionToast("本机原件已经自动关联")
                    }
                case .unavailable(let reason):
                    if presentsResult {
                        showMessage("已确认原件一致，但暂时无法登记：\n\n\(reason)")
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                automaticVerificationCompleted = false
                if presentsResult {
                    showMessage("核验本机原件未完成：\n\n\(error.localizedDescription)")
                }
            }
        }
    }

    private func updateAssociationButtonTitle(_ title: String) {
        var configuration = associateButton.configuration
        configuration?.title = title
        configuration?.showsActivityIndicator = true
        associateButton.configuration = configuration
    }

    private func restoreAssociationButtonTitle() {
        var configuration = associateButton.configuration
        configuration?.title = "核验并关联本机原件"
        configuration?.showsActivityIndicator = false
        associateButton.configuration = configuration
    }

    private func beginDownloadProgress() {
        downloadProgressContainer.isHidden = false
        downloadProgressView.progress = 0
        downloadProgressLabel.text = "正在准备下载原件…"
        updateDownloadButton(title: "正在下载原件…", showsActivity: true)
    }

    private func updateDownloadProgress(_ progress: RemotePhotoDownloadProgress) {
        downloadProgressContainer.isHidden = false
        downloadProgressView.setProgress(Float(progress.fractionCompleted), animated: true)
        let completed = ByteCountFormatter.string(
            fromByteCount: progress.completedByteCount,
            countStyle: .file
        )
        let total = ByteCountFormatter.string(
            fromByteCount: progress.totalByteCount,
            countStyle: .file
        )
        downloadProgressLabel.text = "正在下载 \(progress.resourceIndex + 1) / \(progress.resourceCount) · \(completed) / \(total)"
    }

    private func showImportProgress() {
        downloadProgressContainer.isHidden = false
        downloadProgressView.setProgress(1, animated: true)
        downloadProgressLabel.text = "原件已核验，正在导入系统照片…"
        updateDownloadButton(title: "正在导入系统照片…", showsActivity: true)
    }

    private func finishDownloadProgress() {
        downloadProgressContainer.isHidden = true
        updateDownloadButton(
            title: restingDownloadButtonTitle,
            showsActivity: false
        )
    }

    private var restingDownloadButtonTitle: String {
        if canAssociateLocalCopy && !automaticVerificationCompleted {
            return "正在自动核验本机原件…"
        }
        return "下载并导入原件"
    }

    private func updateDownloadButton(title: String, showsActivity: Bool) {
        var configuration = downloadButton.configuration
        configuration?.title = title
        configuration?.showsActivityIndicator = showsActivity
        downloadButton.configuration = configuration
    }

    private func showDownloadCompletionToast(_ message: String) {
        completionToast?.removeFromSuperview()

        let toast = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        toast.layer.cornerCurve = .continuous
        toast.layer.cornerRadius = 18
        toast.clipsToBounds = true

        let icon = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        icon.tintColor = .systemGreen
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        let label = UILabel()
        label.text = message
        label.font = preferredFont(.subheadline, weight: .semibold)
        label.numberOfLines = 2
        let content = UIStackView(arrangedSubviews: [icon, label])
        content.alignment = .center
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        toast.contentView.addSubview(content)
        NSLayoutConstraint.activate(pin(content, to: toast.contentView, inset: 13))

        view.addSubview(toast)
        toast.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 22),
            toast.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -22),
            toast.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
        completionToast = toast
        toast.alpha = 0
        toast.transform = CGAffineTransform(translationX: 0, y: 12)
        UIView.animate(withDuration: 0.2) {
            toast.alpha = 1
            toast.transform = .identity
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self, weak toast] in
            guard let self, let toast, self.completionToast === toast else { return }
            UIView.animate(withDuration: 0.18, animations: {
                toast.alpha = 0
                toast.transform = CGAffineTransform(translationX: 0, y: 8)
            }, completion: { _ in
                toast.removeFromSuperview()
                if self.completionToast === toast {
                    self.completionToast = nil
                }
            })
        }
    }

    @objc private func downloadOriginals() {
        guard !isPerformingAction else { return }
        guard RemotePhotoDownloadPolicy.offersOriginalDownload(
            hasConfirmedLocalCopy: hasConfirmedLocalCopy
        ) else { return }
        if canAssociateLocalCopy && !automaticVerificationCompleted {
            verifyAndAssociateLocalCopy(presentsResult: false)
            return
        }
        isPerformingAction = true
        Task { [weak self] in
            guard let self else { return }
            defer { isPerformingAction = false }
            do {
                let mapping = try await client.fetchDeviceAssetMapping(
                    account: account,
                    deviceID: PhotoBackupDeviceIdentity.currentID(),
                    assetID: asset.id
                )
                guard !Task.isCancelled else { return }
                if let mapping,
                   localClient.hasAccessibleAsset(localIdentifier: mapping.localIdentifier) {
                    automaticallyVerifiedLocalCopy = true
                    updateActionAvailability()
                    showDownloadCompletionToast("本机已有同一原件")
                } else {
                    await downloadOriginalsToPhotos(alreadyPerformingAction: true)
                }
            } catch let error as RemotePhotoLibraryError
                where error.permitsDownloadWithoutDeviceMappingCheck {
                // The mapping endpoint is optional. Downloading still has its
                // own same-origin, byte-count, and SHA-256 checks.
                await downloadOriginalsToPhotos(alreadyPerformingAction: true)
            } catch {
                showMessage("下载未开始：\n\n\(error.localizedDescription)")
            }
        }
    }

    /// H2 export intentionally shares the byte-for-byte verified originals
    /// from the H1 download path. A preview, an unverified cache hit, or a
    /// remote URL is never handed to the system share sheet.
    @objc private func exportOriginals() {
        guard !isPerformingAction, activeExportDownload == nil else { return }
        Task { [weak self] in
            await self?.exportVerifiedOriginals()
        }
    }

    private func exportVerifiedOriginals() async {
        guard !isPerformingAction, activeExportDownload == nil else { return }
        isPerformingAction = true
        beginDownloadProgress()
        defer { isPerformingAction = false }

        do {
            let download = try await client.downloadOriginalResources(
                for: asset,
                account: account
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.updateDownloadProgress(progress)
                }
            }
            guard !Task.isCancelled else {
                download.removeTemporaryFiles()
                return
            }
            finishDownloadProgress()
            activeExportDownload = download
            updateActionAvailability()

            let activity = UIActivityViewController(
                activityItems: download.resources.map(\.fileURL),
                applicationActivities: nil
            )
            activity.completionWithItemsHandler = { [weak self, download] _, didComplete, _, _ in
                download.removeTemporaryFiles()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.activeExportDownload = nil
                    self.updateActionAvailability()
                    if didComplete {
                        self.showDownloadCompletionToast("已将 \(download.resources.count) 个原件交给系统分享")
                    }
                }
            }
            present(activity, animated: true)
        } catch {
            finishDownloadProgress()
            guard !Task.isCancelled else { return }
            showMessage("导出未完成：\n\n\(error.localizedDescription)")
        }
    }

    private func downloadOriginalsToPhotos(alreadyPerformingAction: Bool = false) async {
        guard alreadyPerformingAction || !isPerformingAction else { return }
        if !alreadyPerformingAction {
            isPerformingAction = true
        }
        defer {
            if !alreadyPerformingAction {
                isPerformingAction = false
            }
        }
        beginDownloadProgress()
        do {
            let download = try await client.downloadOriginalResources(
                for: asset,
                account: account
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.updateDownloadProgress(progress)
                }
            }
            defer { download.removeTemporaryFiles() }
            showImportProgress()
            let importedLocalIdentifier = try await localClient.importDownloadedRemoteResources(download.resources)
            finishDownloadProgress()
            guard !Task.isCancelled else { return }
            let associationResult = await registerImportedLocalCopy(
                localIdentifier: importedLocalIdentifier
            )
            guard let associationResult else {
                showDownloadCompletionToast("已导入 \(download.resources.count) 个 MyNAS 原件资源")
                return
            }
            switch associationResult {
            case .started:
                showDownloadCompletionToast("已导入原件，正在登记当前 iPhone")
            case .alreadyAssociated:
                showDownloadCompletionToast("已导入原件并确认本机关联")
            case .unavailable:
                showDownloadCompletionToast("已导入 \(download.resources.count) 个 MyNAS 原件资源")
            }
        } catch {
            finishDownloadProgress()
            guard !Task.isCancelled else { return }
            showMessage("下载或导入未完成：\n\n\(error.localizedDescription)")
        }
    }

    /// A newly imported asset is already proven against the downloaded MyNAS
    /// resources. Register its device mapping immediately so it cannot appear
    /// as a fresh, unrelated “需要备份” item after this screen closes.
    private func registerImportedLocalCopy(
        localIdentifier: String?
    ) async -> PhotoBackupVerifiedLocalAssociationResult? {
        guard let localIdentifier,
              let onVerifiedLocalCopies else {
            return nil
        }
        // PhotoKit can publish the creation placeholder before a subsequent
        // PHAsset fetch sees it, especially while photolibraryd is reconciling
        // an iCloud library. Keep the exact placeholder identity alive long
        // enough to persist the association instead of silently dropping it.
        for attempt in 0..<60 {
            if let importedLocalAsset = localClient.accessibleAsset(
                localIdentifier: localIdentifier
            ) {
                return onVerifiedLocalCopies(asset, [importedLocalAsset])
            }
            guard attempt < 59 else { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    @objc private func prepareRemoteDeletion() {
        guard !isPerformingAction, remoteMutationAvailability.allowsRemoteMutation else {
            if remoteMutationAvailability == .tailscaleUnavailable {
                showMessage(MyNASRemoteMutationPreflightError.tailscaleUnavailable.localizedDescription)
            }
            return
        }
        isPerformingAction = true
        Task { [weak self] in
            guard let self else { return }
            defer { isPerformingAction = false }
            guard await confirmRemoteMutationAvailability() else { return }
            do {
                let mapping = try await client.fetchDeviceAssetMapping(
                    account: account,
                    deviceID: PhotoBackupDeviceIdentity.currentID(),
                    assetID: asset.id
                )
                guard !Task.isCancelled else { return }
                let candidate = mapping.flatMap { mapping -> PhotoBackupDeletionCandidate? in
                    guard mapping.sourceState == PhotoSourceState.committed.rawValue,
                          let sourceModificationDate = mapping.sourceModificationDate,
                          !sourceModificationDate.isEmpty,
                          self.localClient.hasAccessibleAsset(localIdentifier: mapping.localIdentifier) else {
                        return nil
                    }
                    return PhotoBackupDeletionCandidate(
                        assetID: self.asset.id,
                        deviceID: PhotoBackupDeviceIdentity.currentID(),
                        localIdentifier: mapping.localIdentifier,
                        sourceModificationDate: sourceModificationDate
                    )
                }
                presentDeleteConfirmation(candidate: candidate)
            } catch {
                presentDeleteConfirmation(candidate: nil)
            }
        }
    }

    private func presentDeleteConfirmation(candidate: PhotoBackupDeletionCandidate?) {
        let connectedMessage = candidate == nil
            ? "这会永久删除 MyNAS 项目；本机照片不会被删除。"
            : "可仅删除 MyNAS，或同时将已验证的本机原件移入系统“最近删除”。"
        let alert = UIAlertController(
            title: "选择删除范围",
            message: connectedMessage,
            preferredStyle: .actionSheet
        )
        if let candidate {
            alert.addAction(UIAlertAction(title: "同时删除本机照片", style: .default) { [weak self] _ in
                self?.activeDeletionAlert = nil
                self?.presentFinalPairedDeletionConfirmation(candidate: candidate)
            })
        }
        alert.addAction(UIAlertAction(title: "仅删除 MyNAS 项目", style: .default) { [weak self] _ in
            self?.activeDeletionAlert = nil
            self?.presentFinalMyNASDeletionConfirmation()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.activeDeletionAlert = nil
        })
        if let popover = alert.popoverPresentationController {
            popover.sourceView = deleteButton
            popover.sourceRect = deleteButton.bounds
        }
        trackDeletionAlert(alert, connectedMessage: connectedMessage)
        present(alert, animated: true)
    }

    /// Scope selection is deliberately non-destructive. A separate alert is
    /// required before the first permanent remote mutation, preventing a
    /// delayed second tap from both choosing a scope and executing deletion.
    private func presentFinalMyNASDeletionConfirmation() {
        let connectedMessage = "MyNAS 中的原件、预览和备份记录将永久删除，不能撤销。本机照片不会被删除。"
        let alert = UIAlertController(
            title: "永久删除 MyNAS 项目？",
            message: connectedMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "永久删除 MyNAS 项目", style: .destructive) { [weak self] _ in
            guard let self else { return }
            activeDeletionAlert = nil
            Task { await self.deleteRemoteAsset() }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.activeDeletionAlert = nil
        })
        trackDeletionAlert(alert, connectedMessage: connectedMessage)
        present(alert, animated: true)
    }

    private func presentFinalPairedDeletionConfirmation(
        candidate: PhotoBackupDeletionCandidate
    ) {
        let connectedMessage = "本机照片会先移入系统“最近删除”，随后 MyNAS 原件会被永久删除。请确认这是你要删除的项目。"
        let alert = UIAlertController(
            title: "同时删除本机与 MyNAS？",
            message: connectedMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "继续删除", style: .destructive) { [weak self] _ in
            guard let self else { return }
            activeDeletionAlert = nil
            Task { await self.deleteLocalAndRemoteAsset(candidate) }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.activeDeletionAlert = nil
        })
        trackDeletionAlert(alert, connectedMessage: connectedMessage)
        present(alert, animated: true)
    }

    private func deleteRemoteAsset() async {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        guard await confirmRemoteMutationAvailability() else { return }
        do {
            let result = try await client.deleteRemoteAsset(asset, account: account)
            guard !Task.isCancelled else { return }
            onRemoteDeleted(result.assetID, .retained)
            onDismiss()
        } catch {
            guard !Task.isCancelled else { return }
            showMessage("MyNAS 未删除该项目：\n\n\(error.localizedDescription)")
        }
    }

    private func deleteLocalAndRemoteAsset(_ candidate: PhotoBackupDeletionCandidate) async {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        // Recheck before PhotoKit changes anything. If Tailscale dropped while
        // the confirmation alert was open, neither the local nor remote copy
        // is deleted.
        guard await confirmRemoteMutationAvailability() else { return }
        do {
            try await localClient.deleteAssets(localIdentifiers: [candidate.localIdentifier])
            let result = try await client.deleteBackups(candidates: [candidate], account: account)
            guard result.items.count == 1, result.items[0].assetID == asset.id else {
                throw RemotePhotoLibraryError.invalidResponse
            }
            guard !Task.isCancelled else { return }
            onRemoteDeleted(asset.id, .movedToRecentlyDeleted)
            onDismiss()
        } catch {
            guard !Task.isCancelled else { return }
            showMessage("删除未完成：\n\n\(error.localizedDescription)")
        }
    }

    private func updateActionAvailability() {
        downloadButton.isHidden = !RemotePhotoDownloadPolicy.offersOriginalDownload(
            hasConfirmedLocalCopy: hasConfirmedLocalCopy
        )
        downloadButton.isEnabled = !isPerformingAction
        exportButton.isEnabled = !isPerformingAction && activeExportDownload == nil
        associateButton.isEnabled = !isPerformingAction
        deleteButton.isEnabled = !isPerformingAction
            && remoteMutationAvailability.allowsRemoteMutation
    }

    private func showMessage(_ message: String) {
        let alert = UIAlertController(title: "MyNAS 图库", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}
