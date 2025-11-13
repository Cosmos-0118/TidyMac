import SwiftUI

struct DiagnosticsPanel: View {
    @ObservedObject var center: DiagnosticsCenter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.designSystemPalette) private var palette

    @State private var categoryFilter: CategoryFilter = .all
    @State private var severityFilter: SeverityFilter = .all

    private var filteredEntries: [DiagnosticsEntry] {
        var entries = center.entries
        switch categoryFilter {
        case .all:
            break
        case .category(let category):
            entries = entries.filter { $0.category == category }
        }

        switch severityFilter {
        case .all:
            break
        case .severity(let severity):
            entries = entries.filter { $0.severity == severity }
        }

        return entries.sorted { $0.timestamp > $1.timestamp }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                    .padding(.horizontal, DesignSystem.Spacing.medium)
                    .padding(.vertical, DesignSystem.Spacing.small)
                    .background(palette.surface.opacity(0.9))

                if filteredEntries.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filteredEntries) { entry in
                        DiagnosticsRow(entry: entry, palette: palette)
                            .listRowBackground(Color.clear)
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .background(palette.background)
                }
            }
            .background(palette.background.ignoresSafeArea())
            .navigationTitle("Diagnostics")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear") { center.clear() }
                        .disabled(center.entries.isEmpty)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .accessibilityIdentifier("DiagnosticsPanel")
    }

    private var filterBar: some View {
        HStack(spacing: DesignSystem.Spacing.medium) {
            Picker("Category", selection: $categoryFilter) {
                Text("All Categories").tag(CategoryFilter.all)
                ForEach(DiagnosticsCategory.allCases) { category in
                    Text(category.displayName).tag(CategoryFilter.category(category))
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Diagnostics category filter")

            Picker("Severity", selection: $severityFilter) {
                Text("All Levels").tag(SeverityFilter.all)
                ForEach(DiagnosticsSeverity.allCases, id: \.self) { severity in
                    Text(severity.label).tag(SeverityFilter.severity(severity))
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Diagnostics severity filter")

            Spacer()

            Text("Showing \(filteredEntries.count) item\(filteredEntries.count == 1 ? "" : "s")")
                .font(DesignSystem.Typography.caption)
                .foregroundColor(palette.secondaryText)
                .accessibilityHidden(true)
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.medium) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 48))
                .foregroundColor(palette.accentGreen)
            Text("No diagnostics recorded yet.")
                .font(DesignSystem.Typography.headline)
                .foregroundColor(palette.primaryText)
            Text("As you use MacCleaner, service warnings and errors will appear here for easy debugging.")
                .font(DesignSystem.Typography.caption)
                .foregroundColor(palette.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignSystem.Spacing.large)
        }
    }

    private struct DiagnosticsRow: View {
        let entry: DiagnosticsEntry
        let palette: DesignSystemPalette

        var body: some View {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.medium) {
                Circle()
                    .fill(color(for: entry.severity).opacity(0.9))
                    .frame(width: 12, height: 12)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
                    HStack {
                        Text(entry.category.displayName.uppercased())
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(palette.secondaryText)
                        Spacer()
                        Text(Self.timestampFormatter.string(from: entry.timestamp))
                            .font(DesignSystem.Typography.caption)
                            .foregroundColor(palette.secondaryText)
                    }

                    Text(entry.message)
                        .font(DesignSystem.Typography.body)
                        .foregroundColor(palette.primaryText)

                    if let suggestion = entry.suggestion, !suggestion.isEmpty {
                        Text(suggestion)
                            .font(DesignSystem.Typography.caption)
                            .foregroundColor(palette.accentGray)
                    }

                    if !entry.metadata.isEmpty {
                        Text(Self.formatMetadata(entry.metadata))
                            .font(DesignSystem.Typography.caption)
                            .foregroundColor(palette.secondaryText)
                    }

                    Text(entry.severity.label.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(color(for: entry.severity))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(color(for: entry.severity).opacity(0.2))
                        .clipShape(Capsule())
                }
                .padding(.vertical, DesignSystem.Spacing.small)
                .padding(.horizontal, DesignSystem.Spacing.medium)
                .background(palette.surface.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }

        private static let timestampFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .medium
            return formatter
        }()

        private func color(for severity: DiagnosticsSeverity) -> Color {
            switch severity {
            case .info:
                return palette.accentGray
            case .warning:
                return palette.accentGreen
            case .error:
                return palette.accentRed
            }
        }

        private static func formatMetadata(_ metadata: [String: String]) -> String {
            metadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: " • ")
        }
    }

    private enum CategoryFilter: Hashable {
        case all
        case category(DiagnosticsCategory)
    }

    private enum SeverityFilter: Hashable {
        case all
        case severity(DiagnosticsSeverity)
    }
}
#Preview {
    DiagnosticsPanel(center: DiagnosticsCenter.shared)
        .environment(\.designSystemPalette, DesignSystemPalette.macCleanerDark)
}
