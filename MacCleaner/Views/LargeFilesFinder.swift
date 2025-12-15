import SwiftUI
#if DEBUG
import AppKit
#endif

struct LargeFilesFinder: View {
    @Environment(\.designSystemPalette) private var palette
    @Namespace private var overlayNamespace

    private let autoScan: Bool
    @StateObject private var viewModel: LargeFilesFinderViewModel
    @State private var sortOrder: [KeyPathComparator<FileDetail>]

    init(autoScan: Bool = false, viewModel: LargeFilesFinderViewModel? = nil) {
        self.autoScan = autoScan
        let resolvedModel = viewModel ?? LargeFilesFinderViewModel.shared
        _viewModel = StateObject(wrappedValue: resolvedModel)
        _sortOrder = State(initialValue: [KeyPathComparator(\.size, order: .reverse)])
    }

    init(previewState: LargeFilesPreviewState) {
        autoScan = false
        let previewModel = LargeFilesFinderViewModel(
            service: FileSystemLargeFileScanningService(),
            initialFiles: previewState.files,
            scanCompleted: previewState.scanCompleted,
            totalFiles: previewState.totalFiles,
            scannedFiles: previewState.scannedFiles,
            excluded: previewState.excludedFileIDs,
            selection: previewState.selection,
            permissionIssue: previewState.permissionIssue,
            permissionMessage: previewState.permissionMessage
        )
        _viewModel = StateObject(wrappedValue: previewModel)
        _sortOrder = State(initialValue: previewState.sortOrder)
        previewModel.sort(using: previewState.sortOrder)
    }

