// Sticky: menu bar checklist. Shares ~/.claude/sticky/items.json and log.jsonl
// with the `sticky` CLI (which Claude uses) and SketchyBar. Build with ../build.sh.
import AppKit
import Darwin
import SwiftUI
import UserNotifications

// MARK: - Model

struct Item: Codable, Identifiable, Equatable {
    var id: String
    var text: String
    var done: Bool
    var tags: [String]
    var created: String?
    var source: String?
    var remind: String?
    var reminded: Bool?

    init(id: String, text: String, done: Bool, tags: [String], created: String?, source: String?) {
        self.id = id; self.text = text; self.done = done; self.tags = tags
        self.created = created; self.source = source
    }

    var remindDate: Date? { remind.flatMap { ISO8601DateFormatter().date(from: $0) } }
    var isOverdue: Bool { !done && (remindDate.map { $0 <= Date() } ?? false) }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        created = try c.decodeIfPresent(String.self, forKey: .created)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        remind = try c.decodeIfPresent(String.self, forKey: .remind)
        reminded = try c.decodeIfPresent(Bool.self, forKey: .reminded)
    }
}

struct ItemFile: Codable {
    var items: [Item]
    var tags: [String: String]?
}

struct LogEntry: Codable, Identifiable {
    var ts: String
    var action: String
    var id: String
    var text: String
    var tags: [String]?
    var source: String?
    var line = 0
    var uid: String { "\(line)" }
    enum CodingKeys: String, CodingKey { case ts, action, id, text, tags, source }
}

// MARK: - Tags

/// Keep in sync with sticky.py PALETTE and sketchybar plugins/sticky.sh.
enum TagColor: String, CaseIterable {
    case red, orange, yellow, green, teal, blue, purple, pink, grey

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .grey: .gray
        }
    }

    /// Same default as sticky.py: crc32(name) % 8 (grey is never a default).
    static func fallback(for tag: String) -> TagColor {
        allCases[Int(crc32(Array(tag.utf8)) % UInt32(allCases.count - 1))]
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }
}

enum Tags {
    static let regex = try! NSRegularExpression(pattern: #"(?<![\w#])#([A-Za-z0-9][\w-]{0,29})"#)

    /// "Fix login #work #urgent" -> ("Fix login", ["work", "urgent"])
    static func split(_ raw: String) -> (String, [String]) {
        let ns = raw as NSString
        var tags: [String] = []
        for m in regex.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            let t = ns.substring(with: m.range(at: 1)).lowercased()
            if !tags.contains(t) { tags.append(t) }
        }
        let stripped = regex.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        return (stripped.split(whereSeparator: \.isWhitespace).joined(separator: " "), tags)
    }
}

// MARK: - Store (file-backed, shared with the CLI)

@MainActor
final class Store: ObservableObject {
    @Published var items: [Item] = []
    @Published var tagColors: [String: String] = [:]
    @Published var log: [LogEntry] = []

    private let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sticky")
    private var itemsURL: URL { dir.appendingPathComponent("items.json") }
    private var logURL: URL { dir.appendingPathComponent("log.jsonl") }
    private var lockPath: String { dir.appendingPathComponent(".lock").path }
    private var lastStamp = ""
    private var timer: Timer?

    var openCount: Int { items.filter { !$0.done }.count }
    var doneCount: Int { items.filter(\.done).count }

    /// Tags in use, in first-seen order.
    var tagsInUse: [String] {
        var seen: [String] = []
        for it in items { for t in it.tags where !seen.contains(t) { seen.append(t) } }
        return seen
    }

    func color(of tag: String) -> TagColor {
        tagColors[tag].flatMap(TagColor.init(rawValue:)) ?? TagColor.fallback(for: tag)
    }

