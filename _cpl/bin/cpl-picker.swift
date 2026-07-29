import AppKit

// CPL picker — the "brain". Loads ~/.cpl.json, fingerprints the current display
// layout, resolves the active profile, renders the launch panel, and on an action
// click resolves placement → computes iTerm window bounds → claims a slot → emits a
// fully-resolved launch spec on stdout for the AppleScript executor. Also hosts the
// config panel (⚙). The AppleScript app does zero geometry/parsing.
//
// Output contract (single tab-separated line on stdout, exit 0):
//   L \t T \t R \t B \t itermProfile \t sessionName \t command
// Cancel → exit 1 (no output). Config edits are saved in-process and exit 1.

// MARK: - Config model

struct Placement: Codable {
    var monitor: Int
    var slotMode: String   // "slotted" | "fullscreen"
    var slot: Int?         // optional fixed slot (pin)
    var width: Int?        // reserved; >1 not yet implemented (defaults to 1)
}

struct PlacementOverride: Codable {
    var monitor: Int?
    var slotMode: String?
    var slot: Int?
    var width: Int?
}

// Identity only. Slot/monitor is NOT stored here — it defaults to monitor 1 /
// slotted (defaultPlacement) and is overridden per-profile via Profile.overrides[id].
// Built-ins are hardcoded (builtinActions); only custom commands are persisted.
struct Action: Codable {
    var id: String
    var label: String
    var command: String     // "claude" | "agents" | "terminal" | "shell"
    var shell: String?      // required when command == "shell"
    var dir: String         // "selected-project" | "projects-dir" | "none" | absolute path
    var itermProfile: String
    // iTerm session/title name for non-project actions. nil → falls back to label.
    // (Project-bound actions always title by the selected project dir name.)
    var title: String? = nil
}

struct MonitorCfg: Codable {
    var n: Int
    var maxSlots: Int
}

struct Rect: Codable, Equatable {
    var x: Int; var y: Int; var w: Int; var h: Int
}

struct Profile: Codable {
    var name: String
    var fingerprint: [Rect]?            // nil/empty = wildcard (last-resort match)
    var monitors: [MonitorCfg]
    var overrides: [String: PlacementOverride]?
}

struct Pin: Codable {
    var monitor: Int
    var slot: Int?
}

struct Config: Codable {
    var version: Int
    var projectsDir: String
    var customActions: [Action]   // the looper at the bottom; built-ins are not stored
    var pins: [String: Pin]?
    var defaultProfile: String?
    var profiles: [Profile]

    init(version: Int, projectsDir: String, customActions: [Action],
         pins: [String: Pin]?, defaultProfile: String?, profiles: [Profile]) {
        self.version = version
        self.projectsDir = projectsDir
        self.customActions = customActions
        self.pins = pins
        self.defaultProfile = defaultProfile
        self.profiles = profiles
    }

