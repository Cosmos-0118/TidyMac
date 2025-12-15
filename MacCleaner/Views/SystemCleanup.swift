import SwiftUI

struct SystemCleanup: View {
	@Environment(\.designSystemPalette) private var palette
	@Namespace private var overlayNamespace

	private let autoScan: Bool
	@StateObject private var viewModel: SystemCleanupViewModel
	@State private var selectedStep: CleanupStep?
	@State private var pageByStep: [CleanupStep: Int] = [:]

	init(
			services: [AnyCleanupService] = CleanupServiceRegistry.default,
			autoScan: Bool = true,
			viewModel: SystemCleanupViewModel? = nil
		) {
			self.autoScan = autoScan
			if let viewModel {
				_viewModel = StateObject(wrappedValue: viewModel)
			} else {
				_viewModel = StateObject(wrappedValue: SystemCleanupViewModel(services: services))
			}
		}

#if DEBUG
	init(
			previewCategories: [CleanupCategory],
			previewSummary: CleanupRunSummary? = nil,
			previewStates: [CleanupStep: CleanupStepState] = [:],
			previewProgress: [CleanupStep: Double] = [:]
		) {
			autoScan = false
			let previewModel = SystemCleanupViewModel(services: [])
			previewModel.categories = previewCategories
			if previewStates.isEmpty {
				previewModel.stepStates = Dictionary(uniqueKeysWithValues: CleanupStep.allCases.map { ($0, .pending) })
			} else {
				previewModel.stepStates = previewStates
			}
			previewModel.stepProgress = previewProgress
			previewModel.runSummary = previewSummary
			_viewModel = StateObject(wrappedValue: previewModel)
		}
#endif

	var body: some View {
		ZStack {
			palette.background
				.ignoresSafeArea()

			VStack(alignment: .leading, spacing: DesignSystem.Spacing.large) {
				header

				if viewModel.isRunning {
					runningStatusCard
				}

				if let summary = viewModel.runSummary {
					summaryCard(summary)
				}

				if viewModel.isScanning {
					scanningCard
				} else if viewModel.categories.isEmpty {
					emptyStateCard
				} else {
					twoColumnLayout
				}
			}
			.padding(DesignSystem.Spacing.xLarge)
			.animation(.spring(response: 0.5, dampingFraction: 0.85, blendDuration: 0.2), value: showOverlay)
		}
		.overlay(alignment: .center) {
			if showOverlay {
				cleanupOverlay
					.transition(
						.opacity.combined(with: .scale(scale: 0.94, anchor: .center))
					)
			}
		}
		.dynamicTypeSize(.medium ... .accessibility3)
		.onAppear {
			viewModel.handleAppear(autoScan: autoScan)
			selectDefaultStepIfNeeded()
		}
		.onChange(of: viewModel.categories) { _ in
			selectDefaultStepIfNeeded()
		}
		.onChange(of: selectedStep) { _ in
			resetPageForSelection()
		}
	}

	private var showOverlay: Bool {
		viewModel.isRunning || viewModel.isScanning
	}

