import SwiftUI
import UIKit

private func encounterCapsuleShape(for size: DynamicTypeSize) -> AnyShape {
    size.isAccessibilitySize ? AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous)) : AnyShape(Capsule())
}

/// Semantic colours shared by every Encounter screen. UIKit tokens retain trait resolution.
public enum EncounterPalette {
    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    private static func dynamic(_ light: UInt32, dark: UInt32,
                                highLight: UInt32? = nil, highDark: UInt32? = nil) -> UIColor {
        UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let normal = isDark ? dark : light
            let high = isDark ? highDark : highLight
            return rgb(traits.accessibilityContrast == .high ? high ?? normal : normal)
        }
    }

    public static let accentUIColor = dynamic(0x13777B, dark: 0x5CC8C2, highLight: 0x0B6064, highDark: 0x87E3DD)
    public static let onAccentUIColor = dynamic(0xFFFFFF, dark: 0x04201F)
    // Darkened so systemRed text also reaches 4.5:1 on this fill.
    public static let accentSoftUIColor = dynamic(0xE3F3F2, dark: 0x0C2524)
    public static let inkUIColor = UIColor {
        $0.userInterfaceStyle == .dark ? UIColor.label.resolvedColor(with: $0) : rgb(0x0E1A2B)
    }
    public static let inkSecondaryUIColor = UIColor {
        if $0.userInterfaceStyle == .dark { return UIColor.secondaryLabel.resolvedColor(with: $0) }
        return rgb($0.accessibilityContrast == .high ? 0x414B5B : 0x5B6576)
    }
    public static let backgroundUIColor = UIColor {
        $0.userInterfaceStyle == .dark ? UIColor.systemGroupedBackground.resolvedColor(with: $0) : rgb(0xF6F8F9)
    }
    public static let surfaceUIColor = UIColor {
        $0.userInterfaceStyle == .dark ? UIColor.secondarySystemGroupedBackground.resolvedColor(with: $0) : .white
    }
    public static let borderUIColor = UIColor { $0.userInterfaceStyle == .dark ? .white.withAlphaComponent(0.12) : rgb(0xE3E7EC) }
    public static let controlOutlineUIColor = dynamic(0x7B8494, dark: 0x8E98A8, highLight: 0x5B6576, highDark: 0xC2CAD7)
    public static let neutralFillUIColor = UIColor {
        $0.userInterfaceStyle == .dark ? UIColor.tertiarySystemFill.resolvedColor(with: $0) : rgb(0xEEF1F4)
    }
    public static let warningFillUIColor = dynamic(0xFFF5E6, dark: 0x3A2A10)
    public static let warningIconUIColor = dynamic(0xB26B00, dark: 0xF2B544)
    public static let ambientTextUIColor = dynamic(0x2457C5, dark: 0xA9C5FF)
    public static let ambientFillUIColor = dynamic(0xE7EEFC, dark: 0x172D55)
    public static let sessionTextUIColor = dynamic(0x6B3FC4, dark: 0xD3B8FF)
    public static let sessionFillUIColor = dynamic(0xF0EAFC, dark: 0x33234F)
    public static let destructiveUIColor = UIColor {
        if $0.userInterfaceStyle == .dark { return UIColor.systemRed.resolvedColor(with: $0) }
        return rgb($0.accessibilityContrast == .high ? 0xA01818 : 0xC62828)
    }

    public static let accent = Color(uiColor: accentUIColor)
    public static let onAccent = Color(uiColor: onAccentUIColor)
    public static let accentSoft = Color(uiColor: accentSoftUIColor)
    public static let ink = Color(uiColor: inkUIColor)
    public static let inkSecondary = Color(uiColor: inkSecondaryUIColor)
    public static let background = Color(uiColor: backgroundUIColor)
    public static let surface = Color(uiColor: surfaceUIColor)
    public static let border = Color(uiColor: borderUIColor)
    public static let controlOutline = Color(uiColor: controlOutlineUIColor)
    public static let neutralFill = Color(uiColor: neutralFillUIColor)
    public static let warningFill = Color(uiColor: warningFillUIColor)
    public static let warningIcon = Color(uiColor: warningIconUIColor)
    public static let ambientText = Color(uiColor: ambientTextUIColor)
    public static let ambientFill = Color(uiColor: ambientFillUIColor)
    public static let sessionText = Color(uiColor: sessionTextUIColor)
    public static let sessionFill = Color(uiColor: sessionFillUIColor)
    public static let destructive = Color(uiColor: destructiveUIColor)
}

