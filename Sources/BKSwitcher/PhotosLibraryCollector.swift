import Foundation
import Photos

struct PhotosLibrarySelection {
    let assetLocalIdentifier: String
    let originalFilename: String
    let exportedURL: URL
    let photoTakenDate: Date?
}

enum PhotosLibraryCollectorError: LocalizedError {
    case accessDenied
    case noEligibleImagesFound
    case assetExportFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            let termProgram = ProcessInfo.processInfo.environment["TERM_PROGRAM"]?.lowercased() ?? ""
            if termProgram == "vscode" {
                return "Photos library access denied. Grant access to Visual Studio Code in System Settings > Privacy & Security > Photos."
            }
            if termProgram == "warp" {
                return "Photos library access denied. Grant access to Warp in System Settings > Privacy & Security > Photos."
            }
            return "Photos library access denied. Grant access to the app that launched bkswitcher (for example Visual Studio Code or Terminal) in System Settings > Privacy & Security > Photos."
        case .noEligibleImagesFound:
            return "No eligible images found in Photos library after applying excludedAlbums and allowedExtensions."
        case .assetExportFailed(let assetID, let details):
            return "Failed to export photo asset \(assetID): \(details)"
        }
    }
}

struct PhotosLibraryCollector {
    static func randomPhotos(
        count: Int,
        excludedAlbumNames: [String],
        allowedExtensions: Set<String>,
        stagingDirectory: URL
    ) throws -> [PhotosLibrarySelection] {
        guard count > 0 else {
            return []
        }

        try ensureAuthorization()
        let excludedAssetIDs = excludedAssetIdentifiers(albumNames: excludedAlbumNames)
        let eligibleAssets = fetchEligibleAssets(excluding: excludedAssetIDs, allowedExtensions: allowedExtensions)

        guard !eligibleAssets.isEmpty else {
            throw PhotosLibraryCollectorError.noEligibleImagesFound
        }

        let selectedAssets = pickRandomAssets(from: eligibleAssets, count: count)
        return try exportAssets(selectedAssets, to: stagingDirectory)
    }

