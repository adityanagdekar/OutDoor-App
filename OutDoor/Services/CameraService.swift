@preconcurrency import AVFoundation
import Observation
import UIKit

@MainActor
@Observable
final class CameraService: NSObject {
    enum AuthorizationState: Equatable {
        case notDetermined
        case authorized
        case denied
        case restricted
    }

    enum CameraError: LocalizedError {
        case cameraUnavailable
        case configurationFailed
        case captureFailed

        var errorDescription: String? {
            switch self {
            case .cameraUnavailable:
                "The camera is unavailable on this device."
            case .configurationFailed:
                "The camera could not be configured."
            case .captureFailed:
                "The photo could not be captured."
            }
        }
    }

    let session = AVCaptureSession()

    private(set) var authorizationState: AuthorizationState = .notDetermined
    private(set) var capturedImage: UIImage?
    private(set) var errorMessage: String?

    private let photoOutput = AVCapturePhotoOutput()
    private var isConfigured = false

    override init() {
        super.init()
        refreshAuthorizationState()
    }

    func requestAccessAndStart() async {
        refreshAuthorizationState()

        if authorizationState == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            authorizationState = granted ? .authorized : .denied
        }

        guard authorizationState == .authorized else {
            return
        }

        do {
            try configureSession()
            startSession()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startSession() {
        guard isConfigured, !session.isRunning else {
            return
        }

        let session = session
        Task.detached(priority: .userInitiated) {
            session.startRunning()
        }
    }

    func stopSession() {
        guard session.isRunning else {
            return
        }

        let session = session
        Task.detached(priority: .userInitiated) {
            session.stopRunning()
        }
    }

    func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func retakePhoto() {
        capturedImage = nil
        errorMessage = nil
        startSession()
    }

    private func refreshAuthorizationState() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            authorizationState = .notDetermined
        case .authorized:
            authorizationState = .authorized
        case .denied:
            authorizationState = .denied
        case .restricted:
            authorizationState = .restricted
        @unknown default:
            authorizationState = .denied
        }
    }

    private func configureSession() throws {
        guard !isConfigured else {
            return
        }

        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            throw CameraError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: camera)

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
            throw CameraError.configurationFailed
        }

        session.addInput(input)
        session.addOutput(photoOutput)
        isConfigured = true
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let image = error == nil
            ? photo.fileDataRepresentation().flatMap(UIImage.init(data:))
            : nil

        Task { @MainActor in
            if let image {
                capturedImage = image
                stopSession()
            } else {
                errorMessage = error?.localizedDescription
                    ?? CameraError.captureFailed.localizedDescription
            }
        }
    }
}
