import AppKit
import Foundation

enum BKSwitcherCLIError: LocalizedError {
    case missingConfig

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "Config not found. Run `bkswitcher --init-config` first."
        }
    }
}

let retainedRunCount = 6
func logInfo(_ message: String) {
    print("[BKSwitcher] \(message)")
}
func printUsage() {
    print(
        """
        BKSwitcher

        Usage:
          bkswitcher                 Run once and update wallpaper
          bkswitcher -r              Recreate the last run's collage from the same photos and layout
          bkswitcher --loop          Run continuously using refreshIntervalMinutes from config
          bkswitcher --init-config   Create config template at ~/Library/Application Support/BKSwitcher/config.json
          bkswitcher --help          Show this help
        """
    )
}

func currentCanvasSize() -> CGSize {
    NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
}
func runStamp() -> String {
    let formatter = ISO8601DateFormatter()
    var stamp = formatter.string(from: Date())
    stamp = stamp.replacingOccurrences(of: ":", with: "-")
    return stamp
}

func outputURL(in directory: URL, stamp: String) -> URL {
    directory.appendingPathComponent("wallpaper-\(stamp).jpg")
}

func selectedPhotosDirectory(in directory: URL, stamp: String) -> URL {
    directory.appendingPathComponent("used-photos/\(stamp)", isDirectory: true)
}

func selectedPhotosLogURL(in directory: URL, stamp: String) -> URL {
    directory.appendingPathComponent("wallpaper-\(stamp)-photos.txt")
}

func wallpaperSlotsDirectory(in directory: URL) -> URL {
    directory.appendingPathComponent("wallpaper-slots", isDirectory: true)
}

func contentModificationDate(for url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
}

func wallpaperSlotDestination(in directory: URL, keep count: Int) throws -> URL {
    precondition(count > 0)

    let fileManager = FileManager.default
    let slotsDirectory = wallpaperSlotsDirectory(in: directory)
    try fileManager.createDirectory(at: slotsDirectory, withIntermediateDirectories: true)

    for index in 1...count {
        let candidate = slotsDirectory.appendingPathComponent("slot-\(index).jpg")
        if !fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }
    }

    let candidates = (1...count).map { index in
        slotsDirectory.appendingPathComponent("slot-\(index).jpg")
    }

    return candidates.min(by: { contentModificationDate(for: $0) < contentModificationDate(for: $1) }) ?? candidates[0]
}

func prepareWallpaperSource(from collageURL: URL, in directory: URL, keep count: Int) throws -> URL {
    let fileManager = FileManager.default
    let wallpaperSource = try wallpaperSlotDestination(in: directory, keep: count)
    let sourceData = try Data(contentsOf: collageURL)
    if fileManager.fileExists(atPath: wallpaperSource.path) {
        try sourceData.write(to: wallpaperSource, options: [])
    } else {
        try sourceData.write(to: wallpaperSource, options: .atomic)
    }
    return wallpaperSource
}

func wallpaperSlotCount(in directory: URL) -> Int {
    let slotsDirectory = wallpaperSlotsDirectory(in: directory)
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: slotsDirectory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) else {
        return 0
    }
    return entries.filter { $0.pathExtension.lowercased() == "jpg" }.count
}

func writeSelectedPhotoLog(
    selections: [PhotosLibrarySelection],
    wallpaperURL: URL,
    logURL: URL
) throws {
    let takenDateFormatter = ISO8601DateFormatter()
    takenDateFormatter.formatOptions = [.withInternetDateTime]
    var lines: [String] = []
    lines.append("Wallpaper: \(wallpaperURL.path)")
    lines.append("Generated At: \(ISO8601DateFormatter().string(from: Date()))")
    lines.append("Photo Count: \(selections.count)")
    lines.append("")

    for (index, selection) in selections.enumerated() {
        lines.append("\(index + 1). \(selection.exportedURL.path)")
        lines.append("   assetLocalIdentifier: \(selection.assetLocalIdentifier)")
        lines.append("   originalFilename: \(selection.originalFilename)")
        if let photoTakenDate = selection.photoTakenDate {
            lines.append("   photoTakenDate: \(takenDateFormatter.string(from: photoTakenDate))")
        } else {
            lines.append("   photoTakenDate: unavailable")
        }
        if let photoLocationText = selection.photoLocationText {
            lines.append("   photoLocation: \(photoLocationText)")
        } else {
            lines.append("   photoLocation: unavailable")
        }
    }

    try lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
}

