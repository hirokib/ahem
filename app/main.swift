// ahem.app: the menu bar, native. Runs the plugin script every 3s and renders
// its SwiftBar-format output -- the script stays the single source of truth,
// so SwiftBar and `watch -n2` keep working against the same code. Posts a
// banner when a row turns needs-you; clicking banner or row focuses the window.
//
// An app bundle, not a script, because UNUserNotificationCenter refuses to run
// outside one: this bundle is what makes clickable native banners possible.
import AppKit
import UserNotifications

// Self-contained: build.sh bundles the scripts into Resources, repo layout
// preserved, so the plugin's relative sibling lookups keep working.
let contents = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent()
let plugin = contents.appendingPathComponent("Resources/plugin/ahem.3s.sh").path

struct Row {
    let text: String       // display text, dot included
    let focus: [String]?   // argv that focuses the session, nil if unfocusable
    // Banner dedup key. Not the text: it embeds the age ("(5s)"), which changes
    // every refresh and would re-alert a windowless red row every 3 seconds.
    var key: String { focus?.joined(separator: " ") ?? stripAge(text) }
}

func stripAge(_ s: String) -> String {
    return s.replacingOccurrences(of: #" \(\d+[smh]\)"#, with: "",
                                  options: .regularExpression)
}

func exec(_ argv: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: argv[0])
    p.arguments = Array(argv.dropFirst())
    try? p.run()
}

func runPlugin() -> (title: String, rows: [Row]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = [plugin]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice  // an attached-but-undrained pipe deadlocks
    do { try p.run() } catch { return ("⚠️", []) }
    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    // SwiftBar format: title block, ---, rows, ---, footer (Refresh; ours is a timer)
    let blocks = text.components(separatedBy: "\n---\n")
    guard blocks.count >= 2 else { return ("⚠️", []) }
    var rows: [Row] = []
    for line in blocks[1].split(separator: "\n") {
        let parts = line.components(separatedBy: " | ")
        let params = parts.dropFirst().joined(separator: " | ")
        // bash= runs to " param1=": the value is an unquoted path that may
        // itself contain spaces (the repo can live anywhere).
        var focus: [String]? = nil
        if let b = params.range(of: "bash="), let a = params.range(of: " param1=") {
            let bash = String(params[b.upperBound..<a.lowerBound])
            let pid = params[a.upperBound...].prefix(while: { !$0.isWhitespace })
            if !bash.isEmpty && !pid.isEmpty { focus = [bash, String(pid)] }
        }
        rows.append(Row(text: parts[0], focus: focus))
    }
    return (blocks[0].trimmingCharacters(in: .whitespacesAndNewlines), rows)
}

class App: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var alerted = Set<String>()  // needs-you rows already announced
    var bannersOff = false       // notification permission denied: surface it, don't guess why
    var refreshing = false       // skip a tick rather than queue overlapping runs

    func applicationDidFinishLaunching(_ n: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { self.bannersOff = !granted }
        }
        item.button?.title = "⚪️"
        refresh()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in self.refresh() }
    }

    // Serialized: an overlapping slow run would finish after a newer one and
    // render its stale snapshot -- including re-bannering a resolved session.
    func refresh() {
        if refreshing { return }
        refreshing = true
        DispatchQueue.global().async {
            let (title, rows) = runPlugin()
            DispatchQueue.main.async {
                self.refreshing = false
                self.render(title, rows)
            }
        }
    }

    func render(_ title: String, _ rows: [Row]) {
        item.button?.title = title
        let menu = NSMenu()
        menu.autoenablesItems = false
        for r in rows {
            let mi = NSMenuItem(title: r.text,
                                action: r.focus == nil ? nil : #selector(focusRow(_:)),
                                keyEquivalent: "")
            mi.target = self
            mi.representedObject = r.focus
            mi.isEnabled = r.focus != nil
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        if bannersOff {
            // Actionable, not just a warning: once permission is denied the OS
            // won't re-prompt, so the only fix is the Settings pane -- open it.
            let fix = NSMenuItem(title: "🔕 Turn on banners…",
                                 action: #selector(openNotificationSettings), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
        }
        menu.addItem(NSMenuItem(title: "Quit ahem",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        notifyNew(rows)
    }

    @objc func focusRow(_ sender: NSMenuItem) {
        if let argv = sender.representedObject as? [String] { exec(argv) }
    }

    @objc func openNotificationSettings() {
        // Deep-links straight to Settings › Notifications; the user still picks
        // ahem from the list (macOS exposes no per-app anchor).
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func notifyNew(_ rows: [Row]) {
        let red = rows.filter { $0.text.hasPrefix("🔴") }
        for r in red {
            if alerted.contains(r.key) { continue }
            alerted.insert(r.key)
            let c = UNMutableNotificationContent()
            c.title = "ahem"
            c.body = r.text.replacingOccurrences(of: "🔴 ", with: "")
            c.sound = .default
            if let argv = r.focus { c.userInfo = ["execute": argv] }
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
        // Resolved rows leave the set, so a session that blocks again alerts again.
        alerted.formIntersection(Set(red.map { $0.key }))
    }

    // Banner clicked: focus the window it was about.
    func userNotificationCenter(_ c: UNUserNotificationCenter,
                                didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let argv = r.notification.request.content.userInfo["execute"] as? [String] { exec(argv) }
        done()
    }

    // Banners still show while our own menu is frontmost.
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu bar only: no dock icon, no focus steal
let delegate = App()
app.delegate = delegate
app.run()
