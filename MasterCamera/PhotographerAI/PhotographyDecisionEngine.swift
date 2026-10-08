import Foundation

final class PhotographyDecisionEngine {
    func makeDecision(for analysis: PhotoAnalysis) -> PhotographyDecision {
        let strategy = SceneStrategy.choose(for: analysis)
        var recipe = AutomaticEditingRecipe.naturalEnhancement
        var actions: [PhotographyAction] = []

        applyExposureStrategy(
            analysis: analysis,
            recipe: &recipe,
            actions: &actions
        )
        applyContrastStrategy(
            analysis: analysis,
            recipe: &recipe,
            actions: &actions
        )
        applyColorStrategy(
            analysis: analysis,
            recipe: &recipe,
            actions: &actions
        )
        applySceneStrategy(
            strategy: strategy,
            recipe: &recipe,
            actions: &actions
        )

        if actions.isEmpty {
            actions.append(
                PhotographyAction(
                    title: "轻微润色",
                    reason: "照片整体已经比较均衡，因此只做保守增强。"
                )
            )
        }

        return PhotographyDecision(
            sceneStrategy: strategy,
            intent: intent(for: strategy),
            actions: actions,
            recipe: recipe.clamped()
        )
    }

    private func applyExposureStrategy(
        analysis: PhotoAnalysis,
        recipe: inout AutomaticEditingRecipe,
        actions: inout [PhotographyAction]
    ) {
        switch analysis.exposureProfile {
        case .underexposed:
            recipe.exposureEV = 0.22
            recipe.highlightAmount = 0.82
            recipe.shadowAmount = 0.54
            recipe.noiseReductionAmount = 0.028
            actions.append(
                PhotographyAction(
                    title: "提升曝光",
                    reason: "画面偏暗，需要有控制地提亮阴影和整体曝光。"
                )
            )
        case .balanced:
            break
        case .overexposed:
            recipe.exposureEV = -0.12
            recipe.highlightAmount = 0.46
            recipe.shadowAmount = 0.24
            recipe.contrast = 1.025
            actions.append(
                PhotographyAction(
                    title: "保护高光",
                    reason: "画面偏亮，应该优先恢复高光细节，而不是继续整体提亮。"
                )
            )
        }
    }

    private func applyContrastStrategy(
        analysis: PhotoAnalysis,
        recipe: inout AutomaticEditingRecipe,
        actions: inout [PhotographyAction]
    ) {
        switch analysis.contrastProfile {
        case .flat:
            recipe.contrast += 0.055
            recipe.vibrance += 0.06
            recipe.sharpeningAmount += 0.08
            actions.append(
                PhotographyAction(
                    title: "增加层次",
                    reason: "画面层次偏平，适度增加对比和细节会更有立体感。"
                )
            )
        case .balanced:
            break
        case .highContrast:
            recipe.contrast -= 0.03
            recipe.highlightAmount = min(recipe.highlightAmount, 0.58)
            recipe.shadowAmount += 0.08
            actions.append(
                PhotographyAction(
                    title: "柔化对比",
                    reason: "场景对比已经较强，成片应尽量保留高光和暗部细节。"
                )
            )
        }
    }

    private func applyColorStrategy(
        analysis: PhotoAnalysis,
        recipe: inout AutomaticEditingRecipe,
        actions: inout [PhotographyAction]
    ) {
        switch analysis.colorCast {
        case .cool:
            recipe.saturation += 0.018
            recipe.vibrance += 0.04
            actions.append(
                PhotographyAction(
                    title: "轻微升温",
                    reason: "画面偏冷，轻微提升色彩可以避免照片显得冰冷。"
                )
            )
        case .neutral:
            break
        case .warm:
            recipe.saturation -= 0.012
            actions.append(
                PhotographyAction(
                    title: "控制暖色",
                    reason: "画面已经偏暖，需要控制饱和度，避免滤镜感。"
                )
            )
        case .green:
            recipe.saturation -= 0.018
            recipe.vibrance += 0.03
            actions.append(
                PhotographyAction(
                    title: "控制偏绿",
                    reason: "通道平衡显示画面可能偏绿，因此色彩增强要更保守。"
                )
            )
        }
    }

    private func applySceneStrategy(
        strategy: SceneStrategy,
        recipe: inout AutomaticEditingRecipe,
        actions: inout [PhotographyAction]
    ) {
        switch strategy {
        case .portrait:
            recipe.saturation = min(recipe.saturation, 1.035)
            recipe.vibrance = min(recipe.vibrance, 0.22)
            recipe.sharpeningAmount = min(recipe.sharpeningAmount, 0.24)
            recipe.noiseReductionAmount += 0.01
            recipe.faceExposureEV = 0.16
            actions.append(
                PhotographyAction(
                    title: "保护肤色并补亮人脸",
                    reason: "检测到人脸，因此控制饱和度和锐化，同时用柔和局部补光改善脸部受光。"
                )
            )
        case .lowLight:
            recipe.noiseReductionAmount += 0.012
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
}

