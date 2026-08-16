import Cocoa

// Overlimit - floating usage panel for Claude subscription limits.
// Reads ~/.overlimit/usage-log.csv, written by a launchd agent every 5 minutes.

struct Sample {
    let ts: Date
    let kind: String
    let model: String
    let percent: Double
    let resets: Date?          // empty right after a window rollover
    let active: Bool
    var isWeekly: Bool { kind.hasPrefix("weekly") }
}

let csvPath = NSString(string: "~/.overlimit/usage-log.csv").expandingTildeInPath

func parseISO(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

func loadSamples() -> [Sample] {
    guard let raw = try? String(contentsOfFile: csvPath, encoding: .utf8) else { return [] }
    var out: [Sample] = []
    for line in raw.split(separator: "\n").dropFirst() {
        let c = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard c.count >= 8, let ts = parseISO(c[0]), let p = Double(c[4]) else { continue }
        out.append(Sample(ts: ts, kind: c[1], model: c[3], percent: p,
                          resets: parseISO(c[6]), active: c[7].hasPrefix("True")))
    }
    return out
}

// Session row is coloured by REMAINING, not by pace.
// Inside a five-hour window pace carries no information: nothing you save is
// carried over and everything resets. The only question is whether you hit
// the wall, so "burning faster than even pace" here is noise, not a signal.
// Thresholds: yellow below 35% left (time to replan),
// red below 15% (20% of a five-hour window is still ~40 minutes of work).
func sessionColor(_ percent: Double) -> NSColor {
    let left = 100 - percent
    if left < 15 { return Tone.red }
    if left < 35 { return Tone.yellow }
    return Tone.green
}

// --- Weekly limits: daily budget ---
// Norm is exactly 1/7 of the window per day (14.29 pp). One value for both
// colour and ceiling, otherwise they disagree at the boundary.
// k = budget / norm. Self-calibrating: at window start 100% left across 7 days
// gives exactly the norm (k=1), so no special-casing for the start of a week.
let dailyNorm = 100.0 / 7.0

struct Budget {
    let leftover: Double        // limit remaining, %
    let perDay: Double          // how much may be spent per day
    let k: Double               // ratio to the norm
    let ceiling: Double         // ceiling right now: 100 - norm x days until reset
    var lowRemainder: Bool { leftover < 10 }
}

func budget(_ s: Sample) -> Budget? {
    guard let r = s.resets else { return nil }
    let days = max(r.timeIntervalSinceNow / 86400.0, 1.0 / 24.0)   // at least an hour
    let leftover = max(100 - s.percent, 0)
    let perDay = leftover / days

    // Ceiling: where the even-pace line runs right now.
    // Depends on time only, so it is identical for every weekly limit.
    // Anything below the ceiling is ahead of schedule.
    let ceiling = max(100 - dailyNorm * days, 0)

    return Budget(leftover: leftover, perDay: perDay,
                  k: perDay / dailyNorm, ceiling: ceiling)
}

// Thresholds are chosen so the colour never contradicts the sign in the row:
// yellow starts exactly when the sign flips to ">", i.e. when the actual
// value passes the ceiling (k = 1.00). Red is when the gap can no longer be
// recovered at an even pace.
func weeklyColor(_ b: Budget) -> NSColor {
    if b.lowRemainder { return Tone.red }   // hard rule on top of everything
    if b.k < Cfg.dangerAt { return Tone.red }
    if b.k < Cfg.warnAt { return Tone.yellow }
    return Tone.green
}

// Session uses hours and minutes. An empty resets_at means the window has just
// rolled over, so a full five hours lie ahead.
func fmtLeft(_ d: Date?) -> String {
    guard let d = d else { return L("5ч", "5h") }
    let s = Int(d.timeIntervalSinceNow)
    if s <= 0 { return L("скоро", "soon") }        // the window rolled over between snapshots
    let h = s / 3600
    if h >= 24 { return "\(h / 24)\(L("д","d")) \(h % 24)\(L("ч","h"))" }
    if h >= 1 { return "\(h)\(L("ч","h")) \((s % 3600) / 60)\(L("м","m"))" }
    return "\(s / 60)\(L("м","m"))"
}

// Weekly limits do not need hours - days are enough.
func fmtDays(_ d: Date?) -> String {
    guard let d = d else { return "—" }
    let sec = d.timeIntervalSinceNow
    if sec <= 0 { return L("скоро", "soon") }
    if sec < 86400 { return "\(Int(sec / 3600))\(L("ч","h"))" }
    return "\(Int((sec / 86400).rounded()))\(L("д","d"))"
}

// Sign of actual versus ceiling. ROUNDED values are compared so the sign
// never contradicts the numbers on screen.
func relation(_ fact: Double, _ ceiling: Double) -> String {
    let f = fact.rounded(), c = ceiling.rounded()
    return f < c ? "<" : (f > c ? ">" : "=")
}

// Session row: "5h  34% < 68%  .  1h 37m"
// Same idea as the weekly rows, but the window is five hours: norm is 20 pp
// per hour, computed down to the minute.
// Empty resets_at means the window just opened: all five hours remain.
func sessionText(_ s: Sample) -> String {
    let hoursLeft = min(max((s.resets?.timeIntervalSinceNow ?? 18000) / 3600.0, 0), 5)
    let ceiling = max(100 - 20.0 * hoursLeft, 0)
    let mid = String(format: " %@ %2.0f%%", relation(s.percent, ceiling), ceiling)
    return fmtRow(L("5ч","5h"), s.percent, mid, fmtLeft(s.resets))
}
// Rows are aligned in columns: tag | actual | ceiling | time until reset.
// The middle block has a fixed width so the time column lines up
// across all three rows.
func fmtRow(_ tag: String, _ pct: Double, _ mid: String, _ time: String) -> String {
    "\(pad(tag, 6))\(String(format: "%3.0f", pct))%\(pad(mid, 7))· \(time)"
}

// Weekly row: "Fable  75% > 73%  .  1d 22h"
// The second number is the ceiling: the even-pace line, 100 - 14.29 x days.
// It is the same for both rows and depends only on time until reset.
// The sign shows actual versus ceiling: < under, > over, = exactly on pace.
// ROUNDED values are compared so the sign matches the numbers on screen.
// Below 10% remaining the ceiling is meaningless - show the remainder instead.
func weeklyText(_ tag: String, _ s: Sample, _ b: Budget) -> String {
    if s.percent >= 100 {
        return fmtRow(tag, s.percent, "", "\(L("сброс","reset")) \(fmtLeft(s.resets))")
    }
    if b.lowRemainder {
        return fmtRow(tag, s.percent, "",
                      "\(L("ост.","left")) \(String(format: "%.0f", b.leftover))% \(L("на","for")) \(fmtLeft(s.resets))")
    }
    let mid = String(format: " %@ %2.0f%%", relation(s.percent, b.ceiling), b.ceiling)
    return fmtRow(tag, s.percent, mid, fmtLeft(s.resets))
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

func fmtAgo(_ sec: TimeInterval) -> String {
    let s = Int(sec), h = s / 3600
    if h >= 24 { return "\(h / 24)\(L("д","d")) \(h % 24)\(L("ч","h"))" }
    if h >= 1 { return "\(h)\(L("ч","h")) \((s % 3600) / 60)\(L("м","m"))" }
    return "\(s / 60)\(L("м","m"))"
}

// Height of the hover strip with the traffic lights. At rest the window does not
// include it and sits flush in the corner; on hover it drops down by stripH.
let stripH: CGFloat = 22

// --- Settings, all stored in UserDefaults ---
enum Cfg {
    static let d = UserDefaults.standard
    static var mode: String { d.string(forKey: "mode") ?? "numbers" }   // numbers | bars
    static var showSession: Bool { d.object(forKey: "showSession") == nil ? true : d.bool(forKey: "showSession") }
    static var interval: Double { d.double(forKey: "interval") > 0 ? d.double(forKey: "interval") : 300 }
    static var opacity: Double { d.double(forKey: "opacity") > 0 ? d.double(forKey: "opacity") : 0.88 }
    static var fontSize: CGFloat { d.double(forKey: "fontSize") > 0 ? CGFloat(d.double(forKey: "fontSize")) : 15 }
    static var theme: String { d.string(forKey: "theme") ?? "system" }
    static var isDark: Bool {
        switch theme {
        case "dark": return true
        case "light": return false
        default:
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }
    static var bg: NSColor {
        isDark ? NSColor(calibratedWhite: 0.09, alpha: CGFloat(opacity))
               : NSColor(calibratedWhite: 0.97, alpha: CGFloat(opacity))
    }
    static func show(_ key: String) -> Bool {
        d.object(forKey: key) == nil ? true : d.bool(forKey: key)
    }
    static var statusBar: Bool { d.object(forKey: "statusBar") == nil ? true : d.bool(forKey: "statusBar") }
    static var statusRow: String { d.string(forKey: "statusRow") ?? "auto" }
    static var lang: String { d.string(forKey: "lang") ?? "system" }
    static var collapsed: Bool { d.bool(forKey: "collapsed") }
    static var collapsedRow: String { d.string(forKey: "collapsedRow") ?? "session" }
    static var warnAt: Double { d.double(forKey: "warnAt") > 0 ? d.double(forKey: "warnAt") : 1.00 }
    static var dangerAt: Double { d.double(forKey: "dangerAt") > 0 ? d.double(forKey: "dangerAt") : 0.85 }
}

// Traffic-light colours: the light theme needs darker shades to stay readable.
enum Tone {
    static var green: NSColor { Cfg.isDark ? .systemGreen : NSColor(srgbRed: 0.10, green: 0.48, blue: 0.20, alpha: 1) }
    static var yellow: NSColor { Cfg.isDark ? .systemYellow : NSColor(srgbRed: 0.65, green: 0.45, blue: 0.02, alpha: 1) }
    static var red: NSColor { Cfg.isDark ? .systemRed : NSColor(srgbRed: 0.70, green: 0.12, blue: 0.12, alpha: 1) }
    static var gray: NSColor { Cfg.isDark ? .systemGray : NSColor(calibratedWhite: 0.35, alpha: 1) }
}

// Localisation. Call sites stay `L(ru, en)`; other languages are looked up in
// TR by the English string, falling back to English when a phrase is missing.
// That keeps one table instead of touching fifty call sites.
func systemLang() -> String {
    guard let code = Locale.preferredLanguages.first?.prefix(2).lowercased() else { return "en" }
    return ["ru", "fr", "es", "pt", "zh"].contains(String(code)) ? String(code) : "en"
}

func L(_ ru: String, _ en: String) -> String {
    let lang = Cfg.lang == "system" ? systemLang() : Cfg.lang
    if lang == "ru" { return ru }
    if lang == "en" { return en }
    return TR[en]?[lang] ?? en
}

struct Row {
    let id: String          // session | all | scoped
    let tag: String
    let percent: Double
    let ceiling: Double
    let color: NSColor
    let time: String
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let img = self.copy() as! NSImage
        img.lockFocus()
        color.set()
        NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}

final class PanelView: NSView {
    var onClose: (() -> Void)?
    var onMinimize: (() -> Void)?
    var onZoom: (() -> Void)?
    var onSettings: (() -> Void)?
    var onHelp: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var onHover: ((Bool) -> Void)?
    var rows: [Row] = []
    private(set) var hovered = false
    var strip: CGFloat { hovered ? stripH : 0 }

    override var isFlipped: Bool { true }

    // Cursor tracking is event-driven: the system sends enter and exit,
    // no timers and no redraw at rest.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { hovered = true; onHover?(true) }
    override func mouseExited(with e: NSEvent) { hovered = false; onHover?(false) }

    // Traffic lights on the left of the strip: dock, hide, collapse.
    func lights() -> [NSRect] {
        guard hovered else { return [] }
        let d: CGFloat = 12, gap: CGFloat = 8
        var x = bounds.minX + 10
        return (0..<3).map { _ -> NSRect in
            defer { x += d + gap }
            return NSRect(x: x, y: (stripH - d) / 2, width: d, height: d)
        }
    }

    // Settings and help, same size, to the right of the lights.
    func tools() -> [NSRect] {
        guard hovered else { return [] }
        // Pinned to the right edge: in macOS the left corner belongs to the traffic
        // lights only, utility buttons live on the right - and you stop misclicking
        // the red circle.
        let d: CGFloat = 13, gap: CGFloat = 10
        var x = bounds.maxX - (d * 2 + gap) - 10
        return (0..<2).map { _ -> NSRect in
            defer { x += d + gap }
            return NSRect(x: x, y: (stripH - d) / 2, width: d, height: d)
        }
    }

    override func draw(_ r: NSRect) {
        let bg = Cfg.bg
        let body = NSRect(x: 0, y: strip, width: bounds.width, height: bounds.height - strip)
        bg.setFill()
        NSBezierPath(roundedRect: body, xRadius: 10, yRadius: 10).fill()

        if hovered {
            bg.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width, height: stripH - 3),
                         xRadius: 8, yRadius: 8).fill()
            let cols = [NSColor(srgbRed: 0.92, green: 0.34, blue: 0.33, alpha: 1),
                        NSColor(srgbRed: 0.95, green: 0.75, blue: 0.19, alpha: 1),
                        NSColor(srgbRed: 0.30, green: 0.78, blue: 0.35, alpha: 1)]
            for (i, rect) in lights().enumerated() {
                cols[i].setFill()
                NSBezierPath(ovalIn: rect).fill()
            }
            let names = ["gearshape.fill", "questionmark.circle.fill"]
            let tint = Cfg.isDark ? NSColor(calibratedWhite: 0.62, alpha: 1)
                                  : NSColor(calibratedWhite: 0.42, alpha: 1)
            for (i, rect) in tools().enumerated() {
                guard let img = NSImage(systemSymbolName: names[i], accessibilityDescription: nil)
                else { continue }
                let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                img.withSymbolConfiguration(cfg)?.tinted(tint).draw(in: rect)
            }
        }
        if Cfg.mode == "bars" { drawBars(in: body) }
    }

    // Bar mode: track, fill by actual usage and a tick mark at the ceiling.
    func drawBars(in body: NSRect) {
        let fs = Cfg.fontSize, rowH = fs + 9
        let font = NSFont.monospacedSystemFont(ofSize: fs - 2, weight: .medium)
        var y = body.minY + 6
        let tagW: CGFloat = 52, barW = body.width - tagW - 74
        for row in rows {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: row.color]
            NSAttributedString(string: row.tag, attributes: attrs)
                .draw(at: NSPoint(x: 8, y: y + 1))

            let track = NSRect(x: 8 + tagW, y: y + 3, width: barW, height: fs - 4)
            (Cfg.isDark ? NSColor(calibratedWhite: 0.25, alpha: 1) : NSColor(calibratedWhite: 0.82, alpha: 1)).setFill()
            NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()

            let fillW = max(track.width * CGFloat(min(row.percent, 100)) / 100, track.height)
            row.color.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: fillW,
                                             height: track.height),
                         xRadius: track.height / 2, yRadius: track.height / 2).fill()

            // ceiling tick - where the even-pace line runs
            let cx = track.minX + track.width * CGFloat(min(row.ceiling, 100)) / 100
            (Cfg.isDark ? NSColor(calibratedWhite: 0.95, alpha: 0.85) : NSColor(calibratedWhite: 0.15, alpha: 0.85)).setFill()
            NSRect(x: cx - 1, y: track.minY - 2, width: 2, height: track.height + 4).fill()

            NSAttributedString(string: String(format: "%3.0f%%", row.percent), attributes: attrs)
                .draw(at: NSPoint(x: track.maxX + 8, y: y + 1))
            y += rowH
        }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if hovered {
            for (i, rect) in lights().enumerated() where rect.insetBy(dx: -4, dy: -4).contains(p) {
                [onClose, onMinimize, onZoom][i]?()
                return
            }
            for (i, rect) in tools().enumerated() where rect.insetBy(dx: -5, dy: -5).contains(p) {
                [onSettings, onHelp][i]?()
                return
            }
        }
        super.mouseDown(with: e)
    }
    override func mouseDragged(with e: NSEvent) { window?.performDrag(with: e) }
    override func rightMouseDown(with e: NSEvent) { onMenu?(e) }
}

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var panel: PanelView!
    var refreshTimer: Timer?
    var statusItem: NSStatusItem?
    let label = NSTextField(labelWithString: "…")
    let close = NSButton(title: "×", target: nil, action: nil)
    let claudeBundleID = "com.anthropic.claudefordesktop"

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.removeItem(atPath: App.noAutoFlag)
        let rect = NSRect(x: 0, y: 0, width: 372, height: 86)
        window = NSWindow(contentRect: rect, styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hasShadow = true
        window.isMovableByWindowBackground = true

        let v = PanelView(frame: rect)
        label.frame = NSRect(x: 14, y: 10, width: 322, height: 70)
        label.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .medium)
        label.maximumNumberOfLines = 4
        v.addSubview(label)

        close.frame = NSRect(x: 344, y: 5, width: 24, height: 24)
        close.isBordered = false
        close.target = self
        close.action = #selector(quit)
        close.contentTintColor = NSColor(calibratedWhite: 0.5, alpha: 1)

        v.onClose = { [weak self] in self?.toDock() }
        v.onMinimize = { [weak self] in self?.hideUntilReturn() }
        v.onSettings = { [weak self] in
            guard let me = self, let e = NSApp.currentEvent else { return }
            me.showMenu(e)
        }
        v.onHelp = { [weak self] in self?.showHelp() }
        v.onZoom = { [weak self] in self?.toggleCollapse() }
        v.onMenu = { [weak self] e in self?.showMenu(e) }
        v.onHover = { [weak self] _ in self?.fitToContent() }
        panel = v

        window.contentView = v

        // Default is the chosen corner. If the panel was dragged, the position is
        // remembered and restored - but only if it still lands on a screen.
        window.delegate = self
        let d = UserDefaults.standard
        var placed = false
        if d.object(forKey: "originX") != nil, let scr = NSScreen.main {
            let p = NSPoint(x: d.double(forKey: "originX"), y: d.double(forKey: "originY"))
            let probe = NSRect(origin: p, size: window.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(probe) }) {
                window.setFrameOrigin(p); placed = true
            }
            _ = scr
        }
        if !placed {
            window.setFrameOrigin(defaultOrigin(window.frame.size))
        }
        window.orderFrontRegardless()

        // Show the panel only while Claude itself is frontmost
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        applyVisibility(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)

        refresh()
        startTimer()
        // Visibility watchdog: activation notifications do not always arrive (clicking
        // the desktop, for one), and the window could stay hidden until the next
        // refresh five minutes later.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in self.syncVisibility() }
    }

    func startTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Cfg.interval,
                                            repeats: true) { _ in self.refresh() }
    }

    var shouldBeVisible: Bool {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if docked { return false }          // comes back only by clicking the Dock icon
        if hidden {
            // You must leave Claude first, otherwise the panel would return two seconds
            // after the click and the mode would be useless.
            if front != claudeBundleID && front != Bundle.main.bundleIdentifier {
                leftClaudeSinceHide = true
            }
            if leftClaudeSinceHide && front == claudeBundleID {
                hidden = false
                leftClaudeSinceHide = false
            } else {
                return false
            }
        }
        return front == claudeBundleID || (front != nil && front == Bundle.main.bundleIdentifier)
    }

    func syncVisibility() {
        if shouldBeVisible && !window.isVisible {
            refresh()
            window.orderFrontRegardless()
        } else if !shouldBeVisible && window.isVisible {
            window.orderOut(nil)
        }
        if window.isVisible { rescueOffscreen() }
    }

    // Remember where the user dragged the panel.
    func windowDidMove(_ n: Notification) {
        let d = UserDefaults.standard
        d.set(Double(window.frame.origin.x), forKey: "originX")
        d.set(Double(window.frame.origin.y), forKey: "originY")
    }

    // The window may end up off-screen: external display unplugged, resolution
    // changed, sleep and wake. The process is alive and the window is "visible",
    // but nothing is on screen. Put it back into the chosen corner.
    func rescueOffscreen() {
        let f = window.frame
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(f) }
        guard !onScreen else { return }
        window.setFrameOrigin(defaultOrigin(f.size))
        window.orderFrontRegardless()
    }

    @objc func appActivated(_ n: Notification) {
        let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        applyVisibility(app?.bundleIdentifier)
    }

    func applyVisibility(_ bundleID: String?) {
        // Our own app counts as "ours": dragging the panel makes it frontmost, and
        // without this check it would hide itself right under the cursor while being
        // dragged.
        let mine = Bundle.main.bundleIdentifier
        if bundleID == claudeBundleID || (bundleID != nil && bundleID == mine) {
            refresh()
            window.orderFrontRegardless()
        } else {
            window.orderOut(nil)
        }
    }

    // Green button: collapse the panel to a single row and back.
    @objc func toggleCollapse() {
        Cfg.d.set(!Cfg.collapsed, forKey: "collapsed")
        refresh()
    }

    // Which rows to show: when collapsed, only the one picked in the menu.
    func allow(_ id: String) -> Bool {
        if Cfg.collapsed { return Cfg.collapsedRow == id }
        switch id {
        case "session": return Cfg.show("showSession")
        case "all": return Cfg.show("showAll")
        default: return Cfg.show("showScoped")
        }
    }

    @objc func quit() { NSApp.terminate(nil) }

    // Quit means quit: the watcher will not relaunch. The flag is cleared when
    // the app is started manually.
    static let noAutoFlag = NSString(string: "~/.overlimit/no-autostart").expandingTildeInPath

    @objc func quitForever() {
        FileManager.default.createFile(atPath: App.noAutoFlag, contents: nil)
        NSApp.terminate(nil)
    }

    @objc func showHelp() {
        let a = NSAlert()
        a.messageText = "Overlimit"
        a.informativeText = L("""
        Строки: сессия 5ч, недельный общий, недельный по модели.

        Формат: факт | знак | потолок | время до сброса.
        Потолок — где проходит линия равномерного расхода: 100 − норма × время.
        Знак < значит запас, > перебор, = ровно по графику.

        Цвет недельных строк — по темпу: сколько можно тратить в день до сброса,
        в сравнении с нормой 14,29 п.п. Сессия красится по остатку.

        Кнопки при наведении: красная — в док, жёлтая — скрыть до возврата
        в Claude, зелёная — свернуть до одной строки. Рядом шестерёнка и помощь.

        Правый клик — настройки. Перетаскивание запоминается,
        «Вернуть на место» ставит плашку в выбранный угол.

        Данные обновляет фоновый агент. Если сбор встанет,
        появится строка «данные устарели».
        """, """
        Rows: 5h session, weekly total, weekly per model.

        Format: actual | sign | ceiling | time to reset.
        Ceiling is the even-pace line: 100 − norm × time remaining.
        Sign < means you are under it, > over it, = exactly on pace.

        Weekly rows are coloured by pace: how much you may spend per day
        until reset, against the 14.29 pp norm. The session row uses remaining.

        Hover buttons: red sends to Dock, yellow hides until you return
        to Claude, green collapses to one row. Then gear and help.

        Right-click opens settings. Dragging is remembered;
        "Reset position" puts the panel back in the chosen corner.

        A background agent refreshes the data. If it stalls,
        a "data is stale" row appears.
        """)
        a.addButton(withTitle: L("Понятно","Got it"))
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // --- Two ways to put the panel away ---
    // docked (red): process alive, icon in the Dock, never returns on its own -
    //                    only by clicking that icon.
    // hidden (yellow): process alive, no icon anywhere, returns by itself on the
    //                    next switch back to Claude.
    var docked = false
    var hidden = false
    var leftClaudeSinceHide = false

    // First press: dock it and bring it back after 15 minutes, once.
    // Second press in a row: it stays docked until the icon is clicked.
    var dockPresses = 0
    var dockTimer: Timer?

    @objc func toDock() {
        docked = true; hidden = false
        window.orderOut(nil)
        NSApp.setActivationPolicy(.regular)
        dockTimer?.invalidate()
        if dockPresses == 0 {
            dockTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: false) { _ in
                self.restore()
                self.dockPresses = 1        // it came back once; next time it stays
            }
        }
        dockPresses += 1
    }

    @objc func hideUntilReturn() {
        hidden = true; docked = false
        leftClaudeSinceHide = false
        window.orderOut(nil)
    }

    func restore() {
        dockTimer?.invalidate()
        docked = false; hidden = false
        NSApp.setActivationPolicy(.accessory)
        refresh()
        window.orderFrontRegardless()
    }

    // Clicking the Dock icon is a deliberate return, so reset the counter.
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows f: Bool) -> Bool {
        dockPresses = 0
        restore()
        return true
    }

    // --- Default position ---
    // The corner is chosen in the menu. A drag is remembered and stays until
    // "Reset position" is used.
    func defaultOrigin(_ size: NSSize) -> NSPoint {
        guard let scr = NSScreen.main else { return .zero }
        let vf = scr.visibleFrame, m: CGFloat = 2
        switch UserDefaults.standard.string(forKey: "corner") ?? "topLeft" {
        case "topRight":    return NSPoint(x: vf.maxX - size.width - m, y: vf.maxY - size.height - m)
        case "bottomLeft":  return NSPoint(x: vf.minX + m, y: vf.minY + m)
        case "bottomRight": return NSPoint(x: vf.maxX - size.width - m, y: vf.minY + m)
        default:            return NSPoint(x: vf.minX + m, y: vf.maxY - size.height - m)
        }
    }

    @objc func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "originX")
        UserDefaults.standard.removeObject(forKey: "originY")
        window.setFrameOrigin(defaultOrigin(window.frame.size))
    }

    @objc func setCorner(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? String ?? "topLeft", forKey: "corner")
        resetPosition()
    }

    // Generic setting switch: stores the value and redraws.
    @objc func pick(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String: Any],
              let key = pair["k"] as? String else { return }
        // "menuBar" is one control over two stored values: visibility and choice.
        if key == "menuBar" {
            let v = pair["v"] as? String ?? "auto"
            Cfg.d.set(v != "off", forKey: "statusBar")
            if v != "off" { Cfg.d.set(v, forKey: "statusRow") }
        } else {
            Cfg.d.set(pair["v"], forKey: key)
        }
        if key == "interval" { startTimer() }
        refresh()
    }

    @objc func toggleRow(_ sender: NSMenuItem) {
        guard let k = sender.representedObject as? String else { return }
        Cfg.d.set(!Cfg.show(k), forKey: k)
        refresh()
    }

    // Manual entry for any numeric setting.
    @objc func manual(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let key = info["k"] as? String else { return }
        let a = NSAlert()
        a.messageText = (info["t"] as? String) ?? L("Значение","Value")
        a.informativeText = (info["h"] as? String) ?? ""
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        tf.stringValue = String(format: "%g", Cfg.d.double(forKey: key))
        a.accessoryView = tf
        a.addButton(withTitle: "OK"); a.addButton(withTitle: L("Отмена","Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn,
           let v = Double(tf.stringValue.replacingOccurrences(of: ",", with: ".")), v > 0 {
            Cfg.d.set(v, forKey: key)
            if key == "interval" { startTimer() }
            refresh()
        }
    }

    func sub(_ title: String, _ key: String, _ opts: [(String, Any)],
             _ current: Any, manual manualHint: String? = nil,
             display: String? = nil) -> NSMenuItem {
        let shown = display ?? "\(current)"
        let item = NSMenuItem(title: "\(title): \(shown)", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for (label, value) in opts {
            let it = NSMenuItem(title: label, action: #selector(pick(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = ["k": key, "v": value]
            it.state = "\(value)" == "\(current)" ? .on : .off
            menu.addItem(it)
        }
        if let hint = manualHint {
            menu.addItem(.separator())
            let mi = NSMenuItem(title: L("Ввести вручную…","Enter manually…"), action: #selector(manual(_:)),
                                keyEquivalent: "")
            mi.target = self
            mi.representedObject = ["k": key, "t": title, "h": hint]
            menu.addItem(mi)
        }
        item.submenu = menu
        return item
    }

    // --- macOS menu bar ---
    // Shows the tightest limit and opens the same settings menu.
    // Always visible, even while the panel is hidden or docked.
    func setupStatusItem() {
        if Cfg.statusBar {
            if statusItem == nil {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            }
        } else if let si = statusItem {
            NSStatusBar.system.removeStatusItem(si)
            statusItem = nil
        }
    }

    func updateStatusItem(_ rows: [Row]) {
        guard let btn = statusItem?.button else { return }
        statusItem?.menu = buildMenu()
        // Which row to show: a specific one, or whichever is tightest.
        let pick: Row?
        switch Cfg.statusRow {
        case "session": pick = rows.first { $0.id == "session" }
        case "all":     pick = rows.first { $0.id == "all" }
        case "scoped":  pick = rows.first { $0.id == "scoped" }
        default:        pick = rows.max { (100 - $0.percent) > (100 - $1.percent) }
        }
        guard let worst = pick ?? rows.first else {
            btn.title = "—"; return
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        btn.attributedTitle = NSAttributedString(
            string: "\(worst.tag) \(String(format: "%.0f", worst.percent))%",
            attributes: [.font: font, .foregroundColor: worst.color])
    }

    @objc func showMenu(_ e: NSEvent) {
        NSMenu.popUpContextMenu(buildMenu(), with: e, for: window.contentView!)
    }

    // Menu is grouped by how often each entry is used: actions first, then the
    // three settings that change what you see, then the rest behind submenus.
    func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self
        return it
    }

    func group(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        items.forEach { sub.addItem($0) }
        parent.submenu = sub
        return parent
    }

    func buildMenu() -> NSMenu {
        let m = NSMenu()

        m.addItem(group(L("Убрать плашку", "Put away"), [
            item(Cfg.collapsed ? L("Развернуть","Expand")
                               : L("Свернуть до одной строки","Collapse to one row"),
                 #selector(toggleCollapse)),
            item(L("Скрыть до возврата в Claude","Hide until back in Claude"),
                 #selector(hideUntilReturn)),
            item(L("Убрать в док","Send to Dock"), #selector(toDock)),
        ]))
        m.addItem(.separator())

        m.addItem(sub(L("Вид","View"), "mode", [(L("Цифры","Numbers"), "numbers"),
                      (L("Бары","Bars"), "bars")], Cfg.mode,
                      display: Cfg.mode == "bars" ? L("бары","bars") : L("цифры","numbers")))

        let rowsItem = NSMenuItem(title: L("Показывать строки","Rows shown"),
                                  action: nil, keyEquivalent: "")
        let rowsMenu = NSMenu()
        for (title, key) in [(L("Сессия 5ч","5h session"), "showSession"),
                             (L("Все модели","All models"), "showAll"),
                             (L("По модели","Per model"), "showScoped")] {
            let it = NSMenuItem(title: title, action: #selector(toggleRow(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = key
            it.state = Cfg.show(key) ? .on : .off
            rowsMenu.addItem(it)
        }
        rowsItem.submenu = rowsMenu
        m.addItem(rowsItem)

        // One entry instead of two: hiding the item is just another choice here.
        let barNames = ["off": L("скрыта","hidden"), "auto": L("самый напряжённый","tightest"),
                        "session": L("сессия 5ч","5h session"), "all": L("все модели","all models"),
                        "scoped": L("по модели","per model")]
        let barNow = Cfg.statusBar ? Cfg.statusRow : "off"
        m.addItem(sub(L("В строке меню","Menu bar"), "menuBar",
                      [(L("Скрыть","Hide"), "off"),
                       (L("Самый напряжённый","Tightest"), "auto"),
                       (L("Сессия 5ч","5h session"), "session"),
                       (L("Все модели","All models"), "all"),
                       (L("По модели","Per model"), "scoped")], barNow,
                      display: barNames[barNow] ?? ""))
        m.addItem(.separator())

        m.addItem(group(L("Настройки","Settings"), [
            sub(L("Язык","Language"), "lang",
                // ordered by the English name of each language
                [(L("Как в системе","Match system"), "system"),
                 ("中文", "zh"), ("English", "en"), ("Français", "fr"),
                 ("Português", "pt"), ("Русский", "ru"), ("Español", "es")], Cfg.lang,
                display: ["system": L("как в системе","match system"), "en": "english",
                          "ru": "русский", "fr": "français", "es": "español",
                          "pt": "português", "zh": "中文"][Cfg.lang] ?? ""),
            sub(L("Тема","Theme"), "theme",
                [(L("Как в системе","Match system"), "system"), (L("Дневная","Light"), "light"),
                 (L("Ночная","Dark"), "dark")], Cfg.theme,
                display: ["system": L("как в системе","match system"),
                          "light": L("дневная","light"),
                          "dark": L("ночная","dark")][Cfg.theme] ?? ""),
            sub(L("Размер шрифта","Font size"), "fontSize",
                [("11", 11.0), ("12", 12.0), ("13", 13.0), ("15", 15.0),
                 ("17", 17.0), ("20", 20.0), ("24", 24.0)], Cfg.fontSize,
                manual: L("Размер в пунктах, например 16","Point size, e.g. 16"),
                display: String(format: "%g pt", Cfg.fontSize)),
            sub(L("Прозрачность","Opacity"), "opacity",
                [(L("Плотная","Solid"), 1.0), (L("Обычная","Normal"), 0.88),
                 (L("Лёгкая","Light"), 0.7), (L("Призрак","Ghost"), 0.5)], Cfg.opacity,
                manual: L("От 0.2 до 1.0","From 0.2 to 1.0"),
                display: String(format: "%g", Cfg.opacity)),
            sub(L("Интервал обновления","Refresh interval"), "interval",
                [(L("1 мин","1 min"), 60.0), (L("5 мин","5 min"), 300.0),
                 (L("15 мин","15 min"), 900.0)], Cfg.interval,
                manual: L("В секундах, не меньше 60","Seconds, at least 60"),
                display: "\(Int(Cfg.interval / 60)) \(L("мин","min"))"),
            sub(L("Порог жёлтого","Yellow threshold"), "warnAt",
                [(L("1.00 — по потолку","1.00 — at ceiling"), 1.0), ("0.95", 0.95),
                 ("0.90", 0.90)], Cfg.warnAt,
                manual: L("Доля от нормы, например 0.95","Share of norm, e.g. 0.95"),
                display: String(format: "%.2f", Cfg.warnAt)),
            sub(L("Порог красного","Red threshold"), "dangerAt",
                [("0.90", 0.90), ("0.85", 0.85), ("0.80", 0.80)], Cfg.dangerAt,
                manual: L("Доля от нормы, например 0.82","Share of norm, e.g. 0.82"),
                display: String(format: "%.2f", Cfg.dangerAt)),
        ]))

        var corners: [NSMenuItem] = []
        let cur = Cfg.d.string(forKey: "corner") ?? "topLeft"
        for (title, key) in [(L("Слева вверху","Top left"), "topLeft"),
                             (L("Справа вверху","Top right"), "topRight"),
                             (L("Слева внизу","Bottom left"), "bottomLeft"),
                             (L("Справа внизу","Bottom right"), "bottomRight")] {
            let it = NSMenuItem(title: title, action: #selector(setCorner(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = key
            it.state = key == cur ? .on : .off
            corners.append(it)
        }
        corners.append(.separator())
        corners.append(item(L("Вернуть на место","Reset position"), #selector(resetPosition)))
        m.addItem(group(L("Положение","Position"), corners))
        m.addItem(.separator())

        m.addItem(item(L("Помощь","Help"), #selector(showHelp)))
        m.addItem(item(L("Выйти","Quit"), #selector(quitForever)))
        return m
    }


    // --- Settings ---
    var settingsWin: NSWindow?

    @objc func openSettings() {
        if let w = settingsWin { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 150),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Настройки плашки"
        w.isReleasedWhenClosed = false

        let d = UserDefaults.standard
        let mode = NSPopUpButton(frame: NSRect(x: 150, y: 100, width: 170, height: 25))
        mode.addItems(withTitles: ["в док", "до переключения"])
        mode.selectItem(at: d.string(forKey: "minimizeMode") == "switch" ? 1 : 0)
        mode.target = self; mode.action = #selector(setMinimizeMode(_:))

        let lbl = NSTextField(labelWithString: "Свернуть:")
        lbl.frame = NSRect(x: 20, y: 104, width: 120, height: 18)

        let note = NSTextField(wrappingLabelWithString:
            "Остальные настройки — пороги светофора, интервал, прозрачность, шрифт, вид строк — добавляются следующим шагом.")
        note.frame = NSRect(x: 20, y: 20, width: 300, height: 60)
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        w.contentView?.addSubview(lbl)
        w.contentView?.addSubview(mode)
        w.contentView?.addSubview(note)
        w.center()
        settingsWin = w
        NSApp.setActivationPolicy(.regular)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func setMinimizeMode(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem == 1 ? "switch" : "dock",
                                  forKey: "minimizeMode")
    }

    func windowWillClose(_ n: Notification) {
        if (n.object as? NSWindow) === settingsWin, !docked {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // Paragraph style that forbids wrapping. On a multi-line NSTextField the
    // field properties (lineBreakMode / wraps) do nothing - wrapping lives here.
    static let noWrap: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byClipping
        return p
    }()

    func line(_ text: String, _ c: NSColor, size: CGFloat = 15) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .foregroundColor: c,
            .paragraphStyle: App.noWrap,
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium)])
    }

    func refresh() {
        let all = loadSamples()
        let out = NSMutableAttributedString()
        let grayFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

        guard let newest = all.map({ $0.ts }).max() else {
            label.attributedStringValue = NSAttributedString(
                string: L("нет данных\nпроверь launchd-агент", "no data\ncheck launchd agent"),
                attributes: [.foregroundColor: NSColor.systemGray, .font: grayFont])
            return
        }
        let cur = all.filter { abs($0.ts.timeIntervalSince(newest)) < 1 }
        var rows: [Row] = []

        // 1. Five-hour session: ceiling by hours, colour by remaining
        if allow("session"), let s = cur.first(where: { $0.kind == "session" }) {
            out.append(line(sessionText(s) + "\n", sessionColor(s.percent)))
            let hl = min(max((s.resets?.timeIntervalSinceNow ?? 18000) / 3600.0, 0), 5)
            rows.append(Row(id: "session", tag: L("5ч","5h"), percent: s.percent, ceiling: max(100 - 20 * hl, 0),
                            color: sessionColor(s.percent), time: fmtLeft(s.resets)))
        }

        // 2-3. Weekly limits: daily budget, the colour speaks for itself
        var weeklies: [(String, Sample)] = []
        if allow("all"), let a = cur.first(where: { $0.kind == "weekly_all" }) { weeklies.append((L("Все","All"), a)) }
        if allow("scoped"),
           let m = cur.filter({ $0.kind == "weekly_scoped" }).max(by: { $0.percent < $1.percent }) {
            weeklies.append((m.model.isEmpty ? L("модель","model") : String(m.model.prefix(6)), m))
        }
        for (i, item) in weeklies.enumerated() {
            guard let b = budget(item.1) else { continue }
            let tail = i == weeklies.count - 1 ? "" : "\n"
            out.append(line(weeklyText(item.0, item.1, b) + tail, weeklyColor(b)))
            rows.append(Row(id: item.0 == L("Все","All") ? "all" : "scoped", tag: item.0, percent: item.1.percent, ceiling: b.ceiling,
                            color: weeklyColor(b), time: fmtLeft(item.1.resets)))
        }
        panel.rows = rows
        setupStatusItem()
        updateStatusItem(rows)

        // There is no fourth row: the row colours are the signal.
        // One exception: if collection stalls, we must not stay silent.
        let age = Date().timeIntervalSince(newest)
        if age > 900 {
            out.append(line("\n⚠︎ \(L("данные устарели","data is stale")): \(fmtAgo(age))", .systemOrange, size: 13))
        }
        label.attributedStringValue = out
        fitToContent()
    }

    // Window width is fitted to the longest row.
    // IMPORTANT: NSAttributedString.size() measures the text as a single line and
    // ignores newlines - the width comes out too small and the text wraps.
    // Measure with boundingRect and .usesLineFragmentOrigin instead.
    func fitToContent() {
        let padL: CGFloat = 8, padY: CGFloat = 4
        let padR: CGFloat = 4
        let strip = panel?.strip ?? 0
        var w: CGFloat, h: CGFloat, textW: CGFloat = 0, textH: CGFloat = 0

        if Cfg.mode == "bars" {
            label.isHidden = true
            w = 250
            h = (Cfg.fontSize + 9) * CGFloat(max(panel.rows.count, 1)) + 12 + strip
        } else {
            label.isHidden = false
            label.font = NSFont.monospacedSystemFont(ofSize: Cfg.fontSize, weight: .medium)
            let huge = NSSize(width: CGFloat(10000), height: CGFloat(10000))
            let r = label.attributedStringValue.boundingRect(with: huge,
                                                             options: [.usesLineFragmentOrigin])
            textW = ceil(r.width) + 12      // slack: the field cell adds its own insets
            textH = ceil(r.height) + 4
            w = textW + padL + padR
            h = textH + padY * 2 + strip
            label.frame = NSRect(x: padL, y: padY + strip, width: textW, height: textH)
        }
        panel?.needsDisplay = true

        var f = window.frame
        guard abs(f.size.width - w) > 0.5 || abs(f.size.height - h) > 0.5 else { return }
        f.origin.y += f.size.height - h        // keep the top edge in place
        f.size = NSSize(width: w, height: h)

        // Keep the window on screen: after dragging it to the edge, a width increase
        // could push it out of the visible area.
        if let scr = window.screen ?? NSScreen.main {
            let vf = scr.visibleFrame
            f.origin.x = min(max(f.origin.x, vf.minX), max(vf.maxX - w, vf.minX))
            f.origin.y = min(max(f.origin.y, vf.minY), max(vf.maxY - h, vf.minY))
        }

        window.setFrame(f, display: true)
        window.contentView?.frame = NSRect(x: 0, y: 0, width: w, height: h)
        window.contentView?.needsDisplay = true
    }
}