    enum CodingKeys: String, CodingKey {
        case version, projectsDir, customActions, actions, pins, defaultProfile, profiles
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        projectsDir = try c.decode(String.self, forKey: .projectsDir)
        pins = try c.decodeIfPresent([String: Pin].self, forKey: .pins)
        defaultProfile = try c.decodeIfPresent(String.self, forKey: .defaultProfile)
        profiles = try c.decode([Profile].self, forKey: .profiles)
        // New schema stores only custom actions. Legacy schema stored the built-ins
        // inline under `actions`; migrate by keeping just the shell (custom) entries.
        if let customs = try c.decodeIfPresent([Action].self, forKey: .customActions) {
            customActions = customs
        } else if let legacy = try c.decodeIfPresent([Action].self, forKey: .actions) {
            customActions = legacy.filter { $0.command == "shell" }
        } else {
            customActions = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(projectsDir, forKey: .projectsDir)
        try c.encode(customActions, forKey: .customActions)
        try c.encodeIfPresent(pins, forKey: .pins)
        try c.encodeIfPresent(defaultProfile, forKey: .defaultProfile)
        try c.encode(profiles, forKey: .profiles)
    }
}

// MARK: - Paths

let home = FileManager.default.homeDirectoryForCurrentUser
let jsonPath = home.appendingPathComponent(".cpl.json").path
let legacyConfPath = home.appendingPathComponent(".cpl.conf").path

func expandTilde(_ p: String) -> String {
    if p == "~" { return home.path }
    if p.hasPrefix("~/") { return home.appendingPathComponent(String(p.dropFirst(2))).path }
    return p
}

// MARK: - Screen helpers

// Sorted (X ascending, then Y descending = topmost first). Monitor N == index N-1.
func screensSorted() -> [NSScreen] {
    return NSScreen.screens.sorted { a, b in
        if a.frame.minX != b.frame.minX { return a.frame.minX < b.frame.minX }
        return a.frame.minY > b.frame.minY
    }
}

// Translation-normalized rect set (min X/Y shifted to 0), sorted — the layout identity.
func currentFingerprint() -> [Rect] {
    let frames = NSScreen.screens.map { $0.frame }
    guard !frames.isEmpty else { return [] }
    let minX = frames.map { $0.minX }.min() ?? 0
    let minY = frames.map { $0.minY }.min() ?? 0
    var rects = frames.map {
        Rect(x: Int(($0.minX - minX).rounded()),
             y: Int(($0.minY - minY).rounded()),
             w: Int($0.width.rounded()),
             h: Int($0.height.rounded()))
    }
    rects.sort { lhs, rhs in
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        if lhs.w != rhs.w { return lhs.w < rhs.w }
        return lhs.h < rhs.h
    }
    return rects
}

func sameRects(_ a: [Rect], _ b: [Rect]) -> Bool {
    return a == b
}

// Primary screen height (the screen whose origin is (0,0)) — used to flip NSScreen
// bottom-left coords into iTerm/AppleScript top-left bounds.
func primaryHeight() -> CGFloat {
    let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
    return primary?.frame.height ?? 0
}

// MARK: - Config load / migrate / save

func dieDialog(_ msg: String) -> Never {
    let alert = NSAlert()
    alert.messageText = "CPL"
    alert.informativeText = msg
    alert.alertStyle = .critical
    alert.addButton(withTitle: "OK")
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
    exit(1)
}

// The universal slot/monitor default for every command. Monitor 1 always exists;
// slotted always works. Per-profile overrides (Profile.overrides[id]) layer on top.
let defaultPlacement = Placement(monitor: 1, slotMode: "slotted", slot: nil, width: 1)

// The fixed built-in buttons — identity only, defined in code, never persisted.
// Agents runs `claude agents` (resolved in buildCommand).
func builtinActions() -> [Action] {
    return [
        Action(id: "claude", label: "Claude", command: "claude", shell: nil,
               dir: "selected-project", itermProfile: "CPL"),
        Action(id: "terminal", label: "Terminal", command: "terminal", shell: nil,
               dir: "selected-project", itermProfile: "Default"),
        Action(id: "agents", label: "Claude Agents", command: "agents", shell: nil,
               dir: "projects-dir", itermProfile: "CPL"),
        Action(id: "term-projects", label: "Terminal (projects)", command: "terminal", shell: nil,
               dir: "projects-dir", itermProfile: "Default", title: "Terminal"),
    ]
}

// maxSlots seed heuristic: ~1147px was the comfortable slot width historically.
func seedMaxSlots(forWidth w: CGFloat) -> Int {
    return max(1, Int((w / 1150).rounded(.down)))
}

func seedProfile(name: String, fingerprint: [Rect], legacyMaxSlots: Int?) -> Profile {
    let screens = screensSorted()
    var monitors: [MonitorCfg] = []
    for (i, s) in screens.enumerated() {
        let ms = legacyMaxSlots ?? seedMaxSlots(forWidth: s.frame.width)
        monitors.append(MonitorCfg(n: i + 1, maxSlots: ms))
    }
    if monitors.isEmpty { monitors = [MonitorCfg(n: 1, maxSlots: 1)] }
    return Profile(name: name, fingerprint: fingerprint, monitors: monitors, overrides: [:])
}

// Read a key from the legacy flat ~/.cpl.conf (migration only).
func legacyConfValue(_ key: String) -> String? {
    guard let content = try? String(contentsOfFile: legacyConfPath, encoding: .utf8) else { return nil }
    for line in content.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\(key)=") {
            let v = t.dropFirst(key.count + 1)
            return v.split(separator: "#").first.map { String($0).trimmingCharacters(in: .whitespaces) }
        }
    }
    return nil
}

