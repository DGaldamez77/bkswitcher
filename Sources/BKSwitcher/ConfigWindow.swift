import AppKit
import SwiftUI

/// Editable, string-backed copy of `AppConfig`. Numeric fields are kept as text while editing and
/// parsed only on Save, so a half-typed value never gets silently dropped and bad input can be
/// reported back to the user.
final class ConfigFormModel: ObservableObject {
    @Published var imageCount: String
    @Published var refreshIntervalMinutes: String
    @Published var outputDirectory: String
    @Published var excludedAlbums: String
    @Published var allowedExtensions: String
    @Published var useOptimalCollageLayout: Bool
    @Published var pictureMarginPixels: String
    @Published var pictureSpacingPixels: String
    @Published var tileGap: String
    @Published var allowDockRestart: Bool

    init(config: AppConfig) {
        imageCount = String(config.imageCount)
        refreshIntervalMinutes = String(config.refreshIntervalMinutes)
        outputDirectory = config.outputDirectory
        excludedAlbums = config.excludedAlbums.joined(separator: "\n")
        allowedExtensions = config.allowedExtensions.joined(separator: ", ")
        useOptimalCollageLayout = config.useOptimalCollageLayout
        pictureMarginPixels = Self.format(config.pictureMarginPixels)
        pictureSpacingPixels = Self.format(config.pictureSpacingPixels)
        tileGap = Self.format(config.tileGap)
        allowDockRestart = config.allowDockRestart
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// Builds and validates an `AppConfig` from the form, or throws a message describing the
    /// first invalid field.
    func makeConfig() throws -> AppConfig {
        func int(_ text: String, _ name: String) throws -> Int {
            guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else {
                throw AppConfigError.invalidConfig("\(name) must be a whole number.")
            }
            return value
        }
        func double(_ text: String, _ name: String) throws -> Double {
            guard let value = Double(text.trimmingCharacters(in: .whitespaces)) else {
                throw AppConfigError.invalidConfig("\(name) must be a number.")
            }
            return value
        }

        let directory = outputDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else {
            throw AppConfigError.invalidConfig("Output directory cannot be empty.")
        }

        let config = AppConfig(
            excludedAlbums: excludedAlbums
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            imageCount: try int(imageCount, "Image count"),
            tileGap: try double(tileGap, "Tile gap"),
            outputDirectory: directory,
            refreshIntervalMinutes: try int(refreshIntervalMinutes, "Refresh interval"),
            allowedExtensions: allowedExtensions
                .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }
                .filter { !$0.isEmpty },
            allowDockRestart: allowDockRestart,
            pictureMarginPixels: try double(pictureMarginPixels, "Picture margin"),
            pictureSpacingPixels: try double(pictureSpacingPixels, "Picture spacing"),
            useOptimalCollageLayout: useOptimalCollageLayout
        )
        try config.validate()
        return config
    }
}

struct ConfigFormView: View {
    @ObservedObject var model: ConfigFormModel
    let configPath: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Collage") {
                    LabeledField("Image count", text: $model.imageCount,
                                 help: "How many photos go into each collage.")
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Use scattered collage layout", isOn: $model.useOptimalCollageLayout)
                        Text("On: uncropped photos with white borders, scattered and tilted. Off: legacy cropped mosaic.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledField("Picture margin (px)", text: $model.pictureMarginPixels,
                                 help: "White border around each photo; the date and location are printed in it.")
                        .disabled(!model.useOptimalCollageLayout)
                    LabeledField("Picture spacing (px)", text: $model.pictureSpacingPixels,
                                 help: "Minimum gap between neighboring framed photos.")
                        .disabled(!model.useOptimalCollageLayout)
                    LabeledField("Tile gap (px)", text: $model.tileGap,
                                 help: "Gap between tiles in the legacy mosaic layout.")
                        .disabled(model.useOptimalCollageLayout)
                }

                Section("Photos") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Excluded albums (one per line)")
                        TextEditor(text: $model.excludedAlbums)
                            .font(.body)
                            .frame(minHeight: 60, maxHeight: 90)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                        Text("Photos in these albums never appear. Matching ignores case.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledField("Allowed extensions", text: $model.allowedExtensions,
                                 help: "Comma-separated, e.g. jpg, png, heic.")
                }

                Section("Schedule & output") {
                    LabeledField("Refresh interval (minutes)", text: $model.refreshIntervalMinutes,
                                 help: "How often --loop makes a new collage.")
                    HStack(alignment: .firstTextBaseline) {
                        LabeledField("Output directory", text: $model.outputDirectory,
                                     help: "Where collages and run logs are saved.")
                        Button("Choose…", action: chooseDirectory)
                    }
                }

                Section("Advanced") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Allow Dock restart fallback", isOn: $model.allowDockRestart)
                        Text("Only needed for the legacy wallpaper fallback. Restarting the Dock un-minimizes windows.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text(configPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 520, idealWidth: 580, minHeight: 600, idealHeight: 900)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let expanded = (model.outputDirectory as NSString).expandingTildeInPath
        panel.directoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        model.outputDirectory = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

private struct LabeledField: View {
    let title: String
    @Binding var text: String
    let help: String

    init(_ title: String, text: Binding<String>, help: String) {
        self.title = title
        self._text = text
        self.help = help
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: $text)
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Hosts the settings form in a standalone window for `bkswitcher --config`. Save validates and
/// writes the config file; Cancel (or closing the window) discards changes. Either way the window
/// closes and the process exits.
final class ConfigWindowController: NSObject, NSWindowDelegate {
    private let model: ConfigFormModel
    private var window: NSWindow?
    private var didSave = false
    private var didFinish = false

    init(config: AppConfig) {
        model = ConfigFormModel(config: config)
    }

    func show() {
        let view = ConfigFormView(
            model: model,
            configPath: AppConfig.configURL.path,
            onSave: { [weak self] in self?.save() },
            onCancel: { [weak self] in self?.window?.close() }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 900),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BKSwitcher Settings"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private func save() {
        // End any in-progress text edit so the latest keystrokes are in the model.
        window?.makeFirstResponder(nil)
        do {
            let config = try model.makeConfig()
            try config.save()
            didSave = true
            window?.close()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Settings not saved"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            if let window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard !didFinish else {
            return
        }
        didFinish = true
        print(didSave ? "Settings saved to \(AppConfig.configURL.path)" : "Settings unchanged.")
        NSApp.terminate(nil)
    }
}

/// Runs the settings window as a regular foreground app until it closes.
func runConfigWindow(config: AppConfig) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.mainMenu = makeConfigMainMenu()

    let controller = ConfigWindowController(config: config)
    controller.show()
    app.activate(ignoringOtherApps: true)
    app.run()
    withExtendedLifetime(controller) {}
    exit(0)
}

/// A minimal menu bar so standard shortcuts (copy/paste, select all, undo, close, quit) work in the
/// text fields; a programmatically launched app has no menu otherwise.
private func makeConfigMainMenu() -> NSMenu {
    let mainMenu = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit BKSwitcher Settings", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    mainMenu.addItem(appItem)

    let fileItem = NSMenuItem()
    let fileMenu = NSMenu(title: "File")
    fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    fileItem.submenu = fileMenu
    mainMenu.addItem(fileItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu
    mainMenu.addItem(editItem)

    return mainMenu
}
