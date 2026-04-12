import SwiftUI
import SwiftData

// MARK: - Dive Calendar Heatmap View

struct DiveCalendarHeatmapView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Dive.timestamp, order: .reverse) private var allDives: [Dive]

    @State private var selectedYear: Int = Calendar.current.component(.year, from: .now)
    @State private var selectedDay: Date? = nil
    @State private var selectedDayDives: [Dive] = []

    private let calendar = Calendar.current
    private let monthColumns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
    private var weekdaySymbols: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        // Calendar symbols start Sunday (index 0); reorder to Monday-first
        return Array(symbols[1...]) + [symbols[0]]
    }

    // All available years that have dives
    private var availableYears: [Int] {
        let years = Set(allDives.map { calendar.component(.year, from: $0.timestamp) })
        return years.sorted().reversed()
    }

    // Dives grouped by day for fast lookup
    private var divesByDay: [Date: [Dive]] {
        Dictionary(grouping: allDives) { dive in
            calendar.startOfDay(for: dive.timestamp)
        }
    }

    // Streak computed from all dives (not year-filtered)
    private var currentStreak: Int {
        let days = Set(allDives.map { calendar.startOfDay(for: $0.timestamp) }).sorted().reversed()
        var streak = 0
        var expected = calendar.startOfDay(for: .now)
        for day in days {
            if day == expected {
                streak += 1
                expected = calendar.date(byAdding: .day, value: -1, to: expected)!
            } else if day < expected {
                break
            }
        }
        return streak
    }

    private var yearDiveCount: Int {
        divesByDay.filter { calendar.component(.year, from: $0.key) == selectedYear }
                  .values.map(\.count).reduce(0, +)
    }

    private var yearDiveMinutes: Int {
        allDives
            .filter { calendar.component(.year, from: $0.timestamp) == selectedYear }
            .map(\.duration).reduce(0, +)
    }

    // Days in a given month of the selected year
    private func daysInMonth(_ month: Int) -> [Date] {
        guard let start = calendar.date(from: DateComponents(year: selectedYear, month: month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: start)
        else { return [] }

        return range.compactMap { day in
            calendar.date(from: DateComponents(year: selectedYear, month: month, day: day))
        }
    }

    // Leading empty slots for a month (Mon=0 ... Sun=6)
    private func leadingEmptyDays(for month: Int) -> Int {
        guard let first = calendar.date(from: DateComponents(year: selectedYear, month: month, day: 1)) else { return 0 }
        let weekday = calendar.component(.weekday, from: first)
        return (weekday + 5) % 7
    }

    // Month name
    private func monthName(_ month: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        return formatter.monthSymbols[month - 1]
    }

    // Dive count for a month
    private func diveCountForMonth(_ month: Int) -> Int {
        allDives.filter {
            calendar.component(.year, from: $0.timestamp) == selectedYear &&
            calendar.component(.month, from: $0.timestamp) == month
        }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    yearSelector
                    yearSummary
                    legend

                    // Month-by-month calendar grids
                    ForEach(1...12, id: \.self) { month in
                        let days = daysInMonth(month)
                        let monthDiveCount = diveCountForMonth(month)

                        if !days.isEmpty {
                            monthSection(month: month, days: days, diveCount: monthDiveCount)
                        }
                    }

                    // Selected day detail
                    if let day = selectedDay, !selectedDayDives.isEmpty {
                        selectedDayDetail(day: day, dives: selectedDayDives)
                    }

                    Spacer(minLength: 40)
                }
                .padding()
            }
            .navigationTitle("Calendar")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            #if os(macOS)
            .frame(minWidth: 650, idealWidth: 800, maxWidth: 1000, minHeight: 600, idealHeight: 900, maxHeight: .infinity)
            #endif
            .background(Color.platformBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.cyan)
                }
            }
        }
    }

    // MARK: - Year Selector

    private var yearSelector: some View {
        HStack(spacing: 16) {
            Button {
                if let prev = availableYears.first(where: { $0 < selectedYear }) {
                    withAnimation(.spring(response: 0.3)) { selectedYear = prev; selectedDay = nil; selectedDayDives = [] }
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(availableYears.contains(where: { $0 < selectedYear }) ? .cyan : .secondary)
            }

            Text(String(selectedYear))
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(.primary)
                .frame(minWidth: 80)

            Button {
                if let next = availableYears.last(where: { $0 > selectedYear }) {
                    withAnimation(.spring(response: 0.3)) { selectedYear = next; selectedDay = nil; selectedDayDives = [] }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(availableYears.contains(where: { $0 > selectedYear }) ? .cyan : .secondary)
            }

            Spacer()

            if currentStreak > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(.orange)
                    Text("\(currentStreak) days")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.orange)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.orange.opacity(0.15)))
            }
        }
    }

    // MARK: - Year Summary

    private var yearSummary: some View {
        HStack(spacing: 0) {
            CalHeatStat(
                value: "\(yearDiveCount)",
                label: "Dives",
                icon: "bubbles.and.sparkles",
                color: .cyan
            )
            Divider().frame(height: 36).background(Color.primary.opacity(0.1))
            CalHeatStat(
                value: yearDiveMinutes >= 60 ? "\(yearDiveMinutes / 60)h \(yearDiveMinutes % 60)m" : "\(yearDiveMinutes)m",
                label: "Time",
                icon: "clock.fill",
                color: .green
            )
            Divider().frame(height: 36).background(Color.primary.opacity(0.1))
            CalHeatStat(
                value: "\(Set(allDives.filter { calendar.component(.year, from: $0.timestamp) == selectedYear }.map { $0.siteName.lowercased() }).count)",
                label: "Sites",
                icon: "mappin.circle.fill",
                color: .orange
            )
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.platformSecondaryBackground))
    }

    // MARK: - Legend

    private var legend: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("Less")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ForEach(0..<5) { level in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(heatColor(level: level, maxLevel: 4))
                        .frame(width: 16, height: 16)
                }

                Text("More")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(.cyan, lineWidth: 1.5)
                        .frame(width: 16, height: 16)
                    Text("Today")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                ForEach(1..<5, id: \.self) { count in
                    HStack(spacing: 3) {
                        HStack(spacing: 2) {
                            ForEach(0..<count, id: \.self) { _ in
                                Circle()
                                    .fill(Color.primary.opacity(0.9))
                                    .frame(width: 4, height: 4)
                            }
                        }
                        Text("\(count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.9))
                        .frame(width: 18, height: 4)
                    Text("5+")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
    }

    // MARK: - Month Section

    private func monthSection(month: Int, days: [Date], diveCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Month header
            HStack(alignment: .firstTextBaseline) {
                Text(monthName(month))
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(.primary)

                if diveCount > 0 {
                    Text("\(diveCount) dives")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.cyan.opacity(0.15)))
                }

                Spacer()
            }
            .padding(.horizontal, 4)

            // Weekday header row
            LazyVGrid(columns: monthColumns, spacing: 2) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { index, symbol in
                    Text(symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(index >= 5 ? Color.cyan.opacity(0.5) : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                }
            }

            // Day grid
            let offset = leadingEmptyDays(for: month)

            LazyVGrid(columns: monthColumns, spacing: 2) {
                // Leading blank cells
                ForEach(0..<offset, id: \.self) { _ in
                    Color.clear
                        .frame(height: 36)
                }

                // Day cells
                ForEach(days, id: \.self) { day in
                    let divesOnDay = divesByDay[day] ?? []
                    let isSelected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
                    let isToday = calendar.isDateInToday(day)
                    let dayNumber = calendar.component(.day, from: day)

                    CalendarDayCell(
                        dayNumber: dayNumber,
                        divesCount: divesOnDay.count,
                        maxDepth: divesOnDay.map(\.maxDepth).max() ?? 0,
                        isSelected: isSelected,
                        isToday: isToday
                    )
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3)) {
                            if isSelected {
                                selectedDay = nil
                                selectedDayDives = []
                            } else if !divesOnDay.isEmpty {
                                selectedDay = day
                                selectedDayDives = divesOnDay
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.platformSecondaryBackground)
        )
    }

    // MARK: - Selected Day Detail

    private func selectedDayDetail(day: Date, dives: [Dive]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(day, format: .dateTime.weekday(.wide).day().month(.wide).year())
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation { selectedDay = nil; selectedDayDives = [] }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(dives) { dive in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dive.siteName)
                            .font(.subheadline.weight(.semibold))
                        Text(dive.location)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 4) {
                            Label(String(format: "%.0fm", dive.maxDepth), systemImage: "arrow.down")
                            Label(dive.formattedDuration, systemImage: "clock")
                        }
                        .font(.caption)
                        .foregroundStyle(.cyan)

                        if dive.rating > 0 {
                            HStack(spacing: 2) {
                                ForEach(1...5, id: \.self) { star in
                                    Image(systemName: star <= dive.rating ? "star.fill" : "star")
                                        .font(.system(size: 8))
                                        .foregroundStyle(star <= dive.rating ? .yellow : .secondary)
                                }
                            }
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.platformTertiaryBackground))
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.platformSecondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.cyan.opacity(0.3), lineWidth: 1.5)
                )
        )
    }

    // MARK: - Helpers

    private func heatColor(level: Int, maxLevel: Int) -> Color {
        switch level {
        case 0: return Color(.systemFill)
        case 1: return Color.blue.opacity(0.3)
        case 2: return Color.blue.opacity(0.55)
        case 3: return Color.cyan.opacity(0.75)
        default: return Color.cyan
        }
    }
}

