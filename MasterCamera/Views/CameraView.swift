import PhotosUI
import SwiftUI

struct CameraView: View {
    @StateObject private var viewModel = CameraViewModel()
    @State private var selectedSample: PhotosPickerItem?

    var body: some View {
        ZStack {
            CameraPreview(
                session: viewModel.cameraManager.session,
                onTapToFocus: viewModel.focusAndExpose
            )
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)

            if let message = viewModel.state.message ?? viewModel.errorMessage {
                messageOverlay(message)
            }

            if viewModel.processingState.isProcessing {
                processingOverlay(viewModel.processingState)
            }
        }
        .background(Color.black)
        .onAppear(perform: viewModel.onAppear)
        .onDisappear(perform: viewModel.onDisappear)
        .fullScreenCover(item: $viewModel.capturedPhoto) { photo in
            PhotoPreviewView(
                photo: photo,
                saveState: viewModel.saveState,
                onSave: viewModel.saveCapturedPhoto,
                onRetake: viewModel.dismissPreview
            )
        }
        .onChange(of: selectedSample) { _, newValue in
            guard let newValue else { return }
            Task {
                defer { selectedSample = nil }
                do {
                    guard let data = try await newValue.loadTransferable(type: Data.self) else {
                        viewModel.reportImportFailure("无法读取所选样片。")
                        return
                    }
                    viewModel.processImportedPhotoData(data)
                } catch {
                    viewModel.reportImportFailure("导入样片失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private var topBar: some View {
        HStack {
            Spacer()

            Button(action: viewModel.switchCamera) {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(.black.opacity(0.45), in: Circle())
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("切换摄像头")
            .disabled(viewModel.state == .capturing || viewModel.processingState.isProcessing)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 18) {
            zoomControl

            HStack {
                PhotosPicker(selection: $selectedSample, matching: .images) {
                    VStack(spacing: 4) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 20, weight: .semibold))
                        Text("样片复测")
                            .font(.caption2.weight(.medium))
                    }
                    .frame(width: 78, height: 58)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(viewModel.processingState.isProcessing)
                .accessibilityLabel("导入真实样片复测")

                Button(action: viewModel.capturePhoto) {
                    ZStack {
                        Circle()
                            .stroke(.white, lineWidth: 4)
                            .frame(width: 78, height: 78)

                        Circle()
                            .fill(.white)
                            .frame(width: 62, height: 62)
                    }
                }
                .accessibilityLabel("拍照")
                .disabled(viewModel.state != .ready || viewModel.processingState.isProcessing)

                Color.clear
                    .frame(width: 78, height: 58)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.bottom, 22)
    }

    private var zoomControl: some View {
        VStack(spacing: 8) {
            Text(String(format: "%.1f×", viewModel.zoomFactor))
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)

            if viewModel.maximumZoomFactor > 1.0 {
                Slider(
                    value: Binding(
                        get: { Double(viewModel.zoomFactor) },
                        set: { viewModel.setZoomFactor(CGFloat($0)) }
                    ),
                    in: 1.0...Double(viewModel.maximumZoomFactor),
                    step: 0.1
                )
                .tint(.yellow)
                .disabled(viewModel.state != .ready)
                .accessibilityLabel("相机倍率")
                .accessibilityValue(String(format: "%.1f 倍", viewModel.zoomFactor))
            } else {
                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(height: 4)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }

    private func processingOverlay(_ state: ProcessingState) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)

            VStack(spacing: 6) {
                Text(state.title)
                    .font(.headline)

                Text(state.subtitle)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.white.opacity(0.82))
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: 320)
        .background(.black.opacity(0.74), in: RoundedRectangle(cornerRadius: 8))
        .padding()
    }

    private func messageOverlay(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.system(size: 30, weight: .medium))

            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: 320)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .padding()
    }
}

#Preview {
    CameraView()
}

