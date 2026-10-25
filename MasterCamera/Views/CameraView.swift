import PhotosUI
import SwiftUI

struct CameraView: View {
    @StateObject private var viewModel = CameraViewModel()
    @State private var selectedSample: PhotosPickerItem?

    var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.height < 720

            ZStack {
                Color(red: 0.025, green: 0.027, blue: 0.032)
                    .ignoresSafeArea()

                VStack(spacing: isCompact ? 8 : 12) {
                    topBar
                        .padding(.horizontal, 18)

                    viewfinder
                        .frame(maxWidth: 620, maxHeight: .infinity)
                        .layoutPriority(1)
                        .padding(.horizontal, isCompact ? 10 : 14)

                    controlDeck(isCompact: isCompact)
                        .padding(.horizontal, 14)
                }
                .padding(.top, isCompact ? 4 : 8)
                .padding(.bottom, isCompact ? 6 : 10)

                if let message = viewModel.state.message ?? viewModel.errorMessage {
                    messageOverlay(message)
                }

                if viewModel.processingState.isProcessing {
                    processingOverlay(viewModel.processingState)
                }
            }
        }
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
            VStack(alignment: .leading, spacing: 3) {
                Text("小苏相机")
                    .font(.system(size: 20, weight: .bold, design: .rounded))

                HStack(spacing: 6) {
                    Circle()
                        .fill(cameraStatusColor)
                        .frame(width: 6, height: 6)

                    Text(cameraStatusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                }
            }
            .foregroundStyle(.white)

            Spacer()

            Label("AI 自动", systemImage: "sparkles")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 11)
                .frame(height: 34)
                .background(Color.white.opacity(0.08), in: Capsule())
                .overlay {
                    Capsule().stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                }

            Button(action: viewModel.switchCamera) {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(Color.white.opacity(0.1), in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                    }
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换摄像头")
            .disabled(viewModel.state == .capturing || viewModel.processingState.isProcessing)
        }
        .frame(height: 52)
    }

    private var viewfinder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black)

            CameraPreview(
                session: viewModel.cameraManager.session,
                onTapToFocus: viewModel.focusAndExpose
            )

            LinearGradient(
                colors: [Color.black.opacity(0.26), .clear, Color.black.opacity(0.18)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            ViewfinderGrid()
                .stroke(Color.white.opacity(0.19), lineWidth: 0.5)
                .allowsHitTesting(false)

            VStack {
                HStack {
                    Label("智能取景", systemImage: "viewfinder")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(.black.opacity(0.42), in: Capsule())

                    Spacer()
                }

                Spacer()

                Text("轻触画面进行对焦与测光")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.66))
                    .padding(.horizontal, 10)
                    .frame(height: 27)
                    .background(.black.opacity(0.38), in: Capsule())
            }
            .padding(13)
            .allowsHitTesting(false)
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("相机取景画面")
    }

    private func controlDeck(isCompact: Bool) -> some View {
        VStack(spacing: isCompact ? 8 : 12) {
            zoomControl

            HStack(alignment: .center) {
                PhotosPicker(selection: $selectedSample, matching: .images) {
                    controlButton(icon: "photo.on.rectangle.angled", title: "相册")
                }
                .disabled(viewModel.processingState.isProcessing)
                .accessibilityLabel("从相册导入照片")

                Spacer()

                Button(action: viewModel.capturePhoto) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.26), lineWidth: 2)
                            .frame(width: isCompact ? 72 : 78, height: isCompact ? 72 : 78)

                        Circle()
                            .fill(Color.white)
                            .frame(width: isCompact ? 60 : 66, height: isCompact ? 60 : 66)

                        Circle()
                            .stroke(Color.black.opacity(0.12), lineWidth: 1)
                            .frame(width: isCompact ? 58 : 64, height: isCompact ? 58 : 64)
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("拍照")
                .disabled(viewModel.state != .ready || viewModel.processingState.isProcessing)

                Spacer()

                controlButton(icon: "wand.and.stars", title: "自动")
                .foregroundStyle(Color(red: 0.76, green: 0.88, blue: 1))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("自动场景优化已开启")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, isCompact ? 10 : 13)
        .padding(.bottom, isCompact ? 10 : 14)
        .background(
            Color(red: 0.055, green: 0.06, blue: 0.07),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.6)
        }
    }

    private func controlButton(icon: String, title: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .frame(height: 22)

            Text(title)
                .font(.system(size: 10, weight: .semibold))
        }
        .frame(width: 58, height: 50)
        .foregroundStyle(.white.opacity(0.88))
        .contentShape(Rectangle())
    }

    private var zoomControl: some View {
        HStack(spacing: 12) {
            Image(systemName: "minus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.38))

            if viewModel.maximumZoomFactor > 1.0 {
                Slider(
                    value: Binding(
                        get: { Double(viewModel.zoomFactor) },
                        set: { viewModel.setZoomFactor(CGFloat($0)) }
                    ),
                    in: 1.0...Double(viewModel.maximumZoomFactor),
                    step: 0.1
                )
                .tint(Color.white.opacity(0.76))
                .disabled(viewModel.state != .ready)
                .accessibilityLabel("相机倍率")
                .accessibilityValue(String(format: "%.1f 倍", viewModel.zoomFactor))
            } else {
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: 3)
                    .accessibilityHidden(true)
            }

            Text(String(format: "%.1f×", viewModel.zoomFactor))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 40)

            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.38))
        }
        .frame(height: 28)
    }

    private var cameraStatusText: String {
        switch viewModel.state {
        case .idle:
            return "正在准备"
        case .checkingPermission:
            return "检查相机权限"
        case .permissionDenied:
            return "需要相机权限"
        case .configuring:
            return "正在启动镜头"
        case .ready:
            return "摄影智能已就绪"
        case .capturing:
            return "正在拍摄"
        case .failed:
            return "相机暂不可用"
        }
    }

    private var cameraStatusColor: Color {
        switch viewModel.state {
        case .ready:
            return Color(red: 0.35, green: 0.86, blue: 0.58)
        case .permissionDenied, .failed:
            return Color(red: 1, green: 0.42, blue: 0.4)
        default:
            return Color(red: 1, green: 0.76, blue: 0.32)
        }
    }

    private func processingOverlay(_ state: ProcessingState) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)
                .tint(.white)

            VStack(spacing: 6) {
                Text(state.title)
                    .font(.headline)

                Text(state.subtitle)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 310)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
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
        .padding(22)
        .frame(maxWidth: 310)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        .padding()
    }
}

private struct ViewfinderGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for fraction in [1.0 / 3.0, 2.0 / 3.0] {
            let x = rect.minX + rect.width * fraction
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))

            let y = rect.minY + rect.height * fraction
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

#Preview {
    CameraView()
}

