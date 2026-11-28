import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SystemCamera: UIViewControllerRepresentable {
    var picked: ((CGImage, Int32)?) -> Void
    var failed: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.mediaTypes = [UTType.image.identifier]
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIViewController(_ picker: UIImagePickerController, coordinator: Coordinator) {
        picker.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var parent: SystemCamera

        init(parent: SystemCamera) { self.parent = parent }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.picked(nil)
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage, let cgImage = image.cgImage else {
                parent.failed()
                return
            }
            let orientation: Int32
            switch image.imageOrientation {
            case .up: orientation = 1
            case .upMirrored: orientation = 2
            case .down: orientation = 3
            case .downMirrored: orientation = 4
            case .leftMirrored: orientation = 5
            case .right: orientation = 6
            case .rightMirrored: orientation = 7
            case .left: orientation = 8
            @unknown default: orientation = 1
            }
            parent.picked((cgImage, orientation))
        }
    }
}