@MainActor
public struct EncounterScreen<Content: View>: View {
    public enum HeaderAlignment { case leading, centered }

    private let title: String?
    private let subtitle: String?
    private let alignment: HeaderAlignment
    private let backLabel: String?
    private let backDisabled: Bool
    private let onBack: (@MainActor () -> Void)?
    private let content: Content
    private let bottomBar: AnyView?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(title: String? = nil, subtitle: String? = nil,
                alignment: HeaderAlignment = .leading, backLabel: String? = nil,
                backDisabled: Bool = false, onBack: (@MainActor () -> Void)? = nil,
                @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.alignment = alignment
        self.backLabel = backLabel; self.backDisabled = backDisabled; self.onBack = onBack
        self.content = content(); bottomBar = nil
    }

    public init<BottomBar: View>(title: String? = nil, subtitle: String? = nil,
                alignment: HeaderAlignment = .leading, backLabel: String? = nil,
                backDisabled: Bool = false, onBack: (@MainActor () -> Void)? = nil,
                @ViewBuilder content: () -> Content, @ViewBuilder bottomBar: () -> BottomBar) {
        self.title = title; self.subtitle = subtitle; self.alignment = alignment
        self.backLabel = backLabel; self.backDisabled = backDisabled; self.onBack = onBack
        self.content = content(); self.bottomBar = AnyView(bottomBar())
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let backLabel, let onBack {
                    EncounterBackButton(label: backLabel, action: onBack).disabled(backDisabled)
                }
                if title != nil || subtitle != nil {
                    VStack(alignment: alignment == .centered ? .center : .leading, spacing: 12) {
                        if let title {
                            Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                        }
                        if let subtitle { Text(subtitle).foregroundStyle(EncounterPalette.inkSecondary) }
                    }
                    .multilineTextAlignment(alignment == .centered ? .center : .leading)
                    .frame(maxWidth: .infinity, alignment: alignment == .centered ? .center : .leading)
                    .padding(.bottom, 8)
                }
                content
                if dynamicTypeSize.isAccessibilitySize, let bottomBar { bottomBar }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !dynamicTypeSize.isAccessibilitySize, let bottomBar {
                bottomBar.padding(.horizontal, 20).padding(.vertical, 12)
                    .frame(maxWidth: .infinity).background(EncounterPalette.background)
            }
        }
        .foregroundStyle(EncounterPalette.ink)
        .background(EncounterPalette.background.ignoresSafeArea())
        .tint(EncounterPalette.accent)
    }
}

@MainActor
public struct EncounterSurfaceCard<Content: View>: View {
    private let content: Content
    private let padding: CGFloat
    public init(padding: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.padding = padding; self.content = content()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .foregroundStyle(EncounterPalette.ink)
            .background(EncounterPalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(EncounterPalette.border, lineWidth: 1))
    }
}

@MainActor
public struct EncounterButtonStyle: ButtonStyle {
    public enum Kind { case primary, secondary, tertiary, destructive, destructiveText }
    private let kind: Kind
    private let fullWidth: Bool
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var height = 52.0

    public init(_ kind: Kind = .primary, fullWidth: Bool = true) {
        self.kind = kind; self.fullWidth = fullWidth
    }

