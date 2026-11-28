import CoreTransferable
import Foundation
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FixtureAttachment: Codable, Equatable, Sendable, Transferable {
    let jpeg: Data

    private static let decoder = FixtureAttachmentDecoder()

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { package in
            try await decoder.thumbnail(from: package.file)
        }
    }
}

private actor FixtureAttachmentDecoder {
    enum ImageError: Error {
        case decodingFailed
        case encodingFailed
    }

    func thumbnail(from url: URL) throws -> FixtureAttachment {
        try Task.checkCancellation()
        let file = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard file.isRegularFile == true, let fileSize = file.fileSize, fileSize <= 32 * 1_024 * 1_024 else {
            throw ImageError.decodingFailed
        }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= 100_000_000 / height else {
            throw ImageError.decodingFailed
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageError.decodingFailed
        }
        try Task.checkCancellation()
        guard let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImageError.encodingFailed
        }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageError.encodingFailed }
        let length = CFDataGetLength(output)
        guard length <= 128_000, let bytes = CFDataGetBytePtr(output) else { throw ImageError.encodingFailed }
        try Task.checkCancellation()
        return FixtureAttachment(jpeg: Data(bytes: bytes, count: length))
    }
}

struct FixtureAttachmentPreview: View {
    let attachment: FixtureAttachment

    var body: some View {
        if let image = UIImage(data: attachment.jpeg) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 150)
                .clipShape(.rect(cornerRadius: 8))
                .accessibilityLabel("添付画像")
        }
    }
}

struct FixtureModeNote: View {
    let detail: String

    var body: some View {
        Label {
            Text(detail)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "testtube.2")
                .accessibilityHidden(true)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

func fixtureElapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = start.duration(to: .now).components
    return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
}

extension String {
    var trimmedForFixture: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    func fitsFixtureLimit(_ characters: Int) -> Bool {
        utf8.prefix(characters * 8 + 1).count <= characters * 8 && count <= characters
    }
}