// MARK: - Calendar Day Cell

struct CalendarDayCell: View {
    let dayNumber: Int
    let divesCount: Int
    let maxDepth: Double
    let isSelected: Bool
    let isToday: Bool

    private var fillColor: Color {
        if divesCount == 0 { return Color.clear }
        if divesCount == 1 && maxDepth < 20 { return Color.blue.opacity(0.35) }
        if divesCount == 1 { return Color.blue.opacity(0.6) }
        if divesCount == 2 { return Color.cyan.opacity(0.7) }
        return Color.cyan
    }

    private var textColor: Color {
        if isToday { return .cyan }
        if divesCount > 0 { return .white }
        return .secondary
    }

    var body: some View {
        ZStack {
            // Background fill for dive days
            RoundedRectangle(cornerRadius: 8)
                .fill(fillColor)

            // Today ring
            if isToday {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.cyan, lineWidth: 1.5)
            }

            // Selection ring
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white, lineWidth: 2)
            }

            // Day number + dive indicator
            VStack(spacing: 1) {
                Text("\(dayNumber)")
                    .font(.system(size: 13, weight: divesCount > 0 || isToday ? .bold : .regular, design: .rounded))
                    .foregroundStyle(textColor)

                if divesCount >= 5 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.9))
                        .frame(width: 18, height: 4)
                } else if divesCount > 0 {
                    HStack(spacing: 2) {
                        ForEach(0..<min(divesCount, 4), id: \.self) { _ in
                            Circle()
                                .fill(Color.primary.opacity(0.9))
                                .frame(width: 4, height: 4)
                        }
                    }
                }
            }
        }
        .frame(height: 36)
        .scaleEffect(isSelected ? 1.08 : 1.0)
        .animation(.spring(response: 0.25), value: isSelected)
    }
}

// MARK: - Calendar Stat Cell

struct CalHeatStat: View {
    let value: String
    let label: LocalizedStringKey
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title3).foregroundStyle(color)
            Text(value)
                .font(.system(.body, design: .rounded).weight(.black))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