    private func foreground(for kind: Kind) -> Color {
        guard isEnabled else { return EncounterPalette.inkSecondary }
        return switch kind {
        case .primary: EncounterPalette.onAccent
        case .secondary, .tertiary: EncounterPalette.accent
        case .destructive, .destructiveText: EncounterPalette.destructive
        }
    }
    private func fill(for kind: Kind) -> Color {
        if !isEnabled && (kind == .primary || kind == .secondary) { return EncounterPalette.neutralFill }
        return switch kind {
        case .primary: EncounterPalette.accent
        case .secondary, .destructive: EncounterPalette.surface
        case .tertiary, .destructiveText: .clear
        }
    }

    public func makeBody(configuration: Configuration) -> some View {
        let kind = configuration.role == .destructive && self.kind != .destructiveText ? Kind.destructive : self.kind
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return configuration.label.font(.headline).multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: max(44, height))
            .foregroundStyle(foreground(for: kind))
            .background(fill(for: kind), in: shape)
            .overlay {
                shape.stroke(!isEnabled ? EncounterPalette.border :
                    kind == .destructive ? EncounterPalette.destructive : EncounterPalette.accent,
                    lineWidth: kind == .secondary || kind == .destructive ? 1.5 : 0)
            }
            .contentShape(shape)
            .opacity(isEnabled && configuration.isPressed ? 0.8 : 1)
    }
}

/// Plain controls retain their explicit palette colours while signalling unavailable actions.
@MainActor
struct EncounterPlainButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle())
            .opacity(isEnabled ? configuration.isPressed ? 0.8 : 1 : 0.45)
    }
}

@MainActor
public struct EncounterChip: View {
    public enum TagTone { case accent, neutral }
    private let label: String
    private let selected: Bool
    private let tone: TagTone
    private let action: (@MainActor () -> Void)?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var height = 44.0

    public init(label: String, selected: Bool, action: @escaping @MainActor () -> Void) {
        self.label = label; self.selected = selected; tone = .neutral; self.action = action
    }
    public init(label: String, tone: TagTone = .accent) {
        self.label = label; selected = false; self.tone = tone; action = nil
    }

    private var chip: some View {
        let shape = encounterCapsuleShape(for: dynamicTypeSize)
        return HStack(spacing: 8) {
            Text(label).multilineTextAlignment(.leading)
            if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(minHeight: max(44, height))
        .foregroundStyle(!isEnabled ? EncounterPalette.inkSecondary : selected ? EncounterPalette.onAccent :
            action == nil && tone == .accent ? EncounterPalette.accent : EncounterPalette.ink)
        .background(!isEnabled ? EncounterPalette.neutralFill : selected ? EncounterPalette.accent :
            action == nil && tone == .accent ? EncounterPalette.accentSoft : EncounterPalette.neutralFill,
                    in: shape)
        .overlay(shape.stroke(EncounterPalette.border, lineWidth: 1))
        .contentShape(shape)
    }
    public var body: some View {
        if let action {
            Button(action: action) { chip }.buttonStyle(.plain)
                .accessibilityLabel(label).accessibilityAddTraits(selected ? .isSelected : [])
        } else { chip }
    }
}

/// Pass the screen's Dynamic Type accessibility state to use one full-width item per row.
public struct EncounterFlowLayout: Layout {
    public var spacing: CGFloat
    public var isAccessibilitySize: Bool
    public init(spacing: CGFloat = 8, isAccessibilitySize: Bool = false) {
        self.spacing = spacing; self.isAccessibilitySize = isAccessibilitySize
    }

    struct Arrangement {
        let sizes: [CGSize]
        let origins: [CGPoint]
        let size: CGSize
    }