    private static func ensureAuthorization() throws {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch current {
        case .authorized, .limited:
            return
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            var resolvedStatus = current
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                resolvedStatus = status
                semaphore.signal()
            }
            semaphore.wait()
            guard resolvedStatus == .authorized || resolvedStatus == .limited else {
                throw PhotosLibraryCollectorError.accessDenied
            }
        default:
            throw PhotosLibraryCollectorError.accessDenied
        }
    }

    private static func excludedAssetIdentifiers(albumNames: [String]) -> Set<String> {
        let normalizedAlbumNames = Set(albumNames.map { $0.lowercased() })
        guard !normalizedAlbumNames.isEmpty else {
            return []
        }

        let imageOnlyFetchOptions = PHFetchOptions()
        imageOnlyFetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        var excluded: Set<String> = []

        for collection in matchingCollections(for: normalizedAlbumNames) {
            let assets = PHAsset.fetchAssets(in: collection, options: imageOnlyFetchOptions)
            assets.enumerateObjects { asset, _, _ in
                excluded.insert(asset.localIdentifier)
            }
        }

        return excluded
    }

    private static func matchingCollections(for normalizedAlbumNames: Set<String>) -> [PHAssetCollection] {
        var matches: [PHAssetCollection] = []

        func appendMatches(from fetchResult: PHFetchResult<PHAssetCollection>) {
            fetchResult.enumerateObjects { collection, _, _ in
                guard let title = collection.localizedTitle?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                    return
                }
                if normalizedAlbumNames.contains(title) {
                    matches.append(collection)
                }
            }
        }

        appendMatches(from: PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil))
        appendMatches(from: PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil))
        return matches
    }

    private static func fetchEligibleAssets(excluding excludedAssetIDs: Set<String>, allowedExtensions: Set<String>) -> [PHAsset] {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let assets = PHAsset.fetchAssets(with: .image, options: fetchOptions)

        var eligible: [PHAsset] = []
        eligible.reserveCapacity(assets.count)

        assets.enumerateObjects { asset, _, _ in
            if excludedAssetIDs.contains(asset.localIdentifier) {
                return
            }
            if !allowedExtensions.isEmpty && !hasAllowedExtension(asset: asset, allowedExtensions: allowedExtensions) {
                return
            }
            eligible.append(asset)
        }

        return eligible
    }

    private static func pickRandomAssets(from assets: [PHAsset], count: Int) -> [PHAsset] {
        guard !assets.isEmpty else {
            return []
        }

        if assets.count >= count {
            return Array(assets.shuffled().prefix(count))
        }

        var selected = assets.shuffled()
        while selected.count < count {
            if let extra = assets.randomElement() {
                selected.append(extra)
            }
        }
        return selected
    }

    private static func hasAllowedExtension(asset: PHAsset, allowedExtensions: Set<String>) -> Bool {
        guard let ext = preferredFileExtension(for: asset) else {
            return true
        }
        return allowedExtensions.contains(ext)
    }

    private static func preferredFileExtension(for asset: PHAsset) -> String? {
        for resource in PHAssetResource.assetResources(for: asset) {
            let ext = URL(fileURLWithPath: resource.originalFilename).pathExtension.lowercased()
            if !ext.isEmpty {
                return ext
            }
        }
        return nil
    }

    private static func exportAssets(_ assets: [PHAsset], to stagingDirectory: URL) throws -> [PhotosLibrarySelection] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        let imageManager = PHImageManager.default()
        let requestOptions = PHImageRequestOptions()
        requestOptions.deliveryMode = .highQualityFormat
        requestOptions.isSynchronous = true
        requestOptions.isNetworkAccessAllowed = true
        requestOptions.version = .current

        var selections: [PhotosLibrarySelection] = []
        selections.reserveCapacity(assets.count)

        for (index, asset) in assets.enumerated() {
            let selection: PhotosLibrarySelection = try autoreleasepool {
                var imageData: Data?
                var exportError: Error?
                var wasCancelled = false

                imageManager.requestImageDataAndOrientation(for: asset, options: requestOptions) { data, _, _, info in
                    if let info {
                        if let cancelled = info[PHImageCancelledKey] as? Bool, cancelled {
                            wasCancelled = true
                            return
                        }
                        if let err = info[PHImageErrorKey] as? Error {
                            exportError = err
                            return
                        }
                    }
                    imageData = data
                }

                if let exportError {
                    throw PhotosLibraryCollectorError.assetExportFailed(asset.localIdentifier, exportError.localizedDescription)
                }
                guard !wasCancelled, let imageData else {
                    throw PhotosLibraryCollectorError.assetExportFailed(asset.localIdentifier, "Image request returned no data.")
                }

                let originalFilename = preferredFilename(for: asset)
                let ext = preferredFileExtension(for: asset) ?? "jpg"
                let destination = stagingDirectory.appendingPathComponent("asset-\(index)-\(UUID().uuidString)-\(originalFilename).\(ext)")
                try imageData.write(to: destination, options: .atomic)
                return PhotosLibrarySelection(
                    assetLocalIdentifier: asset.localIdentifier,
                    originalFilename: originalFilename,
                    exportedURL: destination,
                    photoTakenDate: asset.creationDate
                )
            }

            selections.append(selection)
        }

        return selections
    }

    private static func preferredFilename(for asset: PHAsset) -> String {
        for resource in PHAssetResource.assetResources(for: asset) {
            let trimmed = resource.originalFilename.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let base = URL(fileURLWithPath: trimmed).deletingPathExtension().lastPathComponent
                return sanitizedFilename(base)
            }
        }
        return "photo"
    }

    private static func sanitizedFilename(_ filename: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = filename.unicodeScalars.map { scalar -> Character in
            invalid.contains(scalar) ? "-" : Character(scalar)
        }
        let result = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "photo" : result
    }
}
