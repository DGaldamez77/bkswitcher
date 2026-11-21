import AppKit
import ImageIO
import SwiftUI

/// One photo from the current wallpaper's run, as shown in the `--current-images` window.
struct CurrentImageItem: Identifiable {
    let id: Int
    let photo: RunManifestPhoto
    /// The copy exported from Photos for this run (`used-photos/<stamp>/...`).
    let exportedURL: URL

    /// File name with extension, e.g. `IMG_1732.heic`. The manifest records the name without an
    /// extension, so it is taken from the exported copy (which keeps the original's extension).
    var fileName: String {
        let name = photo.originalFilename
        let ext = exportedURL.pathExtension
        guard !ext.isEmpty, URL(fileURLWithPath: name).pathExtension.lowercased() != ext.lowercased() else {
            return name
        }
        return "\(name).\(ext)"
    }

    var fileExists: Bool {
        FileManager.default.fileExists(atPath: exportedURL.path)
    }
}

/// Window contents: a header describing the run, then a grid of every photo used in the collage.
struct CurrentImagesView: View {
    let manifest: RunManifest
    let items: [CurrentImageItem]
    let collageURL: URL
    let onClose: () -> Void

    private static let runDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(items.count) photo\(items.count == 1 ? "" : "s") in the current background")
                        .font(.headline)
                    Text("Generated \(Self.runDateFormatter.string(from: manifest.generatedAt))  ·  Click a photo to copy its file name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Collage") {
                    NSWorkspace.shared.open(collageURL)
                }
                .disabled(!FileManager.default.fileExists(atPath: collageURL.path))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)], spacing: 16) {
                    ForEach(items) { item in
                        CurrentImageCard(item: item)
                    }
                }
                .padding(16)
            }

            Divider()
            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 560, idealWidth: 1000, minHeight: 420, idealHeight: 760)
    }
}

private struct CurrentImageCard: View {
    let item: CurrentImageItem
    @State private var thumbnail: NSImage?
    @State private var isHovering = false
    @State private var showCopied = false

    private static let takenDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yyyy"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.85))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } else if item.fileExists {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Image file no longer available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .frame(height: 190)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: isHovering ? 2 : 0)
            )
            .overlay(alignment: .bottom) {
                if showCopied {
                    Text("File name copied")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }
            }

            Text(item.fileName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(item.photo.photoTakenDate.map { Self.takenDateFormatter.string(from: $0) } ?? "Date unknown")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(item.photo.photoLocationText ?? "Location unknown")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: copyFileName)
        .help("Click to copy \u{201C}\(item.fileName)\u{201D}")
        .contextMenu {
            Button("Copy File Name", action: copyFileName)
            Button("Open in Photos", action: openInPhotos)
            Button("Open Exported Copy") { NSWorkspace.shared.open(item.exportedURL) }
                .disabled(!item.fileExists)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.exportedURL]) }
                .disabled(!item.fileExists)
        }
        .task(id: item.exportedURL) {
            if let cgImage = await Self.loadThumbnail(url: item.exportedURL, maxPixelSize: 640) {
                thumbnail = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }
    }

    /// Copies the photo's file name with extension (as shown on the card) to the clipboard.
    private func copyFileName() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.fileName, forType: .string)

        withAnimation(.easeOut(duration: 0.15)) { showCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeIn(duration: 0.3)) { showCopied = false }
        }
    }

    private func openInPhotos() {
        if let url = item.photo.libraryUrl {
            NSWorkspace.shared.open(url)
        }
    }

    /// Decodes a downsampled, orientation-corrected thumbnail off the main thread. ImageIO avoids
    /// decoding full-resolution HEIC/JPEG files just to show a small preview.
    private static func loadThumbnail(url: URL, maxPixelSize: Int) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }
}

/// Hosts the photo grid for the current background. `onClose` runs when the window closes.
final class CurrentImagesWindowController: NSObject, NSWindowDelegate {
    private let manifest: RunManifest
    private let items: [CurrentImageItem]
    private let collageURL: URL
    private let onClose: () -> Void
    private var window: NSWindow?

    init(manifest: RunManifest, outputDirectory: URL, onClose: @escaping () -> Void) {
        self.manifest = manifest
        self.onClose = onClose
        let photosDirectory = outputDirectory.appendingPathComponent("used-photos/\(manifest.stamp)", isDirectory: true)
        self.items = manifest.photos.enumerated().map { index, photo in
            CurrentImageItem(
                id: index,
                photo: photo,
                exportedURL: photosDirectory.appendingPathComponent(photo.exportedFilename)
            )
        }
        self.collageURL = outputDirectory.appendingPathComponent("wallpaper-\(manifest.stamp).jpg")
    }

    func show() {
        let view = CurrentImagesView(
            manifest: manifest,
            items: items,
            collageURL: collageURL,
            onClose: { [weak self] in self?.window?.close() }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BKSwitcher – Current Images"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    /// Brings an already-open window back to the front.
    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

/// Opens the window listing the photos from the most recent run (the current background).
func runCurrentImagesWindow(manifest: RunManifest, outputDirectory: URL) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.mainMenu = makeStandardMainMenu(appName: "BKSwitcher Current Images")

    let controller = CurrentImagesWindowController(manifest: manifest, outputDirectory: outputDirectory) {
        NSApp.terminate(nil)
    }
    controller.show()
    app.activate(ignoringOtherApps: true)
    app.run()
    withExtendedLifetime(controller) {}
    exit(0)
}