	private var header: some View {
		VStack(alignment: .leading, spacing: DesignSystem.Spacing.large) {
			VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
				Text("System Cleanup")
					.font(DesignSystem.Typography.title)
					.foregroundColor(palette.primaryText)

				Text("Review recommended cleanup steps before deleting caches or developer artifacts.")
					.font(DesignSystem.Typography.body)
					.foregroundColor(palette.secondaryText)

				Text(selectionSummary)
					.font(DesignSystem.Typography.caption)
					.foregroundColor(palette.secondaryText)
			}

			actionBar
		}
	}

	private var actionBar: some View {
		HStack(spacing: DesignSystem.Spacing.medium) {
			Button(allSelected ? "Deselect All" : "Select All") {
				viewModel.selectAll(!allSelected)
			}
			.buttonStyle(SecondaryButtonStyle())
			.disabled(viewModel.isScanning || viewModel.isRunning)

			Button {
				Task { await viewModel.scanServices() }
			} label: {
				Label("Rescan", systemImage: "arrow.clockwise")
			}
			.buttonStyle(SecondaryButtonStyle())
			.disabled(viewModel.isScanning || viewModel.isRunning)

			Spacer()

			deleteButton
		}
	}

	private var deleteButton: some View {
		Button {
			Task { await viewModel.runCleanup() }
		} label: {
			Label("Delete Selected", systemImage: "trash")
		}
		.buttonStyle(PrimaryActionButtonStyle())
		.disabled(!canRunCleanup || viewModel.isScanning || viewModel.isRunning)
		.accessibilityHint("Deletes all selected cleanup items")
	}

	private var runningStatusCard: some View {
		StatusCard(
			title: "Cleanup in Progress",
			iconName: "trash.fill",
			accent: palette.accentGreen
		) {
			VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
				ProgressView(value: viewModel.overallProgress, total: 1.0)
					.tint(palette.accentGreen)

				Text(progressDescription)
					.font(DesignSystem.Typography.caption)
					.foregroundColor(palette.secondaryText)
			}
		}
	}

	private var scanningCard: some View {
		StatusCard(title: "Scanning Cleanup Targets", iconName: "magnifyingglass.circle.fill", accent: palette.accentGray) {
			VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
				ProgressView()
					.progressViewStyle(.circular)
					.tint(palette.accentGreen)

				Text("Gathering cache, large file, and Xcode artifact information…")
					.font(DesignSystem.Typography.caption)
					.foregroundColor(palette.secondaryText)
			}
		}
	}

	private var cleanupOverlay: some View {
		ZStack {
			palette.background.opacity(0.55)
				.ignoresSafeArea()

			VStack(spacing: DesignSystem.Spacing.medium) {
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
								Image(systemName: viewModel.isScanning ? "sparkles" : "arrow.2.circlepath")
									.font(.system(size: 24, weight: .semibold))
									.foregroundColor(palette.accentGreen)
								Text(viewModel.isScanning ? "Preparing Cleanup" : "Running Cleanup")
									.font(DesignSystem.Typography.headline)
									.foregroundColor(palette.primaryText)
							}

							VStack(spacing: DesignSystem.Spacing.small) {
								ProgressView(value: viewModel.isRunning ? viewModel.overallProgress : nil)
									.progressViewStyle(.linear)
									.tint(palette.accentGreen)
									.scaleEffect(x: 1.05, y: 1.05, anchor: .center)
								Text(viewModel.isScanning ? "Gathering cache, large file, and Xcode artifact info" : progressDescription)
									.font(DesignSystem.Typography.caption)
									.foregroundColor(palette.secondaryText)
							}

							Text("You can keep exploring while we prepare your cleanup.")
								.font(DesignSystem.Typography.body)
								.foregroundColor(palette.secondaryText)
						}
						.padding(DesignSystem.Spacing.xLarge)
					}
			}
		}
	}

	private var emptyStateCard: some View {
		StatusCard(title: "No Cleanup Targets", iconName: "checkmark.circle.fill", accent: palette.accentGreen) {
			Text("MacCleaner didn’t find any recommended cleanup actions. Rescan later to keep things tidy.")
				.font(DesignSystem.Typography.body)
				.foregroundColor(palette.primaryText)
		}
	}

	private func summaryCard(_ summary: CleanupRunSummary) -> some View {
		StatusCard(
			title: summary.headline,
			iconName: summary.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
			accent: summary.success ? palette.accentGreen : palette.accentRed
		) {
			VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
				ForEach(Array(summary.details.enumerated()), id: \.offset) { entry in
					Text(entry.element)
						.font(DesignSystem.Typography.caption)
						.foregroundColor(palette.primaryText)
						.frame(maxWidth: .infinity, alignment: .leading)
				}

				if let recovery = summary.recovery {
					Divider()
					Text(recovery)
						.font(DesignSystem.Typography.caption)
						.foregroundColor(palette.secondaryText)
						.frame(maxWidth: .infinity, alignment: .leading)
				}

				Text("Cleanup executed.")
					.font(DesignSystem.Typography.caption)
					.foregroundColor(palette.secondaryText)
			}
		}
	}

	private var progressDescription: String {
		let clamped = min(max(viewModel.overallProgress, 0), 1)
		let percentage = Int((clamped * 100).rounded())
		return "Deleting files… \(percentage)% complete"
	}

	private var canRunCleanup: Bool {
		viewModel.categories.contains { $0.hasSelection }
	}

	private var twoColumnLayout: some View {
		HStack(alignment: .top, spacing: DesignSystem.Spacing.large) {
			categorySidebar
			detailPane
		}
	}

	private var categorySidebar: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
				ForEach($viewModel.categories) { category in
					let step = category.wrappedValue.step
					Button {
						selectedStep = step
					} label: {
						CategorySidebarRow(
							category: category.wrappedValue,
							state: viewModel.stepStates[step],
							progress: viewModel.stepProgress[step],
							isSelected: selectedStep == step
						)
					}
					.buttonStyle(.plain)
				}
			}
		}
		.frame(width: 260, alignment: .top)
	}

	@ViewBuilder
	private var detailPane: some View {
		if let step = selectedStep, let categoryBinding = binding(for: step) {
			CategoryDetailView(
				category: categoryBinding,
				page: currentPage(for: step),
				pageSize: 100,
				onPageChange: { newPage in setPage(newPage, for: step) },
				disabled: viewModel.isRunning || viewModel.isScanning
			)
			.frame(maxWidth: .infinity, alignment: .topLeading)
		} else {
			Text("Select a category to review its items.")
				.font(DesignSystem.Typography.body)
				.foregroundColor(palette.secondaryText)
				.frame(maxWidth: .infinity, alignment: .leading)
		}
	}

	private var allSelected: Bool {
		guard !viewModel.categories.isEmpty else { return false }
		return viewModel.categories.allSatisfy { category in
			guard category.isEnabled, !category.items.isEmpty else { return false }
			return category.items.allSatisfy { $0.isSelected }
		}
	}

	private var selectionSummary: String {
		let enabledSteps = viewModel.categories.filter { $0.isEnabled }
		guard !enabledSteps.isEmpty else { return "No cleanup steps selected yet." }

		let totalItems = enabledSteps.reduce(0) { $0 + $1.selectedCount }
		guard totalItems > 0 else { return "Select individual items to include them in cleanup." }

		let itemLabel = totalItems == 1 ? "item" : "items"
		let totalSize = enabledSteps.compactMap { $0.selectedSize }.reduce(Int64(0), +)

		if totalSize > 0 {
			return "\(totalItems) \(itemLabel) selected (~\(formatBytes(totalSize)))."
		}
		return "\(totalItems) \(itemLabel) selected."
	}

	private func selectDefaultStepIfNeeded() {
		guard !viewModel.categories.isEmpty else {
			selectedStep = nil
			return
		}
		if let selectedStep, viewModel.categories.contains(where: { $0.step == selectedStep }) {
			return
		}
		selectedStep = viewModel.categories.first?.step
	}

	private func resetPageForSelection() {
		guard let step = selectedStep else { return }
		pageByStep[step] = 0
	}

	private func currentPage(for step: CleanupStep) -> Int {
		max(0, pageByStep[step] ?? 0)
	}

	private func setPage(_ page: Int, for step: CleanupStep) {
		pageByStep[step] = max(0, page)
	}

	private func binding(for step: CleanupStep) -> Binding<CleanupCategory>? {
		guard let index = viewModel.categories.firstIndex(where: { $0.step == step }) else { return nil }
		return $viewModel.categories[index]
	}

}

