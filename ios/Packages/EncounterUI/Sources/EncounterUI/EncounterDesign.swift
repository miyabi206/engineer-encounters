import SwiftUI
import UIKit

/// Semantic colours shared by every Encounter screen. UIKit tokens retain trait resolution.
public enum EncounterPalette {
    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    private static func dynamic(_ light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in rgb(traits.userInterfaceStyle == .dark ? dark : light) }
    }

    public static let accentUIColor = dynamic(0x13777B, dark: 0x5CC8C2)
    public static let onAccentUIColor = dynamic(0xFFFFFF, dark: 0x04201F)
    public static let accentSoftUIColor = dynamic(0xE3F3F2, dark: 0x173B3A)
    public static let inkUIColor = UIColor { $0.userInterfaceStyle == .dark ? .label : rgb(0x0E1A2B) }
    public static let inkSecondaryUIColor = UIColor { $0.userInterfaceStyle == .dark ? .secondaryLabel : rgb(0x5B6576) }
    public static let backgroundUIColor = UIColor { $0.userInterfaceStyle == .dark ? .systemGroupedBackground : rgb(0xF6F8F9) }
    public static let surfaceUIColor = UIColor { $0.userInterfaceStyle == .dark ? .secondarySystemGroupedBackground : .white }
    public static let borderUIColor = UIColor { $0.userInterfaceStyle == .dark ? .white.withAlphaComponent(0.12) : rgb(0xE3E7EC) }
    public static let neutralFillUIColor = UIColor { $0.userInterfaceStyle == .dark ? .tertiarySystemFill : rgb(0xEEF1F4) }
    public static let warningFillUIColor = dynamic(0xFFF5E6, dark: 0x3A2A10)
    public static let warningIconUIColor = dynamic(0xB26B00, dark: 0xF2B544)
    public static let ambientTextUIColor = dynamic(0x2457C5, dark: 0xA9C5FF)
    public static let ambientFillUIColor = dynamic(0xE7EEFC, dark: 0x172D55)
    public static let sessionTextUIColor = dynamic(0x6B3FC4, dark: 0xD3B8FF)
    public static let sessionFillUIColor = dynamic(0xF0EAFC, dark: 0x33234F)
    public static let destructiveUIColor = UIColor { _ in .systemRed }

    public static let accent = Color(uiColor: accentUIColor)
    public static let onAccent = Color(uiColor: onAccentUIColor)
    public static let accentSoft = Color(uiColor: accentSoftUIColor)
    public static let ink = Color(uiColor: inkUIColor)
    public static let inkSecondary = Color(uiColor: inkSecondaryUIColor)
    public static let background = Color(uiColor: backgroundUIColor)
    public static let surface = Color(uiColor: surfaceUIColor)
    public static let border = Color(uiColor: borderUIColor)
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
    public enum Kind { case primary, secondary, tertiary, destructive }
    private let kind: Kind
    private let fullWidth: Bool
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var height = 52.0

    public init(_ kind: Kind = .primary, fullWidth: Bool = true) {
        self.kind = kind; self.fullWidth = fullWidth
    }

    private var foreground: Color {
        switch kind {
        case .primary: EncounterPalette.onAccent
        case .secondary, .tertiary: EncounterPalette.accent
        case .destructive: EncounterPalette.destructive
        }
    }
    private var fill: Color {
        switch kind {
        case .primary: EncounterPalette.accent
        case .secondary, .destructive: EncounterPalette.surface
        case .tertiary: .clear
        }
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: max(44, height))
            .foregroundStyle(foreground)
            .background(fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(kind == .destructive ? EncounterPalette.destructive : EncounterPalette.accent,
                            style: StrokeStyle(lineWidth: !isEnabled || kind == .secondary || kind == .destructive ? 1.5 : 0,
                                               dash: isEnabled ? [] : [4, 3]))
            }
            // A dashed outline also identifies unavailable actions without relying on colour.
            .opacity(!isEnabled ? 0.55 : configuration.isPressed ? 0.8 : 1)
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
    @ScaledMetric(relativeTo: .body) private var height = 44.0

    public init(label: String, selected: Bool, action: @escaping @MainActor () -> Void) {
        self.label = label; self.selected = selected; tone = .neutral; self.action = action
    }
    public init(label: String, tone: TagTone = .accent) {
        self.label = label; selected = false; self.tone = tone; action = nil
    }

    private var chip: some View {
        HStack(spacing: 8) {
            Text(label).multilineTextAlignment(.leading)
            if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(minHeight: max(44, height))
        .foregroundStyle(selected ? EncounterPalette.onAccent : action == nil && tone == .accent ? EncounterPalette.accent : EncounterPalette.ink)
        .background(selected ? EncounterPalette.accent : action == nil && tone == .accent ? EncounterPalette.accentSoft : EncounterPalette.neutralFill,
                    in: Capsule())
        .overlay(Capsule().stroke(EncounterPalette.border, style: StrokeStyle(lineWidth: 1, dash: isEnabled ? [] : [4, 3])))
        .opacity(isEnabled ? 1 : 0.55)
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

    private func arrangement(width: CGFloat, subviews: Subviews) -> (sizes: [CGSize], origins: [CGPoint], size: CGSize) {
        var sizes: [CGSize] = []; var origins: [CGPoint] = []
        var x: CGFloat = 0; var y: CGFloat = 0; var rowHeight: CGFloat = 0; var usedWidth: CGFloat = 0
        for subview in subviews {
            let natural = subview.sizeThatFits(.unspecified)
            let itemWidth = isAccessibilitySize ? width : min(width, natural.width)
            let measured = subview.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil))
            let size = CGSize(width: itemWidth, height: measured.height)
            if x > 0 && (isAccessibilitySize || x + size.width > width) {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            sizes.append(size); origins.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height); x += size.width + spacing
        }
        return (sizes, origins, CGSize(width: usedWidth, height: y + rowHeight))
    }
    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let naturalWidth = subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? max(0, naturalWidth - spacing)
        return arrangement(width: max(0, width), subviews: subviews).size
    }
    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
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
    @ScaledMetric(relativeTo: .body) private var indicator = 24.0
    @ScaledMetric(relativeTo: .body) private var target = 44.0
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: radio ? indicator / 2 : 6, style: .continuous)
                    .fill(selected ? EncounterPalette.accent : EncounterPalette.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: radio ? indicator / 2 : 6, style: .continuous)
                            .stroke(selected ? EncounterPalette.accent : EncounterPalette.inkSecondary, lineWidth: 1.5)
                        if selected {
                            if radio { Circle().fill(EncounterPalette.onAccent).padding(indicator / 3) }
                            else { Image(systemName: "checkmark").font(.body.bold()).foregroundStyle(EncounterPalette.onAccent) }
                        }
                    }
                    .frame(width: indicator, height: indicator).accessibilityHidden(true)
                Text(label).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: max(44, target), alignment: .leading)
            .padding(16).foregroundStyle(EncounterPalette.ink)
            .background(EncounterPalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(EncounterPalette.border, style: StrokeStyle(lineWidth: 1, dash: isEnabled ? [] : [4, 3])))
            .opacity(isEnabled ? 1 : 0.55)
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
            .foregroundStyle(foreground).background(fill, in: Capsule())
    }
}