/// Rebuilds the previous run's photo selection by re-exporting the recorded photos from the
/// Photos library. This ensures that if photos have been edited since the original run, the
/// recreate uses the current versions. Deleted photos are skipped with a warning.
func recreateSelections(
    manifest: RunManifest,
    stagingDirectory: URL
) throws -> [PhotosLibrarySelection] {
    let assetIdentifiers = manifest.photos.map { $0.assetLocalIdentifier }
    logInfo("Re-exporting \(assetIdentifiers.count) photo(s) from the Photos library.")
    let reExported = try PhotosLibraryCollector.exportAssets(
        withLocalIdentifiers: assetIdentifiers,
        stagingDirectory: stagingDirectory
    )

    guard !reExported.isEmpty else {
        throw RunManifestError.emptyManifest(manifest.stamp)
    }

    if reExported.count < manifest.photos.count {
        let missingCount = manifest.photos.count - reExported.count
        logInfo("\(missingCount) photo(s) from the original run are no longer in the Photos library (deleted).")
    }

    return reExported
}

@discardableResult
func pruneOldCollages(in directory: URL, keep count: Int) -> Int {
    guard count > 0 else {
        return 0
    }

    let fileManager = FileManager.default
    guard let files = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else {
        return 0
    }

    let jpgs = files.filter { $0.pathExtension.lowercased() == "jpg" }
    let sorted = jpgs.sorted { lhs, rhs in
        let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return leftDate > rightDate
    }

    var removedRunCount = 0
    for stale in sorted.dropFirst(count) {
        let basename = stale.deletingPathExtension().lastPathComponent
        let logURL = directory.appendingPathComponent("\(basename)-photos.txt")
        if basename.hasPrefix("wallpaper-") {
            let stamp = String(basename.dropFirst("wallpaper-".count))
            let usedPhotosDir = directory.appendingPathComponent("used-photos/\(stamp)", isDirectory: true)
            try? fileManager.removeItem(at: usedPhotosDir)
            try? fileManager.removeItem(at: RunManifest.url(in: directory, stamp: stamp))
        }
        try? fileManager.removeItem(at: logURL)
        try? fileManager.removeItem(at: stale)
        removedRunCount += 1
    }

    return removedRunCount
}