    /// Pure geometry, shared by SwiftUI measurement/placement and the layout tests.
    static func arrange(_ itemSizes: [CGSize], proposedWidth: CGFloat?, spacing: CGFloat = 8,
                        isAccessibilitySize: Bool = false) -> Arrangement {
        guard !itemSizes.isEmpty else { return Arrangement(sizes: [], origins: [], size: .zero) }
        let naturalWidth = isAccessibilitySize ? itemSizes.map(\.width).max()! :
            itemSizes.reduce(CGFloat.zero) { $0 + $1.width } + spacing * CGFloat(itemSizes.count - 1)
        let width = max(0, proposedWidth.flatMap { $0.isFinite ? $0 : nil } ?? naturalWidth)
        var sizes: [CGSize] = []; var origins: [CGPoint] = []
        var x: CGFloat = 0; var y: CGFloat = 0; var rowHeight: CGFloat = 0; var usedWidth: CGFloat = 0
        var rowHasItems = false
        for natural in itemSizes {
            let itemWidth = isAccessibilitySize ? width : min(width, natural.width)
            let size = CGSize(width: itemWidth, height: natural.height)
            if rowHasItems && (isAccessibilitySize || x + size.width > width) {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            sizes.append(size); origins.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height); x += size.width + spacing
            rowHasItems = true
        }
        return Arrangement(sizes: sizes, origins: origins, size: CGSize(width: usedWidth, height: y + rowHeight))
    }

    private func arrangement(proposedWidth: CGFloat?, subviews: Subviews) -> Arrangement {
        let natural = subviews.map { $0.sizeThatFits(.unspecified) }
        let initial = Self.arrange(natural, proposedWidth: proposedWidth, spacing: spacing,
                                   isAccessibilitySize: isAccessibilitySize)
        let width = proposedWidth.flatMap { $0.isFinite ? max(0, $0) : nil } ?? initial.size.width
        let measured = subviews.indices.map { index in
            let proposal = ProposedViewSize(width: initial.sizes[index].width, height: nil)
            let size = subviews[index].sizeThatFits(proposal)
            return CGSize(width: initial.sizes[index].width, height: size.height)
        }
        return Self.arrange(measured, proposedWidth: width, spacing: spacing, isAccessibilitySize: isAccessibilitySize)
    }
    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(proposedWidth: proposal.width, subviews: subviews).size
    }
    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(proposedWidth: bounds.width, subviews: subviews)
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: bounds.minX + result.origins[index].x,
                                              y: bounds.minY + result.origins[index].y),
                                  anchor: .topLeading, proposal: ProposedViewSize(result.sizes[index]))
        }
    }
}

@MainActor
private struct EncounterChoiceRow: View {
    let label: String
    let selected: Bool
    let radio: Bool
    let action: @MainActor () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var indicator: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var target = 44.0
    private var indicatorSize: CGFloat { min(indicator, 36) }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: radio ? indicatorSize / 2 : 6, style: .continuous)
                    .fill(selected ? isEnabled ? EncounterPalette.accent : EncounterPalette.neutralFill : EncounterPalette.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: radio ? indicatorSize / 2 : 6, style: .continuous)
                            .stroke(!isEnabled ? EncounterPalette.inkSecondary :
                                selected ? EncounterPalette.accent : EncounterPalette.controlOutline, lineWidth: 1.5)
                        if selected {
                            if radio {
                                Circle().fill(isEnabled ? EncounterPalette.onAccent : EncounterPalette.inkSecondary)
                                    .padding(indicatorSize / 3)
                            } else {
                                Image(systemName: "checkmark").resizable().scaledToFit().padding(indicatorSize * 0.23)
                                    .foregroundStyle(isEnabled ? EncounterPalette.onAccent : EncounterPalette.inkSecondary)
                            }
                        }
                    }
                    .frame(width: indicatorSize, height: indicatorSize).accessibilityHidden(true)
                Text(label).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: max(44, target), alignment: .leading)
            .padding(16).foregroundStyle(isEnabled ? EncounterPalette.ink : EncounterPalette.inkSecondary)
            .background(EncounterPalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(EncounterPalette.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor
public struct EncounterCheckRow: View {
    private let label: String
    private let selected: Bool
    private let action: @MainActor () -> Void
    public init(label: String, selected: Bool, action: @escaping @MainActor () -> Void) {
        self.label = label; self.selected = selected; self.action = action
    }
    public var body: some View { EncounterChoiceRow(label: label, selected: selected, radio: false, action: action) }
}

@MainActor
public struct EncounterRadioRow: View {
    private let label: String
    private let selected: Bool
    private let action: @MainActor () -> Void
    public init(label: String, selected: Bool, action: @escaping @MainActor () -> Void) {
        self.label = label; self.selected = selected; self.action = action
    }
    public var body: some View { EncounterChoiceRow(label: label, selected: selected, radio: true, action: action) }
}

@MainActor
public struct EncounterBadge: View {
    public enum Style { case verified, unverified, visibility, ambient, session, qr }
    private let label: String
    private let style: Style
    private let symbol: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    public init(_ label: String, style: Style, symbol: String? = nil) {
        self.label = label; self.style = style; self.symbol = symbol
    }
    private var defaultSymbol: String {
        switch style {
        case .verified: "checkmark.seal.fill"
        case .unverified: "clock"
        case .visibility: "eye"
        case .ambient: "dot.radiowaves.left.and.right"
        case .session: "person.2"
        case .qr: "qrcode"
        }
    }
    private var foreground: Color {
        switch style {
        case .ambient: EncounterPalette.ambientText
        case .session: EncounterPalette.sessionText
        case .unverified: EncounterPalette.ink
        default: EncounterPalette.accent
        }
    }
    private var fill: Color {
        switch style {
        case .ambient: EncounterPalette.ambientFill
        case .session: EncounterPalette.sessionFill
        case .unverified: EncounterPalette.neutralFill
        default: EncounterPalette.accentSoft
        }
    }
    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol ?? defaultSymbol).accessibilityHidden(true)
            Text(label)
        }.font(.footnote).padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(foreground).background(fill, in: encounterCapsuleShape(for: dynamicTypeSize))
    }
}

