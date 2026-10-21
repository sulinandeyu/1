import Foundation

final class PhotographyDecisionEngine {
    func makeDecision(
        for analysis: PhotoAnalysis,
        problems: PhotoProblemReport
    ) -> PhotographyDecision {
        let strategy = SceneStrategy.choose(for: analysis, problems: problems)
        var recipe = AutomaticEditingRecipe.naturalEnhancement
        var actions: [PhotographyAction] = []

        applyExposureStrategy(
            analysis: analysis,
            problems: problems,
            recipe: &recipe,
            actions: &actions
        )
        applyContrastStrategy(
            problems: problems,
            recipe: &recipe,
            actions: &actions
        )
        applyColorStrategy(
            problems: problems,
            recipe: &recipe,
            actions: &actions
        )
        applySceneStrategy(
            analysis: analysis,
            strategy: strategy,
            recipe: &recipe,
            actions: &actions
        )
        applySkyStrategy(
            analysis: analysis,
            strategy: strategy,
            problems: problems,
            recipe: &recipe,
            actions: &actions
        )
        applyProblemSafetyLimits(problems: problems, recipe: &recipe)

        if actions.isEmpty {
            actions.append(
                PhotographyAction(
                    title: "保留原片观感",
                    reason: "照片曝光、层次和色彩已经均衡，正确处理是避免不必要的滤镜和提亮。"
                )
            )
        }

        return PhotographyDecision(
            sceneStrategy: strategy,
            aestheticTarget: aestheticTarget(for: strategy),
            intent: intent(for: strategy),
            actions: actions,
            recipe: recipe.clamped()
        )
    }

    private func applyExposureStrategy(
        analysis: PhotoAnalysis,
        problems: PhotoProblemReport,
        recipe: inout AutomaticEditingRecipe,
        actions: inout [PhotographyAction]
    ) {
        if problems.contains(.underexposed) {
            if analysis.semanticScene == .night {
                recipe.exposureEV += 0.05
                recipe.shadowAmount = max(recipe.shadowAmount, 0.12)
                recipe.noiseReductionAmount = max(recipe.noiseReductionAmount, 0.04)
            } else {
                recipe.exposureEV += problems.severity(of: .underexposed) == .strong ? 0.18 : 0.14
                recipe.highlightAmount = min(recipe.highlightAmount, 0.86)
                recipe.shadowAmount = max(recipe.shadowAmount, 0.3)
                recipe.noiseReductionAmount = max(recipe.noiseReductionAmount, 0.018)
            }
            actions.append(
                PhotographyAction(
                    title: analysis.semanticScene == .night ? "保留夜景氛围" : "有控制地提亮",
                    reason: analysis.semanticScene == .night
                        ? "画面较暗但属于夜景，只轻提可用暗部并加强降噪，不把夜晚修成白天。"
                        : "画面整体偏暗，适度提亮曝光和阴影，同时避免灰雾感。"
                )
            )
        } else if problems.contains(.overexposed) {
            recipe.exposureEV -= problems.severity(of: .overexposed) == .strong ? 0.14 : 0.1
            recipe.highlightAmount = min(recipe.highlightAmount, 0.5)
            recipe.contrast = max(recipe.contrast, 1.02)
            actions.append(
                PhotographyAction(
                    title: "保护高光",
                    reason: "画面偏亮，应该优先恢复高光细节，而不是继续整体提亮。"
                )
            )
        }

        if problems.contains(.clippedHighlights) {
            recipe.highlightAmount = min(
                recipe.highlightAmount,
                problems.severity(of: .clippedHighlights) == .strong ? 0.42 : 0.58
            )
            actions.append(
                PhotographyAction(
                    title: "恢复亮部过渡",
                    reason: "问题诊断发现高光区域占比偏高，进一步收拢高光，避免天空和灯光失去细节。"
                )
            )
        }

        if problems.contains(.blockedShadows) && analysis.semanticScene != .night {
            recipe.shadowAmount = max(
                recipe.shadowAmount,
                problems.severity(of: .blockedShadows) == .strong ? 0.24 : 0.14
            )
            actions.append(
                PhotographyAction(
                    title: "打开有效暗部",
                    reason: "暗部堵塞比例偏高；只恢复可用层次，夜景和逆光主体仍由场景策略限制强度。"
                )
            )
        }

        if problems.contains(.noiseRisk) {
            recipe.noiseReductionAmount = max(
                recipe.noiseReductionAmount,
                problems.severity(of: .noiseRisk) == .strong ? 0.05 : 0.03
            )
            actions.append(
                PhotographyAction(
                    title: "控制暗部噪点",
                    reason: "问题诊断预判暗部提亮会暴露噪点，因此使用克制降噪并限制锐化。"
                )
            )
        }
    }

