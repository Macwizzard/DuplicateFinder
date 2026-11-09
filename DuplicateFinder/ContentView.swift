import SwiftUI
import AppKit

// MARK: - Sorting

enum GroupSort: String, CaseIterable, Identifiable {
    case savingsDesc  = "Largest savings"
    case sizeDesc     = "File size (largest)"
    case sizeAsc      = "File size (smallest)"
    case countDesc    = "Most duplicates"
    case dateNewest   = "Newest original"
    case dateOldest   = "Oldest original"

    var id: String { rawValue }
}

struct ContentView: View {

    /// How many groups are put on screen at once. A scan of a large tree can
    /// return thousands of groups and tens of thousands of files; handing all of
    /// them to SwiftUI at once exhausts the AttributeGraph node arena and aborts
    /// the process. Paging keeps the live view tree bounded regardless of result
    /// size, and the lazy container below keeps even one page mostly unbuilt.
    private static let pageSize = 200

    @ObservedObject var scanState: ScanState

    @State private var selectedDirectory: URL?
    @State private var groups: [DuplicateGroup] = []

    /// `groups` in `sortOrder`. Rebuilt only when the data or the order changes —
    /// sorting from inside `body` re-sorts on every layout pass instead.
    @State private var sortedGroups: [DuplicateGroup] = []
    @State private var visibleGroupCount = ContentView.pageSize

    @State private var selectedDuplicates: Set<UUID> = []
    /// Kept in step with `selectedDuplicates` so the footer never has to walk
    /// every group to total up the selection.
    @State private var selectedBytes: Int64 = 0
    @State private var totalRecoverable: Int64 = 0

    @State private var statusMessage = "Choose a folder to begin."
    @State private var progress: Double = 0
    @State private var errorMessage: String?
    @State private var sortOrder: GroupSort = .savingsDesc
    @State private var scanTask: Task<Void, Never>?

    /// Has to be `@State`, not `let`: mutating `scanState.isScanning` republishes
    /// to the App, which re-initialises this view. A fresh `let` scanner each time
    /// would hand `cancelScan()` a different actor than the scan is running on.
    @State private var scanner = DuplicateScanner()

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if scanState.isScanning { progressBar; Divider() }

            if sortedGroups.isEmpty {
                emptyState
            } else {
                resultsList
            }

