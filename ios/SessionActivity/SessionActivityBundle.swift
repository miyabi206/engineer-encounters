import ActivityKit
import AppIntents
import SwiftUI
import UIKit
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

private enum SessionActivityAppearance {
    static let accent = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            UIColor(red: 92 / 255, green: 200 / 255, blue: 194 / 255, alpha: 1)
        } else {
            UIColor(red: 19 / 255, green: 119 / 255, blue: 123 / 255, alpha: 1)
        }
    })
}

struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 12) {
                SessionActivityName(displayName: context.state.displayName)
                SessionActivityStatus(state: context.state, isStale: context.isStale)
                if context.state.presentsActive(isStale: context.isStale) {
                    Button(intent: StopSessionIntent(sessionID: context.attributes.sessionID)) {
                        Label(ActivityText.text("stop"), systemImage: "stop.circle")
                            .frame(minHeight: 44)
                    }
                    .tint(SessionActivityAppearance.accent)
                }
            }
            .padding()
            .activitySystemActionForegroundColor(SessionActivityAppearance.accent)
            .widgetURL(URL(string: "engineer-encounters://session"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { SessionActivityName(displayName: context.state.displayName) }
                DynamicIslandExpandedRegion(.trailing) {
                    SessionActivityStatus(state: context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.presentsActive(isStale: context.isStale) {
                        Button(intent: StopSessionIntent(sessionID: context.attributes.sessionID)) {
                            Label(ActivityText.text("stop"), systemImage: "stop.circle")
                                .frame(minHeight: 44)
                        }
                        .tint(SessionActivityAppearance.accent)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.presentsActive(isStale: context.isStale) ? "timer" : "checkmark")
                    .foregroundStyle(SessionActivityAppearance.accent)
                    .accessibilityLabel(ActivityText.text(context.state.presentsActive(isStale: context.isStale) ? "active" : "ended"))
            } compactTrailing: {
                SessionActivityCountdown(state: context.state, isStale: context.isStale)
            } minimal: {
                Image(systemName: context.state.presentsActive(isStale: context.isStale) ? "timer" : "checkmark")
                    .foregroundStyle(SessionActivityAppearance.accent)
                    .accessibilityLabel(ActivityText.text(context.state.presentsActive(isStale: context.isStale) ? "active" : "ended"))
            }
            .widgetURL(URL(string: "engineer-encounters://session"))
        }
    }
}

private struct SessionActivityName: View {
    let displayName: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.fill").font(.title3)
                .foregroundStyle(SessionActivityAppearance.accent)
                .frame(width: 44, height: 44)
                .background(SessionActivityAppearance.accent.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            Text(displayName).font(.headline)
        }
    }
}

private struct SessionActivityStatus: View {
    let state: SessionActivityAttributes.ContentState
    let isStale: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        VStack(alignment: .leading) {
            Text(ActivityText.text(state.presentsActive(isStale: isStale) ? "active" : "ended"))
            if state.presentsActive(isStale: isStale) {
                let layout = dynamicTypeSize.isAccessibilitySize ?
                    AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())
                layout {
                    Text(ActivityText.text("remaining"))
                    SessionActivityCountdown(state: state, isStale: isStale)
                }
            }
        }
    }
}

private struct SessionActivityCountdown: View {
    let state: SessionActivityAttributes.ContentState
    let isStale: Bool
    var body: some View {
        if state.presentsActive(isStale: isStale) {
            // The timer counts down to the holder's fixed end instant, with no timeline polling.
            Text(timerInterval: min(Date.now, state.endsAt)...state.endsAt, countsDown: true)
                .font(.system(.body, design: .monospaced).weight(.semibold)).monospacedDigit()
                .foregroundStyle(SessionActivityAppearance.accent)
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
