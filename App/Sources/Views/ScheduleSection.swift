import DeckhandCore
import SwiftUI

/// "When" for anything that runs on a schedule: a builder instead of cron syntax, with the result in plain words.
/// `idPrefix` keeps the accessibility identifiers of each editor stable for UI tests.
struct ScheduleSection: View {
    @Binding var schedule: CronEditor.Schedule
    var idPrefix = "cron"
    private var time: Binding<Date> {
        Binding {
            Calendar.current.date(from: DateComponents(hour: schedule.hour, minute: schedule.minute)) ?? Date()
        } set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            schedule.hour = c.hour ?? 3; schedule.minute = c.minute ?? 0
        }
    }

    static func isValid(_ s: CronEditor.Schedule) -> Bool {
        CronEditor.isValidExpression(s.cron) && !(s.frequency == .weekly && s.weekdays.isEmpty)
    }

    var body: some View {
        Section {
            Picker("Runs", selection: $schedule.frequency) {
                ForEach(CronEditor.Frequency.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
            }
            .accessibilityIdentifier("\(idPrefix).frequency")
            switch schedule.frequency {
            case .minutes:
                Stepper(String(localized: "Every \(schedule.everyMinutes) minutes"), value: $schedule.everyMinutes, in: 1...30)
            case .hourly:
                Stepper(String(format: String(localized: "At minute %02d"), schedule.minute), value: $schedule.minute, in: 0...59)
            case .daily, .weekly, .monthly:
                DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                if schedule.frequency == .weekly {
                    HStack(spacing: 6) {
                        ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { d in
                            let on = schedule.weekdays.contains(d)
                            Button(Calendar.current.veryShortWeekdaySymbols[d]) {
                                if on { schedule.weekdays.remove(d) } else { schedule.weekdays.insert(d) }
                            }
                            .buttonStyle(.bordered).tint(on ? Theme.accent : .secondary)
                            .accessibilityIdentifier("\(idPrefix).day.\(d)")
                        }
                    }
                }
                if schedule.frequency == .monthly {
                    Stepper(String(localized: "On day \(schedule.dayOfMonth)"), value: $schedule.dayOfMonth, in: 1...28)
                }
            case .custom:
                TextField("0 3 * * 1", text: $schedule.expression).font(Theme.mono)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        } header: {
            Text("When")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(schedule.description)).accessibilityIdentifier("\(idPrefix).preview")
                Text(schedule.cron).font(Theme.monoSmall)
                if !CronEditor.isValidExpression(schedule.cron) { Text("That isn't a valid cron expression.").foregroundStyle(.red) }
                Text("Times are the server's local time.")
            }
        }
    }
}