func loadOrInitConfig() -> Config {
    let fm = FileManager.default
    if fm.fileExists(atPath: jsonPath) {
        guard let data = fm.contents(atPath: jsonPath) else {
            dieDialog("Could not read \(jsonPath)")
        }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            dieDialog("Could not parse ~/.cpl.json:\n\(error.localizedDescription)\n\nFix or delete the file and re-launch.")
        }
    }

    // First run: migrate from legacy ~/.cpl.conf if present, else seed fresh.
    let legacyMax = legacyConfValue("maxSlots").flatMap { Int($0) }
    let fp = currentFingerprint()
    let profile = seedProfile(name: "default", fingerprint: fp, legacyMaxSlots: legacyMax)
    let cfg = Config(version: 3,
                     projectsDir: "~/projects",
                     customActions: [],
                     pins: [:],
                     defaultProfile: "default",
                     profiles: [profile])
    saveConfig(cfg)
    return cfg
}

func saveConfig(_ cfg: Config) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        let data = try enc.encode(cfg)
        try data.write(to: URL(fileURLWithPath: jsonPath), options: .atomic)
    } catch {
        dieDialog("Could not write ~/.cpl.json:\n\(error.localizedDescription)")
    }
}

// MARK: - Profile resolution & seeding

// Returns (activeProfile, wasSeeded). Mutates cfg.profiles when seeding a new layout.
func resolveActiveProfile(_ cfg: inout Config) -> (Profile, Bool) {
    let fp = currentFingerprint()
    if let match = cfg.profiles.first(where: { p in
        if let f = p.fingerprint, !f.isEmpty { return sameRects(f, fp) }
        return false
    }) {
        return (match, false)
    }
    // Wildcard profile (nil/empty fingerprint) as last resort if one exists AND we
    // have no screens to seed from.
    if fp.isEmpty, let wild = cfg.profiles.first(where: { ($0.fingerprint ?? []).isEmpty }) {
        return (wild, false)
    }
    // Unknown layout — seed a new profile, persist, signal a nudge.
    var idx = cfg.profiles.count + 1
    var name = "layout-\(idx)"
    while cfg.profiles.contains(where: { $0.name == name }) { idx += 1; name = "layout-\(idx)" }
    let seeded = seedProfile(name: name, fingerprint: fp, legacyMaxSlots: nil)
    cfg.profiles.append(seeded)
    saveConfig(cfg)
    return (seeded, true)
}

// MARK: - Placement resolution

func applyOverride(_ base: Placement, _ ov: PlacementOverride?) -> Placement {
    guard let ov = ov else { return base }
    var p = base
    if let m = ov.monitor { p.monitor = m }
    if let s = ov.slotMode { p.slotMode = s }
    if let sl = ov.slot { p.slot = sl }
    if let w = ov.width { p.width = w }
    return p
}