private struct CategorySidebarRow: View {
	@Environment(\.designSystemPalette) private var palette

	let category: CleanupCategory
	let state: CleanupStepState?
	let progress: Double?
	let isSelected: Bool

	var body: some View {
		HStack(alignment: .top, spacing: DesignSystem.Spacing.small) {
			Image(systemName: category.step.icon)
				.foregroundColor(palette.accentGreen)
				.font(.system(size: 16, weight: .semibold))

			VStack(alignment: .leading, spacing: DesignSystem.Spacing.xSmall) {
				Text(category.step.title)
					.font(DesignSystem.Typography.body)
					.foregroundColor(palette.primaryText)

				Text(sidebarSummary)
					.font(DesignSystem.Typography.caption)
					.foregroundColor(palette.secondaryText)

				if let descriptor = stateDescriptor() {
					Label(descriptor.title, systemImage: descriptor.icon)
						.font(DesignSystem.Typography.caption)
						.foregroundColor(descriptor.color)
				}
			}

			Spacer()

			if category.isEnabled {
				Image(systemName: "checkmark.circle.fill")
					.foregroundColor(palette.accentGreen)
			} else {
				Image(systemName: "circle")
					.foregroundColor(palette.accentGray)
			}
		}
		.padding(DesignSystem.Spacing.medium)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(isSelected ? palette.surface.opacity(0.8) : palette.surface.opacity(0.4))
		.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: 12, style: .continuous)
				.stroke(isSelected ? palette.accentGreen.opacity(0.6) : palette.accentGray.opacity(0.2), lineWidth: 1)
		)
	}

	private var sidebarSummary: String {
		let countSummary = category.totalCount > 0 ? "\(category.selectedCount)/\(category.totalCount)" : "No items"
		if let size = category.selectedSize ?? category.totalSize {
			return "\(countSummary) • ~\(formatBytes(size))"
		}
		return countSummary
	}

	private func stateDescriptor() -> (title: String, icon: String, color: Color)? {
		switch state ?? .pending {
		case .pending:
			return nil
		case .running:
			return ("Running", "arrow.triangle.2.circlepath", palette.accentGreen)
		case .success:
			return ("Completed", "checkmark.circle", palette.accentGreen)
		case .failure:
			return ("Needs Attention", "exclamationmark.triangle", palette.accentRed)
		}
	}
}

