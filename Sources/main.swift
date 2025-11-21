import AppKit
import Carbon

struct AppItem: Hashable {
    let name: String
    let path: String
}

final class AppIndex {
    private let roots: [URL]

    init(roots: [URL]? = nil) {
        self.roots = roots ?? [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications")
        ]
    }

    func load() -> [AppItem] {
        let fm = FileManager.default
        var seen = Set<String>()
        var items: [AppItem] = []

        for root in roots where fm.fileExists(atPath: root.path) {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension == "app" else { continue }

                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }

                let path = url.path
                if seen.contains(path) {
                    enumerator.skipDescendants()
                    continue
                }
                seen.insert(path)
                items.append(AppItem(name: url.deletingPathExtension().lastPathComponent, path: path))
                enumerator.skipDescendants()
            }
        }

        return items.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}

enum FuzzyMatcher {
    static func matchScore(query: String, candidate: String) -> Int? {
        if query.isEmpty { return 0 }

        let q = query.lowercased()
        let text = candidate.lowercased()
        var score = 0
        var searchIndex = text.startIndex

        for ch in q {
            guard let found = text[searchIndex...].firstIndex(of: ch) else { return nil }
            let gap = text.distance(from: searchIndex, to: found)
            score -= gap
            if gap == 0 {
                score += 5
            } else if gap == 1 {
                score += 2
            }
            searchIndex = text.index(after: found)
        }

        score -= text.distance(from: searchIndex, to: text.endIndex)
        if let first = q.first, let firstMatch = text.firstIndex(of: first) {
            score -= text.distance(from: text.startIndex, to: firstMatch)
        }

        return score + q.count * 6
    }
}

@MainActor
final class SearchField: NSSearchField {
    var onNavigate: ((Int) -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: // down
            onNavigate?(1)
        case 126: // up
            onNavigate?(-1)
        case 36, 76: // return / keypad return
            onConfirm?()
        case 53: // esc
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class LauncherController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate {
    private let appIndex: AppIndex
    private var apps: [AppItem] = []
    private var filtered: [AppItem] = []

    private let window: NSPanel
    private let searchField = SearchField()
    private let tableView = NSTableView()

    var onLaunch: ((AppItem) -> Void)?

    init(appIndex: AppIndex) {
        self.appIndex = appIndex
        self.window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        super.init()
        buildUI()
        reloadApps()
    }

    func show() {
        reloadApps()
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(searchField)
    }

    func hide() {
        window.orderOut(nil)
        searchField.stringValue = ""
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filtered.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("AppCell")

        let cell: NSTableCellView
        if let existing = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier

            let nameLabel = NSTextField(labelWithString: "")
            nameLabel.font = .systemFont(ofSize: 16, weight: .medium)
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.tag = 1

            let pathLabel = NSTextField(labelWithString: "")
            pathLabel.font = .systemFont(ofSize: 11)
            pathLabel.textColor = .secondaryLabelColor
            pathLabel.lineBreakMode = .byTruncatingMiddle
            pathLabel.tag = 2

            let stack = NSStackView(views: [nameLabel, pathLabel])
            stack.orientation = .vertical
            stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
            stack.alignment = .left

            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                stack.topAnchor.constraint(equalTo: cell.topAnchor),
                stack.bottomAnchor.constraint(equalTo: cell.bottomAnchor)
            ])

            cell.textField = nameLabel
        }

        if let nameLabel = cell.viewWithTag(1) as? NSTextField {
            nameLabel.stringValue = filtered[row].name
        }
        if let pathLabel = cell.viewWithTag(2) as? NSTextField {
            pathLabel.stringValue = filtered[row].path
        }

