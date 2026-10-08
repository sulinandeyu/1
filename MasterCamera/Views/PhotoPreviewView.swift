import SwiftUI
import UIKit

struct PhotoPreviewView: View {
    let photo: CapturedPhoto
    let saveState: SaveState
    let onSave: () -> Void
    let onRetake: () -> Void

    @State private var selectedVersion: PhotoVersion = .edited
    @State private var isPressingOriginal = false
    @State private var showsDebugSummary = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = displayedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
                    .overlay(alignment: .top) {
                        if isPressingOriginal {
                            versionBadge("原图")
                                .padding(.top, 86)
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                isPressingOriginal = true
                            }
                            .onEnded { _ in
                                isPressingOriginal = false
                            }
                    )
            } else {
                Text("无法预览照片")
                    .foregroundStyle(.white)
            }

            VStack {
                HStack {
                    Button(action: onRetake) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .bold))
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    .accessibilityLabel("重拍")

                    Spacer()

                    Button {
                        showsDebugSummary.toggle()
                    } label: {
                        Image(systemName: showsDebugSummary ? "info.circle.fill" : "info.circle")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    .accessibilityLabel(showsDebugSummary ? "隐藏成片信息" : "显示成片信息")

                    Button(action: onSave) {
                        ZStack {
                            Circle()
                                .fill(.black.opacity(0.5))
                                .frame(width: 44, height: 44)

                            if saveState.isSaving {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.white)
                            } else {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 18, weight: .bold))
                            }
                        }
                    }
                    .accessibilityLabel("保存原图和 AI 成片")
                    .disabled(saveState.isSaving)
                }
                .foregroundStyle(.white)

                Picker("照片版本", selection: $selectedVersion) {
                    ForEach(PhotoVersion.allCases) { version in
                        Text(version.title).tag(version)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.top, 16)
                .accessibilityLabel("照片版本")

                Text(compareHint)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.top, 8)

                Spacer()

                saveStatusPill

                if showsDebugSummary {
                    debugSummary
                }
            }
            .padding(20)
        }
    }

    private var displayedImage: UIImage? {
        if isPressingOriginal {
            return photo.originalImage
        }

        switch selectedVersion {
        case .original:
            return photo.originalImage
        case .edited:
            return photo.editedImage
        }
    }

    private var compareHint: String {
        selectedVersion == .edited ? "长按照片可临时查看原图" : "已保留未经处理的原图"
    }

    @ViewBuilder
    private var saveStatusPill: some View {
        if let message = saveState.message {
            Text(message)
                .font(.callout)
                .foregroundStyle(saveState.textColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private var debugSummary: some View {
        VStack(spacing: 8) {
            if let analysis = photo.analysis {
                debugPill(analysis.summaryText)
            }

            if let decision = photo.decision {
                debugPill(decision.summaryText, lineLimit: 2)
            }

            if let qualityCheck = photo.qualityCheck {
                debugPill(qualityCheck.summaryText, color: qualityCheck.statusTextColor)
            }
        }
    }

    private func debugPill(
        _ text: String,
        color: Color = .white.opacity(0.86),
        lineLimit: Int = 1
    ) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .lineLimit(lineLimit)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func versionBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.black.opacity(0.58), in: Capsule())
    }
}

private extension SaveState {
    var textColor: Color {
        switch self {
        case .idle, .saving, .saved:
            return .white
        case .failed:
            return .red
        }
    }
}

private extension QualityCheckResult {
    var statusTextColor: Color {
        switch status {
        case .passed:
            return .white.opacity(0.86)
        case .warning:
            return .yellow
        case .failed:
            return .red
        }
    }
}

private extension PhotoAnalysis {
    var summaryText: String {
        let faces = faceCount == 1 ? "1 张人脸" : "\(faceCount) 张人脸"
        return "\(exposureProfile.title) · \(contrastProfile.title) · \(colorCast.title) · \(faces)"
    }
}

private extension ExposureProfile {
    var title: String {
        switch self {
        case .underexposed:
            return "偏暗"
        case .balanced:
            return "曝光均衡"
        case .overexposed:
            return "偏亮"
        }
    }
}

private extension ContrastProfile {
    var title: String {
        switch self {
        case .flat:
            return "层次偏平"
        case .balanced:
            return "对比均衡"
        case .highContrast:
            return "高对比"
        }
    }
}

private extension ColorCast {
    var title: String {
        switch self {
        case .cool:
            return "偏冷"
        case .neutral:
            return "色彩自然"
        case .warm:
            return "偏暖"
        case .green:
            return "偏绿"
        }
    }
}

private enum PhotoVersion: String, CaseIterable, Identifiable {
    case original
    case edited

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .original:
            return "原图"
        case .edited:
            return "AI 成片"
        }
    }
}