private struct CategoryDetailView: View {
	@Environment(\.designSystemPalette) private var palette

	@Binding var category: CleanupCategory
	let page: Int
	let pageSize: Int
	let onPageChange: (Int) -> Void
	let disabled: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: DesignSystem.Spacing.medium) {
			header
			Divider()
			itemsList
			pagination
		}
	}

	private var header: some View {
		HStack(alignment: .center, spacing: DesignSystem.Spacing.medium) {
			VStack(alignment: .leading, spacing: DesignSystem.Spacing.xSmall) {
				Text(category.step.title)
					.font(DesignSystem.Typography.headline)
					.foregroundColor(palette.primaryText)

				Text(summaryLine)
					.font(DesignSystem.Typography.caption)
					.foregroundColor(palette.secondaryText)
			}

			Spacer()

			Toggle(isOn: $category.isEnabled) {
				Text("Enable")
					.foregroundColor(palette.secondaryText)
			}
			.toggleStyle(.switch)
			.disabled(category.items.isEmpty || disabled)
		}
	}

	private var itemsList: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
				ForEach(pagedIndices, id: \.self) { index in
					CleanupItemRow(
						item: $category.items[index],
						isEnabled: category.isEnabled && !disabled
					)
				}

				if category.items.isEmpty {
					Text("No files discovered for this category.")
						.font(DesignSystem.Typography.caption)
						.foregroundColor(palette.secondaryText)
				}
			}
		}
	}

	private var pagination: some View {
		let totalPages = max(1, Int(ceil(Double(category.items.count) / Double(pageSize))))
		let clampedPage = min(max(page, 0), totalPages - 1)
		return HStack {
			Button {
				onPageChange(max(clampedPage - 1, 0))
			} label: {
				Label("Prev", systemImage: "chevron.left")
			}
			.buttonStyle(SecondaryButtonStyle())
			.disabled(clampedPage == 0)

			Text("Page \(clampedPage + 1) of \(totalPages)")
				.font(DesignSystem.Typography.caption)
				.foregroundColor(palette.secondaryText)
				.frame(maxWidth: .infinity)

			Button {
				onPageChange(min(clampedPage + 1, totalPages - 1))
			} label: {
				Label("Next", systemImage: "chevron.right")
			}
			.buttonStyle(SecondaryButtonStyle())
			.disabled(clampedPage >= totalPages - 1)
		}
	}

	private var summaryLine: String {
		let countSummary = category.totalCount > 0 ? "\(category.selectedCount) of \(category.totalCount) selected" : "No items detected"
		if let size = category.selectedSize ?? category.totalSize {
			return "\(countSummary) • ~\(formatBytes(size))"
		}
		return countSummary
	}

	private var pagedIndices: [Int] {
		let total = category.items.count
		guard total > 0 else { return [] }
		let totalPages = max(1, Int(ceil(Double(total) / Double(pageSize))))
		let clampedPage = min(max(page, 0), totalPages - 1)
		let start = min(clampedPage * pageSize, total)
		let end = min(start + pageSize, total)
		return Array(category.items.indices[start..<end])
	}
}