// pin > profile override > action default, then validate monitor (clamp).
func resolvePlacement(action: Action, project: String?, profile: Profile, cfg: Config) -> Placement {
    var p = defaultPlacement
    p = applyOverride(p, profile.overrides?[action.id])
    if action.dir == "selected-project", let proj = project, let pin = cfg.pins?[proj] {
        p.monitor = pin.monitor
        if let s = pin.slot { p.slot = s }
    }
    let available = profile.monitors.map { $0.n }
    if !available.contains(p.monitor) {
        // clamp (default): highest existing monitor <= target, else lowest.
        let lower = available.filter { $0 <= p.monitor }.max()
        p.monitor = lower ?? available.min() ?? 1
    }
    return p
}

// MARK: - Bounds + slot claim

func runProcess(_ launchPath: String, _ args: [String]) -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: launchPath)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    do { try proc.run() } catch { return "" }
    proc.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

struct Bounds { var l: Int; var t: Int; var r: Int; var b: Int }

// Compute iTerm top-left bounds for a placement; claims a slot when slotted.
// Returns (bounds, slotNum) — slotNum 0 means fullscreen / no slot.
func computeBounds(placement: Placement, profile: Profile, sessionName: String) -> (Bounds, Int) {
    let screens = screensSorted()
    let idx = placement.monitor - 1
    guard idx >= 0, idx < screens.count else {
        // Shouldn't happen (resolve clamps), but fail safe to whole primary.
        let f = (screens.first ?? NSScreen.main!).frame
        let ph = primaryHeight()
        return (Bounds(l: Int(f.minX), t: Int(ph - f.maxY), r: Int(f.maxX), b: Int(ph - f.minY)), 0)
    }
    let f = screens[idx].frame
    let ph = primaryHeight()
    let monLeft = Int(f.minX.rounded())
    let monRight = Int(f.maxX.rounded())
    let top = Int((ph - f.maxY).rounded())
    let bottom = Int((ph - f.minY).rounded())

    if placement.slotMode == "fullscreen" {
        return (Bounds(l: monLeft, t: top, r: monRight, b: bottom), 0)
    }

    let maxSlots = profile.monitors.first { $0.n == placement.monitor }?.maxSlots ?? 1
    var args = ["claim", String(placement.monitor), String(maxSlots), sessionName]
    if let forced = placement.slot { args.append(String(forced)) }
    let slotStr = runProcess(home.appendingPathComponent("bin/cpl-slot").path, args)
    let slotNum = Int(slotStr) ?? 1

    let sw = (monRight - monLeft) / maxSlots
    var r = monRight - (slotNum - 1) * sw
    var l = r - sw
    if slotNum == maxSlots { l = monLeft }
    if slotNum == 1 { r = monRight }
    return (Bounds(l: l, t: top, r: r, b: bottom), slotNum)
}

// MARK: - Command construction

