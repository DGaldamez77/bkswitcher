import AppKit
import Foundation
import ServiceManagement

/// The menu bar ("status item") app. It runs when BKSwitcher.app is opened from Finder or with
/// `bkswitcher --menubar`, and offers the command-line actions as menu items:
///
/// | Menu item                  | Command line          |
/// |----------------------------|-----------------------|
/// | New Background             | `bkswitcher`          |
/// | Recreate Last Background   | `bkswitcher -r`       |
/// | Current Images…            | `--current-images`    |
/// | Configuration…             | `--config`            |
/// | Auto Refresh               | `--loop`              |
///
/// Plus **Launch at Login**, which registers the app as a login item (app bundle only).
final class MenuBarController: NSObject, NSMenuDelegate {
    private static let autoRefreshDefaultsKey = "autoRefreshEnabled"
    private static let idleSymbol = "photo.stack"
    private static let busySymbol = "arrow.triangle.2.circlepath"

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let workQueue = DispatchQueue(label: "bkswitcher.cycle", qos: .userInitiated)
    private let renderer = CollageRenderer()

    private var isGenerating = false
    private var lastUpdated: Date?
    private var lastError: String?
    private var refreshTimer: Timer?
    private var configController: ConfigWindowController?
    private var imagesController: CurrentImagesWindowController?

