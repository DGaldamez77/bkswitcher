import AppKit
import CoreImage
import Foundation

enum CollageRendererError: LocalizedError {
    case invalidCanvasSize(CGSize)
    case imageLoadFailed(URL)
    case emptyRenderResult
    case cgImageCreationFailed
    case jpegEncodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidCanvasSize(let size):
            return "Invalid canvas size \(size)."
        case .imageLoadFailed(let url):
            return "Failed to load image at \(url.path)."
        case .emptyRenderResult:
            return "No valid images could be rendered into the collage."
        case .cgImageCreationFailed:
            return "Failed to create CGImage from collage."
        case .jpegEncodingFailed:
            return "Failed to encode collage as JPEG."
        }
    }
}

struct CollageRenderItem {
    let imageURL: URL
    let photoTakenDate: Date?
    let photoLocationText: String?
}

final class CollageRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let minimumTileDimension: CGFloat = 110
    private let landscapeThreshold: CGFloat = 1.12
    private let portraitThreshold: CGFloat = 0.88
    private let monthYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/yyyy"
        return formatter
    }()

    private enum TileOrientation {
        case landscape
        case portrait
        case square
    }

    private struct LoadedImage {
        let image: CIImage
        let aspectRatio: CGFloat
        let orientation: TileOrientation
        let dateText: String?
        let locationText: String?
    }

    private struct RectInfo {
        let index: Int
        let rect: CGRect
        let aspectRatio: CGFloat
        let orientation: TileOrientation
    }

    func renderCollage(items: [CollageRenderItem], canvasSize: CGSize, gap: CGFloat) throws -> CIImage {
        let normalizedCanvas = CGSize(width: floor(canvasSize.width), height: floor(canvasSize.height))
        guard normalizedCanvas.width > 0, normalizedCanvas.height > 0 else {
            throw CollageRendererError.invalidCanvasSize(canvasSize)
        }

        let canvasRect = CGRect(origin: .zero, size: normalizedCanvas)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
        var canvas = black.cropped(to: canvasRect)
        let safeGap = max(0, gap)
        let layoutRects = mosaicLayout(count: items.count, in: canvasRect, gap: safeGap)
        let loadedImages = try items.map { item in
            guard let image = loadImage(at: item.imageURL) else {
                throw CollageRendererError.imageLoadFailed(item.imageURL)
            }
            let aspectRatio = aspectRatio(of: image.extent.size)
            return LoadedImage(
                image: image,
                aspectRatio: aspectRatio,
                orientation: orientation(forAspectRatio: aspectRatio),
                dateText: formattedMonthYear(from: item.photoTakenDate),
                locationText: normalizedLocationText(item.photoLocationText)
            )
        }
        let assignedPairs = assignImages(loadedImages, to: layoutRects)

        var renderedTiles = 0
        for pair in assignedPairs {
            let targetRect = pair.rect
            guard targetRect.width > 1, targetRect.height > 1 else {
                continue
            }
            var tile = fitAndCrop(image: pair.image.image, to: targetRect.size)
            tile = applyMetadataOverlay(
                to: tile,
                targetSize: targetRect.size,
                dateText: pair.image.dateText,
                locationText: pair.image.locationText
            )
            tile = tile.transformed(by: CGAffineTransform(translationX: targetRect.origin.x, y: targetRect.origin.y))

            canvas = tile.composited(over: canvas)
            renderedTiles += 1
        }

        guard renderedTiles > 0 else {
            throw CollageRendererError.emptyRenderResult
        }
        return canvas
    }

    func writeJPEG(image: CIImage, to outputURL: URL, compression: CGFloat = 0.92) throws {
        let outputDirectory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        guard let cgImage = context.createCGImage(image, from: image.extent.integral) else {
            throw CollageRendererError.cgImageCreationFailed
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: compression]) else {
            throw CollageRendererError.jpegEncodingFailed
        }

        try data.write(to: outputURL, options: .atomic)
    }

    func clearCaches() {
        context.clearCaches()
    }

    private enum BadgeAnchor {
        case topLeft
        case bottomRight
    }

    private func formattedMonthYear(from date: Date?) -> String? {
        guard let date else {
            return nil
        }
        return monthYearFormatter.string(from: date)
    }

    private func normalizedLocationText(_ text: String?) -> String? {
        guard let text else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func applyMetadataOverlay(
        to tile: CIImage,
        targetSize: CGSize,
        dateText: String?,
        locationText: String?
    ) -> CIImage {
        guard dateText != nil || locationText != nil else {
            return tile
        }
        guard let overlay = metadataOverlayImage(
            size: targetSize,
            dateText: dateText,
            locationText: locationText
        ) else {
            return tile
        }
        return overlay.composited(over: tile)
    }

    private func metadataOverlayImage(
        size: CGSize,
        dateText: String?,
        locationText: String?
    ) -> CIImage? {
        let normalizedSize = CGSize(width: floor(size.width), height: floor(size.height))
        guard normalizedSize.width > 2, normalizedSize.height > 2 else {
            return nil
        }

        let minDimension = min(normalizedSize.width, normalizedSize.height)
        let fontSize = max(8, min(16, minDimension * 0.060))
        let margin = max(4, fontSize * 0.5)
        let pixelWidth = max(1, Int(normalizedSize.width))
        let pixelHeight = max(1, Int(normalizedSize.height))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        defer { NSGraphicsContext.restoreGraphicsState() }

        graphicsContext.cgContext.clear(CGRect(origin: .zero, size: normalizedSize))

        if let dateText {
            drawTextBadge(
                dateText,
                anchor: .topLeft,
                in: normalizedSize,
                fontSize: fontSize,
                margin: margin
            )
        }

        if let locationText {
            drawTextBadge(
                locationText,
                anchor: .bottomRight,
                in: normalizedSize,
                fontSize: fontSize,
                margin: margin
            )
        }
        guard let cgImage = bitmap.cgImage else {
            return nil
        }

        return CIImage(cgImage: cgImage)
    }

    private func drawTextBadge(
        _ text: String,
        anchor: BadgeAnchor,
        in canvasSize: CGSize,
        fontSize: CGFloat,
        margin: CGFloat
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = anchor == .topLeft ? .left : .right
        paragraph.lineBreakMode = .byTruncatingTail

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.72)
        shadow.shadowBlurRadius = max(1.5, fontSize * 0.18)
        shadow.shadowOffset = NSSize(width: 0, height: -1)

        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
            .shadow: shadow
        ]

        let maxTextWidth = max(40, canvasSize.width * 0.65)
        let drawingOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let measured = attributed.boundingRect(
            with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: drawingOptions
        )
        let textSize = CGSize(width: ceil(min(maxTextWidth, measured.width)), height: ceil(measured.height))
        let horizontalPadding = max(3, fontSize * 0.24)
        let verticalPadding = max(2, fontSize * 0.14)
        let badgeWidth = textSize.width + horizontalPadding * 2
        let badgeHeight = textSize.height + verticalPadding * 2

        let originX: CGFloat = anchor == .topLeft
            ? margin
            : max(margin, canvasSize.width - margin - badgeWidth)
        let originY: CGFloat = anchor == .topLeft
            ? max(margin, canvasSize.height - margin - badgeHeight)
            : margin
        let badgeRect = NSRect(x: originX, y: originY, width: badgeWidth, height: badgeHeight)

        let radius = max(4, fontSize * 0.22)
        NSColor.black.withAlphaComponent(0.24).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: radius, yRadius: radius).fill()

        let textRect = badgeRect.insetBy(dx: horizontalPadding, dy: verticalPadding)
        attributed.draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]
        )
    }

    private func assignImages(_ images: [LoadedImage], to rects: [CGRect]) -> [(image: LoadedImage, rect: CGRect)] {
        guard !images.isEmpty, !rects.isEmpty else {
            return []
        }

        let rectInfos = rects.enumerated().map { index, rect in
            let ratio = aspectRatio(of: rect.size)
            return RectInfo(index: index, rect: rect, aspectRatio: ratio, orientation: orientation(forAspectRatio: ratio))
        }

        let prioritizedRects = rectInfos.sorted { lhs, rhs in
            let lhsPriority = lhs.orientation == .square ? 1 : 0
            let rhsPriority = rhs.orientation == .square ? 1 : 0
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }

            let lhsExtremeness = abs(log(Double(lhs.aspectRatio)))
            let rhsExtremeness = abs(log(Double(rhs.aspectRatio)))
            if abs(lhsExtremeness - rhsExtremeness) > 0.0001 {
                return lhsExtremeness > rhsExtremeness
            }

            return lhs.index < rhs.index
        }

        var remaining = images
        var assignments = Array<(image: LoadedImage, rect: CGRect)?>(repeating: nil, count: rects.count)

        for rectInfo in prioritizedRects {
            guard let candidateIndex = bestCandidateIndex(for: rectInfo, among: remaining) else {
                continue
            }
            let chosenImage = remaining.remove(at: candidateIndex)
            assignments[rectInfo.index] = (image: chosenImage, rect: rectInfo.rect)
        }

        return assignments.compactMap { $0 }
    }

    private func bestCandidateIndex(for rectInfo: RectInfo, among images: [LoadedImage]) -> Int? {
        guard !images.isEmpty else {
            return nil
        }

        let preferred = preferredOrientations(for: rectInfo.orientation)
        for preferredOrientation in preferred {
            let candidates = images.indices.filter { images[$0].orientation == preferredOrientation }
            if let best = candidates.min(
                by: { lhs, rhs in
                    aspectDistance(images[lhs].aspectRatio, rectInfo.aspectRatio)
                        < aspectDistance(images[rhs].aspectRatio, rectInfo.aspectRatio)
                }
            ) {
                return best
            }
        }

        return images.indices.min(
            by: { lhs, rhs in
                aspectDistance(images[lhs].aspectRatio, rectInfo.aspectRatio)
                    < aspectDistance(images[rhs].aspectRatio, rectInfo.aspectRatio)
            }
        )
    }

    private func preferredOrientations(for orientation: TileOrientation) -> [TileOrientation] {
        switch orientation {
        case .landscape:
            return [.landscape, .square, .portrait]
        case .portrait:
            return [.portrait, .square, .landscape]
        case .square:
            return [.square, .landscape, .portrait]
        }
    }

    private func aspectRatio(of size: CGSize) -> CGFloat {
        let width = max(abs(size.width), 1)
        let height = max(abs(size.height), 1)
        return width / height
    }

    private func orientation(forAspectRatio ratio: CGFloat) -> TileOrientation {
        if ratio > landscapeThreshold {
            return .landscape
        }
        if ratio < portraitThreshold {
            return .portrait
        }
        return .square
    }

    private func aspectDistance(_ lhs: CGFloat, _ rhs: CGFloat) -> Double {
        abs(log(Double(lhs)) - log(Double(rhs)))
    }

    private func mosaicLayout(count: Int, in canvasRect: CGRect, gap: CGFloat) -> [CGRect] {
        guard count > 0 else {
            return []
        }

        var partitions: [CGRect] = [canvasRect]
        while partitions.count < count {
            guard let splitIndex = largestSplittableRectIndex(in: partitions, gap: gap) else {
                break
            }

            let rect = partitions.remove(at: splitIndex)
            guard let splitRects = split(rect: rect, gap: gap) else {
                partitions.append(rect)
                break
            }

            partitions.append(splitRects.0)
            partitions.append(splitRects.1)
        }

        if partitions.count < count {
            return fallbackGridLayout(count: count, in: canvasRect, gap: gap)
        }

        let sorted = partitions.sorted { lhs, rhs in
            if abs(lhs.minY - rhs.minY) > 1 {
                return lhs.minY > rhs.minY
            }
            return lhs.minX < rhs.minX
        }

        return Array(sorted.prefix(count)).map { inset($0, gap: gap) }
    }

    private func largestSplittableRectIndex(in rects: [CGRect], gap: CGFloat) -> Int? {
        rects.indices
            .filter { index in
                let rect = rects[index]
                let minDimension = minimumTileDimension + gap
                return rect.width >= minDimension * 2 || rect.height >= minDimension * 2
            }
            .max { lhs, rhs in
                let lhsArea = rects[lhs].width * rects[lhs].height
                let rhsArea = rects[rhs].width * rects[rhs].height
                return lhsArea < rhsArea
            }
    }

    private func split(rect: CGRect, gap: CGFloat) -> (CGRect, CGRect)? {
        let minDimension = minimumTileDimension + gap
        let splitAlongWidth = rect.width >= rect.height
        let ratio = CGFloat.random(in: 0.34...0.66)

        if splitAlongWidth {
            let proposed = rect.minX + rect.width * ratio
            let minX = rect.minX + minDimension
            let maxX = rect.maxX - minDimension
            guard minX < maxX else {
                return nil
            }
            let splitX = min(max(proposed, minX), maxX)
            let left = CGRect(x: rect.minX, y: rect.minY, width: splitX - rect.minX, height: rect.height)
            let right = CGRect(x: splitX, y: rect.minY, width: rect.maxX - splitX, height: rect.height)
            return (left, right)
        }

        let proposed = rect.minY + rect.height * ratio
        let minY = rect.minY + minDimension
        let maxY = rect.maxY - minDimension
        guard minY < maxY else {
            return nil
        }
        let splitY = min(max(proposed, minY), maxY)
        let bottom = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: splitY - rect.minY)
        let top = CGRect(x: rect.minX, y: splitY, width: rect.width, height: rect.maxY - splitY)
        return (bottom, top)
    }

    private func inset(_ rect: CGRect, gap: CGFloat) -> CGRect {
        let insetAmount = gap / 2
        let insetRect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        if insetRect.width < 2 || insetRect.height < 2 {
            return rect
        }
        return insetRect.integral
    }

    private func fallbackGridLayout(count: Int, in canvasRect: CGRect, gap: CGFloat) -> [CGRect] {
        let aspectRatio = canvasRect.width / max(canvasRect.height, 1)
        let columns = max(1, Int(round(sqrt(CGFloat(count) * aspectRatio))))
        let rows = Int(ceil(Double(count) / Double(columns)))
        let cellWidth = canvasRect.width / CGFloat(columns)
        let cellHeight = canvasRect.height / CGFloat(rows)

        var rects: [CGRect] = []
        rects.reserveCapacity(count)

        for index in 0..<count {
            let row = index / columns
            let column = index % columns
            let rect = CGRect(
                x: CGFloat(column) * cellWidth,
                y: CGFloat(rows - row - 1) * cellHeight,
                width: cellWidth,
                height: cellHeight
            )
            rects.append(inset(rect, gap: gap))
        }

        return rects
    }

    private func loadImage(at url: URL) -> CIImage? {
        CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }

    private func fitAndCrop(image: CIImage, to targetSize: CGSize) -> CIImage {
        let originNormalized = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y)
        )

        let widthScale = targetSize.width / originNormalized.extent.width
        let heightScale = targetSize.height / originNormalized.extent.height
        let scale = max(widthScale, heightScale)

        let scaled = originNormalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let xOffset = (targetSize.width - scaled.extent.width) / 2
        let yOffset = (targetSize.height - scaled.extent.height) / 2
        let centered = scaled.transformed(by: CGAffineTransform(translationX: xOffset, y: yOffset))

        return centered.cropped(to: CGRect(origin: .zero, size: targetSize))
    }
}
