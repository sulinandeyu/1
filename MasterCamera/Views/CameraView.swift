import SwiftUI

struct CameraView: View {
    @StateObject private var viewModel = CameraViewModel()

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
                Spacer()

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

                Spacer()
            }
        }
        .padding(.bottom, 22)
    }

    private var zoomControl: some View {
        VStack(spacing: 8) {
            Text(String(format: "%.1f×", viewModel.zoomFactor))
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)

            Slider(
                value: Binding(
                    get: { Double(viewModel.zoomFactor) },
                    set: { viewModel.setZoomFactor(CGFloat($0)) }
                ),
                in: 1.0...Double(max(viewModel.maximumZoomFactor, 1.0)),
                step: 0.1
            )
            .tint(.yellow)
            .disabled(viewModel.maximumZoomFactor <= 1.0 || viewModel.state != .ready)
            .accessibilityLabel("相机倍率")
            .accessibilityValue(String(format: "%.1f 倍", viewModel.zoomFactor))
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