func runCycle(config: AppConfig, renderer: CollageRenderer, recreateLastRun: Bool = false) throws {
    let outputDirectory = config.resolvedOutputDirectoryURL()
    let stamp = runStamp()
    let stagingDirectory = selectedPhotosDirectory(in: outputDirectory, stamp: stamp)

    logInfo("Cycle started at \(stamp).")
    logInfo("Using output directory: \(outputDirectory.path)")

    let selected: [PhotosLibrarySelection]
    let layoutSeed: UInt64
    let tileGap: Double

    if recreateLastRun {
        let manifest = try RunManifest.loadLatest(in: outputDirectory)
        logInfo("Recreating run \(manifest.stamp): \(manifest.photos.count) photo(s), layout seed \(manifest.layoutSeed), tile gap \(manifest.tileGap).")
        selected = try recreateSelections(
            manifest: manifest,
            stagingDirectory: stagingDirectory
        )
        layoutSeed = manifest.layoutSeed
        tileGap = manifest.tileGap
    } else {
        let neededCount = config.imageCount
        let excludedAlbumCount = config.normalizedExcludedAlbumNames().count
        logInfo("Selecting \(neededCount) photo(s) from Photos library (excluded albums: \(excludedAlbumCount)).")
        selected = try PhotosLibraryCollector.randomPhotos(
            count: neededCount,
            excludedAlbumNames: config.normalizedExcludedAlbumNames(),
            allowedExtensions: config.allowedExtensionSet(),
            stagingDirectory: stagingDirectory
        )
        layoutSeed = UInt64.random(in: UInt64.min...UInt64.max)
        tileGap = config.tileGap
    }

    logInfo("Prepared \(selected.count) photo(s) in \(stagingDirectory.path)")
    let selectedWithReadableLocation = selected.filter { $0.photoLocationText != nil }.count
    logInfo("Resolved readable location for \(selectedWithReadableLocation)/\(selected.count) selected photo(s).")
    let canvasSize = currentCanvasSize()
    logInfo("Rendering collage at \(Int(canvasSize.width))x\(Int(canvasSize.height)) with tile gap \(tileGap) and layout seed \(layoutSeed).")
    let renderItems = selected.map { selection in
        CollageRenderItem(
            imageURL: selection.exportedURL,
            photoTakenDate: selection.photoTakenDate,
            photoLocationText: selection.photoLocationText
        )
    }

    let collage = try renderer.renderCollage(
        items: renderItems,
        canvasSize: canvasSize,
        gap: CGFloat(tileGap),
        seed: layoutSeed
    )

    let destination = outputURL(in: outputDirectory, stamp: stamp)
    try renderer.writeJPEG(image: collage, to: destination)
    logInfo("Saved collage image: \(destination.path)")
    let logURL = selectedPhotosLogURL(in: outputDirectory, stamp: stamp)
    try writeSelectedPhotoLog(selections: selected, wallpaperURL: destination, logURL: logURL)
    logInfo("Saved selected photo log: \(logURL.path)")

    let manifest = RunManifest(
        stamp: stamp,
        generatedAt: Date(),
        canvasWidth: Double(canvasSize.width),
        canvasHeight: Double(canvasSize.height),
        tileGap: tileGap,
        layoutSeed: layoutSeed,
        photos: selected.map { selection in
            RunManifestPhoto(
                assetLocalIdentifier: selection.assetLocalIdentifier,
                originalFilename: selection.originalFilename,
                exportedFilename: selection.exportedURL.lastPathComponent,
                photoTakenDate: selection.photoTakenDate,
                photoLocationText: selection.photoLocationText
            )
        }
    )
    let manifestURL = try manifest.write(in: outputDirectory)
    logInfo("Saved run manifest: \(manifestURL.path)")
    let wallpaperSource = try prepareWallpaperSource(from: destination, in: outputDirectory, keep: retainedRunCount)
    logInfo("Prepared wallpaper source slot: \(wallpaperSource.path)")
    logInfo("Wallpaper slot inventory: \(wallpaperSlotCount(in: outputDirectory))/\(retainedRunCount)")
    try WallpaperSetter.setDesktopWallpaper(
        imageURL: wallpaperSource,
        allowDockRestart: config.allowDockRestart
    ) { detail in
        logInfo("Wallpaper: \(detail)")
    }
    let removedRunCount = pruneOldCollages(in: outputDirectory, keep: retainedRunCount)
    logInfo("Retention cleanup complete. Removed \(removedRunCount) stale run(s); keeping latest \(retainedRunCount).")

    print("Updated wallpaper: \(wallpaperSource.path)")
    print("Saved collage: \(destination.path)")
    print("Selected photo list: \(logURL.path)")
}

func runManagedCycle(config: AppConfig, renderer: CollageRenderer, recreateLastRun: Bool = false) throws {
    try autoreleasepool {
        defer { renderer.clearCaches() }
        try runCycle(config: config, renderer: renderer, recreateLastRun: recreateLastRun)
    }
}

let arguments = Set(CommandLine.arguments.dropFirst())

if arguments.contains("--help") || arguments.contains("-h") {
    printUsage()
    exit(0)
}

if arguments.contains("--init-config") {
    do {
        let url = try AppConfig.initializeTemplate(overwrite: false)
        print("Config ready: \(url.path)")
        print("Adjust excludedAlbums/imageCount/tileGap as needed, then run bkswitcher.")
        exit(0)
    } catch {
        fputs("Failed to initialize config: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

let shouldRecreateLastRun = arguments.contains("-r") || arguments.contains("--recreate")

if shouldRecreateLastRun && arguments.contains("--loop") {
    fputs("--recreate/-r rebuilds a single past run and cannot be combined with --loop.\n", stderr)
    exit(1)
}

do {
    let config = try AppConfig.load()
    let renderer = CollageRenderer()

    if arguments.contains("--loop") {
        while true {
            autoreleasepool {
                do {
                    try runManagedCycle(config: config, renderer: renderer)
                } catch {
                    fputs("Cycle failed: \(error.localizedDescription)\n", stderr)
                }
            }

            let interval = TimeInterval(config.refreshIntervalMinutes * 60)
            Thread.sleep(forTimeInterval: interval)
        }
    } else {
        try runManagedCycle(config: config, renderer: renderer, recreateLastRun: shouldRecreateLastRun)
    }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
