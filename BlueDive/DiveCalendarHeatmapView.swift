import SwiftUI
import SwiftData

// MARK: - Dive Calendar Heatmap View

struct DiveCalendarHeatmapView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Query(sort: \Dive.timestamp, order: .reverse) private var allDives: [Dive]

    @State private var selectedYear: Int = Calendar.current.component(.year, from: .now)
    @State private var selectedDay: Date? = nil
    @State private var selectedDayDives: [Dive] = []
    @State private var showDaySheet = false

    private var calendar: Calendar {
        var cal = Calendar.current
        cal.locale = locale
        return cal
    }
    private let monthColumns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
    private var weekdaySymbols: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        return Array(symbols[1...]) + [symbols[0]]
    }

    // Cached statistics — computed once in .task / recomputeYearStats, not on every render
    @State private var cachedAvailableYears: [Int] = []
    @State private var cachedDivesByDay: [Date: [Dive]] = [:]
    @State private var cachedCurrentStreak: Int = 0
    @State private var cachedYearDiveCount: Int = 0
    @State private var cachedYearDiveMinutes: Int = 0
    @State private var cachedYearUniqueSites: Int = 0
    @State private var cachedMonthDiveCounts: [Int: Int] = [:]
    @State private var statsReady = false
    @AppStorage(DiverFilter.storageKey) private var selectedDiver: String = ""

    private var uniqueDivers: [String] { DiverFilter.uniqueDivers(in: allDives) }
    private var filteredDives: [Dive] { DiverFilter.apply(selectedDiver, to: allDives) }

    private func recomputeAllStats(_ dives: [Dive]) {
        // Build divesByDay once
        cachedDivesByDay = Dictionary(grouping: dives) { dive in
            calendar.startOfDay(for: dive.timestamp)
        }

        cachedAvailableYears = Set(dives.map { calendar.component(.year, from: $0.timestamp) }).sorted(by: >)

        // Current streak
        let days = Set(cachedDivesByDay.keys).sorted().reversed()
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
        cachedCurrentStreak = streak

        recomputeYearStats(dives)
        statsReady = true
    }

    private func recomputeYearStats(_ dives: [Dive]) {
        cachedYearDiveCount = cachedDivesByDay
            .filter { calendar.component(.year, from: $0.key) == selectedYear }
            .values.map(\.count).reduce(0, +)

        cachedYearDiveMinutes = dives
            .filter { calendar.component(.year, from: $0.timestamp) == selectedYear }
            .map(\.duration).reduce(0, +)

        cachedYearUniqueSites = Set(
            dives.filter { calendar.component(.year, from: $0.timestamp) == selectedYear }
                 .map { $0.siteName.lowercased() }
        ).count

        var monthCounts: [Int: Int] = [:]
        for month in 1...12 {
            monthCounts[month] = dives.filter {
                calendar.component(.year, from: $0.timestamp) == selectedYear &&
                calendar.component(.month, from: $0.timestamp) == month
            }.count
        }
        cachedMonthDiveCounts = monthCounts
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
        formatter.locale = locale
        return formatter.monthSymbols[month - 1]
    }

    var body: some View {
        NavigationStack {
            Group {
                if !allDives.isEmpty && !selectedDiver.isEmpty && filteredDives.isEmpty {
                    NoEntriesForDiverView(
                        title: "No Dives for Diver",
                        description: "No dives were found for the selected diver."
                    )
                } else if !statsReady {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            yearSelector
                            yearSummary
                            legend

                            // Month-by-month calendar grids
                            ForEach(1...12, id: \.self) { month in
                                let days = daysInMonth(month)
                                let monthDiveCount = cachedMonthDiveCounts[month] ?? 0

                                if !days.isEmpty {
                                    monthSection(month: month, days: days, diveCount: monthDiveCount)
                                }
                            }

                            Spacer(minLength: 40)
                        }
                        .padding()
                    }
                }
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
                DiverFilterToolbar(uniqueDivers: uniqueDivers, selectedDiver: $selectedDiver)
            }
            .task(id: "\(allDives.count):\(selectedDiver)") {
                recomputeAllStats(filteredDives)
            }
            .diverFilterReset(uniqueDivers: uniqueDivers, selectedDiver: $selectedDiver)
            .onChange(of: selectedYear) {
                recomputeYearStats(filteredDives)
            }
            .sheet(isPresented: $showDaySheet, onDismiss: {
                selectedDay = nil
                selectedDayDives = []
            }) {
                if let day = selectedDay {
                    DayDivesSheetView(day: day, dives: selectedDayDives, diverFilter: selectedDiver)
                }
            }
        }
    }

    // MARK: - Year Selector

    private var yearSelector: some View {
        HStack(spacing: 16) {
            Button {
                if let prev = cachedAvailableYears.first(where: { $0 < selectedYear }) {
                    withAnimation(.spring(response: 0.3)) { selectedYear = prev; selectedDay = nil; selectedDayDives = [] }
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(cachedAvailableYears.contains(where: { $0 < selectedYear }) ? .cyan : .secondary)
            }

            Text(String(selectedYear))
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(.primary)
                .frame(minWidth: 80)

            Button {
                if let next = cachedAvailableYears.last(where: { $0 > selectedYear }) {
                    withAnimation(.spring(response: 0.3)) { selectedYear = next; selectedDay = nil; selectedDayDives = [] }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(cachedAvailableYears.contains(where: { $0 > selectedYear }) ? .cyan : .secondary)
            }

            Spacer()

            if cachedCurrentStreak > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(.orange)
                    Text("\(cachedCurrentStreak) days")
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
                value: "\(cachedYearDiveCount)",
                label: "Dive(s)",
                icon: "bubbles.and.sparkles",
                color: .cyan
            )
            Divider().frame(height: 36).background(Color.primary.opacity(0.1))
            CalHeatStat(
                value: cachedYearDiveMinutes >= 60 ? "\(cachedYearDiveMinutes / 60)h \(cachedYearDiveMinutes % 60)m" : "\(cachedYearDiveMinutes)m",
                label: "Time",
                icon: "clock.fill",
                color: .green
            )
            Divider().frame(height: 36).background(Color.primary.opacity(0.1))
            CalHeatStat(
                value: "\(cachedYearUniqueSites)",
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
                    let label = diveCount == 1
                        ? NSLocalizedString("1 dive", bundle: .forAppLanguage(), comment: "Single dive count in calendar heatmap month header")
                        : String(format: NSLocalizedString("%lld dives", bundle: .forAppLanguage(), comment: "Multiple dives count in calendar heatmap month header"), diveCount)
                    Text(verbatim: label)
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
                    let divesOnDay = cachedDivesByDay[day] ?? []
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
                        if !divesOnDay.isEmpty {
                            selectedDay = day
                            selectedDayDives = divesOnDay
                            showDaySheet = true
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

// MARK: - Day Dives Sheet

struct DayDivesSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Query(sort: \Dive.timestamp, order: .reverse) private var allDives: [Dive]

    let day: Date
    let dives: [Dive]
    let diverFilter: String

    private var numberMap: [PersistentIdentifier: Int] {
        let numbering = diverFilter.isEmpty
            ? allDives
            : allDives.filter { $0.diverName == diverFilter }
        let total = numbering.count
        return Dictionary(uniqueKeysWithValues: numbering.enumerated().map {
            ($0.element.persistentModelID, total - $0.offset)
        })
    }

    private var formattedDay: String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "EEEEddMMMMyyyy", options: 0, locale: locale)
        return formatter.string(from: day)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(dives) { dive in
                    NavigationLink(destination: DiveDetailView(dive: dive)) {
                        DiveRowView(
                            dive: dive,
                            diveNumber: numberMap[dive.persistentModelID] ?? 0
                        )
                    }
                    .listRowBackground(Color.primary.opacity(0.07))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.platformBackground.ignoresSafeArea())
            #if os(iOS)
            .listStyle(.plain)
            #endif
            .navigationTitle(formattedDay)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.cyan)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 650, minHeight: 400, idealHeight: 600)
        #endif
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