    init() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reload()
        // Poll modification times: cheap, and survives atomic replace by the CLI.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadIfChanged(); self?.fireDueReminders() }
        }
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            Task { @MainActor in Store.notificationsAllowed = ok }
        }
    }

    static var notificationsAllowed = false

    /// Notify once for each open item whose reminder time has passed.
    func fireDueReminders() {
        let now = Date()
        let due = items.filter { !$0.done && $0.reminded != true && ($0.remindDate.map { $0 <= now } ?? false) }
        guard !due.isEmpty else { return }
        let ids = Set(due.map(\.id))
        mutate { f in
            var ev: [(String, Item)] = []
            for i in f.items.indices where ids.contains(f.items[i].id) && f.items[i].reminded != true {
                f.items[i].reminded = true
                ev.append(("alert", f.items[i]))
            }
            return ev
        }
        for it in due { Self.notify(it) }
    }

    static func notify(_ it: Item) {
        let tags = it.tags.map { "#\($0)" }.joined(separator: " ")
        if notificationsAllowed {
            let c = UNMutableNotificationContent()
            c.title = "Sticky reminder"
            c.body = it.text
            if !tags.isEmpty { c.subtitle = tags }
            c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: it.id + (it.remind ?? ""), content: c, trigger: nil))
        } else {
            // Fallback when the app may not post notifications itself.
            let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "display notification \"\(esc(it.text))\" with title \"Sticky reminder\" subtitle \"\(esc(tags))\" sound name \"Glass\""]
            try? p.run()
        }
    }

    private func stamp() -> String {
        [itemsURL, logURL].map { url in
            let a = try? FileManager.default.attributesOfItem(atPath: url.path)
            let d = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let s = (a?[.size] as? Int) ?? 0
            return "\(d):\(s)"
        }.joined(separator: "|")
    }

    func reloadIfChanged() { if stamp() != lastStamp { reload() } }

    func reload() {
        lastStamp = stamp()
        let f = readFile()
        if f.items != items { items = f.items }
        if (f.tags ?? [:]) != tagColors { tagColors = f.tags ?? [:] }
        log = readLog()
    }

    private func readFile() -> ItemFile {
        guard let data = try? Data(contentsOf: itemsURL),
              let file = try? JSONDecoder().decode(ItemFile.self, from: data) else { return ItemFile(items: [], tags: [:]) }
        return file
    }

    private func readLog(limit: Int = 500) -> [LogEntry] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n")
        let start = max(0, lines.count - limit)
        var out: [LogEntry] = []
        for (i, ln) in lines[start...].enumerated() {
            if var e = try? JSONDecoder().decode(LogEntry.self, from: Data(ln.utf8)) {
                e.line = start + i
                out.append(e)
            }
        }
        return out.reversed()
    }

    /// Lock, re-read from disk, apply the change, write atomically, append log lines.
    private func mutate(_ change: (inout ItemFile) -> [(String, Item)], force: Bool = false) {
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }

        var file = readFile()
        if file.tags == nil { file.tags = [:] }
        let events = change(&file)
        guard force || !events.isEmpty else { return }
        // Give every tag in use a stored color, as the CLI does.
        for it in file.items { for t in it.tags where file.tags?[t] == nil {
            file.tags?[t] = TagColor.fallback(for: t).rawValue
        } }

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? enc.encode(file) {
            let tmp = dir.appendingPathComponent("items.json.\(getpid()).tmp")
            try? data.write(to: tmp)
            _ = rename(tmp.path, itemsURL.path)
        }
        let ts = Self.isoNow()
        var lines = ""
        for (action, item) in events {
            let e = LogEntry(ts: ts, action: action, id: item.id, text: item.text, tags: item.tags, source: "app")
            if let d = try? JSONEncoder().encode(e), let s = String(data: d, encoding: .utf8) { lines += s + "\n" }
        }
        if !lines.isEmpty {
            if let h = try? FileHandle(forWritingTo: logURL) {
                h.seekToEndOfFile(); h.write(Data(lines.utf8)); try? h.close()
            } else {
                try? lines.write(to: logURL, atomically: true, encoding: .utf8)
            }
        }
        reload()
        Self.notifyBar()
    }

    /// Tell SketchyBar to repaint the sticky item, if SketchyBar is installed.
    static func notifyBar() {
        for bar in ["/opt/homebrew/bin/sketchybar", "/usr/local/bin/sketchybar"]
        where FileManager.default.isExecutableFile(atPath: bar) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bar)
            p.arguments = ["--trigger", "sticky_update"]
            try? p.run()
            return
        }
    }

    static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    // MARK: Actions

    func add(_ raw: String, extraTag: String? = nil) {
        var (text, tags) = Tags.split(raw)
        if let t = extraTag, !tags.contains(t) { tags.append(t) }
        guard !text.isEmpty else { return }
        mutate { f in
            let id = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
            let it = Item(id: id, text: text, done: false, tags: tags, created: Self.isoNow(), source: "app")
            f.items.append(it)
            return [("add", it)]
        }
    }

    func toggle(_ id: String) {
        mutate { f in
            guard let i = f.items.firstIndex(where: { $0.id == id }) else { return [] }
            f.items[i].done.toggle()
            return [(f.items[i].done ? "done" : "undo", f.items[i])]
        }
    }

    func remove(_ id: String) {
        mutate { f in
            guard let i = f.items.firstIndex(where: { $0.id == id }) else { return [] }
            return [("remove", f.items.remove(at: i))]
        }
    }

    /// Edit text; #tags in the new text replace the item's tags.
    func edit(_ id: String, _ raw: String) {
        let (text, tags) = Tags.split(raw)
        mutate { f in
            guard let i = f.items.firstIndex(where: { $0.id == id }) else { return [] }
            if text.isEmpty { return [("remove", f.items.remove(at: i))] }
            guard f.items[i].text != text || f.items[i].tags != tags else { return [] }
            f.items[i].text = text
            f.items[i].tags = tags
            return [("edit", f.items[i])]
        }
    }

    func toggleTag(_ id: String, _ tag: String) {
        mutate { f in
            guard let i = f.items.firstIndex(where: { $0.id == id }) else { return [] }
            if let j = f.items[i].tags.firstIndex(of: tag) {
                f.items[i].tags.remove(at: j)
                return [("untag", f.items[i])]
            }
            f.items[i].tags.append(tag)
            return [("tag", f.items[i])]
        }
    }

    func setRemind(_ id: String, _ date: Date?) {
        mutate { f in
            guard let i = f.items.firstIndex(where: { $0.id == id }) else { return [] }
            if let date {
                f.items[i].remind = Self.isoUTC(date)
                f.items[i].reminded = false
            } else {
                f.items[i].remind = nil
                f.items[i].reminded = nil
            }
            return [("remind", f.items[i])]
        }
    }

    static func isoUTC(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    func setColor(_ tag: String, _ c: TagColor) {
        mutate({ f in f.tags?[tag] = c.rawValue; return [] }, force: true)
    }

    func clearDone() {
        mutate { f in
            let gone = f.items.filter(\.done)
            f.items.removeAll(where: \.done)
            return gone.map { ("remove", $0) }
        }
    }

    /// Reorder among open items (ids in their new order); done items keep their order after them.
    func reorderOpen(_ ids: [String]) {
        mutate { f in
            let byId = Dictionary(uniqueKeysWithValues: f.items.map { ($0.id, $0) })
            let open = ids.compactMap { byId[$0] }.filter { !$0.done }
            let rest = f.items.filter { it in !open.contains(where: { $0.id == it.id }) }
            guard open.map(\.id) != f.items.filter({ !$0.done }).map(\.id) else { return [] }
            f.items = open + rest
            return []
        }
        // Reorders are not logged as separate events; write still happens.
    }
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

enum When {
    static func label(_ d: Date) -> String {
        let cal = Calendar.current
        let t = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return t }
        if cal.isDateInTomorrow(d) { return "Tomorrow \(t)" }
        return d.formatted(.dateTime.day().month(.abbreviated)) + " " + t
    }
    static func at(hour: Int, dayOffset: Int = 0) -> Date {
        let cal = Calendar.current
        let base = cal.date(byAdding: .day, value: dayOffset, to: Date())!
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: base)!
    }
}