    var body: some View {
        ZStack {
            palette.background
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.large) {
                header
                contentSection
                Spacer()
            }
            .padding(DesignSystem.Spacing.xLarge)
            .animation(.spring(response: 0.45, dampingFraction: 0.85, blendDuration: 0.18), value: showOverlay)
        }
        .overlay(alignment: .center) {
            if showOverlay {
                overlayCard
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .center)))
            }
        }
        .dynamicTypeSize(.medium ... .accessibility3)
        .onAppear {
            viewModel.handleAppear(autoScan: autoScan)
        }
        .onChange(of: sortOrder) { newOrder in
            viewModel.sort(using: newOrder)
        }
    }

    private var showOverlay: Bool {
        viewModel.isScanning
    }

    private var selectionBinding: Binding<Set<FileDetail.ID>> {
        Binding(
            get: { viewModel.selection },
            set: { viewModel.selection = $0 }
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
            Text("Large & Old Files")
                .font(DesignSystem.Typography.title)
                .foregroundColor(palette.primaryText)

            HStack(spacing: DesignSystem.Spacing.medium) {
                Text(viewModel.scanCompleted ? scanSummary : "Press Scan to map large and old files.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(palette.secondaryText)

                Spacer()

                Button {
                    viewModel.startScan()
                } label: {
                    Label(viewModel.scanCompleted ? "Rescan" : "Scan", systemImage: viewModel.scanCompleted ? "arrow.clockwise" : "play.circle")
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(viewModel.isScanning)
            }
        }
    }

    private var scanSummary: String {
        let retained = viewModel.largeFiles.count - viewModel.excludedFileIDs.count
        if viewModel.largeFiles.isEmpty {
            return "No flagged files in the latest scan."
        }
        if viewModel.excludedFileIDs.isEmpty {
            return "\(viewModel.largeFiles.count) files ready for review."
        }
        return "\(retained) files ready • \(viewModel.excludedFileIDs.count) excluded."
    }

    @ViewBuilder
    private var contentSection: some View {
        permissionAlert

        if viewModel.isScanning {
            loadingState
        } else if viewModel.scanCompleted {
            if viewModel.largeFiles.isEmpty {
                StatusCard(title: "No Findings", iconName: "checkmark.circle", accent: palette.accentGreen) {
                    Text("Great news! We didn't detect any large, outdated files that need attention.")
                        .font(DesignSystem.Typography.body)
                        .foregroundColor(palette.primaryText)
                }
            } else {
                tableSection
            }
        } else {
            readyState
        }
    }

    private var readyState: some View {
        StatusCard(title: "Ready to Scan", iconName: "folder.badge.clock", accent: palette.accentGreen) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
                Text("Find large and old files when you’re ready.")
                    .font(DesignSystem.Typography.body)
                    .foregroundColor(palette.primaryText)

                Button {
                    viewModel.startScan()
                } label: {
                    Label("Start Scan", systemImage: "play.circle")
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .disabled(viewModel.isScanning)
            }
        }
    }

    @ViewBuilder
    private var permissionAlert: some View {
        if viewModel.permissionIssue, let message = viewModel.permissionMessage {
            StatusCard(title: "Permissions Required", iconName: "lock.shield", accent: palette.accentRed) {
                Text(message)
                    .font(DesignSystem.Typography.body)
                    .foregroundColor(palette.primaryText)
                FullDiskAccessButton()
            }
        }
    }

    private var tableSection: some View {
        VStack(spacing: DesignSystem.Spacing.medium) {
            Table(viewModel.largeFiles, selection: selectionBinding, sortOrder: $sortOrder) {
                TableColumn("File", value: \.name) { file in
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xSmall) {
                        Text(file.name)
                            .font(DesignSystem.Typography.headline)
                            .foregroundColor(palette.primaryText)
                        Text(file.path)
                            .font(DesignSystem.Typography.caption)
                            .foregroundColor(palette.secondaryText)
                    }
                    .padding(.vertical, DesignSystem.Spacing.xSmall)
                }
                .width(min: 220)

                TableColumn("Size", value: \.size) { file in
                    Text(formatBytes(file.size))
                        .font(DesignSystem.Typography.body)
                        .foregroundColor(palette.primaryText)
                }
                .width(120)

                TableColumn("Modified", value: \.modificationDate) { file in
                    Text(formatDate(file.modificationDate))
                        .font(DesignSystem.Typography.body)
                        .foregroundColor(palette.primaryText)
                }
                .width(140)

                TableColumn("Exclude") { file in
                    Toggle(isOn: exclusionBinding(for: file)) {
                        Text("Exclude")
                            .font(DesignSystem.Typography.caption)
                            .foregroundColor(palette.secondaryText)
                    }
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Exclude \(file.name) from deletion actions")
                }
                .width(90)

                TableColumn("Actions") { file in
                    Button {
                        viewModel.delete(file)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(DestructiveButtonStyle())
                    .disabled(viewModel.isExcluded(file.id))
                    .help(viewModel.isExcluded(file.id) ? "File excluded from removal." : "Delete \(file.name) now")
                }
                .width(140)
            }
            .background(palette.surface.opacity(0.92))
            .frame(minHeight: 260)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(palette.accentGray.opacity(0.25), lineWidth: 1)
            )

            footerBar
        }
    }

    private var footerBar: some View {
        HStack(spacing: DesignSystem.Spacing.medium) {
            let deletableSelection = viewModel.largeFiles.filter { viewModel.selection.contains($0.id) && !viewModel.isExcluded($0.id) }

            Button {
                viewModel.delete(deletableSelection)
            } label: {
                Label("Delete Selected", systemImage: "trash.fill")
            }
            .buttonStyle(DestructiveButtonStyle())
            .disabled(deletableSelection.isEmpty)
            .accessibilityHint("Deletes selected files that are not excluded")

            Button {
                viewModel.startScan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(SecondaryButtonStyle())

            Spacer()

            Text("\(viewModel.largeFiles.count) flagged • \(viewModel.excludedFileIDs.count) excluded")
                .font(DesignSystem.Typography.caption)
                .foregroundColor(palette.secondaryText)
        }
    }

    private var overlayCard: some View {
        ZStack {
            palette.background.opacity(0.55)
                .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(palette.surface.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(palette.accentGreen.opacity(0.25), lineWidth: 1)
                )
                .shadow(color: palette.accentGray.opacity(0.35), radius: 28, x: 0, y: 12)
                .frame(maxWidth: 520)
                .frame(height: 260)
                .overlay(alignment: .center) {
                    VStack(spacing: DesignSystem.Spacing.large) {
                        HStack(spacing: DesignSystem.Spacing.small) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundColor(palette.accentGreen)
                            Text("Scanning for Large Files")
                                .font(DesignSystem.Typography.headline)
                                .foregroundColor(palette.primaryText)
                        }

                        VStack(spacing: DesignSystem.Spacing.small) {
                            ProgressView(
                                value: viewModel.totalFiles > 0 ? Double(viewModel.scannedFiles) : nil,
                                total: Double(max(viewModel.totalFiles, 1))
                            )
                            .progressViewStyle(.linear)
                            .tint(palette.accentGreen)
                            .scaleEffect(x: 1.05, y: 1.05, anchor: .center)

                            Text("We’re mapping your disks to find large and old files. You can keep browsing.")
                                .font(DesignSystem.Typography.caption)
                                .foregroundColor(palette.secondaryText)
                                .multilineTextAlignment(.center)

                            if viewModel.totalFiles > 0 {
                                Text("Scanned \(viewModel.scannedFiles) of \(viewModel.totalFiles) files")
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundColor(palette.secondaryText)
                            }
                        }
                    }
                    .padding(DesignSystem.Spacing.xLarge)
                }
        }
    }

    private var loadingState: some View {
        StatusCard(title: "Scanning", iconName: "magnifyingglass.circle.fill", accent: palette.accentGreen) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
                Text("Scanning for large and old files…")
                    .font(DesignSystem.Typography.body)
                    .foregroundColor(palette.primaryText)
                ProgressView(value: Double(viewModel.scannedFiles), total: Double(max(viewModel.totalFiles, 1)))
                    .tint(palette.accentGreen)
                Text("Scanned \(viewModel.scannedFiles) of \(viewModel.totalFiles) files")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(palette.secondaryText)
            }
        }
    }

    private func updateExclusion(for id: FileDetail.ID, isExcluded: Bool) {
        viewModel.toggleExclusion(for: id, isExcluded: isExcluded)
    }

    private func exclusionBinding(for file: FileDetail) -> Binding<Bool> {
        Binding(
            get: { viewModel.isExcluded(file.id) },
            set: { updateExclusion(for: file.id, isExcluded: $0) }
        )
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    struct LargeFilesPreviewState {
        let files: [FileDetail]
        let scanCompleted: Bool
        let totalFiles: Int
        let scannedFiles: Int
        let sortOrder: [KeyPathComparator<FileDetail>]
        let excludedFileIDs: Set<FileDetail.ID>
        let selection: Set<FileDetail.ID>
        let permissionIssue: Bool
        let permissionMessage: String?
    }

    #if DEBUG
    private enum LargeFilesPreviewData {
        static var loaded: [FileDetail] {
            guard let asset = NSDataAsset(name: "LargeFilesSample") else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode([FileDetail].self, from: asset.data)) ?? []
        }
    }

    #Preview("Large Files • Loading") {
        LargeFilesFinder(previewState: LargeFilesPreviewState(
            files: [],
            scanCompleted: false,
            totalFiles: 2800,
            scannedFiles: 1260,
            sortOrder: [KeyPathComparator(\.size, order: .reverse)],
            excludedFileIDs: [],
            selection: [],
            permissionIssue: true,
            permissionMessage: "Grant Full Disk Access to scan your Downloads folder."
        ))
        .environment(\.designSystemPalette, .macCleanerDark)
    }

    #Preview("Large Files • Loaded") {
        LargeFilesFinder(previewState: LargeFilesPreviewState(
            files: LargeFilesPreviewData.loaded,
            scanCompleted: true,
            totalFiles: LargeFilesPreviewData.loaded.count,
            scannedFiles: LargeFilesPreviewData.loaded.count,
            sortOrder: [KeyPathComparator(\.size, order: .reverse)],
            excludedFileIDs: Set([LargeFilesPreviewData.loaded.first?.id].compactMap { $0 }),
            selection: [],
            permissionIssue: false,
            permissionMessage: nil
        ))
        .environment(\.designSystemPalette, .macCleanerDark)
    }
    #endif
}
