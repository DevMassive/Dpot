import AppKit
import Carbon
import JavaScriptCore

struct AppItem: Hashable {
    let name: String
    let path: String
}

struct AppIndexMetrics {
    let items: [AppItem]
    let rootDurations: [(root: URL, duration: TimeInterval, count: Int)]
    let totalDuration: TimeInterval
}

struct CalcResult {
    let expression: String
    let display: String
}

enum CalcEngine {
    static func evaluate(_ text: String) -> CalcResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Limit to basic arithmetic symbols to avoid JS oddities.
        let allowed = CharacterSet(charactersIn: "0123456789+-*/(). ")
        guard trimmed.rangeOfCharacter(from: allowed.inverted) == nil else { return nil }

        // Collapse accidental repeats like '//' -> '/'
        let sanitized = trimmed.replacingOccurrences(of: "/{2,}", with: "/", options: .regularExpression)

        guard let context = JSContext() else { return nil }
        guard let jsValue = context.evaluateScript(sanitized) else { return nil }
        if let exception = context.exception, !exception.isNull {
            return nil
        }
        guard jsValue.isNumber, let number = jsValue.toNumber() else { return nil }

        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 6
        formatter.minimumFractionDigits = 0
        formatter.numberStyle = .decimal
        let display = formatter.string(from: number) ?? number.stringValue
        return CalcResult(expression: sanitized, display: display)
    }
}

struct UsageInfo: Codable {
    var openCount: Int
    var lastOpened: Date
}

struct UsageStore: Codable {
    var records: [String: UsageInfo] = [:]

    mutating func bump(path: String) {
        let now = Date()
        records[path, default: UsageInfo(openCount: 0, lastOpened: now)].openCount += 1
        records[path]?.lastOpened = now
    }

    func scoreBoost(for path: String) -> Double {
        guard let info = records[path] else { return 0 }
        let freqBoost = log2(Double(info.openCount) + 1.0) * 5.0
        let minutes = -info.lastOpened.timeIntervalSinceNow / 60.0
        let recencyBoost = max(0, 100.0 - minutes * 0.5)
        return freqBoost + recencyBoost
    }
}

final class AppIndex: @unchecked Sendable {
    private let roots: [URL]
    private let queue = DispatchQueue(label: "dpot.appindex", qos: .utility)
    private var cachedItems: [AppItem] = []
    private var usageStore: UsageStore = .init()

    init(roots: [URL]? = nil) {
        self.roots = roots ?? [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications")
        ]
    }

    func load() -> [AppItem] {
        loadWithMetrics().items
    }

    func loadWithMetrics() -> AppIndexMetrics {
        let totalStart = Date()
        let fm = FileManager.default
        var seen = Set<String>()
        var items: [AppItem] = []
        var rootDurations: [(URL, TimeInterval, Int)] = []

        for root in roots where fm.fileExists(atPath: root.path) {
            let start = Date()
            var rootCount = 0
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { continue }

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
                rootCount += 1
            }

            rootDurations.append((root, Date().timeIntervalSince(start), rootCount))
        }