struct RemindPill: View {
    let date: Date
    let overdue: Bool
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: overdue ? "bell.badge.fill" : "bell.fill").font(.system(size: 8.5))
            Text(When.label(date)).font(.system(size: 10.5, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(overdue ? Color.red : Color.secondary)
        .padding(.horizontal, 6).padding(.vertical, 1.5)
        .background((overdue ? Color.red : Color.primary).opacity(overdue ? 0.14 : 0.06), in: Capsule())
    }
}

// MARK: - Small views

struct TagPill: View {
    let tag: String
    let color: TagColor
    var compact = false

    var body: some View {
        Text("#\(tag)")
            .font(.system(size: compact ? 10 : 10.5, weight: .medium))
            .foregroundStyle(color.color)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(color.color.opacity(0.14), in: Capsule())
            .lineLimit(1)
    }
}

struct CheckCircle: View {
    let done: Bool
    var body: some View {
        ZStack {
            Circle().strokeBorder(done ? Color.green : Color.secondary.opacity(0.55), lineWidth: 1.4)
            if done {
                Circle().fill(Color.green)
                Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: 16, height: 16)
        .contentShape(Circle())
    }
}

// MARK: - Item row

struct RowView: View {
    let item: Item
    @EnvironmentObject var store: Store
    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @State private var showPicker = false
    @State private var pickDate = Date().addingTimeInterval(3600)
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { store.toggle(item.id) }
            } label: { CheckCircle(done: item.done) }
            .buttonStyle(.plain)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                if editing {
                    TextField("", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focused)
                        .onSubmit { commit() }
                        .onExitCommand { editing = false }
                        .onChange(of: focused) { _, f in if !f { commit() } }
                } else {
                    Text(item.text)
                        .font(.system(size: 13))
                        .strikethrough(item.done, color: .secondary)
                        .foregroundStyle(item.done ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { startEdit() }
                }
                if (!item.tags.isEmpty || (item.remindDate != nil && !item.done)) && !editing {
                    HStack(spacing: 4) {
                        if let d = item.remindDate, !item.done {
                            RemindPill(date: d, overdue: item.isOverdue)
                                .onTapGesture { pickDate = d; showPicker = true }
                        }
                        ForEach(item.tags, id: \.self) { TagPill(tag: $0, color: store.color(of: $0), compact: true) }
                    }
                    .opacity(item.done ? 0.6 : 1)
                }
            }