func shellQuote(_ s: String) -> String {
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func projectPath(action: Action, project: String?, projectsDir: String) -> (path: String, name: String) {
    let root = expandTilde(projectsDir)
    switch action.dir {
    case "selected-project":
        let p = project ?? ""
        return (root + "/" + p, p)
    case "projects-dir":
        return (root, action.title ?? action.label)
    case "none":
        return (home.path, action.title ?? action.label)
    default:
        let abs = expandTilde(action.dir)
        return (abs, action.title ?? action.label)
    }
}

// Builds the shell command line the iTerm session runs.
func buildCommand(action: Action, path: String, name: String, mon: Int, slot: Int) -> String {
    let cplSlot = shellQuote(home.appendingPathComponent("bin/cpl-slot").path)
    let cplLaunch = shellQuote(home.appendingPathComponent("bin/cpl-launch").path)
    let rawCleanup = home.appendingPathComponent("bin/cpl-cleanup").path
    let qpath = shellQuote(path)

    if action.command == "terminal" {
        // Interactive shell stays open; trap lives in this shell so the slot
        // releases when the user closes the window. Name is double-quoted inside
        // the single-quoted trap body so a session name with spaces (e.g. a
        // project dir like "NextAge Consulting") reaches cpl-cleanup as one arg.
        if slot == 0 {
            return "cd \(qpath)"
        }
        return "\(cplSlot) set-pid \(mon) \(slot) $$; "
             + "trap '\(rawCleanup) \(mon) \(slot) \"\(name)\"' EXIT; cd \(qpath)"
    }

    // claude / agents / shell — run via cpl-launch (handles set-pid, release trap, exec).
    let exec: String
    switch action.command {
    case "shell":  exec = action.shell ?? ""
    case "agents": exec = "claude agents"
    default:       exec = "claude"
    }
    return "cd \(qpath) && \(cplLaunch) \(mon) \(slot) \(shellQuote(name)) \(qpath) \(shellQuote(exec))"
}

// MARK: - Project listing

func listProjects(_ projectsDir: String) -> [String] {
    let dir = expandTilde(projectsDir)
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
    return entries
        .filter { name in
            guard !name.hasPrefix(".") else { return false }
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: dir + "/" + name, isDirectory: &isDir) && isDir.boolValue
        }
        .sorted { a, b in
            let aa = try? fm.attributesOfItem(atPath: dir + "/" + a)
            let bb = try? fm.attributesOfItem(atPath: dir + "/" + b)
            let da = aa?[.modificationDate] as? Date ?? .distantPast
            let db = bb?[.modificationDate] as? Date ?? .distantPast
            return da > db
        }
}

// MARK: - Controller

final class Controller: NSObject, NSWindowDelegate {
    var cfg: Config
    var active: Profile
    let wasSeeded: Bool
    let projects: [String]

    // The rendered button set: fixed built-ins first, then the custom looper.
    var actions: [Action] { builtinActions() + cfg.customActions }

    var launchWindow: NSWindow?
    var configWindow: NSWindow?
    var projectPopup: NSPopUpButton?

    // config panel control references (read back on Save)
    var slotSteppers: [(n: Int, field: NSTextField)] = []
    var overrideMon: [(id: String, popup: NSPopUpButton)] = []
    var overrideMode: [(id: String, popup: NSPopUpButton)] = []
    var projectsDirField: NSTextField?
    var identifyWindows: [NSWindow] = []

    override init() {
        var c = loadOrInitConfig()
        let (a, seeded) = resolveActiveProfile(&c)
        self.cfg = c
        self.active = a
        self.wasSeeded = seeded
        self.projects = listProjects(c.projectsDir)
        super.init()
    }

    // MARK: Launch panel

