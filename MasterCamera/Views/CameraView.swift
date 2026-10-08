import SwiftUI

struct CameraView: View {
    @StateObject private var viewModel = CameraViewModel()

    var body: some View {
        ZStack {
            CameraPreview(
                session: viewModel.cameraManager.session,
                onTapToFocus: viewModel.focusAndExpose
            )
            .ignoresSafeArea()

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
        .padding(.bottom, 22)
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