            if hovering && !editing {
                Button { withAnimation { store.remove(item.id) } } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Color.primary.opacity(0.05) : .clear))
        .onHover { hovering = $0 }
        .popover(isPresented: $showPicker, arrowEdge: .trailing) { picker }
        .help(item.source.map { "Added by \($0)" } ?? "")
        .contextMenu {
            Button("Edit") { startEdit() }
            Button(item.done ? "Mark as not done" : "Mark as done") { store.toggle(item.id) }
            Menu("Remind me") {
                Button("In 15 minutes") { store.setRemind(item.id, Date().addingTimeInterval(15 * 60)) }
                Button("In 1 hour") { store.setRemind(item.id, Date().addingTimeInterval(3600)) }
                if Calendar.current.component(.hour, from: Date()) < 18 {
                    Button("This evening (6 PM)") { store.setRemind(item.id, When.at(hour: 18)) }
                }
                Button("Tomorrow (9 AM)") { store.setRemind(item.id, When.at(hour: 9, dayOffset: 1)) }
                Button("Pick a time…") {
                    pickDate = item.remindDate ?? Date().addingTimeInterval(3600)
                    showPicker = true
                }
                if item.remind != nil {
                    Divider()
                    Button("Clear reminder") { store.setRemind(item.id, nil) }
                }
            }
            if !store.tagsInUse.isEmpty {
                Menu("Tags") {
                    ForEach(store.tagsInUse, id: \.self) { t in
                        Toggle("#\(t)", isOn: Binding(get: { item.tags.contains(t) },
                                                      set: { _ in store.toggleTag(item.id, t) }))
                    }
                }
            }
            Divider()
            Button("Remove", role: .destructive) { store.remove(item.id) }
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Remind me at").font(.system(size: 12, weight: .semibold))
            DatePicker("", selection: $pickDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.field)
                .labelsHidden()
            HStack {
                if item.remind != nil {
                    Button("Clear") { store.setRemind(item.id, nil); showPicker = false }
                }
                Spacer()
                Button("Cancel") { showPicker = false }
                Button("Set") { store.setRemind(item.id, pickDate); showPicker = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 250)
    }

    private func startEdit() {
        draft = ([item.text] + item.tags.map { "#\($0)" }).joined(separator: " ")
        editing = true
        focused = true
    }

    private func commit() {
        guard editing else { return }
        editing = false
        store.edit(item.id, draft)
    }
}

// MARK: - List tab

struct ListTab: View {
    @EnvironmentObject var store: Store
    @State private var newText = ""
    @State private var filter: String? = nil
    @State private var showDone = false
    @FocusState private var addFocused: Bool

    private var open: [Item] { store.items.filter { !$0.done && matches($0) } }
    private var done: [Item] { store.items.filter { $0.done && matches($0) } }
    private func matches(_ it: Item) -> Bool { filter.map { it.tags.contains($0) } ?? true }