    func start() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)

        if wasSeeded {
            let note = NSTextField(wrappingLabelWithString: "New display layout detected — running with defaults. Click ⚙ to configure.")
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            note.translatesAutoresizingMaskIntoConstraints = false
            note.widthAnchor.constraint(equalToConstant: 320).isActive = true
            stack.addArrangedSubview(note)
        }

        // Project dropdown (lives inside the project-bound card)
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        projects.forEach { popup.addItem(withTitle: $0) }
        if projects.isEmpty { popup.addItem(withTitle: "(no projects)"); popup.isEnabled = false }
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: 300).isActive = true
        self.projectPopup = popup

        let bound = actions.enumerated().filter { $0.element.dir == "selected-project" }
        let other = actions.enumerated().filter { $0.element.dir != "selected-project" }

        func actionButton(_ item: (offset: Int, element: Action)) -> NSButton {
            let b = NSButton(title: item.element.label, target: self, action: #selector(actionClicked(_:)))
            b.bezelStyle = .rounded
            b.tag = item.offset
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 300).isActive = true
            return b
        }

        func header(_ text: String) -> NSTextField {
            let h = NSTextField(labelWithString: text.uppercased())
            h.font = .systemFont(ofSize: 11, weight: .bold)
            h.textColor = .controlAccentColor
            return h
        }

        // A visually distinct "card" — filled, bordered, rounded — to separate sections.
        func card(_ views: [NSView]) -> NSBox {
            let inner = NSStackView()
            inner.orientation = .vertical
            inner.alignment = .leading
            inner.spacing = 8
            views.forEach { inner.addArrangedSubview($0) }
            let box = NSBox()
            box.boxType = .custom
            box.fillColor = .controlBackgroundColor
            box.borderColor = .separatorColor
            box.borderWidth = 1
            box.cornerRadius = 8
            box.titlePosition = .noTitle
            box.contentViewMargins = NSSize(width: 12, height: 10)
            box.contentView = inner
            box.translatesAutoresizingMaskIntoConstraints = false
            return box
        }

        if !bound.isEmpty {
            var v: [NSView] = [header("Opens the selected project"), popup]
            v.append(contentsOf: bound.map { actionButton($0) })
            stack.addArrangedSubview(card(v))
        } else {
            stack.addArrangedSubview(card([header("Project"), popup]))
        }

        if !other.isEmpty {
            var v: [NSView] = [header("Standalone — ignores the dropdown")]
            v.append(contentsOf: other.map { actionButton($0) })
            stack.addArrangedSubview(card(v))
        }

        // Footer
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 8
        let configBtn = NSButton(title: "⚙ Config", target: self, action: #selector(openConfig))
        configBtn.bezelStyle = .rounded
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}" // Escape
        footer.addArrangedSubview(configBtn)
        footer.addArrangedSubview(cancelBtn)
        stack.addArrangedSubview(footer)

        let win = makeWindow(title: "CPL", content: stack)
        self.launchWindow = win
        win.makeKeyAndOrderFront(nil)
    }

    func makeWindow(title: String, content: NSView) -> NSWindow {
        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = title
        win.contentView = container
        win.delegate = self
        win.level = .floating
        win.center()
        return win
    }

    @objc func actionClicked(_ sender: NSButton) {
        let action = actions[sender.tag]
        var project: String? = nil
        if action.dir == "selected-project" {
            guard !projects.isEmpty, let sel = projectPopup?.titleOfSelectedItem else {
                NSSound.beep(); return
            }
            project = sel
        }
        let placement = resolvePlacement(action: action, project: project, profile: active, cfg: cfg)
        let (path, name) = projectPath(action: action, project: project, projectsDir: cfg.projectsDir)

        if action.dir == "selected-project" || action.dir == "projects-dir" {
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) || !isDir.boolValue {
                dieDialog("Path does not exist: \(path)")
            }
        }

        let (bounds, slot) = computeBounds(placement: placement, profile: active, sessionName: name)
        let cmd = buildCommand(action: action, path: path, name: name, mon: placement.monitor, slot: slot)
        let line = "\(bounds.l)\t\(bounds.t)\t\(bounds.r)\t\(bounds.b)\t\(action.itermProfile)\t\(name)\t\(cmd)"
        print(line)
        fflush(stdout)
        exit(0)
    }

    @objc func cancel() { exit(1) }

    func windowWillClose(_ notification: Notification) {
        // Closing either window without an explicit launch is a cancel.
        exit(1)
    }

    // MARK: Config panel

    @objc func openConfig() {
        slotSteppers.removeAll(); overrideMon.removeAll(); overrideMode.removeAll()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let header = NSTextField(labelWithString: "Profile: \(active.name)   (\(active.monitors.count) monitor\(active.monitors.count == 1 ? "" : "s"))")
        header.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(header)

        // Projects directory (global)
        let pdRow = NSStackView(); pdRow.orientation = .horizontal; pdRow.spacing = 8
        pdRow.addArrangedSubview(NSTextField(labelWithString: "Projects dir:"))
        let pdField = NSTextField(string: cfg.projectsDir)
        pdField.translatesAutoresizingMaskIntoConstraints = false
        pdField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        pdRow.addArrangedSubview(pdField)
        self.projectsDirField = pdField
        stack.addArrangedSubview(pdRow)

        // Per-monitor maxSlots
        let msLabel = NSTextField(labelWithString: "Slots per monitor")
        msLabel.font = .systemFont(ofSize: 11); msLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(msLabel)
        for m in active.monitors {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 8
            row.addArrangedSubview(NSTextField(labelWithString: "Monitor \(m.n):"))
            let field = NSTextField(string: String(m.maxSlots))
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 50).isActive = true
            row.addArrangedSubview(field)
            slotSteppers.append((n: m.n, field: field))
            stack.addArrangedSubview(row)
        }

        let sep = NSBox(); sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.widthAnchor.constraint(equalToConstant: 420).isActive = true
        stack.addArrangedSubview(sep)

        // Per-action placement override (for this profile)
        let ovLabel = NSTextField(labelWithString: "Action placement (overrides for this profile)")
        ovLabel.font = .systemFont(ofSize: 11); ovLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(ovLabel)

        let monCount = active.monitors.count
        for action in actions {
            let resolved = applyOverride(defaultPlacement, active.overrides?[action.id])
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 8
            let lbl = NSTextField(labelWithString: action.label)
            lbl.translatesAutoresizingMaskIntoConstraints = false
            lbl.widthAnchor.constraint(equalToConstant: 150).isActive = true
            row.addArrangedSubview(lbl)

            let monPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            for i in 1...max(1, monCount) { monPopup.addItem(withTitle: "Mon \(i)") }
            monPopup.selectItem(at: max(0, min(resolved.monitor - 1, monCount - 1)))
            row.addArrangedSubview(monPopup)
            overrideMon.append((id: action.id, popup: monPopup))

            let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
            modePopup.addItem(withTitle: "slotted")
            modePopup.addItem(withTitle: "fullscreen")
            modePopup.selectItem(withTitle: resolved.slotMode)
            row.addArrangedSubview(modePopup)
            overrideMode.append((id: action.id, popup: modePopup))

            stack.addArrangedSubview(row)
        }

        let sep2 = NSBox(); sep2.boxType = .separator
        sep2.translatesAutoresizingMaskIntoConstraints = false
        sep2.widthAnchor.constraint(equalToConstant: 420).isActive = true
        stack.addArrangedSubview(sep2)

        // Footer
        let footer = NSStackView(); footer.orientation = .horizontal; footer.spacing = 8
        let idBtn = NSButton(title: "Identify Monitors", target: self, action: #selector(identifyMonitors))
        idBtn.bezelStyle = .rounded
        let addBtn = NSButton(title: "Add custom command…", target: self, action: #selector(addCustom))
        addBtn.bezelStyle = .rounded
        let rawBtn = NSButton(title: "Edit raw JSON", target: self, action: #selector(openRawJSON))
        rawBtn.bezelStyle = .rounded
        let saveBtn = NSButton(title: "Save", target: self, action: #selector(saveConfigPanel))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelBtn.bezelStyle = .rounded
        footer.addArrangedSubview(idBtn)
        footer.addArrangedSubview(addBtn)
        footer.addArrangedSubview(rawBtn)
        footer.addArrangedSubview(saveBtn)
        footer.addArrangedSubview(cancelBtn)
        stack.addArrangedSubview(footer)

        let win = makeWindow(title: "CPL Config", content: stack)
        self.configWindow = win
        launchWindow?.orderOut(nil)
        win.makeKeyAndOrderFront(nil)
    }

    @objc func addCustom() {
        let alert = NSAlert()
        alert.messageText = "Add custom command"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let v = NSStackView(frame: NSRect(x: 0, y: 0, width: 300, height: 64))
        v.orientation = .vertical; v.spacing = 6; v.alignment = .leading
        let labelField = NSTextField(string: ""); labelField.placeholderString = "Button label (e.g. SSH box)"
        labelField.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        let cmdField = NSTextField(string: ""); cmdField.placeholderString = "Shell command (e.g. ssh box)"
        cmdField.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        v.addArrangedSubview(labelField)
        v.addArrangedSubview(cmdField)
        alert.accessoryView = v
        if alert.runModal() == .alertFirstButtonReturn {
            let label = labelField.stringValue.trimmingCharacters(in: .whitespaces)
            let cmd = cmdField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, !cmd.isEmpty else { return }
            let id = "custom-\(cfg.customActions.count + 1)"
            cfg.customActions.append(Action(id: id, label: label, command: "shell", shell: cmd,
                                            dir: "none", itermProfile: "Default"))
            saveConfig(cfg)
            openConfig() // rebuild
        }
    }

    @objc func openRawJSON() {
        // `open -t` forces the default text editor regardless of file extension.
        _ = runProcess("/usr/bin/open", ["-t", jsonPath])
    }

    // Flash a large number on each physical display so the user can map CPL's
    // monitor numbering (X-then-Y) to the screens in front of them.
    @objc func identifyMonitors() {
        identifyWindows.forEach { $0.orderOut(nil) }
        identifyWindows.removeAll()
        let screens = screensSorted()
        for (i, screen) in screens.enumerated() {
            let f = screen.frame
            let side: CGFloat = 240
            let rect = NSRect(x: f.midX - side / 2, y: f.midY - side / 2, width: side, height: side)
            let win = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            win.level = .screenSaver
            win.isOpaque = false
            win.backgroundColor = .clear
            win.ignoresMouseEvents = true
            let box = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
            box.wantsLayer = true
            box.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.85).cgColor
            box.layer?.cornerRadius = 24
            let num = NSTextField(labelWithString: "\(i + 1)")
            num.alignment = .center
            num.font = .systemFont(ofSize: 120, weight: .bold)
            num.textColor = .white
            num.frame = NSRect(x: 0, y: 60, width: side, height: 150)
            box.addSubview(num)
            let res = NSTextField(labelWithString: "\(Int(f.width))×\(Int(f.height))")
            res.alignment = .center
            res.font = .systemFont(ofSize: 20, weight: .medium)
            res.textColor = .white
            res.frame = NSRect(x: 0, y: 28, width: side, height: 28)
            box.addSubview(res)
            win.contentView = box
            win.orderFrontRegardless()
            identifyWindows.append(win)
        }
        // Auto-dismiss after 2.5s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.identifyWindows.forEach { $0.orderOut(nil) }
            self?.identifyWindows.removeAll()
        }
    }

    @objc func saveConfigPanel() {
        if let pd = projectsDirField?.stringValue.trimmingCharacters(in: .whitespaces), !pd.isEmpty {
            cfg.projectsDir = pd
        }
        // maxSlots
        for s in slotSteppers {
            if let idx = active.monitors.firstIndex(where: { $0.n == s.n }),
               let v = Int(s.field.stringValue), v >= 1 {
                active.monitors[idx].maxSlots = v
            }
        }
        // overrides
        var overrides = active.overrides ?? [:]
        for action in actions {
            let mon = (overrideMon.first { $0.id == action.id }?.popup.indexOfSelectedItem ?? 0) + 1
            let mode = overrideMode.first { $0.id == action.id }?.popup.titleOfSelectedItem ?? "slotted"
            // Only store an override when it differs from the monitor-1/slotted default.
            if mon != defaultPlacement.monitor || mode != defaultPlacement.slotMode {
                overrides[action.id] = PlacementOverride(monitor: mon, slotMode: mode, slot: nil, width: nil)
            } else {
                overrides.removeValue(forKey: action.id)
            }
        }
        active.overrides = overrides
        if let idx = cfg.profiles.firstIndex(where: { $0.name == active.name }) {
            cfg.profiles[idx] = active
        }
        saveConfig(cfg)
        exit(1) // config saved; re-launch CPL to act on it
    }
}

// MARK: - Entry

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = Controller()
controller.start()
app.activate(ignoringOtherApps: true)
app.run()
