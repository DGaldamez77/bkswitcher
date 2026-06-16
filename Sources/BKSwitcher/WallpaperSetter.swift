import AppKit
import Foundation

enum WallpaperSetterError: LocalizedError {
    case osascriptFailed(step: String, message: String)
    case processLaunchFailed(step: String, message: String)

    var errorDescription: String? {
        switch self {
        case .osascriptFailed(let step, let message):
            return "Failed to set wallpaper (\(step)): \(message)"
        case .processLaunchFailed(let step, let message):
            return "Failed to launch process (\(step)): \(message)"
        }
    }
}

struct WallpaperSetter {
    private struct ProcessResult {
        let terminationStatus: Int32
        let stdout: String
        let stderr: String
    }

    static func setDesktopWallpaper(
        imageURL: URL,
        logger: (String) -> Void = { _ in }
    ) throws {
        let escapedPath = imageURL.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        logger("Starting wallpaper apply for: \(imageURL.path)")
        applyViaNSWorkspace(imageURL: imageURL, logger: logger)

        let finderScript = """
        tell application "Finder"
            set desktop picture to POSIX file "\(escapedPath)"
        end tell
        """
        _ = try runAppleScript(step: "Finder desktop picture", script: finderScript)
        logger("Finder desktop picture updated.")

        let systemEventsScript = """
        tell application "System Events"
            set desktopCount to count of desktops
            repeat with i from 1 to desktopCount
                set picture of desktop i to POSIX file "\(escapedPath)"
            end repeat
            return desktopCount
        end tell
        """
        let desktopCountOutput = try runAppleScript(step: "System Events desktop update", script: systemEventsScript)
        let desktopCount = Int(desktopCountOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if desktopCount > 0 {
            logger("System Events updated \(desktopCount) desktop object(s).")
        } else {
            logger("System Events update completed (desktop count unavailable: '\(desktopCountOutput)').")
        }

        if desktopCount <= 1 {
            logger("System Events exposes <=1 desktop object; attempting wallpaper store + Dock DB fallbacks for other Spaces.")
            bestEffortWallpaperStoreSync(imageURL: imageURL, logger: logger)
            bestEffortDockDatabaseSync(imageURL: imageURL, logger: logger)
        }

        bestEffortHUP(processName: "WallpaperAgent", logger: logger)
    }

    private static func applyViaNSWorkspace(imageURL: URL, logger: (String) -> Void) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            logger("NSWorkspace skipped: no screens detected.")
            return
        }