    private var autoRefreshEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoRefreshDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoRefreshDefaultsKey) }
    }

    private static let statusDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    func start() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()

        if let config = try? AppConfig.loadForEditing() {
            lastUpdated = (try? RunManifest.loadLatest(in: config.resolvedOutputDirectoryURL()))?.generatedAt
        }
        scheduleAutoRefresh()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        menu.addItem(item("New Background", #selector(newBackground), key: "n", enabled: !isGenerating))
        menu.addItem(item("Recreate Last Background", #selector(recreateLastBackground), key: "r", enabled: !isGenerating && lastUpdated != nil))
        menu.addItem(.separator())

        menu.addItem(item("Current Images…", #selector(showCurrentImages), key: "i"))
        menu.addItem(item("Configuration…", #selector(showConfiguration), key: ","))
        menu.addItem(item("Open Output Folder", #selector(openOutputFolder)))
        menu.addItem(.separator())

        let minutes = (try? AppConfig.loadForEditing().refreshIntervalMinutes) ?? AppConfig.defaultValue.refreshIntervalMinutes
        let autoRefresh = item("Auto Refresh Every \(minutes) Minute\(minutes == 1 ? "" : "s")", #selector(toggleAutoRefresh))
        autoRefresh.state = autoRefreshEnabled ? .on : .off
        menu.addItem(autoRefresh)

        // Login items need an app bundle; `--menubar` from a terminal can't register one.
        let loginStatus = SMAppService.mainApp.status
        let launchAtLogin = item("Launch at Login", #selector(toggleLaunchAtLogin), enabled: launchedFromAppBundle)
        launchAtLogin.state = loginStatus == .enabled ? .on : (loginStatus == .requiresApproval ? .mixed : .off)
        if !launchedFromAppBundle {
            launchAtLogin.toolTip = "Available when running BKSwitcher.app"
        } else if loginStatus == .requiresApproval {
            launchAtLogin.toolTip = "Waiting for approval in System Settings > General > Login Items"
        }
        menu.addItem(launchAtLogin)
        menu.addItem(.separator())

        menu.addItem(item("Quit BKSwitcher", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", enabled: Bool = true) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        menuItem.isEnabled = enabled
        return menuItem
    }

    private func statusText() -> String {
        if isGenerating {
            return "Generating new background…"
        }
        if let lastError {
            return "Last update failed: \(lastError)"
        }
        if let lastUpdated {
            return "Updated \(Self.statusDateFormatter.string(from: lastUpdated))"
        }
        return "No background generated yet"
    }

    private func updateIcon() {
        guard let button = statusItem.button else {
            return
        }
        let symbol = isGenerating ? Self.busySymbol : Self.idleSymbol
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "BKSwitcher")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "BKSwitcher – \(statusText())"
    }

    // MARK: Actions

    @objc private func newBackground() {
        generate(recreateLastRun: false, userInitiated: true)
    }

    @objc private func recreateLastBackground() {
        generate(recreateLastRun: true, userInitiated: true)
    }

    @objc private func showCurrentImages() {
        if let imagesController {
            imagesController.bringToFront()
            return
        }
        do {
            let outputDirectory = try AppConfig.loadForEditing().resolvedOutputDirectoryURL()
            let manifest = try RunManifest.loadLatest(in: outputDirectory)
            let controller = CurrentImagesWindowController(manifest: manifest, outputDirectory: outputDirectory) { [weak self] in
                self?.imagesController = nil
            }
            imagesController = controller
            NSApp.activate(ignoringOtherApps: true)
            controller.show()
        } catch {
            showAlert(title: "No current images", message: error.localizedDescription)
        }
    }

    @objc private func showConfiguration() {
        if let configController {
            configController.bringToFront()
            return
        }
        let config = (try? AppConfig.loadForEditing()) ?? AppConfig.defaultValue
        let controller = ConfigWindowController(config: config) { [weak self] saved in
            self?.configController = nil
            if saved {
                // The refresh interval may have changed.
                self?.scheduleAutoRefresh()
            }
        }
        configController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.show()
    }

    @objc private func openOutputFolder() {
        let config = (try? AppConfig.loadForEditing()) ?? AppConfig.defaultValue
        let directory = config.resolvedOutputDirectoryURL()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    @objc private func toggleAutoRefresh() {
        autoRefreshEnabled.toggle()
        scheduleAutoRefresh()
    }

    private var launchedFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled, .requiresApproval:
                try service.unregister()
            default:
                try service.register()
            }
        } catch {
            showAlert(title: "Could not change Launch at Login", message: error.localizedDescription)
            return
        }
        if service.status == .requiresApproval {
            // macOS wants the user to allow it; take them straight to the Login Items settings.
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Generating

    private func scheduleAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard autoRefreshEnabled else {
            return
        }
        let minutes = max(1, (try? AppConfig.loadForEditing().refreshIntervalMinutes) ?? AppConfig.defaultValue.refreshIntervalMinutes)
        let timer = Timer(timeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in
            self?.generate(recreateLastRun: false, userInitiated: false)
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// Runs one wallpaper cycle on a background queue. Failures from the timer only update the
    /// status line; failures from a menu click also show an alert.
    private func generate(recreateLastRun: Bool, userInitiated: Bool) {
        guard !isGenerating else {
            return
        }

        let config: AppConfig
        do {
            config = try Self.loadConfigCreatingTemplate()
        } catch {
            lastError = error.localizedDescription
            updateIcon()
            if userInitiated {
                showAlert(title: "Configuration problem", message: error.localizedDescription)
            }
            return
        }

        isGenerating = true
        updateIcon()
        // AppKit screen geometry is read on the main thread, then handed to the worker.
        let canvasSize = currentCanvasSize()
        let renderer = renderer

        workQueue.async { [weak self] in
            var failure: Error?
            do {
                try runManagedCycle(config: config, renderer: renderer, recreateLastRun: recreateLastRun, canvasSize: canvasSize)
            } catch {
                failure = error
            }
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.isGenerating = false
                if let failure {
                    self.lastError = failure.localizedDescription
                    if userInitiated {
                        self.showAlert(title: "Could not update the background", message: failure.localizedDescription)
                    }
                } else {
                    self.lastError = nil
                    self.lastUpdated = Date()
                }
                self.updateIcon()
            }
        }
    }

    /// Like `AppConfig.load()`, but a missing config file is created from the defaults and used,
    /// instead of stopping like the command line does.
    private static func loadConfigCreatingTemplate() throws -> AppConfig {
        do {
            return try AppConfig.load()
        } catch AppConfigError.templateCreated {
            return try AppConfig.load()
        }
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// Runs BKSwitcher as a menu bar app until the user quits.
func runMenuBarApp() -> Never {
    let app = NSApplication.shared
    // No Dock icon. (The app bundle also sets LSUIElement; this covers `--menubar` from a terminal.)
    app.setActivationPolicy(.accessory)
    // Not shown for a menu bar app, but its shortcuts (copy/paste, close window) still work in the
    // settings and images windows.
    app.mainMenu = makeStandardMainMenu(appName: "BKSwitcher")

    let controller = MenuBarController()
    controller.start()
    app.run()
    withExtendedLifetime(controller) {}
    exit(0)
}
