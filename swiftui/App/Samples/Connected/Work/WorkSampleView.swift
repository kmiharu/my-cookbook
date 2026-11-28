import CatalogCore
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreTransferable
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Vision

private enum DocumentError: Error {
    case imageTooLarge, dimensionsTooLarge, unreadableImage
}

private struct DocumentImage: Transferable, Sendable {
    static let byteLimit = 20 * 1024 * 1024

    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            let attributes = try file.file.resourceValues(forKeys: [.fileSizeKey])
            guard let size = attributes.fileSize, size <= byteLimit else {
                throw DocumentError.imageTooLarge
            }
            let data = try Data(contentsOf: file.file, options: .mappedIfSafe)
            guard data.count <= byteLimit else { throw DocumentError.imageTooLarge }
            return DocumentImage(data: data)
        }
    }

    @MainActor
    static func fixture() -> Data? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data("COOKBOOK-2026-01".utf8)
        guard let output = filter.outputImage,
              let code = CIContext().createCGImage(output, from: output.extent) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: 1_200, height: 720)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            let lines = ["Work sample", "Reference: LAB-1042", "Subject: Equipment return", "Location: Room A"]
            let style: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 51, weight: .medium),
                .foregroundColor: UIColor.black
            ]
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 82, y: 88 + index * 84), withAttributes: style)
            }
            context.cgContext.interpolationQuality = .none
            UIImage(cgImage: code).draw(in: CGRect(x: 850, y: 104, width: 216, height: 216))
        }
        return image.pngData()
    }
}

private struct DocumentRecognition: Sendable {
    let lines: [String]
    let codes: [String]

