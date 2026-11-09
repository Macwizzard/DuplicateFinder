import Cocoa

// MARK: - Sorting

enum GroupSort: Int, CaseIterable {
    case savingsDesc, sizeDesc, sizeAsc, countDesc, dateNewest, dateOldest

    var label: String {
        switch self {
        case .savingsDesc: return "Largest savings"
        case .sizeDesc:    return "File size (largest)"
        case .sizeAsc:     return "File size (smallest)"
        case .countDesc:   return "Most duplicates"
        case .dateNewest:  return "Newest original"
        case .dateOldest:  return "Oldest original"
        }
    }
}

// MARK: - Main view controller

final class MainViewController: NSViewController {

    // State
    private var selectedDirectory: URL?
    private var groups: [DuplicateGroup] = []
    private var selectedDuplicates: Set<UUID> = []
    private var sortOrder: GroupSort = .savingsDesc
    private(set) var isScanning = false

    private let scanner = DuplicateScanner()

    // UI
    private var chooseButton: NSButton!
    private var pathLabel: NSTextField!
    private var sortPopup: NSPopUpButton!
    private var scanButton: NSButton!
    private var cancelButton: NSButton!
    private var progressBar: NSProgressIndicator!
    private var statusLabel: NSTextField!
    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var footerLabel: NSTextField!
    private var trashButton: NSButton!
    private var emptyStateLabel: NSTextField!

