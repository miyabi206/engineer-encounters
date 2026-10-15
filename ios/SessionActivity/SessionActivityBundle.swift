import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct SessionActivityBundle: WidgetBundle {
    var body: some Widget {
        SessionLiveActivity()
        StartSessionControl()
    }
}

private enum ActivityText {
    static func text(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: "SessionActivity")
    }
}

// Values mirror EncounterPalette.accentUIColor without linking the app or EncounterUI.
private struct SessionActivityAppearance: DynamicProperty {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var accent: Color { color(dark: colorScheme == .dark) }
    // The Dynamic Island always has a dark background, regardless of the Lock Screen scheme.
    var islandAccent: Color { color(dark: true) }

    private func color(dark: Bool) -> Color {
        let hex: UInt32 = contrast == .increased
            ? (dark ? 0x87E3DD : 0x0B6064) : (dark ? 0x5CC8C2 : 0x13777B)
        return Color(red: Double((hex >> 16) & 255) / 255,
                     green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            SessionActivityLockScreen(context: context)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .widgetURL(URL(string: "engineer-encounters://session"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.state.displayName).font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SessionActivityStatus(state: context.state, isStale: context.isStale, island: true)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.presentsActive(isStale: context.isStale) {
                        SessionActivityStopButton(sessionID: context.attributes.sessionID, island: true)
                    }
                }
            } compactLeading: {
                SessionActivitySymbol(state: context.state, isStale: context.isStale)
            } compactTrailing: {
                SessionActivityCountdown(state: context.state, isStale: context.isStale, island: true, compact: true)
            } minimal: {
                SessionActivitySymbol(state: context.state, isStale: context.isStale)
            }
            .widgetURL(URL(string: "engineer-encounters://session"))
        }
    }
}

private struct SessionActivityLockScreen: View {
    let context: ActivityViewContext<SessionActivityAttributes>
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var appearance = SessionActivityAppearance()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill").font(.body)
                    .foregroundStyle(appearance.accent)
                    .frame(width: 28, height: 28)
                    .background(appearance.accent.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                Text(context.state.displayName).font(.headline)
                    .lineLimit(2)
            }
            let layout = dynamicTypeSize.isAccessibilitySize ?
                AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) :
                AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                SessionActivityStatus(state: context.state, isStale: context.isStale)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if context.state.presentsActive(isStale: context.isStale) {
                    SessionActivityStopButton(sessionID: context.attributes.sessionID)
                }
            }
        }
        .padding(12)
        .activitySystemActionForegroundColor(appearance.accent)
    }
}

private struct SessionActivityStopButton: View {
    let sessionID: String
    var island = false
    private var appearance = SessionActivityAppearance()
    var body: some View {
        Button(intent: StopSessionIntent(sessionID: sessionID)) {
            Label(ActivityText.text("stop"), systemImage: "stop.circle")
                .frame(minHeight: 44)
        }
        .tint(island ? appearance.islandAccent : appearance.accent)
    }
}

private struct SessionActivitySymbol: View {
    let state: SessionActivityAttributes.ContentState
    let isStale: Bool
    private var appearance = SessionActivityAppearance()
    var body: some View {
        Image(systemName: state.presentsActive(isStale: isStale) ? "timer" : "checkmark")
            .foregroundStyle(appearance.islandAccent)
            .accessibilityLabel(ActivityText.text(state.presentsActive(isStale: isStale) ? "active" : "ended"))
    }
}

private struct SessionActivityStatus: View {
    let state: SessionActivityAttributes.ContentState
    let isStale: Bool
    var island = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ActivityText.text(state.presentsActive(isStale: isStale) ? "active" : "ended"))
            if state.presentsActive(isStale: isStale) {
                let layout = dynamicTypeSize.isAccessibilitySize ?
                    AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())
                layout {
                    Text(ActivityText.text("remaining"))
                    SessionActivityCountdown(state: state, isStale: isStale, island: island)
                }
            }
        }
    }
}

private struct SessionActivityCountdown: View {
    let state: SessionActivityAttributes.ContentState
    let isStale: Bool
    var island = false
    var compact = false
    private var appearance = SessionActivityAppearance()
    var body: some View {
        if state.presentsActive(isStale: isStale) {
            // The timer counts down to the holder's fixed end instant, with no timeline polling.
            Text(timerInterval: min(Date.now, state.endsAt)...state.endsAt, countsDown: true)
                .font(compact ? .body : .system(.body, design: .monospaced).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(island ? appearance.islandAccent : appearance.accent)
        } else { Text(ActivityText.text("ended")) }
    }
}

struct StartSessionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "EngineerEncounters.StartSession") {
            ControlWidgetButton(action: StartSessionIntent()) {
                Label(ActivityText.text("start"), systemImage: "timer")
            }
        }
        .displayName(LocalizedStringResource("start", table: "SessionActivity"))
    }
}