    private func applyContrastStrategy(
        problems: PhotoProblemReport,
        recipe: inout AutomaticEditingRecipe,
        actions: inout [PhotographyAction]
    ) {
        if problems.contains(.flatContrast) {
            recipe.contrast += 0.055
            recipe.vibrance += 0.05
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.3)
            recipe.sharpeningAmount += 0.07
            actions.append(
                PhotographyAction(
                    title: "增加层次",
                    reason: "画面层次偏平，适度增加对比和细节会更有立体感。"
                )
            )
        } else if problems.contains(.harshContrast) {
            recipe.contrast -= 0.03
            recipe.highlightAmount = min(recipe.highlightAmount, 0.58)
            recipe.shadowAmount = max(recipe.shadowAmount, 0.12)
            actions.append(
                PhotographyAction(
                    title: "柔化对比",
                    reason: "场景对比已经较强，成片应尽量保留高光和暗部细节。"
                )
            )
        }
    }

    private func applyColorStrategy(
        problems: PhotoProblemReport,
        recipe: inout AutomaticEditingRecipe,
        actions: inout [PhotographyAction]
    ) {
        if problems.contains(.coolCast) {
            recipe.temperatureShift += 140
            actions.append(
                PhotographyAction(
                    title: "校正偏冷色温",
                    reason: "问题诊断确认冷色不是当前场景的合理氛围，轻微提高色温而不增加全局饱和度。"
                )
            )
        } else if problems.contains(.warmCast) {
            recipe.temperatureShift -= 80
            recipe.saturation -= 0.008
            actions.append(
                PhotographyAction(
                    title: "控制暖色偏移",
                    reason: "问题诊断确认暖色不是日落或食物的记忆色，轻微回正色温，避免黄色滤镜感。"
                )
            )
        } else if problems.contains(.greenCast) {
            recipe.tintShift += 5
            recipe.saturation -= 0.01
            actions.append(
                PhotographyAction(
                    title: "控制偏绿",
                    reason: "问题诊断排除自然风景记忆色后确认偏绿，向洋红方向轻微校正。"
                )
            )
        }

        if problems.contains(.oversaturated) {
            recipe.saturation = min(recipe.saturation, 0.96)
            recipe.vibrance = min(recipe.vibrance, 0.04)
            actions.append(
                PhotographyAction(
                    title: "恢复真实色彩",
                    reason: "原片平均饱和度过高，降低全局饱和度并限制后续自然饱和增强。"
                )
            )
        }
    }

    private func applyProblemSafetyLimits(
        problems: PhotoProblemReport,
        recipe: inout AutomaticEditingRecipe
    ) {
        if problems.contains(.clippedHighlights) {
            recipe.highlightAmount = min(recipe.highlightAmount, 0.58)
        }

        if problems.contains(.oversaturated) {
            recipe.saturation = min(recipe.saturation, 0.96)
            recipe.vibrance = min(recipe.vibrance, 0.04)
        }

        if problems.contains(.noiseRisk) {
            recipe.sharpeningAmount = min(recipe.sharpeningAmount, 0.16)
        }
    }

    private func applySkyStrategy(
        analysis: PhotoAnalysis,
        strategy: SceneStrategy,
        problems: PhotoProblemReport,
        recipe: inout AutomaticEditingRecipe,
        actions: inout [PhotographyAction]
    ) {
        guard analysis.skyMask != nil else { return }

        switch strategy {
        case .landscape, .brightOutdoor, .highContrast:
            recipe.skyExposureEV = problems.contains(.clippedHighlights) ? -0.12 : -0.04
            recipe.skyHighlightAmount = problems.contains(.clippedHighlights) ? 0.52 : 0.72
            recipe.skySaturation = problems.contains(.oversaturated) ? 0.98 : 1.035
        case .sunset:
            recipe.skyExposureEV = -0.08
            recipe.skyHighlightAmount = 0.5
            recipe.skySaturation = problems.contains(.oversaturated) ? 0.98 : 1.025
        case .backlitPortrait:
            recipe.skyExposureEV = -0.09
            recipe.skyHighlightAmount = 0.54
            recipe.skySaturation = 1.0
        default:
            return
        }

        actions.append(
            PhotographyAction(
                title: "分区保护天空",
                reason: "离线语义分割确认天空约占画面 \(Int((analysis.skyCoverage * 100).rounded()))%，只在天空蒙版内恢复高光和层次，不压暗人物或地面。"
            )
        )
    }

    private func applySceneStrategy(
        analysis: PhotoAnalysis,
        strategy: SceneStrategy,
        recipe: inout AutomaticEditingRecipe,
        actions: inout [PhotographyAction]
    ) {
        switch strategy {
        case .portrait:
            recipe.saturation = min(recipe.saturation, 1.01)
            recipe.vibrance = min(max(recipe.vibrance, 0.06), 0.12)
            recipe.sharpeningAmount = min(max(recipe.sharpeningAmount, 0.1), 0.16)
            recipe.noiseReductionAmount = max(recipe.noiseReductionAmount, 0.012)
            recipe.skinTextureProtection = 0.56
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.16)
            if let faceLuminance = analysis.faceAverageLuminance, faceLuminance < 0.44 {
                let correction = min(max((0.46 - faceLuminance) * 0.9, 0.06), 0.24)
                recipe.subjectExposureEV = analysis.personMask == nil
                    ? 0.0
                    : min(max(correction * 0.36, 0.03), 0.09)
                recipe.faceExposureEV = correction
            } else if analysis.faceAverageLuminance == nil,
                      analysis.averageLuminance < 0.4 {
                recipe.subjectExposureEV = analysis.personMask == nil ? 0.0 : 0.04
                recipe.faceExposureEV = 0.08
            }
            actions.append(
                PhotographyAction(
                    title: "保护肤色与皮肤纹理",
                    reason: "检测到人脸，因此限制饱和度、锐化和降噪强度，只在画面偏暗时进行轻微局部补光。"
                )
            )
        case .backlitPortrait:
            recipe.exposureEV = min(recipe.exposureEV, -0.04)
            recipe.highlightAmount = min(recipe.highlightAmount, 0.5)
            recipe.shadowAmount = min(max(recipe.shadowAmount, 0.12), 0.28)
            recipe.saturation = min(recipe.saturation, 1.01)
            recipe.vibrance = min(max(recipe.vibrance, 0.06), 0.12)
            recipe.sharpeningAmount = min(max(recipe.sharpeningAmount, 0.1), 0.16)
            recipe.skinTextureProtection = 0.62
            let faceLuminance = analysis.faceAverageLuminance ?? analysis.averageLuminance
            let backgroundLuminance = analysis.backgroundAverageLuminance ?? analysis.averageLuminance
            let faceDeficit = max(0, 0.48 - faceLuminance)
            let backgroundSeparation = max(0, backgroundLuminance - faceLuminance)
            recipe.subjectExposureEV = analysis.personMask == nil
                ? 0.0
                : min(max(0.1 + (backgroundSeparation * 0.42), 0.1), 0.26)
            recipe.faceExposureEV = min(max(0.16 + (faceDeficit * 0.9), 0.16), 0.4)
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.22)
            actions.append(
                PhotographyAction(
                    title: "保天空并单独补亮人物",
                    reason: "分区测光确认人脸暗于背景；根据人脸亮度差动态计算补光，同时压住背景高光。"
                )
            )
        case .landscape:
            recipe.highlightAmount = min(recipe.highlightAmount, 0.72)
            recipe.shadowAmount = max(recipe.shadowAmount, 0.14)
            recipe.contrast += 0.035
            recipe.saturation += 0.012
            recipe.vibrance += 0.14
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.42)
            recipe.sharpeningAmount = max(recipe.sharpeningAmount, 0.2)
            actions.append(
                PhotographyAction(
                    title: "建立风景层次",
                    reason: "按风景场景保护亮部和云层，适度打开暗部，并增强中间调层次与自然色彩。"
                )
            )
        case .night:
            recipe.highlightAmount = min(recipe.highlightAmount, 0.54)
            recipe.shadowAmount = min(max(recipe.shadowAmount, 0.08), 0.18)
            recipe.contrast = max(recipe.contrast, 1.035)
            recipe.saturation = min(recipe.saturation, 0.995)
            recipe.vibrance = max(recipe.vibrance, 0.1)
            recipe.noiseReductionAmount = max(recipe.noiseReductionAmount, 0.045)
            recipe.sharpeningAmount = min(max(recipe.sharpeningAmount, 0.1), 0.16)
            recipe.temperatureShift -= 80
            recipe.tintShift += 2
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.34)
            recipe.vignetteIntensity = 0.1
            actions.append(
                PhotographyAction(
                    title: "控制灯光高光与噪点",
                    reason: "夜景不粗暴拉亮暗部，优先保住灯牌和路灯高光，适度降噪并维持冷暖电影感。"
                )
            )
        case .food:
            recipe.temperatureShift += 160
            recipe.contrast += 0.03
            recipe.saturation += 0.02
            recipe.vibrance += 0.12
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.28)
            recipe.sharpeningAmount = max(recipe.sharpeningAmount, 0.18)
            recipe.vignetteIntensity = 0.06
            recipe.subjectExposureEV = analysis.salientSubjectMask == nil ? 0.0 : 0.04
            actions.append(
                PhotographyAction(
                    title: "恢复食物质感与自然暖色",
                    reason: "轻微升温并增强局部观感，但限制饱和度，避免食物颜色失真。"
                )
            )
        case .architecture:
            recipe.highlightAmount = min(recipe.highlightAmount, 0.76)
            recipe.contrast += 0.045
            recipe.vibrance += 0.06
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.38)
            recipe.sharpeningAmount = max(recipe.sharpeningAmount, 0.24)
            actions.append(
                PhotographyAction(
                    title: "强化结构与材质",
                    reason: "建筑场景采用克制色彩、清晰边缘和受控高光，突出线条而不是套重滤镜。"
                )
            )
        case .sunset:
            recipe.exposureEV = min(recipe.exposureEV, -0.06)
            recipe.highlightAmount = min(recipe.highlightAmount, 0.48)
            recipe.shadowAmount = min(recipe.shadowAmount, 0.12)
            recipe.temperatureShift += 220
            recipe.saturation += 0.018
            recipe.vibrance += 0.12
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.28)
            actions.append(
                PhotographyAction(
                    title: "保护太阳高光与暖色渐变",
                    reason: "日落场景不做强 HDR，压住太阳附近高光并保留自然暖色过渡。"
                )
            )
        case .indoor:
            recipe.highlightAmount = min(recipe.highlightAmount, 0.82)
            recipe.shadowAmount = max(recipe.shadowAmount, 0.12)
            recipe.temperatureShift += 80
            recipe.tintShift += 2
            recipe.noiseReductionAmount = max(recipe.noiseReductionAmount, 0.018)
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.16)
            actions.append(
                PhotographyAction(
                    title: "平衡室内色温和明暗",
                    reason: "室内场景轻微修正混合光偏色，并温和打开暗部，不制造假 HDR。"
                )
            )
        case .lowLight:
            recipe.noiseReductionAmount = max(recipe.noiseReductionAmount, 0.03)
        case .brightOutdoor:
            recipe.highlightAmount = min(recipe.highlightAmount, 0.52)
        case .flatScene:
            recipe.contrast += 0.018
        case .highContrast:
            recipe.shadowAmount += 0.04
        case .general:
            break
        }
    }

    private func intent(for strategy: SceneStrategy) -> String {
        switch strategy {
        case .portrait:
            return "在不改变人物身份和皮肤纹理的前提下，让人物受光更自然。"
        case .backlitPortrait:
            return "保护明亮背景，同时仅对人物进行符合光向的柔和补光。"
        case .landscape:
            return "参考经典风景摄影的动态范围和层次原则，让天空、地面与色彩保持自然。"
        case .night:
            return "保留夜晚和环境灯光氛围，同时控制高光、噪点和暗部层次。"
        case .food:
            return "让食物色彩自然诱人，并保留纹理与真实白平衡。"
        case .architecture:
            return "突出建筑线条、材质与明暗秩序，保持色彩克制。"
        case .sunset:
            return "保护太阳高光和暖色渐变，避免过度 HDR。"
        case .indoor:
            return "校正室内混合光色温，让暗部和主体看起来自然。"
        case .lowLight:
            return "提亮暗部，同时控制噪点和不自然的亮度。"
        case .brightOutdoor:
            return "恢复亮部和高光细节，同时保留干净的户外观感。"
        case .flatScene:
            return "增加画面层次，但避免明显滤镜感。"
        case .highContrast:
            return "在高对比场景中尽量保留细节。"
        case .general:
            return "在保留原始观感的基础上做轻量摄影润色。"
        }
    }

    private func aestheticTarget(for strategy: SceneStrategy) -> AestheticTarget {
        switch strategy {
        case .portrait: return .naturalPortrait
        case .backlitPortrait: return .protectedBacklightPortrait
        case .landscape, .brightOutdoor, .flatScene, .highContrast: return .luminousLandscape
        case .night, .lowLight: return .cinematicNight
        case .food: return .appetizingNatural
        case .architecture: return .architecturalClarity
        case .sunset: return .warmSunset
        case .indoor: return .balancedIndoor
        case .general: return .neutral
        }
    }

}