@MainActor
public struct EncounterAvatar: View {
    private let displayName: String
    @ScaledMetric private var size: CGFloat
    public init(displayName: String, size: CGFloat = 56) {
        self.displayName = displayName; _size = ScaledMetric(wrappedValue: size, relativeTo: .title)
    }
    public var body: some View {
        Text(String(displayName.prefix(1))).font(.title.bold())
            .frame(width: size, height: size).foregroundStyle(EncounterPalette.accent)
            .background(EncounterPalette.accentSoft, in: Circle()).accessibilityLabel(displayName)
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
        Image(systemName: symbol).font(.title3.weight(.semibold))
            .frame(width: size, height: size).foregroundStyle(EncounterPalette.accent)
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
    @ScaledMetric(relativeTo: .body) private var target = 44.0
    @ScaledMetric(relativeTo: .body) private var dividerInset = 60.0
    public init(symbol: String, title: String, showsChevron: Bool = true, showsDivider: Bool = false) {
        self.symbol = symbol; self.title = title; self.showsChevron = showsChevron; self.showsDivider = showsDivider
    }
    public var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                EncounterSymbolTile(symbol: symbol)
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
                if showsChevron { Image(systemName: "chevron.right").foregroundStyle(EncounterPalette.inkSecondary).accessibilityHidden(true) }
            }.frame(minHeight: max(44, target)).foregroundStyle(EncounterPalette.ink)
            if showsDivider { Rectangle().fill(EncounterPalette.border).frame(height: 1).padding(.leading, dividerInset).accessibilityHidden(true) }
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
    @Binding private var selection: Value
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var target = 44.0
    public init(segments: [Segment], selection: Binding<Value>) { self.segments = segments; _selection = selection }
    public var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        layout {
            ForEach(segments) { segment in
                Button { selection = segment.id } label: {
                    HStack(spacing: 8) {
                        if let symbol = segment.symbol { Image(systemName: symbol).accessibilityHidden(true) }
                        Text(segment.label).multilineTextAlignment(.center)
                    }.padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: max(44, target))
                        .foregroundStyle(selection == segment.id ? EncounterPalette.onAccent : EncounterPalette.ink)
                        .background(selection == segment.id ? EncounterPalette.accent : .clear, in: Capsule())
                }.buttonStyle(.plain).accessibilityLabel(segment.label)
                    .accessibilityAddTraits(selection == segment.id ? .isSelected : [])
            }
        }.padding(4).background(EncounterPalette.neutralFill, in: Capsule())
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
        }.buttonStyle(.plain).foregroundStyle(EncounterPalette.ink).accessibilityLabel(label)
    }
}