        let sorted = items.sorted { $0.name.lowercased() < $1.name.lowercased() }
        return AppIndexMetrics(items: sorted, rootDurations: rootDurations, totalDuration: Date().timeIntervalSince(totalStart))
    }

    func cachedItemsSnapshot() -> [AppItem] {
        queue.sync { cachedItems }
    }

    func refreshAsync(collectMetrics: Bool, completion: @escaping @Sendable ([AppItem], AppIndexMetrics?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.loadUsage()
            let metrics = self.loadWithMetrics()
            self.cachedItems = metrics.items
            DispatchQueue.main.async {
                completion(metrics.items, collectMetrics ? metrics : nil)
            }
        }
    }

    func bumpUsage(for path: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.loadUsage()
            self.usageStore.bump(path: path)
            self.saveUsage()
        }
    }

    func boost(for path: String) -> Double {
        queue.sync {
            usageStore.scoreBoost(for: path)
        }
    }

    private var usageURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("DpotUsage.json")
    }

    private func loadUsage() {
        let url = usageURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        if let store = try? JSONDecoder().decode(UsageStore.self, from: data) {
            usageStore = store
        }
    }

    private func saveUsage() {
        let url = usageURL
        if let data = try? JSONEncoder().encode(usageStore) {
            try? data.write(to: url)
        }
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

enum FzfFilter {
    private static let candidatePaths = [
        "/opt/homebrew/bin/fzf",
        "/usr/local/bin/fzf",
        "/usr/bin/fzf"
    ]

    private static func fzfExecutable() -> String? {
        for path in candidatePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    static func filter(query: String, items: [AppItem]) -> [AppItem]? {
        guard let exe = fzfExecutable() else { return nil }
        guard !query.isEmpty else { return items }

        let input = items.map { "\($0.name)\t\($0.path)" }.joined(separator: "\n")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = ["--filter", query, "--delimiter", "\t", "--nth=1", "--with-nth=1,2", "--no-sort", "--ansi"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            NSLog("Failed to run fzf: \(error.localizedDescription)")
            return nil
        }

        if let data = input.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        stdinPipe.fileHandleForWriting.closeFile()

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        guard let output = String(data: outputData, encoding: .utf8) else { return nil }

        var results: [AppItem] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map { String($0) }
            guard parts.count == 2 else { continue }
            results.append(AppItem(name: parts[0], path: parts[1]))
        }

        return results
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
    private var calcResult: CalcResult?

    private let window: NSPanel
    private let searchField = SearchField()
    private let tableView = NSTableView()
    private var lastQuery: String = ""

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

    func hide(clearQuery: Bool = false) {
        window.orderOut(nil)
        if clearQuery {
            searchField.stringValue = ""
            lastQuery = ""
        }
    }

    func toggle() {
        if window.isVisible && NSApp.isActive {
            hide(clearQuery: false)
        } else {
            show()
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count + (calcResult == nil ? 0 : 1)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let isCalcRow = calcResult != nil && row == 0
        let appIndex = row - (calcResult == nil ? 0 : 1)
        if !isCalcRow && appIndex >= filtered.count {
            return nil
        }
        let identifier = NSUserInterfaceItemIdentifier("AppCell")

        let cell: NSTableCellView
        if let existing = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier

            let iconView = NSImageView()
            iconView.wantsLayer = true
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
            iconView.setContentHuggingPriority(.required, for: .horizontal)

            let nameLabel = NSTextField(labelWithString: "")
            nameLabel.font = .systemFont(ofSize: 16, weight: .medium)
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.tag = 1
            nameLabel.setContentCompressionResistancePriority(.required, for: .vertical)
            nameLabel.setContentHuggingPriority(.required, for: .vertical)

            let pathLabel = NSTextField(labelWithString: "")
            pathLabel.font = .systemFont(ofSize: 11)
            pathLabel.textColor = .secondaryLabelColor
            pathLabel.lineBreakMode = .byTruncatingMiddle
            pathLabel.tag = 2
            pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

            let textStack = NSStackView(views: [nameLabel, pathLabel])
            textStack.orientation = .vertical
            textStack.spacing = 2
            textStack.alignment = .left

            let rowStack = NSStackView(views: [iconView, textStack])
            rowStack.orientation = .horizontal
            rowStack.spacing = 10
            rowStack.edgeInsets = NSEdgeInsetsZero
            rowStack.alignment = .centerY

            rowStack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(rowStack)
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: 32),
                iconView.heightAnchor.constraint(equalToConstant: 32),

                rowStack.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                rowStack.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                rowStack.topAnchor.constraint(equalTo: cell.topAnchor),
                rowStack.bottomAnchor.constraint(equalTo: cell.bottomAnchor)
            ])

            cell.textField = nameLabel
            cell.imageView = iconView
        }

        if isCalcRow, let calc = calcResult {
            if let nameLabel = cell.viewWithTag(1) as? NSTextField {
                nameLabel.stringValue = calc.display
            }
            if let pathLabel = cell.viewWithTag(2) as? NSTextField {
                pathLabel.stringValue = calc.expression
            }
            if let iconView = cell.imageView {
                iconView.image = NSImage(systemSymbolName: "function", accessibilityDescription: "Calc")
            }
            return cell
        }
        guard appIndex >= 0 && appIndex < filtered.count else { return cell }
        if let nameLabel = cell.viewWithTag(1) as? NSTextField {
            nameLabel.stringValue = filtered[appIndex].name
        }
        if let pathLabel = cell.viewWithTag(2) as? NSTextField {
            pathLabel.stringValue = filtered[appIndex].path
        }
        if let iconView = cell.imageView {
            iconView.image = NSWorkspace.shared.icon(forFile: filtered[appIndex].path)
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
            hide(clearQuery: true)
            return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        lastQuery = searchField.stringValue
        applyFilter(lastQuery)
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
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.cell?.isBezeled = false
        searchField.cell?.isBordered = false
        searchField.cell?.backgroundStyle = .normal
        if let cell = searchField.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
            cell.cancelButtonCell = nil
        }
        searchField.onNavigate = { [weak self] delta in self?.moveSelection(by: delta) }
        searchField.onConfirm = { [weak self] in self?.launchSelection() }
        searchField.onCancel = { [weak self] in self?.hide() }

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.contentInsets = NSEdgeInsetsZero

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.headerView = nil
        tableView.rowHeight = 40
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(launchFromTable)
        tableView.backgroundColor = .clear

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("AppColumn"))
        column.width = 540
        tableView.addTableColumn(column)
        scrollView.documentView = tableView

        contentView.addSubview(searchField)
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: 28),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        window.initialFirstResponder = searchField
    }

    private func reloadApps() {
        let query = searchField.stringValue
        lastQuery = query

        let cached = appIndex.cachedItemsSnapshot()
        if !cached.isEmpty {
            apps = cached
            applyFilter(query)
        } else {
            apps = []
            filtered = []
            tableView.reloadData()
        }

        let shouldLog = ProcessInfo.processInfo.environment["DPOT_LOG_INDEX"] != nil
        appIndex.refreshAsync(collectMetrics: shouldLog) { [weak self] items, metrics in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.apps = items
                self.applyFilter(self.lastQuery)

                #if DEBUG
                if shouldLog, let metrics {
                    let perRoot = metrics.rootDurations.map { "\($0.count) in \($0.root.lastPathComponent)=\(String(format: "%.3f", $0.duration))s" }.joined(separator: ", ")
                    NSLog("Index load: total=\(String(format: "%.3f", metrics.totalDuration))s count=\(metrics.items.count) [\(perRoot)]")
                }
                #endif
            }
        }
    }

    private func applyFilter(_ query: String) {
        calcResult = CalcEngine.evaluate(query)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            filtered = apps
        } else {
            if let fzfFiltered = FzfFilter.filter(query: trimmed, items: apps), !fzfFiltered.isEmpty {
                filtered = scored(items: fzfFiltered, boost: true)
            } else {
                let matches = apps.compactMap { item -> (Int, AppItem)? in
                    if let nameScore = FuzzyMatcher.matchScore(query: trimmed, candidate: item.name) {
                        return (nameScore, item)
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
                filtered = scored(items: filtered, boost: true)
            }
        }

        tableView.reloadData()
        selectRow(0)
    }

    private func scored(items: [AppItem], boost: Bool) -> [AppItem] {
        guard boost else { return items }
        return items
            .map { item in
                let bonus = appIndex.boost(for: item.path)
                return (bonus, item)
            }
            .sorted {
                if $0.0 == $1.0 {
                    return $0.1.name.lowercased() < $1.1.name.lowercased()
                }
                return $0.0 > $1.0
            }
            .map { $0.1 }
    }

    private func moveSelection(by delta: Int) {
        let totalRows = filtered.count + (calcResult == nil ? 0 : 1)
        guard totalRows > 0 else { return }
        var row = tableView.selectedRow
        if row == -1 { row = 0 }
        row = max(0, min(totalRows - 1, row + delta))
        selectRow(row)
        tableView.scrollRowToVisible(row)
    }

    private func selectRow(_ row: Int) {
        let totalRows = filtered.count + (calcResult == nil ? 0 : 1)
        guard row >= 0, row < totalRows else {
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
        let hasCalc = calcResult != nil
        if hasCalc && row == 0 {
            if let calc = calcResult {
                let pboard = NSPasteboard.general
                pboard.clearContents()
                pboard.setString(calc.display, forType: .string)
            }
            hide(clearQuery: false)
            return
        }
        let index = row - (hasCalc ? 1 : 0)
        guard index >= 0, index < filtered.count else { return }
        let item = filtered[index]
        onLaunch?(item)
        hide(clearQuery: true)
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
            self?.appIndex.bumpUsage(for: item.path)
        }

        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(controlKey)) { [weak self] in
            Task { @MainActor [weak self] in
                self?.launcherController.toggle()
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