@MainActor
public struct EncounterAvatar: View {
    private let displayName: String
    private let decorative: Bool
    @ScaledMetric private var size: CGFloat
    public init(displayName: String, size: CGFloat = 56, decorative: Bool = false) {
        self.displayName = displayName; _size = ScaledMetric(wrappedValue: size, relativeTo: .title)
        self.decorative = decorative
    }
    public var body: some View {
        Text(String(displayName.prefix(1))).font(.title.bold())
            .frame(width: size, height: size).foregroundStyle(EncounterPalette.accent)
            .background(EncounterPalette.accentSoft, in: Circle()).accessibilityLabel(displayName)
            .accessibilityHidden(decorative)
    }
}

@MainActor
public struct EncounterSymbolTile: View {
    private let symbol: String
    @ScaledMetric private var size: CGFloat
    public init(symbol: String, size: CGFloat = 44) {
        self.symbol = symbol; _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }
    public var body: some View {
        let side = min(size, 64)
        Image(systemName: symbol).resizable().scaledToFit()
            .frame(width: side * 0.5, height: side * 0.5)
            .frame(width: side, height: side).foregroundStyle(EncounterPalette.accent)
            .background(EncounterPalette.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
    }
}

@MainActor
public struct EncounterIconRow: View {
    private let symbol: String
    private let title: String
    private let showsChevron: Bool
    private let showsDivider: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var target = 44.0
    @ScaledMetric(relativeTo: .body) private var dividerInset = 60.0
    public init(symbol: String, title: String, showsChevron: Bool = true, showsDivider: Bool = false) {
        self.symbol = symbol; self.title = title; self.showsChevron = showsChevron; self.showsDivider = showsDivider
    }
    public var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ?
            AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 16))
        VStack(spacing: 12) {
            layout {
                EncounterSymbolTile(symbol: symbol)
                Text(title).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                if showsChevron { Image(systemName: "chevron.right").foregroundStyle(EncounterPalette.inkSecondary).accessibilityHidden(true) }
            }.frame(minHeight: max(44, target)).foregroundStyle(EncounterPalette.ink)
            if showsDivider {
                Rectangle().fill(EncounterPalette.border).frame(height: 1)
                    .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 0 : dividerInset).accessibilityHidden(true)
            }
        }
    }
}