        return cell
    }

    // MARK: - NSTableViewDelegate

    func tableViewSelectionDidChange(_ notification: Notification) {}

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            launchSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter(searchField.stringValue)
    }

    // MARK: - Private

    private func buildUI() {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.hasShadow = true
        window.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97)
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = .statusBar
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false

        let contentView = NSView()
        window.contentView = contentView

        searchField.placeholderString = "Launch app"
        searchField.font = .systemFont(ofSize: 18, weight: .medium)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.focusRingType = .none
        searchField.onNavigate = { [weak self] delta in self?.moveSelection(by: delta) }
        searchField.onConfirm = { [weak self] in self?.launchSelection() }
        searchField.onCancel = { [weak self] in self?.hide() }

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.headerView = nil
        tableView.rowHeight = 38
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(launchFromTable)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("AppColumn"))
        column.width = 540
        tableView.addTableColumn(column)
        scrollView.documentView = tableView

        contentView.addSubview(searchField)
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            searchField.heightAnchor.constraint(equalToConstant: 34),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        ])

        window.initialFirstResponder = searchField
    }

    private func reloadApps() {
        apps = appIndex.load()
        applyFilter(searchField.stringValue)
    }

    private func applyFilter(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            filtered = apps
        } else {
            let matches = apps.compactMap { item -> (Int, AppItem)? in
                if let nameScore = FuzzyMatcher.matchScore(query: trimmed, candidate: item.name) {
                    return (nameScore, item)
                }
                if let pathScore = FuzzyMatcher.matchScore(query: trimmed, candidate: item.path) {
                    return (pathScore - 6, item)
                }
                return nil
            }

            filtered = matches
                .sorted {
                    if $0.0 == $1.0 {
                        return $0.1.name.lowercased() < $1.1.name.lowercased()
                    }
                    return $0.0 > $1.0
                }
                .map { $0.1 }
        }

        tableView.reloadData()
        selectRow(0)
    }

    private func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        var row = tableView.selectedRow
        if row == -1 { row = 0 }
        row = max(0, min(filtered.count - 1, row + delta))
        selectRow(row)
        tableView.scrollRowToVisible(row)
    }

    private func selectRow(_ row: Int) {
        guard row >= 0, row < filtered.count else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    @objc private func launchFromTable() {
        launchSelection()
    }

    private func launchSelection() {
        let row = tableView.selectedRow == -1 ? 0 : tableView.selectedRow
        guard row >= 0, row < filtered.count else { return }
        let item = filtered[row]
        onLaunch?(item)
        hide()
    }

#if DEBUG
    // Helpers exposed for unit tests only.
    func setAppsForTesting(_ items: [AppItem]) {
        apps = items
        filtered = items
        tableView.reloadData()
        if !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    @discardableResult
    func simulateCommand(_ selector: Selector) -> Bool {
        control(searchField, textView: NSTextView(), doCommandBy: selector)
    }

    var selectedAppForTesting: AppItem? {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count else { return nil }
        return filtered[row]
    }
#endif
}

final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let handler: @Sendable () -> Void

    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping @Sendable () -> Void) {
        self.handler = handler

        let hotKeyID = EventHotKeyID(signature: OSType(0x44504F54), id: 1) // "DPOT"
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            NSLog("Failed to register hotkey: \(status)")
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { (_, _, userData) -> OSStatus in
            guard let userData = userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async(execute: hotKey.handler)
            return noErr
        }, 1, &eventType, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), &eventHandler)
    }

    deinit {
        if let handler = eventHandler {
            RemoveEventHandler(handler)
        }
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appIndex = AppIndex()
    private var launcherController: LauncherController!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        launcherController = LauncherController(appIndex: appIndex)
        launcherController.onLaunch = { [weak self] item in
            self?.launchApp(at: item.path)
        }

        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(controlKey)) { [weak self] in
            Task { @MainActor [weak self] in
                self?.launcherController.show()
            }
        }
    }

    private func launchApp(at rawPath: String) {
        let fm = FileManager.default
        let standardizedPath = URL(fileURLWithPath: rawPath).standardizedFileURL.path

        guard fm.fileExists(atPath: standardizedPath) else {
            NSLog("Not launching missing app at path: \(standardizedPath)")
            return
        }
        guard Bundle(path: standardizedPath) != nil else {
            NSLog("Not launching non-bundle path: \(standardizedPath)")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-a", standardizedPath]
            do {
                try task.run()
            } catch {
                NSLog("Failed to open \(standardizedPath) via open(1): \(error.localizedDescription)")
            }
        }
    }
}

@main
struct DpotMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
