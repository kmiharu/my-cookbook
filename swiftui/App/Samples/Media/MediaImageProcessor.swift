import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreTransferable
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MediaImageError: LocalizedError {
    case tooLarge, invalidImage, cannotWrite, exportLimit

    var errorDescription: String? {
        switch self {
        case .tooLarge: "写真は 32 MB、1 億画素以下のものを選んでください。"
        case .invalidImage: "画像を読み込めませんでした。別の写真を選んでください。"
        case .cannotWrite: "画像を作成できませんでした。端末の空き容量を確認してください。"
        case .exportLimit: "今日作成できる書き出しファイルの上限に達しました。時間をおいてお試しください。"
        }
    }
}

struct ImportedPhoto: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            let values = try file.file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard let size = values.fileSize, values.isRegularFile == true else {
                throw MediaImageError.invalidImage
            }
            guard size <= 32 * 1_024 * 1_024 else { throw MediaImageError.tooLarge }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-imports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for entry in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) {
                if let created = try? entry.resourceValues(forKeys: [.creationDateKey]).creationDate,
                   created.timeIntervalSinceNow < -3_600 {
                    try? FileManager.default.removeItem(at: entry)
                }
            }
            let url = directory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.copyItem(at: file.file, to: url)
                try Task.checkCancellation()
                return ImportedPhoto(url: url)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
    }
}

struct MediaImageAsset: Sendable {
    let full: Data
    let preview: Data
}

enum StudioFilter: String, CaseIterable, Identifiable, Sendable {
    case original = "なし"
    case mono = "モノクロ"
    case sepia = "セピア"
    var id: Self { self }
}

struct ImageEdits: Equatable, Sendable {
    var squareCrop = false
    var filter: StudioFilter = .original
    var strokes: [[CGPoint]] = []
}

actor MediaImageProcessor {
    // A single reusable context per screen keeps rendering serialized and avoids per-render setup.
    private let context = CIContext(options: [.cacheIntermediates: false])

    func prepare(_ url: URL) throws -> MediaImageAsset {
        try Task.checkCancellation()
        guard let original = CGImageSourceCreateWithURL(url as CFURL, Self.imageSourceOptions) else {
            throw MediaImageError.invalidImage
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            throw MediaImageError.invalidImage
        }
        guard width <= 100_000_000 / height else { throw MediaImageError.tooLarge }
        return try makeAsset(Self.downsample(original, maximum: 1_600))
    }

    func prepare(_ image: CGImage, orientation: Int32) throws -> MediaImageAsset {
        try Task.checkCancellation()
        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: orientation)
        let ratio = min(1, 1_600 / max(oriented.extent.width, oriented.extent.height))
        let reduced = oriented.transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
        guard let result = context.createCGImage(reduced, from: reduced.extent.integral) else {
            throw MediaImageError.invalidImage
        }
        return try makeAsset(result)
    }

    func preview(_ data: Data, edits: ImageEdits) throws -> Data {
        try Self.jpeg(render(data, edits: edits, maximum: 640), quality: 0.8)
    }

    func export(_ data: Data, edits: ImageEdits) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("studio-exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
        let cutoff = Date().addingTimeInterval(-86_400)
        var recentCount = 0
        for entry in entries {
            let created = try entry.resourceValues(forKeys: [.creationDateKey]).creationDate
            if let created, created < cutoff {
                try FileManager.default.removeItem(at: entry)
            } else {
                recentCount += 1
            }
        }
        guard recentCount < 20 else { throw MediaImageError.exportLimit }
        let result = try Self.jpeg(render(data, edits: edits, maximum: 1_600), quality: 0.85)
        try Task.checkCancellation()
        let url = directory.appendingPathComponent("編集した写真-\(UUID().uuidString.prefix(8)).jpg")
        try result.write(to: url, options: .atomic)
        return url
    }

    private func makeAsset(_ image: CGImage) throws -> MediaImageAsset {
        try Task.checkCancellation()
        let full = try Self.jpeg(image, quality: 0.83)
        guard let source = CGImageSourceCreateWithData(full as CFData, Self.imageSourceOptions) else {
            throw MediaImageError.invalidImage
        }
        let preview = try Self.jpeg(Self.downsample(source, maximum: 480), quality: 0.75)
        try Task.checkCancellation()
        return MediaImageAsset(full: full, preview: preview)
    }

    private func render(_ data: Data, edits: ImageEdits, maximum: Int) throws -> CGImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, Self.imageSourceOptions) else {
            throw MediaImageError.invalidImage
        }
        var image = CIImage(cgImage: try Self.downsample(source, maximum: maximum))
        if edits.squareCrop {
            let side = min(image.extent.width, image.extent.height)
            let area = CGRect(x: image.extent.midX - side / 2, y: image.extent.midY - side / 2,
                              width: side, height: side).integral
            image = image.cropped(to: area)
        }
        switch edits.filter {
        case .original:
            break
        case .mono:
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.saturation = 0
            image = filter.outputImage ?? image
        case .sepia:
            let filter = CIFilter.sepiaTone()
            filter.inputImage = image
            filter.intensity = 0.7
            image = filter.outputImage ?? image
        }
        try Task.checkCancellation()
        guard let rendered = context.createCGImage(image, from: image.extent) else {
            throw MediaImageError.invalidImage
        }
        guard !edits.strokes.isEmpty else { return rendered }
        return try draw(edits.strokes, on: rendered)
    }

    private func draw(_ strokes: [[CGPoint]], on image: CGImage) throws -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard let graphics = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw MediaImageError.cannotWrite }
        graphics.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        graphics.setStrokeColor(red: 1, green: 0.70, blue: 0.10, alpha: 1)
        graphics.setLineWidth(max(2, min(width, height) * 0.015))
        graphics.setLineCap(.round)
        graphics.setLineJoin(.round)
        for stroke in strokes where stroke.count > 1 {
            graphics.addLines(between: stroke.map { CGPoint(x: $0.x * width, y: (1 - $0.y) * height) })
            graphics.strokePath()
        }
        try Task.checkCancellation()
        guard let result = graphics.makeImage() else { throw MediaImageError.cannotWrite }
        return result
    }

    private static var imageSourceOptions: CFDictionary {
        [kCGImageSourceShouldCache: false] as CFDictionary
    }

    private static func downsample(_ source: CGImageSource, maximum: Int) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MediaImageError.invalidImage
        }
        return image
    }

    private static func jpeg(_ image: CGImage, quality: Double) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MediaImageError.cannotWrite
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MediaImageError.cannotWrite }
        return output as Data
    }
}
