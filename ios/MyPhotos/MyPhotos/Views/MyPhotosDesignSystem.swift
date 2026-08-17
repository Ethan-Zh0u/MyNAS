import SwiftUI

enum MyPhotosMetrics {
    static let minimumTouchTarget: CGFloat = 44
    static let compactSpacing: CGFloat = 8
    static let standardSpacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 16
    static let contentInset: CGFloat = 18
    static let compactCornerRadius: CGFloat = 12
    static let standardCornerRadius: CGFloat = 14
}

enum MyPhotosStatusTone {
    case accent
    case success
    case warning
    case danger
    case neutral

    var color: Color {
        switch self {
        case .accent: .accentColor
        case .success: .green
        case .warning: .orange
        case .danger: .red
        case .neutral: .secondary
        }
    }
}

struct MyPhotosStatusBadge: View {
    let title: String
    let systemImage: String
    let tone: MyPhotosStatusTone

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tone.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tone.color.opacity(0.11), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

struct MyPhotosInlineNotice: View {
    let title: String
    let message: String
    let systemImage: String
    let tone: MyPhotosStatusTone

    var body: some View {
        HStack(alignment: .top, spacing: MyPhotosMetrics.standardSpacing) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(tone.color)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(MyPhotosMetrics.standardSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            tone.color.opacity(0.09),
            in: RoundedRectangle(
                cornerRadius: MyPhotosMetrics.standardCornerRadius,
                style: .continuous
            )
        )
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func myPhotosMinimumTouchTarget() -> some View {
        frame(minHeight: MyPhotosMetrics.minimumTouchTarget)
    }
}