private struct CleanupCategoryCard: View {
	@Environment(\.designSystemPalette) private var palette

	@Binding var category: CleanupCategory
	let state: CleanupStepState?
	let progress: Double?
	let disabled: Bool

	init(
		category: Binding<CleanupCategory>,
		state: CleanupStepState?,
		progress: Double?,
		disabled: Bool
	) {
		_category = category
		self.state = state
		self.progress = progress
		self.disabled = disabled
	}

	var body: some View {
		VStack(alignment: .leading, spacing: DesignSystem.Spacing.medium) {
			header
			statusSection
			contentSection
			footerNotes
		}
		.padding(DesignSystem.Spacing.large)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(palette.surface.opacity(0.95))
		.clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: 18, style: .continuous)
				.stroke(palette.accentGray.opacity(0.25), lineWidth: 1)
		)
	}

	private var header: some View {
		HStack(alignment: .top, spacing: DesignSystem.Spacing.medium) {
			iconView

			VStack(alignment: .leading, spacing: DesignSystem.Spacing.xSmall) {
				Text(category.step.title)
					.font(DesignSystem.Typography.headline)
					.foregroundColor(palette.primaryText)

				Text(category.step.detail)
					.font(DesignSystem.Typography.caption)
					.foregroundColor(palette.secondaryText)

				Text(selectionDescription)
					.font(DesignSystem.Typography.caption)
					.foregroundColor(palette.secondaryText)
			}

			Spacer()

			Toggle(isOn: $category.isEnabled) {
				Text("Enable")
					.foregroundColor(palette.secondaryText)
			}
			.toggleStyle(.switch)
			.disabled(category.items.isEmpty || disabled)
			.accessibilityLabel("Enable \(category.step.title)")
		}
	}

	private var statusSection: some View {
		VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
			let descriptor = stateDescriptor()

			Label(descriptor.title, systemImage: descriptor.icon)
				.font(DesignSystem.Typography.caption)
				.foregroundColor(descriptor.color)

			if case .success(let message) = state ?? .pending, !message.isEmpty {
				Text(message)
					.font(DesignSystem.Typography.caption)
					.foregroundColor(palette.secondaryText)
			}

			if case .failure(let message, let recovery) = state ?? .pending {
				Text(message)
					.font(DesignSystem.Typography.caption)
					.foregroundColor(palette.accentRed)

				if let recovery, !recovery.isEmpty {
					Text(recovery)
						.font(DesignSystem.Typography.caption)
						.foregroundColor(palette.secondaryText)
				}
			}

			if isRunning, let progress {
				ProgressView(value: min(max(progress, 0), 1))
					.tint(palette.accentGreen)
				Text("Processing… \(Int((min(max(progress, 0), 1) * 100).rounded()))%")
					.font(DesignSystem.Typography.caption)
					.foregroundColor(palette.secondaryText)
			}
		}
	}

	@ViewBuilder
	private var contentSection: some View {
		if category.items.isEmpty {
			Text(emptyStateMessage)
				.font(DesignSystem.Typography.caption)
				.foregroundColor(palette.secondaryText)
		} else {
			Divider()

			VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
				Text(categorySummary)
					.font(DesignSystem.Typography.caption)
					.foregroundColor(palette.secondaryText)
			}
		}
	}

	private var categorySummary: String {
		let selected = category.selectedCount
		let total = category.totalCount
		guard total > 0 else { return "No items detected." }
		let base = "\(selected) of \(total) selected"
		if let size = category.selectedSize ?? category.totalSize {
			return "\(base) • ~\(formatBytes(size))"
		}
		return base
	}

	@ViewBuilder
	private var footerNotes: some View {
		if let note = category.note, !note.isEmpty {
			Text(note)
				.font(DesignSystem.Typography.caption)
				.foregroundColor(palette.secondaryText)
		}

		if let error = category.error, !error.isEmpty {
			Text(error)
				.font(DesignSystem.Typography.caption)
				.foregroundColor(palette.accentRed)
		}
	}

	private var iconView: some View {
		ZStack {
			RoundedRectangle(cornerRadius: 14, style: .continuous)
				.fill(palette.accentGray.opacity(0.2))
				.frame(width: 52, height: 52)

			Image(systemName: category.step.icon)
				.font(.system(size: 22, weight: .medium))
				.foregroundColor(palette.accentGreen)
		}
	}

	private var selectionDescription: String {
		guard category.totalCount > 0 else { return "No items detected for this step yet." }
		let prefix = "\(category.selectedCount) of \(category.totalCount) selected"

		if let selectedSize = category.selectedSize {
			return "\(prefix) • ~\(formatBytes(selectedSize))"
		}
		return prefix
	}

	private var emptyStateMessage: String {
		if let error = category.error, !error.isEmpty {
			return error
		}
		if let note = category.note, !note.isEmpty {
			return note
		}
		return "Nothing to review here right now."
	}

	private var isRunning: Bool {
		if case .running = state { return true }
		return false
	}

	private func stateDescriptor() -> (title: String, icon: String, color: Color) {
		switch state ?? .pending {
		case .pending:
			return ("Pending", "clock", palette.secondaryText)
		case .running:
			return ("Running", "arrow.triangle.2.circlepath", palette.accentGreen)
		case .success:
			return ("Completed", "checkmark.circle", palette.accentGreen)
		case .failure:
			return ("Needs Attention", "exclamationmark.triangle", palette.accentRed)
		}
	}
}