    // Layout
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        view.autoresizingMask = [.width, .height]
        buildUI()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateUIState()
    }

    // MARK: - UI construction

    private func buildUI() {
        // --- Toolbar row ---
        chooseButton = NSButton(title: "Choose Folder…", target: self, action: #selector(chooseFolder))
        chooseButton.bezelStyle = .rounded

        pathLabel = NSTextField(labelWithString: "")
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.font = NSFont.userFixedPitchFont(ofSize: 11)

        sortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for option in GroupSort.allCases {
            sortPopup.addItem(withTitle: option.label)
        }
        sortPopup.target = self
        sortPopup.action = #selector(sortChanged(_:))
        sortPopup.isHidden = true

        scanButton = NSButton(title: "Scan", target: self, action: #selector(startScan))
        scanButton.bezelStyle = .rounded
        scanButton.keyEquivalent = "\r"
        scanButton.isEnabled = false

        cancelButton = NSButton(title: "Cancel Scan", target: self, action: #selector(cancelScanAction))
        cancelButton.bezelStyle = .rounded
        cancelButton.isHidden = true

        // --- Progress row ---
        progressBar = NSProgressIndicator()
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isHidden = true

        statusLabel = NSTextField(labelWithString: "Choose a folder to begin.")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 11)

        // --- Outline view ---
        outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.autoresizesOutlineColumn = false
        outlineView.indentationPerLevel = 16
        outlineView.rowHeight = 30
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.selectionHighlightStyle = .none

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.minWidth = 400
        column.resizingMask = [.autoresizingMask, .userResizingMask]
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        // --- Empty state placeholder (shown when no results) ---
        emptyStateLabel = NSTextField(labelWithString: "Choose a folder to begin.")
        emptyStateLabel.alignment = .center
        emptyStateLabel.textColor = .secondaryLabelColor

        // --- Footer ---
        footerLabel = NSTextField(labelWithString: "")
        footerLabel.textColor = .secondaryLabelColor

        trashButton = NSButton(title: "Move Selected to Trash", target: self, action: #selector(moveSelectedToTrash))
        trashButton.bezelStyle = .rounded
        trashButton.isEnabled = false
        trashButton.keyEquivalent = String(UnicodeScalar(NSDeleteCharacter)!)
        trashButton.keyEquivalentModifierMask = [.command]

        // --- Layout via Auto Layout ---
        let toolbarRow = NSStackView(views: [chooseButton, pathLabel, sortPopup, cancelButton, scanButton])
        toolbarRow.orientation = .horizontal
        toolbarRow.spacing = 8
        toolbarRow.setHuggingPriority(.defaultLow, for: .horizontal)
        toolbarRow.setHuggingPriority(.required, for: .vertical)
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let progressRow = NSStackView(views: [progressBar, statusLabel])
        progressRow.orientation = .vertical
        progressRow.alignment = .leading
        progressRow.spacing = 4
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        let footerRow = NSStackView(views: [footerLabel, NSView(), trashButton])
        footerRow.orientation = .horizontal
        footerRow.spacing = 8

        let mainStack = NSStackView(views: [toolbarRow, progressRow, scrollView, footerRow])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 8
        mainStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mainStack)

        // Empty-state label sits centered behind the (empty) outline view
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: view.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            scrollView.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor, constant: -12),
            toolbarRow.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor, constant: 12),
            toolbarRow.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor, constant: -12),
            progressRow.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor, constant: 12),
            progressRow.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor, constant: -12),
            footerRow.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor, constant: 12),
            footerRow.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor, constant: -12),

            progressBar.leadingAnchor.constraint(equalTo: progressRow.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: progressRow.trailingAnchor),

            // Scroll view fills the vertical space between toolbar and footer
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),

            emptyStateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    // MARK: - State updates

    private var sortedGroups: [DuplicateGroup] {
        switch sortOrder {
        case .savingsDesc:
            return groups.sorted { $0.size * Int64($0.duplicates.count) > $1.size * Int64($1.duplicates.count) }
        case .sizeDesc:
            return groups.sorted { $0.size > $1.size }
        case .sizeAsc:
            return groups.sorted { $0.size < $1.size }
        case .countDesc:
            return groups.sorted { $0.duplicates.count > $1.duplicates.count }
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

    private var totalRecoverable: Int64 {
        return groups.flatMap { $0.duplicates }.reduce(0) { $0 + $1.size }
    }

    private var selectedRecoverable: Int64 {
        return groups.flatMap { $0.duplicates }
            .filter { selectedDuplicates.contains($0.id) }
            .reduce(0) { $0 + $1.size }
    }

    private func updateUIState() {
        chooseButton.isEnabled = !isScanning
        scanButton.isEnabled = (selectedDirectory != nil) && !isScanning
        scanButton.isHidden = isScanning
        cancelButton.isHidden = !isScanning
        progressBar.isHidden = !isScanning
        sortPopup.isHidden = isScanning || groups.isEmpty
        trashButton.isEnabled = !isScanning && !selectedDuplicates.isEmpty

        pathLabel.stringValue = selectedDirectory?.path ?? ""
        emptyStateLabel.isHidden = !groups.isEmpty || isScanning

        // Footer
        if groups.isEmpty {
            footerLabel.stringValue = ""
        } else {
            var s = "\(groups.count) group\(groups.count == 1 ? "" : "s") · \(formatBytes(totalRecoverable)) recoverable"
            if !selectedDuplicates.isEmpty {
                s += "  ·  \(selectedDuplicates.count) selected (\(formatBytes(selectedRecoverable)))"
            }
            footerLabel.stringValue = s
        }
    }

    // MARK: - Actions

    @objc func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select a folder to scan for duplicate files."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        selectedDirectory = url
        groups = []
        selectedDuplicates = []
        outlineView.reloadData()
        statusLabel.stringValue = "Ready. Click Scan to begin."
        emptyStateLabel.stringValue = "Ready. Click Scan to begin."
        updateUIState()
    }

    @objc func startScan() {
        guard let dir = selectedDirectory else { return }
        groups = []
        selectedDuplicates = []
        outlineView.reloadData()
        progressBar.doubleValue = 0
        statusLabel.stringValue = "Starting…"
        isScanning = true
        updateUIState()

        scanner.scan(directory: dir, progress: { [weak self] msg, p in
            guard let self = self else { return }
            self.statusLabel.stringValue = msg
            self.progressBar.doubleValue = p
        }, completion: { [weak self] result in
            guard let self = self else { return }
            self.isScanning = false
            switch result {
            case .success(let found):
                self.groups = found
                self.outlineView.reloadData()
                self.outlineView.expandItem(nil, expandChildren: true)
                self.statusLabel.stringValue = found.isEmpty ? "No duplicates found." : "Scan complete."
                self.emptyStateLabel.stringValue = "No duplicates found."
            case .failure(let error):
                if (error as? ScanError) != nil, case .cancelled = error as? ScanError {
                    self.statusLabel.stringValue = "Scan cancelled."
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Scan failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                    self.statusLabel.stringValue = "Scan failed."
                }
            }
            self.updateUIState()
        })
    }

    @objc func cancelScanAction() {
        cancelScan()
    }

    func cancelScan() {
        scanner.cancel()
        statusLabel.stringValue = "Cancelling…"
    }

    @objc func sortChanged(_ sender: NSPopUpButton) {
        if let s = GroupSort(rawValue: sender.indexOfSelectedItem) {
            sortOrder = s
            outlineView.reloadData()
            outlineView.expandItem(nil, expandChildren: true)
        }
    }

    @objc func moveSelectedToTrash() {
        let toTrash = groups.flatMap { $0.duplicates }.filter { selectedDuplicates.contains($0.id) }
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

        // Rebuild groups; drop any group reduced below 2 files.
        groups = groups.compactMap { group in
            group.files.removeAll { trashedIDs.contains($0.id) }
            guard group.files.count >= 2 else { return nil }
            if !group.files.contains(where: { $0.id == group.keeperID }) {
                group.keeperID = group.files[0].id
            }
            return group
        }
        selectedDuplicates.subtract(trashedIDs)
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        updateUIState()

        if !failures.isEmpty {
            let a = NSAlert()
            a.messageText = "Some files could not be trashed"
            a.informativeText = failures.joined(separator: "\n")
            a.alertStyle = .warning
            a.runModal()
        }
    }

    // Per-row callbacks from cell views
    fileprivate func toggleDuplicateSelected(_ fileID: UUID, on: Bool) {
        if on { selectedDuplicates.insert(fileID) }
        else { selectedDuplicates.remove(fileID) }
        updateUIState()
    }

    fileprivate func setKeeper(_ fileID: UUID, in groupID: UUID) {
        guard let g = groups.first(where: { $0.id == groupID }) else { return }
        g.keeperID = fileID
        selectedDuplicates.remove(fileID)
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        updateUIState()
    }

    fileprivate func selectAllInGroup(_ groupID: UUID, select: Bool) {
        guard let g = groups.first(where: { $0.id == groupID }) else { return }
        for d in g.duplicates {
            if select { selectedDuplicates.insert(d.id) }
            else { selectedDuplicates.remove(d.id) }
        }
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        updateUIState()
    }

    fileprivate func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    fileprivate func isSelected(_ fileID: UUID) -> Bool {
        return selectedDuplicates.contains(fileID)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    fileprivate func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    fileprivate func formatGroupHeader(_ g: DuplicateGroup) -> String {
        return "\(formatBytes(g.size)) · \(g.duplicates.count) duplicate\(g.duplicates.count == 1 ? "" : "s")"
    }
}

// MARK: - Outline data source / delegate

extension MainViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {

    // Two-level tree: groups at the top, file entries underneath.

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return sortedGroups.count
        }
        if let group = item as? DuplicateGroup {
            return group.files.count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return sortedGroups[index]
        }
        let group = item as! DuplicateGroup
        return group.files[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return item is DuplicateGroup
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if item is DuplicateGroup { return 28 }
        return 36  // file rows have two lines (path + date)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? DuplicateGroup {
            return GroupHeaderRow(group: group, controller: self)
        }
        if let file = item as? FileEntry {
            // Find which group it belongs to
            let group = groups.first { $0.files.contains(where: { $0.id == file.id }) }!
            return FileRow(file: file, group: group, controller: self)
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        return false  // we handle selection through checkboxes/radios, not row selection
    }
}

