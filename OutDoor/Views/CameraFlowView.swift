import AVFoundation
import SwiftUI
import UIKit

struct CameraFlowView: View {
    let challenge: Challenge

    @Environment(\.dismiss) private var dismiss
    @State private var camera = CameraService()
    @State private var hasRequestedCamera = false
    @State private var isSaving = false
    @State private var saveError: String?

    private let photoLibrary = PhotoLibraryService()

    var body: some View {
        NavigationStack {
            Group {
                if let image = camera.capturedImage {
                    PhotoReviewView(
                        image: image,
                        isSaving: isSaving,
                        onRetake: camera.retakePhoto,
                        onSubmit: { submit(image) }
                    )
                } else if hasRequestedCamera && camera.authorizationState == .authorized {
                    LiveCameraView(
                        session: camera.session,
                        errorMessage: camera.errorMessage,
                        onCapture: camera.capturePhoto
                    )
                } else {
                    CameraPermissionView(
                        challengeTitle: challenge.title,
                        authorizationState: camera.authorizationState,
                        onOpenCamera: openCamera
                    )
                }
            }
            .navigationTitle(challenge.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        camera.stopSession()
                        dismiss()
                    }
                }
            }
            .alert(
                "Couldn’t Save Photo",
                isPresented: Binding(
                    get: { saveError != nil },
                    set: { if !$0 { saveError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
        .onDisappear {
            camera.stopSession()
        }
    }

    private func openCamera() {
        hasRequestedCamera = true
        Task {
            await camera.requestAccessAndStart()
        }
    }

    private func submit(_ image: UIImage) {
        isSaving = true

        Task {
            do {
                try await photoLibrary.save(image)
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                saveError = error.localizedDescription
            }
        }
    }
}

private struct CameraPermissionView: View {
    let challengeTitle: String
    let authorizationState: CameraService.AuthorizationState
    let onOpenCamera: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "camera")
                .font(.system(size: 64))

            Text("Camera Access")
                .font(.title)
                .fontWeight(.semibold)

            Text("Take a photo for “\(challengeTitle)” to complete this outdoor challenge. The photo will be saved to your Photos library after you submit it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if authorizationState == .denied || authorizationState == .restricted {
                Text("Camera access is unavailable. Enable it for OutDoor in Settings.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.red)

                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else {
                        return
                    }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Open Camera", action: onOpenCamera)
                    .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
        .padding()
    }
}

private struct LiveCameraView: View {
    let session: AVCaptureSession
    let errorMessage: String?
    let onCapture: () -> Void

    var body: some View {
        ZStack {
            CameraPreview(session: session)
                .ignoresSafeArea(edges: .bottom)

            VStack {
                if let errorMessage {
                    Text(errorMessage)
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding()
                }

                Spacer()

                Button(action: onCapture) {
                    Circle()
                        .fill(.white)
                        .frame(width: 72, height: 72)
                        .overlay {
                            Circle()
                                .stroke(.black, lineWidth: 2)
                                .padding(5)
                        }
                }
                .accessibilityLabel("Take photo")
                .padding(.bottom, 32)
            }
        }
    }
}

private struct PhotoReviewView: View {
    let image: UIImage
    let isSaving: Bool
    let onRetake: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)

            HStack(spacing: 16) {
                Button("Retake", action: onRetake)
                    .buttonStyle(.bordered)
                    .disabled(isSaving)

                Button(action: onSubmit) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Submit & Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }
}
