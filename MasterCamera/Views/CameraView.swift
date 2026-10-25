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
            .ignoresSafeArea()

            LinearGradient(
                colors: [.black.opacity(0.62), .clear, .black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 12)

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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("小苏相机")
                    .font(.system(size: 17, weight: .bold, design: .rounded))

                Text("智能摄影后期")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(.black.opacity(0.46), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.14), lineWidth: 0.5)
            }

            Spacer()

            Button(action: viewModel.switchCamera) {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(.black.opacity(0.46), in: Circle())
                    .overlay {
                        Circle()
                            .stroke(.white.opacity(0.14), lineWidth: 0.5)
                    }
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换摄像头")
            .disabled(viewModel.state == .capturing || viewModel.processingState.isProcessing)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            zoomControl

            HStack(alignment: .center) {
                PhotosPicker(selection: $selectedSample, matching: .images) {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 19, weight: .semibold))
                        Text("导入照片")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .frame(width: 82, height: 62)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(.white.opacity(0.14), lineWidth: 0.5)
                    }
                }
                .disabled(viewModel.processingState.isProcessing)
                .accessibilityLabel("导入照片")

                Spacer()

                Button(action: viewModel.capturePhoto) {
                    ZStack {
                        Circle()
                            .fill(.black.opacity(0.18))
                            .frame(width: 88, height: 88)

                        Circle()
                            .stroke(.white, lineWidth: 4)
                            .frame(width: 82, height: 82)

                        Circle()
                            .fill(.white)
                            .frame(width: 66, height: 66)

                        Circle()
                            .stroke(.black.opacity(0.08), lineWidth: 1)
                            .frame(width: 64, height: 64)
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("拍照")
                .disabled(viewModel.state != .ready || viewModel.processingState.isProcessing)

                Spacer()

                VStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 18, weight: .semibold))
                    Text("自动优化")
                        .font(.system(size: 11, weight: .semibold))
                }
                .frame(width: 82, height: 62)
                .foregroundStyle(.white.opacity(0.9))
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(.white.opacity(0.14), lineWidth: 0.5)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("自动场景优化已开启")
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var zoomControl: some View {
        VStack(spacing: 9) {
            HStack {
                Label("自动场景", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))

                Spacer()

                Text(String(format: "%.1f×", viewModel.zoomFactor))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }

            if viewModel.maximumZoomFactor > 1.0 {
                Slider(
                    value: Binding(
                        get: { Double(viewModel.zoomFactor) },
                        set: { viewModel.setZoomFactor(CGFloat($0)) }
                    ),
                    in: 1.0...Double(viewModel.maximumZoomFactor),
                    step: 0.1
                )
                .tint(.white)
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
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.14), lineWidth: 0.5)
        }
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
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(.white.opacity(0.14), lineWidth: 0.5)
        }
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
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(.white.opacity(0.14), lineWidth: 0.5)
        }
        .padding()
    }
}

#Preview {
    CameraView()
}

