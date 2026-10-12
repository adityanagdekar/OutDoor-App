import Photos
import UIKit

enum PhotoLibraryError: LocalizedError {
    case accessDenied

    var errorDescription: String? {
        "Photo Library access is required to save this photo."
    }
}

struct PhotoLibraryService {
    func save(_ image: UIImage) async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)

        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }

        guard status == .authorized || status == .limited else {
            throw PhotoLibraryError.accessDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }
}