@MainActor
public struct EncounterNotice: View {
    public enum Kind { case warning, info }
    private let message: String
    private let kind: Kind
    public init(_ message: String, kind: Kind = .info) { self.message = message; self.kind = kind }
    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(kind == .warning ? EncounterPalette.warningIcon : EncounterPalette.accent).accessibilityHidden(true)
            Text(message).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(16).foregroundStyle(EncounterPalette.ink)
            .background(kind == .warning ? EncounterPalette.warningFill : EncounterPalette.accentSoft,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

@MainActor
public struct EncounterSegmentedControl<Value: Hashable>: View {
    public struct Segment: Identifiable {
        public let id: Value
        public let label: String
        public let symbol: String?
        public init(_ id: Value, label: String, symbol: String? = nil) { self.id = id; self.label = label; self.symbol = symbol }
    }
    private let segments: [Segment]
    private let label: String?
    @Binding private var selection: Value
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var target = 44.0
    public init(segments: [Segment], selection: Binding<Value>, label: String? = nil) {
        self.segments = segments; _selection = selection; self.label = label
    }

    nonisolated static func shouldChangeSelection(from current: Value, to proposed: Value) -> Bool {
        current != proposed
    }

    private var segmentShape: AnyShape {
        encounterCapsuleShape(for: dynamicTypeSize)
    }
    private var trackShape: AnyShape {
        encounterCapsuleShape(for: dynamicTypeSize)
    }
    public var body: some View {
        if let label {
            control.accessibilityElement(children: .contain).accessibilityLabel(label)
        } else {
            control
        }
    }

    private var control: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        return layout {
            ForEach(segments) { segment in
                Button {
                    if Self.shouldChangeSelection(from: selection, to: segment.id) { selection = segment.id }
                } label: {
                    HStack(spacing: 8) {
                        if let symbol = segment.symbol { Image(systemName: symbol).accessibilityHidden(true) }
                        Text(segment.label).multilineTextAlignment(.center)
                        if selection == segment.id { Image(systemName: "checkmark").accessibilityHidden(true) }
                    }.padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: max(44, target))
                        .foregroundStyle(selection == segment.id ? EncounterPalette.onAccent : EncounterPalette.ink)
                        .background(selection == segment.id ? EncounterPalette.accent : .clear, in: segmentShape)
                        .contentShape(segmentShape)
                }.buttonStyle(.plain).accessibilityLabel(segment.label)
                    .accessibilityAddTraits(selection == segment.id ? .isSelected : [])
            }
        }.padding(4).background(EncounterPalette.neutralFill, in: trackShape)
    }
}

@MainActor
public struct EncounterSectionHeader: View {
    private let title: String
    private let subtitle: String?
    public init(_ title: String, subtitle: String? = nil) { self.title = title; self.subtitle = subtitle }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(EncounterPalette.ink).accessibilityAddTraits(.isHeader)
            if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(EncounterPalette.inkSecondary) }
        }
    }
}

@MainActor
public struct EncounterInlineError<Details: View>: View {
    private let message: String
    private let retryLabel: String
    private let disabled: Bool
    private let retry: @MainActor () -> Void
    private let details: Details
    public init(message: String, retryLabel: String, disabled: Bool = false,
                retry: @escaping @MainActor () -> Void, @ViewBuilder details: () -> Details) {
        self.message = message; self.retryLabel = retryLabel; self.disabled = disabled
        self.retry = retry; self.details = details()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                Text(message)
            }
            details
            Button(retryLabel, action: retry).buttonStyle(EncounterButtonStyle(.secondary, fullWidth: false)).disabled(disabled)
        }.foregroundStyle(EncounterPalette.destructive)
    }
}

extension EncounterInlineError where Details == EmptyView {
    public init(message: String, retryLabel: String, disabled: Bool = false, retry: @escaping @MainActor () -> Void) {
        self.init(message: message, retryLabel: retryLabel, disabled: disabled, retry: retry) { EmptyView() }
    }
}

@MainActor
public struct EncounterProgress: View {
    private let label: String
    public init(_ label: String) { self.label = label }
    public var body: some View { ProgressView(label).tint(EncounterPalette.accent).accessibilityLabel(label) }
}