            Divider()
            footer
        }
        .alert("Error",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } }),
               presenting: errorMessage) { _ in
            Button("OK") { errorMessage = nil }
        } message: { msg in
            Text(msg)
        }
        .onChange(of: sortOrder) { _ in rebuildSortedGroups() }
    }

    // MARK: - Subviews

    private var toolbar: some View {
        HStack {
            Button {
                chooseFolder()
            } label: {
                Label("Choose Folder…", systemImage: "folder")
            }
            .disabled(scanState.isScanning)

            if let dir = selectedDirectory {
                Text(dir.path)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if !sortedGroups.isEmpty && !scanState.isScanning {
                Picker("Sort", selection: $sortOrder) {
                    ForEach(GroupSort.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
            }

            // Scan or Cancel, depending on state
            if scanState.isScanning {
                Button(role: .destructive) {
                    cancelScan()
                } label: {
                    Label("Cancel Scan", systemImage: "xmark.circle")
                }
                .keyboardShortcut(".", modifiers: [.command])
            } else {
                Button {
                    startScan()
                } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                }
                .disabled(selectedDirectory == nil)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding()
    }

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: progress)
            Text(statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.on.doc")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(statusMessage).foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// A `ScrollView` + `LazyVStack` rather than a `List`. On macOS 12 a `List`
    /// is backed by `NSTableView`, which asks SwiftUI for the height of *every*
    /// changed row in one pass — and each of those measurements spins up a
    /// hosting view and a full layout graph for that row. Dropping thousands of
    /// rows in at once therefore materialises thousands of graphs in a single
    /// run-loop observer, which is what ran the AttributeGraph arena out of space.
    /// A lazy container only builds the rows actually on screen.
    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sortedGroups.prefix(visibleGroupCount)) { group in
                    groupSection(group)
                }
                if visibleGroupCount < sortedGroups.count {
                    pagingFooter
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func groupSection(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(formatBytes(group.size)) · \(group.duplicateCount) duplicate\(group.duplicateCount == 1 ? "" : "s")")
                    .font(.headline)
                Spacer()
                Button("Select All Duplicates") {
                    selectAllDuplicates(in: group)
                }
                .font(.caption)
                Button("Deselect All") {
                    deselectAllDuplicates(in: group)
                }
                .font(.caption)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            ForEach(group.files) { file in
                fileRow(file: file, in: group)
            }
        }
        .padding(.bottom, 6)
    }

    private var pagingFooter: some View {
        VStack(spacing: 6) {
            Text("Showing \(visibleGroupCount) of \(sortedGroups.count) groups")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Show \(min(Self.pageSize, sortedGroups.count - visibleGroupCount)) More") {
                visibleGroupCount = min(visibleGroupCount + Self.pageSize, sortedGroups.count)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    /// One row per file in a group. The "keeper" gets a filled radio button;
    /// others get a checkbox for trashing and an empty radio button to promote them.
    private func fileRow(file: FileEntry, in group: DuplicateGroup) -> some View {
        let isKeeper = file.id == group.keeperID

        return HStack(spacing: 8) {
            // Radio — click to mark as original/keeper
            Button {
                setKeeper(file.id, in: group.id)
            } label: {
                Image(systemName: isKeeper ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(isKeeper ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .help(isKeeper ? "This file will be kept" : "Mark this file as the original to keep")

            // Checkbox — only shown for non-keepers (keeper is never trashed)
            if isKeeper {
                Text("KEEP")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.yellow)
                    .frame(width: 60, alignment: .leading)
            } else {
                Toggle("", isOn: Binding(
                    get: { selectedDuplicates.contains(file.id) },
                    set: { on in
                        if on { select(file) } else { deselect(file) }
                    }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 60, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.path)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let date = file.creationDate {
                    Text("Created \(formatDate(date))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if !sortedGroups.isEmpty {
                Text("\(sortedGroups.count) group\(sortedGroups.count == 1 ? "" : "s") · \(formatBytes(totalRecoverable)) recoverable")
                    .foregroundColor(.secondary)
                if !selectedDuplicates.isEmpty {
                    Text("·").foregroundColor(.secondary)
                    Text("\(selectedDuplicates.count) selected (\(formatBytes(selectedBytes)))")
                        .foregroundColor(.accentColor)
                }
            }
            Spacer()
            Button(role: .destructive) {
                moveSelectedToTrash()
            } label: {
                Label("Move Selected to Trash", systemImage: "trash")
            }
            .disabled(selectedDuplicates.isEmpty || scanState.isScanning)
            .keyboardShortcut(.delete, modifiers: [.command])
        }
        .padding()
    }

    // MARK: - Derived state

    /// Recompute the sorted view of `groups` and the derived totals. Called when
    /// the data or the sort order changes — never from `body`.
    private func rebuildSortedGroups() {
        sortedGroups = sortedByCurrentOrder(groups)
        totalRecoverable = groups.reduce(0) { $0 + $1.reclaimableBytes }
        visibleGroupCount = Self.pageSize
    }

    private func sortedByCurrentOrder(_ groups: [DuplicateGroup]) -> [DuplicateGroup] {
        switch sortOrder {
        case .savingsDesc:
            return groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
        case .sizeDesc:
            return groups.sorted { $0.size > $1.size }
        case .sizeAsc:
            return groups.sorted { $0.size < $1.size }
        case .countDesc:
            return groups.sorted { $0.duplicateCount > $1.duplicateCount }
        case .dateNewest:
            return groups.sorted {
                ($0.keeper.creationDate ?? .distantPast) > ($1.keeper.creationDate ?? .distantPast)
            }
        case .dateOldest:
            return groups.sorted {
                ($0.keeper.creationDate ?? .distantFuture) < ($1.keeper.creationDate ?? .distantFuture)
            }
        }
    }

    // MARK: - Selection

    private func select(_ file: FileEntry) {
        if selectedDuplicates.insert(file.id).inserted {
            selectedBytes += file.size
        }
    }

    private func deselect(_ file: FileEntry) {
        if selectedDuplicates.remove(file.id) != nil {
            selectedBytes -= file.size
        }
    }

    private func selectAllDuplicates(in group: DuplicateGroup) {
        for d in group.duplicates { select(d) }
    }

    private func deselectAllDuplicates(in group: DuplicateGroup) {
        for d in group.duplicates { deselect(d) }
    }

    private func clearSelection() {
        selectedDuplicates = []
        selectedBytes = 0
    }

    // MARK: - Actions

    /// Change which file in a group is the keeper.
    private func setKeeper(_ fileID: UUID, in groupID: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[idx].keeperID = fileID
        if let promoted = groups[idx].files.first(where: { $0.id == fileID }) {
            deselect(promoted)
        }
        // Mirror the change into the sorted copy instead of re-sorting, so rows
        // don't reorder out from under the click.
        if let sortedIdx = sortedGroups.firstIndex(where: { $0.id == groupID }) {
            sortedGroups[sortedIdx].keeperID = fileID
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select a folder to scan for duplicate files."
        if panel.runModal() == .OK, let url = panel.url {
            selectedDirectory = url
            groups = []
            clearSelection()
            rebuildSortedGroups()
            statusMessage = "Ready. Click Scan to begin."
        }
    }

    private func startScan() {
        guard let dir = selectedDirectory else { return }

        groups = []
        clearSelection()
        rebuildSortedGroups()
        progress = 0
        statusMessage = "Starting…"
        scanState.isScanning = true

        // Expose a cancel hook to the AppDelegate for quit interception.
        scanState.cancelHandler = { [scanner] in
            scanner.cancel()
        }

        scanTask = Task {
            do {
                let found = try await scanner.scan(directory: dir) { msg, p in
                    Task { @MainActor in
                        statusMessage = msg
                        progress = p
                    }
                }
                await MainActor.run {
                    groups = found
                    rebuildSortedGroups()
                    scanState.isScanning = false
                    scanState.cancelHandler = nil
                    statusMessage = found.isEmpty
                        ? "No duplicates found."
                        : "Scan complete."
                }
            } catch is CancellationError {
                await MainActor.run {
                    scanState.isScanning = false
                    scanState.cancelHandler = nil
                    statusMessage = "Scan cancelled."
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Scan failed: \(error.localizedDescription)"
                    scanState.isScanning = false
                    scanState.cancelHandler = nil
                    statusMessage = "Scan failed."
                }
            }
        }
    }

    private func cancelScan() {
        scanner.cancel()
        scanTask?.cancel()
        statusMessage = "Cancelling…"
    }

    private func moveSelectedToTrash() {
        let toTrash = groups.flatMap(\.duplicates).filter { selectedDuplicates.contains($0.id) }
        guard !toTrash.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Move \(toTrash.count) file\(toTrash.count == 1 ? "" : "s") to the Trash?"
        alert.informativeText = "This will free up \(formatBytes(toTrash.reduce(0) { $0 + $1.size })). You can restore the files from the Trash until it is emptied."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var trashedIDs: Set<UUID> = []
        var failures: [String] = []

        for file in toTrash {
            do {
                try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
                trashedIDs.insert(file.id)
            } catch {
                failures.append("\(file.url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // Remove trashed files from their groups; drop groups that no longer have at least one duplicate.
        groups = groups.compactMap { group in
            var updated = group
            updated.files.removeAll { trashedIDs.contains($0.id) }
            guard updated.files.count >= 2 else { return nil }
            if !updated.files.contains(where: { $0.id == updated.keeperID }) {
                updated.keeperID = updated.files[0].id
            }
            return updated
        }

        // Dropping whole groups (and promoting new keepers) can orphan entries in
        // the selection, so rebuild it from what is actually still trashable.
        let stillSelectable = groups.flatMap(\.duplicates)
        selectedDuplicates.formIntersection(stillSelectable.map(\.id))
        selectedBytes = stillSelectable
            .filter { selectedDuplicates.contains($0.id) }
            .reduce(0) { $0 + $1.size }

        rebuildSortedGroups()

        if !failures.isEmpty {
            errorMessage = "Some files could not be trashed:\n" + failures.joined(separator: "\n")
        }
    }

    // MARK: - Formatters

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
