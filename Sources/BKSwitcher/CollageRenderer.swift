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

/// SplitMix64. The mosaic layout is randomized, so rendering is driven by an explicit seeded
/// generator instead of the system RNG. Recording the seed lets a later run redraw an identical
/// collage from the same photo set.
struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class CollageRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let minimumTileDimension: CGFloat = 110
    private let landscapeThreshold: CGFloat = 1.12
    private let portraitThreshold: CGFloat = 0.88
    private let takenDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yyyy"
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

    /// Seeded per render so an identical `seed`, photo set, canvas, and gap reproduce the same collage.
    private var layoutGenerator = SeededRandomNumberGenerator(seed: 0)

    func renderCollage(
        items: [CollageRenderItem],
        canvasSize: CGSize,
        gap: CGFloat,
        seed: UInt64,
        useOptimalLayout: Bool = false,
        pictureMargin: CGFloat = 15,
        pictureSpacing: CGFloat = 10
    ) throws -> CIImage {
        let normalizedCanvas = CGSize(width: floor(canvasSize.width), height: floor(canvasSize.height))
        guard normalizedCanvas.width > 0, normalizedCanvas.height > 0 else {
            throw CollageRendererError.invalidCanvasSize(canvasSize)
        }

        layoutGenerator = SeededRandomNumberGenerator(seed: seed)
        let canvasRect = CGRect(origin: .zero, size: normalizedCanvas)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
        let baseCanvas = black.cropped(to: canvasRect)

        let loadedImages = try items.map { item -> LoadedImage in
            guard let image = loadImage(at: item.imageURL) else {
                throw CollageRendererError.imageLoadFailed(item.imageURL)
            }
            let aspectRatio = aspectRatio(of: image.extent.size)
            return LoadedImage(
                image: image,
                aspectRatio: aspectRatio,
                orientation: orientation(forAspectRatio: aspectRatio),
                dateText: formattedTakenDate(from: item.photoTakenDate),
                locationText: normalizedLocationText(item.photoLocationText)
            )
        }

        let canvas: CIImage
        if useOptimalLayout {
            canvas = try renderJustifiedCollage(
                images: loadedImages,
                canvasRect: canvasRect,
                baseCanvas: baseCanvas,
                margin: max(0, pictureMargin),
                spacing: max(0, pictureSpacing)
            )
        } else {
            canvas = try renderMosaicCollage(
                images: loadedImages,
                canvasRect: canvasRect,
                baseCanvas: baseCanvas,
                gap: max(0, gap)
            )
        }

        // Safety net in case any layout arithmetic produces a tile extent that slightly overshoots
        // the canvas bounds.
        return canvas.cropped(to: canvasRect)
    }

    /// Legacy layout: recursively partitions the canvas into randomly-sized rects and crops each
    /// photo to fill its rect exactly (cover-fit), leaving the black background visible in the gap
    /// between tiles.
    private func renderMosaicCollage(
        images loadedImages: [LoadedImage],
        canvasRect: CGRect,
        baseCanvas: CIImage,
        gap: CGFloat
    ) throws -> CIImage {
        var canvas = baseCanvas
        let layoutRects = mosaicLayout(count: loadedImages.count, in: canvasRect, gap: gap)
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

    /// New layout: recursively partitions the canvas into randomly-sized cells (so every region of
    /// the screen gets a photo), then scatters the photos collage-style: each photo keeps its
    /// original proportions (never cropped), gets a random size and position within its cell, and
    /// is then grown toward its neighbors. Each photo has a white margin hugging its edges, and
    /// framed photos are always at least `spacing` pixels apart so borders never touch.
    private func renderJustifiedCollage(
        images loadedImages: [LoadedImage],
        canvasRect: CGRect,
        baseCanvas: CIImage,
        margin: CGFloat,
        spacing: CGFloat
    ) throws -> CIImage {
        guard !loadedImages.isEmpty else {
            throw CollageRendererError.emptyRenderResult
        }

        let cellRects = mosaicLayout(
            count: loadedImages.count,
            in: canvasRect,
            gap: 0,
            randomizeSplitDirection: true
        )
        let assignedPairs = assignImages(loadedImages, to: cellRects)
        let placements = scatterPlacements(
            for: assignedPairs,
            canvasRect: canvasRect,
            margin: margin,
            spacing: spacing
        )

        var canvas = baseCanvas
        var renderedTiles = 0

        for placement in placements {
            let photoRect = placement.photoRect
            guard photoRect.width > 1, photoRect.height > 1 else {
                continue
            }

            // Build the framed photo (white border + photo + metadata) at origin, then rotate and
            // position it on the canvas as a unit.
            let unrotatedFrame = photoRect.insetBy(dx: -margin, dy: -margin)
            let localPhotoRect = CGRect(
                x: margin,
                y: margin,
                width: photoRect.width,
                height: photoRect.height
            )
            let localFrameRect = CGRect(origin: .zero, size: unrotatedFrame.size)

            var tile = whiteRect(localFrameRect)
            let scaledTile = scaledPhoto(placement.image.image, toFill: localPhotoRect)
            tile = scaledTile.composited(over: tile)
            tile = drawBorderMetadata(
                onto: tile,
                frameRect: localFrameRect,
                photoRect: localPhotoRect,
                margin: margin,
                dateText: placement.image.dateText,
                locationText: placement.image.locationText
            )

            // Rotate tile around its center, then translate so its center lands at placement.center.
            let tileCenter = CGPoint(x: unrotatedFrame.width / 2, y: unrotatedFrame.height / 2)
            let rotated = tile
                .transformed(by: CGAffineTransform(translationX: -tileCenter.x, y: -tileCenter.y))
                .transformed(by: CGAffineTransform(rotationAngle: placement.rotation))
                .transformed(by: CGAffineTransform(translationX: placement.center.x, y: placement.center.y))

            canvas = rotated.composited(over: canvas)
            renderedTiles += 1
        }

        guard renderedTiles > 0 else {
            throw CollageRendererError.emptyRenderResult
        }
        return canvas
    }

    private struct ScatterPlacement {
        let image: LoadedImage
        /// Center of the photo; the growth pass may nudge it toward open space.
        var center: CGPoint
        /// Photo size (without the white margin) at scale 1.
        let baseSize: CGSize
        var scale: CGFloat
        let margin: CGFloat
        /// Rotation in radians (small tilt for hand-made collage feel).
        let rotation: CGFloat

        var photoRect: CGRect {
            let width = round(baseSize.width * scale)
            let height = round(baseSize.height * scale)
            return CGRect(
                x: round(center.x - width / 2),
                y: round(center.y - height / 2),
                width: width,
                height: height
            )
        }

        /// Axis-aligned bounding box of the rotated frame (used for collision detection).
        var frameRect: CGRect {
            let photo = photoRect
            let frame = photo.insetBy(dx: -margin, dy: -margin)
            return rotatedBoundingBox(frame, rotation: rotation, around: center)
        }

        func frameRect(atScale candidate: CGFloat, center candidateCenter: CGPoint? = nil) -> CGRect {
            var copy = self
            copy.scale = candidate
            if let candidateCenter {
                copy.center = candidateCenter
            }
            return copy.frameRect
        }

        /// Returns the axis-aligned bounding box of `rect` after rotating it by `angle` radians
        /// around `pivot`.
        private func rotatedBoundingBox(_ rect: CGRect, rotation angle: CGFloat, around pivot: CGPoint) -> CGRect {
            let corners = [
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY)
            ]
            let cosA = cos(angle)
            let sinA = sin(angle)
            var minX = CGFloat.greatestFiniteMagnitude
            var minY = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude
            var maxY = -CGFloat.greatestFiniteMagnitude
            for corner in corners {
                let dx = corner.x - pivot.x
                let dy = corner.y - pivot.y
                let rx = pivot.x + dx * cosA - dy * sinA
                let ry = pivot.y + dx * sinA + dy * cosA
                minX = min(minX, rx)
                minY = min(minY, ry)
                maxX = max(maxX, rx)
                maxY = max(maxY, ry)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    /// Turns the partition cells into a loose, collage-like scatter while guaranteeing that framed
    /// photos never come closer than `spacing` pixels to each other:
    /// 1. Each photo starts at a random size (a fraction of the largest size that fits its cell)
    ///    at a random position inside its cell, so neighbors no longer line up on shared edges.
    /// 2. Over a few rounds, in random order, each photo tries a handful of small nudges toward
    ///    open space and keeps whichever position lets it grow largest before its frame would come
    ///    within `spacing` of another frame or the canvas edge (capped so no photo balloons far
    ///    past its cell's share). This soaks up much of the empty black space while keeping the
    ///    irregular, off-grid arrangement.
    private func scatterPlacements(
        for pairs: [(image: LoadedImage, rect: CGRect)],
        canvasRect: CGRect,
        margin: CGFloat,
        spacing: CGFloat
    ) -> [ScatterPlacement] {
        let halfSpacing = spacing / 2
        let initialScaleRange: ClosedRange<CGFloat> = 0.62...0.9
        let maximumGrowth: CGFloat = 1.5
        let growthRounds = 3
        let maxTiltDegrees: CGFloat = 4.0
        let tiltRange = -maxTiltDegrees...maxTiltDegrees

        var placements: [ScatterPlacement] = []
        placements.reserveCapacity(pairs.count)

        for pair in pairs {
            // Each cell owns a region inset by half the spacing, so two neighboring regions are
            // always at least `spacing` apart.
            let region = pair.rect.insetBy(dx: halfSpacing, dy: halfSpacing)
            let photoBounds = region.insetBy(dx: margin, dy: margin)
            guard photoBounds.width > 4, photoBounds.height > 4 else {
                continue
            }

            let aspect = pair.image.aspectRatio
            let fitScale = min(photoBounds.width / aspect, photoBounds.height)
            let baseSize = CGSize(width: fitScale * aspect, height: fitScale)

            let startScale = CGFloat.random(in: initialScaleRange, using: &layoutGenerator)
            let startFrame = CGSize(
                width: baseSize.width * startScale + margin * 2,
                height: baseSize.height * startScale + margin * 2
            )
            let slackX = max(0, region.width - startFrame.width)
            let slackY = max(0, region.height - startFrame.height)
            let originX = region.minX + CGFloat.random(in: 0...1, using: &layoutGenerator) * slackX
            let originY = region.minY + CGFloat.random(in: 0...1, using: &layoutGenerator) * slackY
            let center = CGPoint(x: originX + startFrame.width / 2, y: originY + startFrame.height / 2)

            let tiltDegrees = CGFloat.random(in: tiltRange, using: &layoutGenerator)
            let tiltRadians = tiltDegrees * .pi / 180

            placements.append(
                ScatterPlacement(
                    image: pair.image,
                    center: center,
                    baseSize: baseSize,
                    scale: startScale,
                    margin: margin,
                    rotation: tiltRadians
                )
            )
        }

        let allowedArea = canvasRect.insetBy(dx: halfSpacing, dy: halfSpacing)
        let growthOrder = Array(placements.indices).shuffled(using: &layoutGenerator)

        func isValid(_ frame: CGRect, excluding index: Int) -> Bool {
            guard allowedArea.contains(frame) else {
                return false
            }
            let padded = frame.insetBy(dx: -spacing, dy: -spacing)
            for other in placements.indices where other != index {
                if padded.intersects(placements[other].frameRect) {
                    return false
                }
            }
            return true
        }

        func largestValidScale(for index: Int, center: CGPoint) -> CGFloat? {
            var low = placements[index].scale
            guard isValid(placements[index].frameRect(atScale: low, center: center), excluding: index) else {
                return nil
            }
            var high = maximumGrowth
            guard high > low else {
                return low
            }
            if isValid(placements[index].frameRect(atScale: high, center: center), excluding: index) {
                return high
            }
            for _ in 0..<18 {
                let mid = (low + high) / 2
                if isValid(placements[index].frameRect(atScale: mid, center: center), excluding: index) {
                    low = mid
                } else {
                    high = mid
                }
            }
            return low
        }

        let nudgeStep = min(canvasRect.width, canvasRect.height) * 0.03
        let directions: [CGPoint] = [
            CGPoint(x: 1, y: 0), CGPoint(x: -1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 0, y: -1),
            CGPoint(x: 0.707, y: 0.707), CGPoint(x: -0.707, y: 0.707),
            CGPoint(x: 0.707, y: -0.707), CGPoint(x: -0.707, y: -0.707)
        ]

        for _ in 0..<growthRounds {
            for index in growthOrder {
                let current = placements[index].center
                var bestCenter = current
                var bestScale = largestValidScale(for: index, center: current) ?? placements[index].scale
                for direction in directions {
                    for multiplier in [1.0, 2.0, 3.0] as [CGFloat] {
                        let candidate = CGPoint(
                            x: current.x + direction.x * nudgeStep * multiplier,
                            y: current.y + direction.y * nudgeStep * multiplier
                        )
                        if let scale = largestValidScale(for: index, center: candidate), scale > bestScale + 0.005 {
                            bestScale = scale
                            bestCenter = candidate
                        }
                    }
                }
                placements[index].center = bestCenter
                placements[index].scale = bestScale
            }
        }

        return placements
    }

    /// Uniformly scales `image` so it fills `rect` (whose aspect ratio already matches the photo's,
    /// give or take pixel rounding) and positions it there.
    private func scaledPhoto(_ image: CIImage, toFill rect: CGRect) -> CIImage {
        let normalized = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y)
        )
        let scale = max(rect.width / max(normalized.extent.width, 1), rect.height / max(normalized.extent.height, 1))
        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let offsetX = (rect.width - scaled.extent.width) / 2
        let offsetY = (rect.height - scaled.extent.height) / 2
        return scaled
            .transformed(by: CGAffineTransform(translationX: rect.minX + offsetX, y: rect.minY + offsetY))
            .cropped(to: rect)
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

    private enum BorderTextAlignment {
        case left
        case right
    }

    private func formattedTakenDate(from date: Date?) -> String? {
        guard let date else {
            return nil
        }
        return takenDateFormatter.string(from: date)
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

    /// Draws the date (top-left) and location (bottom-right) directly into the white border band
    /// around a photo, rather than over the photo itself. Text is solid black (no shadow/badge
    /// needed since it already sits on white) and sized to fit inside the border thickness.
    private func drawBorderMetadata(
        onto canvas: CIImage,
        frameRect: CGRect,
        photoRect: CGRect,
        margin: CGFloat,
        dateText: String?,
        locationText: String?
    ) -> CIImage {
        guard margin > 4, dateText != nil || locationText != nil else {
            return canvas
        }

        let fontSize = max(6, min(margin - 5, 16))
        var result = canvas

        if let dateText {
            let topBand = CGRect(
                x: frameRect.minX,
                y: photoRect.maxY,
                width: frameRect.width,
                height: frameRect.maxY - photoRect.maxY
            )
            if let textImage = borderTextImage(dateText, in: topBand.size, fontSize: fontSize, alignment: .left) {
                result = textImage
                    .transformed(by: CGAffineTransform(translationX: topBand.minX, y: topBand.minY))
                    .composited(over: result)
            }
        }

        if let locationText {
            let bottomBand = CGRect(
                x: frameRect.minX,
                y: frameRect.minY,
                width: frameRect.width,
                height: photoRect.minY - frameRect.minY
            )
            if let textImage = borderTextImage(locationText, in: bottomBand.size, fontSize: fontSize, alignment: .right) {
                result = textImage
                    .transformed(by: CGAffineTransform(translationX: bottomBand.minX, y: bottomBand.minY))
                    .composited(over: result)
            }
        }

        return result
    }

    /// Renders a single line of solid black text, aligned left or right and vertically centered,
    /// within a thin band (typically the white border above/below a photo). Returns nil if the
    /// band is too small to draw into.
    private func borderTextImage(
        _ text: String,
        in size: CGSize,
        fontSize: CGFloat,
        alignment: BorderTextAlignment
    ) -> CIImage? {
        let normalizedSize = CGSize(width: floor(size.width), height: floor(size.height))
        guard normalizedSize.width > 2, normalizedSize.height > 2 else {
            return nil
        }

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

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment == .left ? .left : .right
        paragraph.lineBreakMode = .byTruncatingTail

        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ]

        let horizontalPadding = max(6, fontSize * 0.5)
        let maxTextWidth = max(10, normalizedSize.width - horizontalPadding * 2)
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let measured = attributed.boundingRect(
            with: NSSize(width: maxTextWidth, height: normalizedSize.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        let textOriginY = max(0, (normalizedSize.height - measured.height) / 2)
        let textRect = NSRect(x: horizontalPadding, y: textOriginY, width: maxTextWidth, height: measured.height)
        attributed.draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]
        )

        guard let cgImage = bitmap.cgImage else {
            return nil
        }

        return CIImage(cgImage: cgImage)
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

    private func mosaicLayout(
        count: Int,
        in canvasRect: CGRect,
        gap: CGFloat,
        randomizeSplitDirection: Bool = false
    ) -> [CGRect] {
        guard count > 0 else {
            return []
        }

        var partitions: [CGRect] = [canvasRect]
        while partitions.count < count {
            guard let splitIndex = largestSplittableRectIndex(in: partitions, gap: gap) else {
                break
            }

            let rect = partitions.remove(at: splitIndex)
            guard let splitRects = split(rect: rect, gap: gap, randomizeDirection: randomizeSplitDirection) else {
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

    /// `randomizeDirection` (used by the scattered collage) lets a near-square rect split either way
    /// instead of always across its longer side, which breaks up the row/column feel. The legacy
    /// mosaic keeps the deterministic rule so `-r` reproduces old mosaic runs exactly.
    private func split(rect: CGRect, gap: CGFloat, randomizeDirection: Bool = false) -> (CGRect, CGRect)? {
        let minDimension = minimumTileDimension + gap
        var splitAlongWidth = rect.width >= rect.height
        if randomizeDirection {
            let rectAspect = rect.width / max(rect.height, 1)
            let canSplitWidth = rect.width >= minDimension * 2
            let canSplitHeight = rect.height >= minDimension * 2
            if rectAspect > 0.6, rectAspect < 1.7, canSplitWidth, canSplitHeight {
                splitAlongWidth = Bool.random(using: &layoutGenerator)
            }
        }
        let ratio = CGFloat.random(in: 0.34...0.66, using: &layoutGenerator)

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

    /// A solid white rect at `rect`'s absolute position. Used as the per-picture margin background
    /// in the optimal layout.
    private func whiteRect(_ rect: CGRect) -> CIImage {
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
        return white.cropped(to: rect)
    }
}