    var body: some View {
        VStack(spacing: 0) {
            if !store.tagsInUse.isEmpty { chips }

            if open.isEmpty && done.isEmpty {
                empty
            } else {
                List {
                    ForEach(open) { RowView(item: $0) }
                        .onMove(perform: filter == nil ? { from, to in
                            var ids = open.map(\.id)
                            ids.move(fromOffsets: from, toOffset: to)
                            store.reorderOpen(ids)
                        } : nil)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                        .listRowSeparator(.hidden)

                    if open.isEmpty {
                        Text(filter == nil ? "Everything is done." : "Nothing open in #\(filter!).")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .listRowSeparator(.hidden)
                    }

                    if !done.isEmpty {
                        Button { withAnimation(.snappy) { showDone.toggle() } } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .rotationEffect(.degrees(showDone ? 90 : 0))
                                Text("Completed").font(.system(size: 11, weight: .semibold))
                                Text("\(done.count)").font(.system(size: 11)).foregroundStyle(.tertiary)
                                Spacer()
                                if showDone {
                                    Button("Clear") { withAnimation { store.clearDone() } }
                                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                        .listRowSeparator(.hidden)

                        if showDone {
                            ForEach(done) { RowView(item: $0) }
                                .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                                .listRowSeparator(.hidden)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 10)
                .frame(height: listHeight)
            }

            addBar
        }
        .onAppear { addFocused = true }
    }

    private var listHeight: CGFloat {
        // Plain row ~34pt; a row with tag or reminder pills ~54pt.
        let shown = open + (showDone ? done : [])
        let rowsH = shown.reduce(CGFloat(0)) { h, it in
            h + ((it.tags.isEmpty && (it.remind == nil || it.done)) ? 34 : 54)
        }
        let extra: CGFloat = (open.isEmpty ? 44 : 0) + (done.isEmpty ? 12 : 40)
        return min(max(rowsH + extra, 220), 640)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                chip(label: "All", count: store.openCount, color: nil, selected: filter == nil) { filter = nil }
                ForEach(store.tagsInUse, id: \.self) { t in
                    let c = store.color(of: t)
                    chip(label: "#\(t)", count: store.items.filter { !$0.done && $0.tags.contains(t) }.count,
                         color: c, selected: filter == t) { filter = filter == t ? nil : t }
                        .contextMenu {
                            Menu("Color") {
                                ForEach(TagColor.allCases, id: \.self) { tc in
                                    Toggle(tc.rawValue.capitalized, isOn: Binding(get: { c == tc },
                                                                                  set: { _ in store.setColor(t, tc) }))
                                }
                            }
                        }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
    }

    private func chip(label: String, count: Int, color: TagColor?, selected: Bool, action: @escaping () -> Void) -> some View {
        let tint = color?.color ?? .primary
        return Button(action: { withAnimation(.snappy(duration: 0.18)) { action() } }) {
            HStack(spacing: 4) {
                if let color { Circle().fill(color.color).frame(width: 6, height: 6) }
                Text(label).font(.system(size: 11, weight: .medium))
                Text("\(count)").font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 8).padding(.vertical, 3.5)
            .foregroundStyle(selected ? tint : .secondary)
            .background(Capsule().fill(selected ? tint.opacity(0.16) : Color.primary.opacity(0.05)))
            .overlay(Capsule().strokeBorder(selected ? tint.opacity(0.35) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "checklist").font(.system(size: 22)).foregroundStyle(.tertiary)
            Text("Nothing here yet").font(.callout).foregroundStyle(.secondary)
            Text("Add one below, or ask Claude.").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 130)
    }

    private var addBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            TextField(filter.map { "Add to #\($0)…" } ?? "Add an item…  use #tag to tag it", text: $newText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($addFocused)
                .onSubmit {
                    withAnimation(.snappy) { store.add(newText, extraTag: filter) }
                    newText = ""; addFocused = true
                }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(addFocused ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
        .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 10)
    }
}

// MARK: - Log tab

struct LogTab: View {
    @EnvironmentObject var store: Store

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, d MMM"; return f
    }()
    private static let yearFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, d MMM yyyy"; return f
    }()

    struct Day: Identifiable { let id: Date; let entries: [(Date, LogEntry)] }

    private var days: [Day] {
        let cal = Calendar.current
        var order: [Date] = []
        var groups: [Date: [(Date, LogEntry)]] = [:]
        for e in store.log {
            guard let d = Self.iso.date(from: e.ts) else { continue }
            let key = cal.startOfDay(for: d)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append((d, e))
        }
        return order.map { Day(id: $0, entries: groups[$0]!) }
    }

    private func title(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return cal.isDate(day, equalTo: Date(), toGranularity: .year) ? Self.dayFmt.string(from: day) : Self.yearFmt.string(from: day)
    }

    var body: some View {
        if store.log.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 22)).foregroundStyle(.tertiary)
                Text("No history yet").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(days) { day in
                        Section {
                            ForEach(Array(day.entries.enumerated()), id: \.element.1.uid) { idx, pair in
                                row(pair.0, pair.1, last: idx == day.entries.count - 1)
                            }
                        } header: {
                            HStack(alignment: .firstTextBaseline) {
                                Text(title(day.id)).font(.system(size: 11.5, weight: .semibold))
                                Spacer()
                                Text("\(day.entries.count) \(day.entries.count == 1 ? "change" : "changes")")
                                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 5)
                            .background(Color(nsColor: .windowBackgroundColor))
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(height: 560)
        }
    }

    private func row(_ date: Date, _ e: LogEntry, last: Bool) -> some View {
        let (verb, icon, tint) = style(e.action)
        return HStack(alignment: .top, spacing: 8) {
            Text(Self.timeFmt.string(from: date))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .leading)
                .padding(.top, 1)
            // timeline rail
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(tint.opacity(0.16)).frame(width: 18, height: 18)
                    Image(systemName: icon).font(.system(size: 8.5, weight: .bold)).foregroundStyle(tint)
                }
                if !last { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1).frame(maxHeight: .infinity) }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(Text(verb).foregroundStyle(.secondary)) \(e.text)")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    ForEach(e.tags ?? [], id: \.self) { TagPill(tag: $0, color: store.color(of: $0), compact: true) }
                    SourceBadge(source: e.source ?? "?")
                }
            }
            .padding(.bottom, last ? 4 : 10)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
    }

    private func style(_ action: String) -> (String, String, Color) {
        switch action {
        case "add": ("Added", "plus", .blue)
        case "done": ("Completed", "checkmark", .green)
        case "undo": ("Reopened", "arrow.uturn.backward", .orange)
        case "remove": ("Removed", "minus", .red)
        case "edit": ("Edited", "pencil", .purple)
        case "tag": ("Tagged", "number", .teal)
        case "untag": ("Untagged", "number", .gray)
        case "remind": ("Set reminder for", "bell", .yellow)
        case "alert": ("Reminded about", "bell.fill", .orange)
        default: (action.capitalized, "circle", .gray)
        }
    }
}

