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

struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Text(context.state.displayName).font(.headline)
                SessionActivityStatus(state: context.state, isStale: context.isStale)
                if context.state.presentsActive(isStale: context.isStale) {
                    Button(intent: StopSessionIntent(sessionID: context.attributes.sessionID)) {
                        Label(ActivityText.text("stop"), systemImage: "stop.circle")
                    }
                }
            }
            .padding()
            .widgetURL(URL(string: "engineer-encounters://session"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Text(context.state.displayName) }
                DynamicIslandExpandedRegion(.trailing) {
                    SessionActivityStatus(state: context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.presentsActive(isStale: context.isStale) {
                        Button(intent: StopSessionIntent(sessionID: context.attributes.sessionID)) {
                            Label(ActivityText.text("stop"), systemImage: "stop.circle")
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.presentsActive(isStale: context.isStale) ? "timer" : "checkmark")
                    .accessibilityLabel(ActivityText.text(context.state.presentsActive(isStale: context.isStale) ? "active" : "ended"))
            } compactTrailing: {
                SessionActivityCountdown(state: context.state, isStale: context.isStale)
            } minimal: {
                Image(systemName: context.state.presentsActive(isStale: context.isStale) ? "timer" : "checkmark")
                    .accessibilityLabel(ActivityText.text(context.state.presentsActive(isStale: context.isStale) ? "active" : "ended"))
            }
            .widgetURL(URL(string: "engineer-encounters://session"))
        }
    }
}

private struct SessionActivityStatus: View {
    let state: SessionActivityAttributes.ContentState
    let isStale: Bool
    var body: some View {
        VStack(alignment: .leading) {
            Text(ActivityText.text(state.presentsActive(isStale: isStale) ? "active" : "ended"))
            if state.presentsActive(isStale: isStale) {
                HStack {
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
                .monospacedDigit()
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