        var successCount = 0
        for screen in screens {
            do {
                let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
                try NSWorkspace.shared.setDesktopImageURL(imageURL, for: screen, options: options)
                successCount += 1
            } catch {
                logger("NSWorkspace failed for one screen: \(error.localizedDescription)")
            }
        }
        logger("NSWorkspace updated \(successCount)/\(screens.count) screen(s).")
    }

    private static func runAppleScript(step: String, script: String) throws -> String {
        let result = try runProcess(
            executablePath: "/usr/bin/osascript",
            arguments: ["-e", script],
            step: step
        )
        guard result.terminationStatus == 0 else {
            throw WallpaperSetterError.osascriptFailed(step: step, message: processMessage(for: result))
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runProcess(
        executablePath: String,
        arguments: [String],
        step: String
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdOut = Pipe()
        let stdErr = Pipe()
        process.standardOutput = stdOut
        process.standardError = stdErr

        do {
            try process.run()
        } catch {
            throw WallpaperSetterError.processLaunchFailed(step: step, message: error.localizedDescription)
        }
        process.waitUntilExit()

        let outData = stdOut.fileHandleForReading.readDataToEndOfFile()
        let errData = stdErr.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(
            terminationStatus: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    private static func bestEffortDockDatabaseSync(imageURL: URL, logger: (String) -> Void) {
        let dbPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Dock/desktoppicture.db")
        guard FileManager.default.fileExists(atPath: dbPath) else {
            logger("Dock DB fallback skipped: desktoppicture.db not found.")
            return
        }

        let escapedPathForSQL = imageURL.path.replacingOccurrences(of: "'", with: "''")
        let sql = "UPDATE data SET value='\(escapedPathForSQL)';"

        do {
            let updateResult = try runProcess(
                executablePath: "/usr/bin/sqlite3",
                arguments: [dbPath, sql],
                step: "sqlite3 Dock DB update"
            )
            if updateResult.terminationStatus == 0 {
                logger("Dock DB updated for all legacy wallpaper rows.")
                bestEffortHUP(processName: "Dock", logger: logger)
            } else {
                logger("Dock DB update failed: \(processMessage(for: updateResult))")
            }
        } catch {
            logger("Dock DB fallback error: \(error.localizedDescription)")
        }
    }

    private static func bestEffortWallpaperStoreSync(imageURL: URL, logger: (String) -> Void) {
        let storeURL = URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist"))
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            logger("Wallpaper store fallback skipped: Index.plist not found.")
            return
        }

        let targetRelative = "file://\(imageURL.path)"
        do {
            let sourceData = try Data(contentsOf: storeURL)
            var format = PropertyListSerialization.PropertyListFormat.binary
            let root = try PropertyListSerialization.propertyList(from: sourceData, options: [], format: &format)
            let rewritten = rewriteImageConfigurations(in: root, targetRelativePath: targetRelative)
            guard rewritten.updatedCount > 0 else {
                logger("Wallpaper store fallback skipped: no image configuration entries needed updates.")
                return
            }

            let rewrittenData = try PropertyListSerialization.data(
                fromPropertyList: rewritten.node,
                format: format,
                options: 0
            )
            try rewrittenData.write(to: storeURL, options: .atomic)
            logger("Wallpaper store updated \(rewritten.updatedCount) image configuration entr\(rewritten.updatedCount == 1 ? "y" : "ies").")
            bestEffortHUP(processName: "WallpaperAgent", logger: logger)
        } catch {
            logger("Wallpaper store fallback failed: \(error.localizedDescription)")
        }
    }

    private static func rewriteImageConfigurations(
        in node: Any,
        targetRelativePath: String
    ) -> (node: Any, updatedCount: Int) {
        if var dictionary = node as? [String: Any] {
            var updates = 0

            if let provider = dictionary["Provider"] as? String,
               provider == "com.apple.wallpaper.choice.image",
               let configurationData = dictionary["Configuration"] as? Data,
               let rewritten = rewriteImageConfigurationData(
                configurationData,
                targetRelativePath: targetRelativePath
               ) {
                dictionary["Configuration"] = rewritten.data
                if rewritten.didChange {
                    updates += 1
                }
            }

            for (key, value) in dictionary {
                let rewrittenChild = rewriteImageConfigurations(in: value, targetRelativePath: targetRelativePath)
                dictionary[key] = rewrittenChild.node
                updates += rewrittenChild.updatedCount
            }

            return (dictionary, updates)
        }

        if var array = node as? [Any] {
            var updates = 0
            for index in array.indices {
                let rewrittenChild = rewriteImageConfigurations(in: array[index], targetRelativePath: targetRelativePath)
                array[index] = rewrittenChild.node
                updates += rewrittenChild.updatedCount
            }
            return (array, updates)
        }

        return (node, 0)
    }

    private static func rewriteImageConfigurationData(
        _ configurationData: Data,
        targetRelativePath: String
    ) -> (data: Data, didChange: Bool)? {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var configuration = try? PropertyListSerialization.propertyList(
            from: configurationData,
            options: [],
            format: &format
        ) as? [String: Any] else {
            return nil
        }

        guard (configuration["type"] as? String) == "imageFile" else {
            return nil
        }

        var didChange = false
        var urlPayload = (configuration["url"] as? [String: Any]) ?? [:]
        if (urlPayload["relative"] as? String) != targetRelativePath {
            urlPayload["relative"] = targetRelativePath
            configuration["url"] = urlPayload
            didChange = true
        }

        guard let encoded = try? PropertyListSerialization.data(
            fromPropertyList: configuration,
            format: format,
            options: 0
        ) else {
            return nil
        }

        return (encoded, didChange)
    }

    private static func bestEffortHUP(processName: String, logger: (String) -> Void) {
        do {
            let result = try runProcess(
                executablePath: "/usr/bin/killall",
                arguments: ["-HUP", processName],
                step: "killall -HUP \(processName)"
            )
            if result.terminationStatus == 0 {
                logger("Sent HUP to \(processName).")
            } else {
                logger("Could not signal \(processName): \(processMessage(for: result))")
            }
        } catch {
            logger("Signal step failed for \(processName): \(error.localizedDescription)")
        }
    }

    private static func processMessage(for result: ProcessResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty {
            return stderr
        }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty {
            return stdout
        }
        return "Unknown process failure."
    }
}
