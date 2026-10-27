import SwiftUI
import UIKit

struct PhotoPreviewView: View {
    let photo: CapturedPhoto
    let saveState: SaveState
    let onSave: () -> Void
    let onRetake: () -> Void

    @State private var selectedVersion: PhotoVersion = .edited
    @State private var selectedStageID: String?
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

            LinearGradient(
                colors: [.black.opacity(0.86), .clear, .clear, .black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                ZStack {
                    VStack(spacing: 1) {
                        Text("小苏相机")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                        Text(selectedStageID == nil ? selectedVersion.title : "处理阶段")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                    }

                    HStack(spacing: 10) {
                        Button(action: onRetake) {
                            Image(systemName: "xmark")
                                .font(.system(size: 17, weight: .bold))
                                .frame(width: 46, height: 46)
                                .background(.black.opacity(0.62), in: Circle())
                                .overlay {
                                    Circle().stroke(.white.opacity(0.16), lineWidth: 0.5)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("重拍")

                        Spacer()

                        Button {
                            showsDebugSummary.toggle()
                        } label: {
                            Image(systemName: showsDebugSummary ? "info.circle.fill" : "info.circle")
                                .font(.system(size: 19, weight: .semibold))
                                .frame(width: 46, height: 46)
                                .background(.black.opacity(0.62), in: Circle())
                                .overlay {
                                    Circle().stroke(.white.opacity(0.16), lineWidth: 0.5)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showsDebugSummary ? "隐藏成片信息" : "显示成片信息")

                        Button(action: onSave) {
                            ZStack {
                                Circle()
                                    .fill(.white)
                                    .frame(width: 46, height: 46)

                                if saveState.isSaving {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .tint(.black)
                                } else {
                                    Image(systemName: "square.and.arrow.down")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(.black)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            photo.isDiagnosticImport
                                ? "保存 A 原图、B 正式算法成片和可用的 C 参考候选"
                                : "保存原图和 AI 成片"
                        )
                        .disabled(saveState.isSaving)
                    }
                }
                .foregroundStyle(.white)

                versionSelector
                    .padding(.top, 14)

                Text(compareHint)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(.top, 9)

                Spacer()

                saveStatusPill

                if showsDebugSummary {
                    debugSummary
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    private var versionSelector: some View {
        HStack(spacing: 5) {
            ForEach(PhotoVersion.allCases) { version in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        selectedVersion = version
                        selectedStageID = nil
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: version.iconName)
                            .font(.system(size: 12, weight: .semibold))

                        Text(version.title)
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(selectedVersion == version && selectedStageID == nil ? .black : .white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(
                        selectedVersion == version && selectedStageID == nil
                            ? Color.white
                            : Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 13)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看\(version.title)")
                .accessibilityValue(
                    selectedVersion == version && selectedStageID == nil ? "已选择" : ""
                )
            }
        }
        .padding(5)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.18), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("照片版本")
    }

    private var displayedImage: UIImage? {
        if isPressingOriginal {
            return photo.originalImage
        }

        if
            let selectedStageID,
            let preview = photo.processingStagePreviews.first(where: { $0.id == selectedStageID })
        {
            return UIImage(data: preview.imageData)
        }

        switch selectedVersion {
        case .original:
            return photo.originalImage
        case .edited:
            return photo.editedImage
        case .difference:
            return photo.differenceImage
        }
    }

    private var compareHint: String {
        if let selectedStageID {
            return "正在查看处理阶段：\(selectedStageID)；长按仍可查看原图"
        }

        switch selectedVersion {
        case .edited:
            return "长按照片可临时查看原图"
        case .original:
            return "已保留未经处理的原图"
        case .difference:
            return "差异图已放大 5 倍；越亮代表像素变化越明显"
        }
    }

    @ViewBuilder
    private var saveStatusPill: some View {
        if let message = saveState.message {
            Text(message)
                .font(.callout)
                .foregroundStyle(saveState.textColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.7), in: Capsule())
                .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private var debugSummary: some View {
        let diagnostics = PhotoDiagnostics(photo: photo)

        if diagnostics.isEmpty {
            debugPill("暂无成片诊断信息")
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if !photo.processingStagePreviews.isEmpty {
                        stagePreviewStrip
                    }

                    ForEach(diagnostics.sections) { section in
                        diagnosticSection(section)
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 280)
            .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.white.opacity(0.14), lineWidth: 0.5)
            }
        }
    }

    private var stagePreviewStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("逐阶段像素预览")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(photo.processingStagePreviews) { preview in
                        Button {
                            selectedVersion = .edited
                            selectedStageID = selectedStageID == preview.id ? nil : preview.id
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                if let image = UIImage(data: preview.imageData) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 82, height: 62)
                                        .clipped()
                                }

                                Text(preview.name)
                                    .font(.system(size: 9, weight: .medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(
                                selectedStageID == preview.id
                                    ? Color.blue.opacity(0.7)
                                    : Color.white.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                        }
                    }
                }
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

    private func diagnosticSection(_ section: PhotoDiagnosticSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(section.items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Text(item.label)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.58))
                            .frame(width: 62, alignment: .leading)

                        Text(item.value)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.86))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
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
        case .idle, .saving, .saved, .savedDiagnosticABC:
            return .white
        case .failed:
            return .red
        }
    }
}

private enum PhotoVersion: String, CaseIterable, Identifiable {
    case original
    case edited
    case difference

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .original:
            return "原图"
        case .edited:
            return "AI 成片"
        case .difference:
            return "差异"
        }
    }

    var iconName: String {
        switch self {
        case .original:
            return "photo"
        case .edited:
            return "wand.and.stars"
        case .difference:
            return "circle.lefthalf.filled"
        }
    }
}

