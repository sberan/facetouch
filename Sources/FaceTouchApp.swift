import SwiftUI
import ServiceManagement

@main
struct FaceTouchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    var detector: FaceTouchDetector!
    var historyWindow: NSWindow?
    var testWindow: NSWindow?
    let history = CheckHistory.shared
    let overlay = OverlayWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "hand.raised.slash", accessibilityDescription: "FaceTouch")
        }

        rebuildMenu()

        detector = FaceTouchDetector(
            onResult: { [weak self] result in
                DispatchQueue.main.async {
                    self?.updateIcon(touching: result.isAlert)
                    self?.rebuildMenu()
                    if result.isAlert {
                        self?.overlay.show()
                    } else {
                        self?.overlay.dismiss()
                    }
                }
            },
            onCheckStarted: { [weak self] in
                DispatchQueue.main.async {
                    self?.flashGreen()
                }
            }
        )
        detector.start()

        // Enable launch at login
        enableLaunchAtLogin()
    }

    func rebuildMenu() {
        let menu = NSMenu()

        let statusLabel = detector?.paused == true ? "FaceTouch — Paused" : "FaceTouch — Monitoring"
        menu.addItem(NSMenuItem(title: statusLabel, action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        // Pause/Resume
        if detector?.paused == true {
            let resumeItem = NSMenuItem(title: "Resume", action: #selector(togglePause), keyEquivalent: "p")
            menu.addItem(resumeItem)
        } else {
            let pauseMenu = NSMenu()
            let indefinite = NSMenuItem(title: "Until Resumed", action: #selector(togglePause), keyEquivalent: "p")
            pauseMenu.addItem(indefinite)
            pauseMenu.addItem(NSMenuItem.separator())
            let pause15 = NSMenuItem(title: "15 Minutes", action: #selector(pauseFor15Min), keyEquivalent: "")
            pauseMenu.addItem(pause15)
            let pause1h = NSMenuItem(title: "1 Hour", action: #selector(pauseFor1Hour), keyEquivalent: "")
            pauseMenu.addItem(pause1h)
            let pauseDay = NSMenuItem(title: "Rest of Day", action: #selector(pauseRestOfDay), keyEquivalent: "")
            pauseMenu.addItem(pauseDay)
            let pauseItem = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
            pauseItem.submenu = pauseMenu
            menu.addItem(pauseItem)
        }

        menu.addItem(NSMenuItem.separator())

        let recent = history.entries.prefix(10)
        if recent.isEmpty {
            menu.addItem(NSMenuItem(title: "No checks yet...", action: nil, keyEquivalent: ""))
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm:ss a"
            for entry in recent {
                let time = formatter.string(from: entry.timestamp)
                let item = NSMenuItem(title: "\(time)  \(entry.result.label)", action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: entry.result.symbol, accessibilityDescription: nil)
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let intervalMenu = NSMenu()
        for seconds in [2, 5, 10, 20, 30, 60] {
            let label = seconds < 60 ? "\(seconds)s" : "1m"
            let item = NSMenuItem(title: label, action: #selector(setInterval(_:)), keyEquivalent: "")
            item.tag = seconds
            item.state = Int(detector?.interval ?? 10) == seconds ? .on : .off
            intervalMenu.addItem(item)
        }
        let intervalItem = NSMenuItem(title: "Check Interval", action: nil, keyEquivalent: "")
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Test Mode (Live Preview)...", action: #selector(openTestMode), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Show Full History...", action: #selector(showHistory), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func flashGreen() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "hand.raised.slash", accessibilityDescription: "FaceTouch")
        let greenImage = image?.withSymbolConfiguration(.init(paletteColors: [.systemGreen]))
        button.image = greenImage

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard self?.detector.paused != true else { return }
            self?.updateIcon(touching: false)
        }
    }

    func updateIcon(touching: Bool) {
        if let button = statusItem.button {
            if detector?.paused == true {
                let image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "FaceTouch Paused")
                button.image = image?.withSymbolConfiguration(.init(paletteColors: [.systemGray]))
            } else if touching {
                let image = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: "FaceTouch")
                button.image = image?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            } else {
                button.image = NSImage(systemSymbolName: "hand.raised.slash", accessibilityDescription: "FaceTouch")
            }
        }
    }

    @objc func togglePause() {
        if detector.paused {
            detector.resume()
        } else {
            detector.pause()
            overlay.dismiss()
        }
        updateIcon(touching: false)
        rebuildMenu()
    }

    @objc func pauseFor15Min() {
        detector.pauseFor(15 * 60)
        overlay.dismiss()
        updateIcon(touching: false)
        rebuildMenu()
    }

    @objc func pauseFor1Hour() {
        detector.pauseFor(60 * 60)
        overlay.dismiss()
        updateIcon(touching: false)
        rebuildMenu()
    }

    @objc func pauseRestOfDay() {
        // Pause until midnight
        let now = Date()
        let calendar = Calendar.current
        if let midnight = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) {
            let seconds = midnight.timeIntervalSince(now)
            detector.pauseFor(seconds)
        } else {
            detector.pause()
        }
        overlay.dismiss()
        updateIcon(touching: false)
        rebuildMenu()
    }

    @objc func setInterval(_ sender: NSMenuItem) {
        detector.interval = TimeInterval(sender.tag)
        detector.restartTimer()
        rebuildMenu()
    }

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            print("Launch at login error: \(error)")
        }
        rebuildMenu()
    }

    func enableLaunchAtLogin() {
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }

    private var testModeView: TestModeView?

    @objc func openTestMode() {
        // Pause the face touch detector to free the camera and CPU
        detector.pause()

        if let window = testWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = TestModeView()
        testModeView = view
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FaceTouch — Test Mode"
        window.center()
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        testWindow = window
    }

    @objc func showHistory() {
        if let window = historyWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FaceTouch History"
        window.center()
        window.contentView = NSHostingView(rootView: HistoryView())
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        historyWindow = window
    }

    @objc func quit() {
        detector.stop()
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === testWindow else { return }
        testModeView?.cleanup()
        testModeView = nil
        testWindow = nil
        detector.resume()
    }
}

struct HistoryView: View {
    @ObservedObject var history = CheckHistory.shared

    var body: some View {
        List(history.entries) { entry in
            HStack(spacing: 10) {
                Image(systemName: entry.result.symbol)
                    .foregroundColor(iconColor(entry.result))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.result.label)
                        .font(.body)
                    Text(entry.timestamp, format: .dateTime.hour().minute().second())
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 2)
        }
        .overlay {
            if history.entries.isEmpty {
                Text("No checks yet")
                    .foregroundColor(.secondary)
            }
        }
    }

    func iconColor(_ result: CheckResult) -> Color {
        switch result {
        case .clear: return .green
        case .faceTouch: return .red
        case .mouthCovered: return .orange
        case .noFaceDetected: return .secondary
        case .error: return .orange
        }
    }
}