@MainActor
public struct EncounterBackButton: View {
    private let label: String
    private let action: @MainActor () -> Void
    @ScaledMetric(relativeTo: .body) private var target = 44.0
    public init(label: String, action: @escaping @MainActor () -> Void) { self.label = label; self.action = action }
    public var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left").font(.title3.weight(.semibold)).accessibilityHidden(true)
                .frame(width: max(44, target), height: max(44, target)).contentShape(Rectangle())
        }.buttonStyle(EncounterPlainButtonStyle()).foregroundStyle(EncounterPalette.ink).accessibilityLabel(label)
    }
}

@MainActor
public struct EncounterField: View {
    private let label: String
    private let counter: String?
    private let error: String?
    private let multiline: Bool
    private let textContentType: UITextContentType?
    private let keyboardType: UIKeyboardType?
    private let autocapitalization: TextInputAutocapitalization?
    private let autocorrectionDisabled: Bool?
    private let submitLabel: SubmitLabel?
    private let lineLimit: ClosedRange<Int>?
    @Binding private var text: String
    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric private var height: CGFloat
    public init(_ label: String, text: Binding<String>, multiline: Bool = false, counter: String? = nil,
                error: String? = nil, textContentType: UITextContentType? = nil,
                keyboardType: UIKeyboardType? = nil, autocapitalization: TextInputAutocapitalization? = nil,
                autocorrectionDisabled: Bool? = nil, submitLabel: SubmitLabel? = nil, lineLimit: ClosedRange<Int>? = nil,
                minHeight: CGFloat? = nil) {
        self.label = label; _text = text; self.multiline = multiline; self.counter = counter
        self.error = error; self.textContentType = textContentType
        self.keyboardType = keyboardType; self.autocapitalization = autocapitalization
        self.autocorrectionDisabled = autocorrectionDisabled; self.submitLabel = submitLabel; self.lineLimit = lineLimit
        _height = ScaledMetric(wrappedValue: minHeight ?? (multiline ? 120 : 52), relativeTo: .body)
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.headline)
            TextField(label, text: $text, axis: multiline ? .vertical : .horizontal)
                .focused($isFocused)
                .textContentType(textContentType).textFieldStyle(.plain).accessibilityLabel(label)
                .encounterInputOption(keyboardType) { $0.keyboardType($1) }
                .encounterInputOption(autocapitalization) { $0.textInputAutocapitalization($1) }
                .encounterInputOption(autocorrectionDisabled) { $0.autocorrectionDisabled($1) }
                .encounterInputOption(submitLabel) { $0.submitLabel($1) }
                .encounterInputOption(lineLimit) { $0.lineLimit($1) }
                .padding(16).frame(maxWidth: .infinity, minHeight: max(44, height), alignment: .topLeading)
                .background(EncounterPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(EncounterPalette.controlOutline, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .simultaneousGesture(TapGesture().onEnded { if isEnabled { isFocused = true } })
            if let counter { Text(counter).font(.footnote).foregroundStyle(EncounterPalette.inkSecondary).frame(maxWidth: .infinity, alignment: .trailing) }
            if let error { Text(error).foregroundStyle(EncounterPalette.destructive) }
        }.foregroundStyle(EncounterPalette.ink)
    }
}

private extension View {
    @ViewBuilder
    func encounterInputOption<Value, Modified: View>(_ value: Value?,
                                                     transform: (Self, Value) -> Modified) -> some View {
        if let value { transform(self, value) } else { self }
    }
}