private struct CleanupItemRow: View {
	@Environment(\.designSystemPalette) private var palette

	@Binding var item: CleanupCategory.CleanupItem
	let isEnabled: Bool

	var body: some View {
		Toggle(isOn: $item.isSelected) {
			VStack(alignment: .leading, spacing: DesignSystem.Spacing.xSmall) {
				HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.small) {
					Text(item.name)
						.font(DesignSystem.Typography.body)
						.foregroundColor(palette.primaryText)
						.lineLimit(1)

					Spacer(minLength: DesignSystem.Spacing.medium)

					if let size = item.size {
						Text(formatBytes(size))
							.font(DesignSystem.Typography.caption)
							.foregroundColor(palette.secondaryText)
							.fixedSize(horizontal: true, vertical: false)
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)

				Text(item.path)
					.font(DesignSystem.Typography.caption)
					.foregroundColor(palette.secondaryText)
					.lineLimit(1)
					.truncationMode(.middle)

				if let detail = item.detail, !detail.isEmpty {
					Text(detail)
						.font(DesignSystem.Typography.caption)
						.foregroundColor(palette.secondaryText)
				}

				if !item.reasons.isEmpty {
					VStack(alignment: .leading, spacing: DesignSystem.Spacing.xSmall) {
						ForEach(item.reasons) { reason in
							Text("• \(reason.labelLine)")
								.font(DesignSystem.Typography.caption)
								.foregroundColor(palette.secondaryText)
						}
					}
				}

				let decision = item.guardDecision
				let descriptor = guardDescriptor(for: decision)
				Label(descriptor.title, systemImage: descriptor.icon)
					.font(DesignSystem.Typography.caption)
					.foregroundColor(descriptor.color(palette))
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.toggleStyle(.checkbox)
		.disabled(!isEnabled)
	}
}

private extension CleanupReason {
	var labelLine: String {
		if let detail, !detail.isEmpty {
			return "\(label) — \(detail)"
		}
		return label
	}
}

private func guardDescriptor(for decision: DeletionGuard.Decision) -> (title: String, icon: String, color: (DesignSystemPalette) -> Color) {
	switch decision {
	case .allow:
		return ("Allowed", "checkmark.shield.fill", { $0.accentGreen })
	case .excluded:
		return ("Excluded by Preferences", "shield.fill", { $0.accentGray })
	case .restricted:
		return ("Restricted", "hand.raised.fill", { $0.accentRed })
	}
}

private func formatBytes(_ bytes: Int64) -> String {
	let formatter = ByteCountFormatter()
	formatter.allowedUnits = [.useGB, .useMB, .useKB]
	formatter.countStyle = .file
	return formatter.string(fromByteCount: bytes)
}

#if DEBUG
private enum SystemCleanupPreviewData {
	static let categories: [CleanupCategory] = [
		CleanupCategory(
			step: .systemCaches,
			items: [
				.init(
					path: "/Library/Caches/com.apple.Safari/Cache.db",
					name: "Safari Cache",
					size: 268_435_456,
					detail: "Last used 3 days ago"
				),
				.init(
					path: "/Users/demo/Library/Caches/com.apple.Preview/Preview.db",
					name: "Preview Cache",
					size: 92_532_480,
					detail: "Safe to remove"
				)
			],
			isEnabled: true,
			note: "Caches are re-created automatically."
		),
		CleanupCategory(
			step: .largeFiles,
			items: [
				.init(
					path: "/Users/demo/Downloads/WWDC-Session.mov",
					name: "WWDC Session Recording",
					size: 1_534_772_736,
					detail: "Large file, last opened 45 days ago"
				),
				.init(
					path: "/Users/demo/Documents/Archive.zip",
					name: "Old Project Archive",
					size: 812_646_400,
					detail: "7 months old"
				)
			],
			isEnabled: true
		),
		CleanupCategory(
			step: .xcodeArtifacts,
			items: [
				.init(
					path: "/Users/demo/Library/Developer/Xcode/DerivedData",
					name: "Derived Data",
					size: 4_826_337_280,
					detail: "Project build cache"
				)
			],
			isEnabled: true,
			error: nil,
			note: "Requires Xcode to be closed for best results."
		)
	]

	static let states: [CleanupStep: CleanupStepState] = [
		.systemCaches: .success(message: "Removed 3 cache folders"),
		.largeFiles: .pending,
		.xcodeArtifacts: .failure(message: "Failed to delete DerivedData", recovery: "Close Xcode and try again.")
	]

	static let summary = CleanupRunSummary(
		success: false,
		headline: "Cleanup completed with issues.",
		details: [
			"System Caches: Removed 2 folders (1.2 GB)",
			"Large & Old Files: Pending user confirmation"
		],
		recovery: "Close Xcode and retry removing build artifacts."
	)
}

#Preview("System Cleanup • Overview") {
	SystemCleanup(
		previewCategories: SystemCleanupPreviewData.categories,
		previewSummary: SystemCleanupPreviewData.summary,
		previewStates: SystemCleanupPreviewData.states,
		previewProgress: [.largeFiles: 0.45]
	)
	.environment(\.designSystemPalette, .macCleanerDark)
}
#endif
