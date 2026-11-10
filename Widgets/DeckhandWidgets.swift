import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DeckhandWidgets: WidgetBundle {
    var body: some Widget { TaskLiveActivity() }
}

struct TaskLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaskActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(nil)
                .widgetURL(URL(string: "deckhand://thread/\(context.attributes.threadID)"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseIcon(phase: context.state.phase).font(.title2).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Elapsed(attributes: context.attributes, state: context.state).font(.title3.monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.7).multilineTextAlignment(.trailing)
                        .frame(width: 72, alignment: .trailing).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(stepLine(context.state)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                PhaseIcon(phase: context.state.phase)
            } compactTrailing: {
                Elapsed(attributes: context.attributes, state: context.state).monospacedDigit()
                    .lineLimit(1).multilineTextAlignment(.trailing).frame(width: 48, alignment: .trailing)
            } minimal: {
                PhaseIcon(phase: context.state.phase)
            }
            .widgetURL(URL(string: "deckhand://thread/\(context.attributes.threadID)"))
            .keylineTint(.blue)
        }
    }
}

func stepLine(_ s: TaskActivityAttributes.ContentState) -> String {
    switch s.phase {
    case .waiting:
        if let until = s.waitingUntil { return String(localized: "Usage limit — continues at \(until.formatted(date: .omitted, time: .shortened))") }
        return String(localized: "Waiting for the usage limit")
    case .approval: return String(localized: "Needs your approval: \(s.step)")
    default: return s.step
    }
}

private struct LockScreenView: View {
    let attributes: TaskActivityAttributes
    let state: TaskActivityAttributes.ContentState
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PhaseIcon(phase: state.phase).font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(attributes.title).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    Elapsed(attributes: attributes, state: state).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        .lineLimit(1).multilineTextAlignment(.trailing).frame(width: 64, alignment: .trailing)
                }
                Text(stepLine(state)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                Text("\(attributes.engine) · \(attributes.server)").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
    }
}

private struct Elapsed: View {
    let attributes: TaskActivityAttributes
    let state: TaskActivityAttributes.ContentState
    var body: some View {
        if let end = state.endedAt {
            Text(Duration.seconds(end.timeIntervalSince(attributes.started)).formatted(.time(pattern: .minuteSecond)))
        } else {
            Text(timerInterval: attributes.started...Date.distantFuture, countsDown: false)
        }
    }
}

private struct PhaseIcon: View {
    let phase: TaskActivityAttributes.Phase
    var body: some View {
        switch phase {
        case .running: Image(systemName: "sparkles").foregroundStyle(.blue)
        case .approval: Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        case .waiting: Image(systemName: "hourglass").foregroundStyle(.orange)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}