    func field(prefix: String) -> String? {
        guard let line = lines.first(where: { $0.localizedCaseInsensitiveContains(prefix) }) else { return nil }
        return line.components(separatedBy: ":").dropFirst().joined(separator: ":")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private actor DocumentRecognizer {
    func recognize(_ data: Data) async throws -> DocumentRecognition {
        guard data.count <= DocumentImage.byteLimit else { throw DocumentError.imageTooLarge }
        let fileOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_600,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, fileOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0 else {
            throw DocumentError.unreadableImage
        }
        guard width <= 12_000, height <= 12_000, width * height <= 48_000_000 else {
            throw DocumentError.dimensionsTooLarge
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw DocumentError.unreadableImage
        }
        try Task.checkCancellation()
        var text = RecognizeTextRequest()
        text.recognitionLanguages = [Locale.Language(identifier: "ja-JP"), Locale.Language(identifier: "en-US")]
        let recognized = try await text.perform(on: image, orientation: .up)
        try Task.checkCancellation()
        var barcodes = DetectBarcodesRequest()
        barcodes.symbologies = [.qr, .code128, .ean13]
        let found = try await barcodes.perform(on: image, orientation: .up)
        try Task.checkCancellation()
        return DocumentRecognition(
            lines: recognized.prefix(40).compactMap { observation in
                observation.topCandidates(1).first.map { String($0.string.prefix(256)) }
            },
            codes: found.prefix(12).compactMap { $0.payloadString.map { String($0.prefix(512)) } }
        )
    }
}

private struct WorkDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let decoded = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = decoded
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct WorkSampleView: View {
    @Environment(\.diagnostics) private var diagnostics
    @Environment(\.scenePhase) private var scenePhase
    @State private var recognizer = DocumentRecognizer()
    @State private var photo: PhotosPickerItem?
    @State private var result: DocumentRecognition?
    @State private var processing: Task<Void, Never>?
    @State private var status: String?
    @State private var reference = ""
    @State private var subject = ""
    @State private var notes = ""
    @State private var validation: String?
    @State private var document: WorkDocument?
    @State private var exporting = false

    var body: some View {
        Form {
            Section("入力に使う画像") {
                Button("文字とQRコードの見本を読む", systemImage: "doc.viewfinder") {
                    startRecognition {
                        guard let data = DocumentImage.fixture() else { throw DocumentError.unreadableImage }
                        return data
                    }
                }
                .disabled(processing != nil)
                PhotosPicker(selection: $photo, matching: .images) {
                    Label("写真を選ぶ", systemImage: "photo")
                }
                .disabled(processing != nil)
                if processing != nil {
                    ProgressView("文字とコードを読み取っています")
                    Button("読み取りを中止") { processing?.cancel() }
                }
                if let status {
                    Text(status).foregroundStyle(.secondary)
                }
                if let result {
                    if !result.lines.isEmpty {
                        DisclosureGroup("認識した文字") {
                            ForEach(Array(result.lines.enumerated()), id: \.offset) { row in
                                Text(row.element).textSelection(.enabled)
                            }
                        }
                    }
                    if !result.codes.isEmpty {
                        DisclosureGroup("検出したコード") {
                            ForEach(Array(result.codes.enumerated()), id: \.offset) { row in
                                Text(row.element).textSelection(.enabled)
                            }
                        }
                    }
                    if !result.lines.isEmpty || !result.codes.isEmpty {
                        Button("認識結果を入力に反映") { apply(result) }
                    }
                }
            }
            Section("書類の内容") {
                TextField("管理番号（必須）", text: $reference)
                    .textInputAutocapitalization(.never)
                TextField("件名（必須）", text: $subject, axis: .vertical)
                Text("備考").font(.subheadline)
                TextEditor(text: $notes)
                    .frame(minHeight: 88)
                    .accessibilityLabel("備考")
                Text("管理番号は40文字、件名は100文字、備考は500文字まで。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let validation {
                    Text(validation).foregroundStyle(.secondary)
                }
                Button("テキストを書き出す", systemImage: "square.and.arrow.up") { prepareExport() }
                    .disabled(exporting)
            }
        }
        .navigationTitle("書類を作る")
        .onChange(of: photo) { _, item in
            guard let item else { return }
            startRecognition {
                guard let image = try await item.loadTransferable(type: DocumentImage.self) else {
                    throw DocumentError.unreadableImage
                }
                return image.data
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { processing?.cancel() }
        }
        .onDisappear { processing?.cancel() }
        .fileExporter(isPresented: $exporting, document: document, contentTypes: [.plainText],
                      defaultFilename: "work-sample.txt") { result in
            document = nil
            switch result {
            case .success:
                validation = "テキストを書き出しました。"
                Task { await diagnostics?.record(sample: .work, action: .save, outcome: .success) }
            case .failure:
                validation = "書き出せませんでした。保存先と空き容量を確認して、もう一度お試しください。"
                Task { await diagnostics?.record(sample: .work, action: .save, outcome: .failure) }
            }
        } onCancellation: {
            document = nil
            validation = "書き出しを中止しました。"
            Task { await diagnostics?.record(sample: .work, action: .save, outcome: .cancelled) }
        }
    }

    private func startRecognition(_ input: @escaping @MainActor () async throws -> Data) {
        guard processing == nil else { return }
        result = nil
        status = nil
        processing = Task {
            defer {
                processing = nil
                photo = nil
            }
            do {
                let data = try await input()
                try Task.checkCancellation()
                let started = ContinuousClock.now
                let recognized = try await recognizer.recognize(data)
                try Task.checkCancellation()
                result = recognized
                if recognized.lines.isEmpty, recognized.codes.isEmpty {
                    status = "文字やコードを検出できませんでした。明るく、正面から撮った画像をお試しください。"
                }
                let elapsed = started.duration(to: .now).components
                let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
                await diagnostics?.record(sample: .work, action: .process, outcome: .success, milliseconds: milliseconds)
            } catch {
                if Task.isCancelled {
                    status = "読み取りを中止しました。"
                    await diagnostics?.record(sample: .work, action: .process, outcome: .cancelled)
                } else {
                    if let error = error as? DocumentError, case .imageTooLarge = error {
                        status = "20 MB以内の画像を選んでください。"
                    } else if let error = error as? DocumentError, case .dimensionsTooLarge = error {
                        status = "画像の縦横と画素数が上限を超えています。縮小した写真を選んでください。"
                    } else {
                        status = "画像を読み取れませんでした。写真を選び直すか、見本をお試しください。"
                    }
                    await diagnostics?.record(sample: .work, action: .process, outcome: .failure)
                }
            }
        }
    }

    private func apply(_ recognition: DocumentRecognition) {
        if let number = recognition.field(prefix: "Reference:") ?? recognition.codes.first {
            reference = String(number.prefix(40))
        }
        if let title = recognition.field(prefix: "Subject:") {
            subject = String(title.prefix(100))
        }
        if let location = recognition.field(prefix: "Location:") {
            notes = String(location.prefix(500))
        }
        validation = nil
    }

    private func prepareExport() {
        let identifier = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, !title.isEmpty else {
            validation = "管理番号と件名を入力してください。"
            return
        }
        guard identifier.count <= 40, title.count <= 100, notes.count <= 500 else {
            validation = "文字数の上限を超えています。管理番号、件名、備考を確認してください。"
            return
        }
        validation = nil
        document = WorkDocument(text: "管理番号: \(identifier)\n件名: \(title)\n備考:\n\(notes)\n")
        exporting = true
    }
}

#Preview {
    NavigationStack { WorkSampleView() }
}