@MainActor
public struct EncounterStepper: View {
    @Binding private var value: Int
    private let range: ClosedRange<Int>
    private let label: String
    private let decreaseLabel: String
    private let increaseLabel: String
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var target = 44.0
    public init(_ label: String, value: Binding<Int>, in range: ClosedRange<Int>, decreaseLabel: String, increaseLabel: String) {
        self.label = label; _value = value; self.range = range
        self.decreaseLabel = decreaseLabel; self.increaseLabel = increaseLabel
    }
    public var body: some View {
        let shape = encounterCapsuleShape(for: dynamicTypeSize)
        HStack(spacing: 12) {
            Button { if value > range.lowerBound { value -= 1 } } label: {
                Image(systemName: "minus").accessibilityHidden(true).frame(width: max(44, target), height: max(44, target))
                    .contentShape(Rectangle())
            }.accessibilityLabel(decreaseLabel).disabled(value <= range.lowerBound)
            Text(value, format: .number).font(.headline).foregroundStyle(EncounterPalette.ink)
            Button { if value < range.upperBound { value += 1 } } label: {
                Image(systemName: "plus").accessibilityHidden(true).frame(width: max(44, target), height: max(44, target))
                    .contentShape(Rectangle())
            }.accessibilityLabel(increaseLabel).disabled(value >= range.upperBound)
        }.buttonStyle(EncounterPlainButtonStyle()).foregroundStyle(EncounterPalette.accent)
            .background(EncounterPalette.surface, in: shape).overlay(shape.stroke(EncounterPalette.border, lineWidth: 1))
            .accessibilityElement(children: .ignore).accessibilityLabel(label).accessibilityValue(Text(value, format: .number))
            .accessibilityAdjustableAction { direction in
                guard isEnabled else { return }
                switch direction {
                case .increment: if value < range.upperBound { value += 1 }
                case .decrement: if value > range.lowerBound { value -= 1 }
                @unknown default: break
                }
            }
    }
}

private struct EncounterFigureBody: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.maxY)
        let outer = min(rect.width / 2, rect.height)
        let inner = outer * 0.45
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: center.x + inner, y: center.y))
        path.addArc(center: center, radius: inner, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: true)
        path.closeSubpath()
        return path
    }
}

@MainActor
public struct EncounterMark: View {
    private let signals: Bool
    private let pulseRings: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric private var scaledWidth: CGFloat
    private var width: CGFloat { min(scaledWidth, dynamicTypeSize.isAccessibilitySize ? 100 : 180) }
    @OnboardingViewState private var pulsing = false
    public init(width: CGFloat = 140, signals: Bool = false, pulseRings: Bool = false) {
        _scaledWidth = ScaledMetric(wrappedValue: width, relativeTo: .largeTitle)
        self.signals = signals; self.pulseRings = pulseRings
    }
    private func figure(opacity: Double) -> some View {
        VStack(spacing: width * 0.06) {
            Circle().frame(width: width * 0.26, height: width * 0.26)
            EncounterFigureBody().frame(width: width * 0.56, height: width * 0.28)
        }.foregroundStyle(EncounterPalette.accent.opacity(opacity))
    }

    private func updatePulse() {
        if pulseRings && !reduceMotion {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { pulsing = true }
        } else {
            pulsing = false
        }
    }

    public var body: some View {
        ZStack {
            if pulseRings {
                ForEach(1...3, id: \.self) { ring in
                    Circle().stroke(EncounterPalette.accentSoft, lineWidth: 2)
                        .frame(width: width * (0.65 + Double(ring) * 0.2))
                        .scaleEffect(pulsing && !reduceMotion ? 1.08 : 1)
                }
            }
            figure(opacity: 0.35).offset(x: width * 0.22, y: width * 0.04)
            figure(opacity: 1).offset(x: -width * 0.22)
            if signals {
                HStack(spacing: width * 0.08) {
                    ForEach(-1...1, id: \.self) { index in
                        Capsule().fill(EncounterPalette.accent.opacity(0.5))
                            .frame(width: width * 0.035, height: width * 0.14)
                            .rotationEffect(.degrees(Double(index) * 30))
                    }
                }.offset(y: -width * 0.4)
            }
        }.frame(width: width, height: width * (signals || pulseRings ? 1.05 : 0.7))
            .accessibilityHidden(true)
            .onAppear(perform: updatePulse)
            .onChange(of: reduceMotion) { _, _ in updatePulse() }
            .onChange(of: pulseRings) { _, _ in updatePulse() }
    }
}