struct SourceBadge: View {
    let source: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8))
            Text(source).font(.system(size: 9.5, weight: .medium))
        }
        .foregroundStyle(source == "claude" ? Color.orange : Color.secondary)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
    private var icon: String {
        switch source {
        case "claude": "sparkle"
        case "cli": "terminal"
        case "sketchybar": "menubar.rectangle"
        default: "macwindow"
        }
    }
}

// MARK: - Panel

struct Panel: View {
    @EnvironmentObject var store: Store
    @State private var tab = 0

    private var progress: Double {
        store.items.isEmpty ? 0 : Double(store.doneCount) / Double(store.items.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            if tab == 0 { ListTab() } else { LogTab() }
        }
        .frame(width: 340)
        // Solid panel: no translucent, blurred desktop behind the content.
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { store.reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sticky").font(.system(size: 14, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Picker("", selection: $tab) {
                    Image(systemName: "checklist").tag(0).help("List")
                    Image(systemName: "clock").tag(1).help("Log")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 84)
                Menu {
                    if !store.tagsInUse.isEmpty {
                        Menu("Tag colors") {
                            ForEach(store.tagsInUse, id: \.self) { t in
                                Menu("#\(t)") {
                                    ForEach(TagColor.allCases, id: \.self) { tc in
                                        Toggle(tc.rawValue.capitalized, isOn: Binding(get: { store.color(of: t) == tc },
                                                                                      set: { _ in store.setColor(t, tc) }))
                                    }
                                }
                            }
                        }
                    }
                    if store.doneCount > 0 { Button("Clear completed") { store.clearDone() } }
                    Button("Open data folder") {
                        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sticky"))
                    }
                    Divider()
                    Button("Quit Sticky") { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if tab == 0 && !store.items.isEmpty {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Color.green.gradient).frame(width: max(4, g.size.width * progress))
                    }
                }
                .frame(height: 4)
                .animation(.snappy, value: progress)
            }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
    }

    private var subtitle: String {
        if tab == 1 { return "History of every change" }
        if store.items.isEmpty { return "No items" }
        if store.openCount == 0 { return "All \(store.items.count) done" }
        return "\(store.openCount) open · \(store.doneCount) of \(store.items.count) done"
    }
}

@main
struct StickyApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            Panel().environmentObject(store)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: store.openCount == 0 && !store.items.isEmpty ? "checklist.checked" : "checklist")
                if store.openCount > 0 { Text("\(store.openCount)").monospacedDigit() }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