@MainActor
public struct EncounterField: View {
    private let label: String
    private let counter: String?
    private let error: String?
    private let multiline: Bool
    private let textContentType: UITextContentType?
    @Binding private var text: String
    @ScaledMetric(relativeTo: .body) private var height = 52.0
    @ScaledMetric(relativeTo: .body) private var multilineHeight = 120.0
    public init(_ label: String, text: Binding<String>, multiline: Bool = false, counter: String? = nil,
                error: String? = nil, textContentType: UITextContentType? = nil) {
        self.label = label; _text = text; self.multiline = multiline; self.counter = counter
        self.error = error; self.textContentType = textContentType
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.headline)
            TextField(label, text: $text, axis: multiline ? .vertical : .horizontal)
                .textContentType(textContentType).textFieldStyle(.plain).accessibilityLabel(label)
                .padding(16).frame(maxWidth: .infinity, minHeight: multiline ? multilineHeight : max(44, height), alignment: .topLeading)
                .background(EncounterPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(EncounterPalette.border, lineWidth: 1))
            if let counter { Text(counter).font(.footnote).foregroundStyle(EncounterPalette.inkSecondary).frame(maxWidth: .infinity, alignment: .trailing) }
            if let error { Text(error).foregroundStyle(EncounterPalette.destructive) }
        }.foregroundStyle(EncounterPalette.ink)
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
    @ScaledMetric(relativeTo: .body) private var target = 44.0
    public init(_ label: String, value: Binding<Int>, in range: ClosedRange<Int>, decreaseLabel: String, increaseLabel: String) {
        self.label = label; _value = value; self.range = range
        self.decreaseLabel = decreaseLabel; self.increaseLabel = increaseLabel
    }
    public var body: some View {
        HStack(spacing: 12) {
            Button { if value > range.lowerBound { value -= 1 } } label: {
                Image(systemName: "minus").accessibilityHidden(true).frame(width: max(44, target), height: max(44, target))
            }.accessibilityLabel(decreaseLabel).disabled(value <= range.lowerBound)
            Text(value, format: .number).font(.headline).foregroundStyle(EncounterPalette.ink)
            Button { if value < range.upperBound { value += 1 } } label: {
                Image(systemName: "plus").accessibilityHidden(true).frame(width: max(44, target), height: max(44, target))
            }.accessibilityLabel(increaseLabel).disabled(value >= range.upperBound)
        }.buttonStyle(.plain).foregroundStyle(EncounterPalette.accent)
            .background(EncounterPalette.surface, in: Capsule()).overlay(Capsule().stroke(EncounterPalette.border, lineWidth: 1))
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
    @ScaledMetric private var width: CGFloat
    @OnboardingViewState private var pulsing = false
    public init(width: CGFloat = 140, signals: Bool = false, pulseRings: Bool = false) {
        _width = ScaledMetric(wrappedValue: width, relativeTo: .largeTitle)
        self.signals = signals; self.pulseRings = pulseRings
    }
    private func figure(opacity: Double) -> some View {
        VStack(spacing: width * 0.06) {
            Circle().frame(width: width * 0.26, height: width * 0.26)
            EncounterFigureBody().frame(width: width * 0.56, height: width * 0.28)
        }.foregroundStyle(EncounterPalette.accent.opacity(opacity))
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
            .onAppear {
                if pulseRings && !reduceMotion {
                    withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { pulsing = true }
                }
            }
            .onChange(of: reduceMotion) { _, reduced in
                if reduced { pulsing = false }
                else if pulseRings {
                    withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { pulsing = true }
                }
            }
    }
}