// MARK: - Row views

/// Header row for a group: shows total size + duplicate count + select-all buttons.
fileprivate final class GroupHeaderRow: NSTableCellView {
    init(group: DuplicateGroup, controller: MainViewController) {
        super.init(frame: .zero)

        let label = NSTextField(labelWithString: controller.formatGroupHeader(group))
        label.font = NSFont.boldSystemFont(ofSize: 13)

        let selectAll = NSButton(title: "Select All Duplicates", target: controller,
                                 action: #selector(MainViewController.selectAllInGroupAction(_:)))
        selectAll.bezelStyle = .recessed
        selectAll.font = NSFont.systemFont(ofSize: 11)
        selectAll.identifier = NSUserInterfaceItemIdentifier(group.id.uuidString + ":select")

        let deselectAll = NSButton(title: "Deselect All", target: controller,
                                   action: #selector(MainViewController.selectAllInGroupAction(_:)))
        deselectAll.bezelStyle = .recessed
        deselectAll.font = NSFont.systemFont(ofSize: 11)
        deselectAll.identifier = NSUserInterfaceItemIdentifier(group.id.uuidString + ":deselect")

        let stack = NSStackView(views: [label, NSView(), selectAll, deselectAll])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// File row: keeper radio, trash checkbox (or "KEEP" label), path, date, reveal button.
fileprivate final class FileRow: NSTableCellView {
    private weak var controller: MainViewController?
    private let file: FileEntry
    private let group: DuplicateGroup

    init(file: FileEntry, group: DuplicateGroup, controller: MainViewController) {
        self.file = file
        self.group = group
        self.controller = controller
        super.init(frame: .zero)

        let isKeeper = (file.id == group.keeperID)

        // Radio button (clickable, marks this file as the keeper)
        let radio = NSButton()
        radio.setButtonType(.radio)
        radio.title = ""
        radio.state = isKeeper ? .on : .off
        radio.target = self
        radio.action = #selector(radioClicked)

        // Keep label or trash checkbox
        let keepOrCheck: NSView
        if isKeeper {
            let l = NSTextField(labelWithString: "KEEP")
            l.font = NSFont.boldSystemFont(ofSize: 10)
            l.textColor = .systemYellow
            keepOrCheck = l
        } else {
            let cb = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxToggled(_:)))
            cb.state = (controller.isSelected(file.id)) ? .on : .off
            keepOrCheck = cb
        }

        // Path + date
        let pathLabel = NSTextField(labelWithString: file.url.path)
        pathLabel.font = NSFont.userFixedPitchFont(ofSize: 11)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.isSelectable = true

        let dateString: String
        if let d = file.creationDate {
            dateString = "Created \(controller.formatDate(d))"
        } else {
            dateString = ""
        }
        let dateLabel = NSTextField(labelWithString: dateString)
        dateLabel.font = NSFont.systemFont(ofSize: 10)
        dateLabel.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [pathLabel, dateLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Reveal in Finder button
        let reveal = NSButton(title: "Reveal", target: self, action: #selector(revealClicked))
        reveal.bezelStyle = .recessed
        reveal.font = NSFont.systemFont(ofSize: 11)

        let row = NSStackView(views: [radio, keepOrCheck, textStack, reveal])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            keepOrCheck.widthAnchor.constraint(equalToConstant: 50),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func radioClicked() {
        controller?.setKeeper(file.id, in: group.id)
    }

    @objc private func checkboxToggled(_ sender: NSButton) {
        controller?.toggleDuplicateSelected(file.id, on: sender.state == .on)
    }

    @objc private func revealClicked() {
        controller?.reveal(file.url)
    }
}

// MARK: - Bridging callbacks for the per-group buttons

extension MainViewController {
    @objc fileprivate func selectAllInGroupAction(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let groupID = UUID(uuidString: parts[0]) else { return }
        let select = (parts[1] == "select")
        selectAllInGroup(groupID, select: select)
    }
}
