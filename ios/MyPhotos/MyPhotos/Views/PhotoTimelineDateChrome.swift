import SwiftUI

/// A chronological section that preserves the order supplied by the timeline.
/// Items with no trustworthy capture date are deliberately kept separate rather
/// than being assigned a guessed year.
struct PhotoTimelineYearSection<Item: Identifiable>: Identifiable {
    let year: Int?
    let items: [Item]

    var id: String {
        year.map { "year-\($0)" } ?? "year-unknown"
    }

    static func make(
        items: [Item],
        date: (Item) -> Date?
    ) -> [PhotoTimelineYearSection<Item>] {
        let calendar = Calendar.autoupdatingCurrent
        let groups = Dictionary(grouping: items) { item -> Int? in
            date(item).map { calendar.component(.year, from: $0) }
        }

        var sections = groups.keys
            .compactMap { $0 }
            .sorted(by: >)
            .compactMap { year in
                groups[year].map { PhotoTimelineYearSection(year: year, items: $0) }
            }

        let unknownYear: Int? = nil
        if let unknownItems = groups[unknownYear], !unknownItems.isEmpty {
            sections.append(PhotoTimelineYearSection(year: nil, items: unknownItems))
        }
        return sections
    }
}

/// A sectioned square photo grid shared by the local and unified timelines.
/// The anchor on every materialised cell lets the enclosing scroll view derive
/// the date range from the photos that are actually on screen.
struct PhotoTimelineYearGroupedGrid<Item: Identifiable, Cell: View>: View {
    let sections: [PhotoTimelineYearSection<Item>]
    let columns: [GridItem]
    let spacing: CGFloat
    let date: (Item) -> Date?
    let lastItemID: Item.ID?
    let onLastItemAppear: () -> Void
    private let cell: (Item) -> Cell

    init(
        sections: [PhotoTimelineYearSection<Item>],
        columns: [GridItem],
        spacing: CGFloat,
        date: @escaping (Item) -> Date?,
        lastItemID: Item.ID?,
        onLastItemAppear: @escaping () -> Void = {},
        @ViewBuilder cell: @escaping (Item) -> Cell
    ) {
        self.sections = sections
        self.columns = columns
        self.spacing = spacing
        self.date = date
        self.lastItemID = lastItemID
        self.onLastItemAppear = onLastItemAppear
        self.cell = cell
    }

    var body: some View {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(sections) { section in
                Section {
                    LazyVGrid(columns: columns, spacing: spacing) {
                        ForEach(section.items) { item in
                            cell(item)
                                .photoTimelineDateAnchor(date: date(item))
                                .onAppear {
                                    if item.id == lastItemID {
                                        onLastItemAppear()
                                    }
                                }
                        }
                    }
                    .padding(.bottom, spacing)
                } header: {
                    PhotoTimelineYearHeader(year: section.year)
                }
            }
        }
        .padding(.horizontal, spacing)
    }
}

struct PhotoTimelineVisibleDateOverlay: View {
    let anchors: [PhotoTimelineDateAnchor]

    var body: some View {
        GeometryReader { proxy in
            let viewport = proxy.frame(in: .local)
            let visible = anchors.compactMap { anchor -> (date: Date, frame: CGRect)? in
                let frame = proxy[anchor.bounds]
                guard frame.intersects(viewport) else { return nil }
                return (anchor.date, frame)
            }

            if let oldest = visible.map(\.date).min(),
               let newest = visible.map(\.date).max() {
                PhotoTimelineVisibleDateBadge(oldest: oldest, newest: newest)
                    .padding(.leading, 12)
                    .padding(.top, max(10, visible.map(\.frame.minY).min() ?? 10))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct PhotoTimelineYearHeader: View {
    let year: Int?

    private var title: String {
        guard let year else { return "日期未知" }
        return String(year) + "年"
    }

    var body: some View {
        HStack {
            Text(verbatim: title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .timelineDateChromeSurface(cornerRadius: 0)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct PhotoTimelineVisibleDateBadge: View {
    let oldest: Date
    let newest: Date

    private var isSingleMonth: Bool {
        Calendar.autoupdatingCurrent.isDate(oldest, equalTo: newest, toGranularity: .month)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(monthText(oldest))
                .font(.caption.weight(.semibold))
            if !isSingleMonth {
                Label(monthText(newest), systemImage: "arrow.down")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .timelineDateChromeSurface(cornerRadius: 15)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if isSingleMonth {
            return "当前可见照片拍摄于\(monthText(oldest))"
        }
        return "当前可见照片最早为\(monthText(oldest))，最新为\(monthText(newest))"
    }

    private func monthText(_ date: Date) -> String {
        Self.monthFormatter.string(from: date)
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy年M月"
        return formatter
    }()
}

struct PhotoTimelineDateAnchor {
    let date: Date
    let bounds: Anchor<CGRect>
}

struct PhotoTimelineDateAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: [PhotoTimelineDateAnchor] = []

    static func reduce(
        value: inout [PhotoTimelineDateAnchor],
        nextValue: () -> [PhotoTimelineDateAnchor]
    ) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    @ViewBuilder
    func photoTimelineDateAnchor(date: Date?) -> some View {
        if let date {
            anchorPreference(key: PhotoTimelineDateAnchorPreferenceKey.self, value: .bounds) { bounds in
                [PhotoTimelineDateAnchor(date: date, bounds: bounds)]
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func timelineDateChromeSurface(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }
}
