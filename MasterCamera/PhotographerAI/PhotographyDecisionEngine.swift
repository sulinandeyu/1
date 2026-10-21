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
            strategy: strategy,
            recipe: &recipe,
            actions: &actions
        )
        applySceneStrategy(
            analysis: analysis,
            strategy: strategy,
            recipe: &recipe,
            actions: &actions
        )

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
        recipe: inout AutomaticEditingRecipe,
        actions: inout [PhotographyAction]
    ) {
        switch analysis.exposureProfile {
        case .underexposed:
            if analysis.semanticScene == .night {
                recipe.exposureEV += 0.05
                recipe.shadowAmount = max(recipe.shadowAmount, 0.12)
                recipe.noiseReductionAmount = max(recipe.noiseReductionAmount, 0.04)
            } else {
                recipe.exposureEV += 0.14
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
        case .balanced:
            break
        case .overexposed:
            recipe.exposureEV -= 0.1
            recipe.highlightAmount = min(recipe.highlightAmount, 0.5)
            recipe.contrast = max(recipe.contrast, 1.02)
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
            recipe.vibrance += 0.05
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.3)
            recipe.sharpeningAmount += 0.07
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
        analysis: PhotoAnalysis,
        strategy: SceneStrategy,
        recipe: inout AutomaticEditingRecipe,
        actions: inout [PhotographyAction]
    ) {
        switch analysis.colorCast {
        case .cool:
            if strategy != .night && strategy != .landscape {
                recipe.temperatureShift += 140
            }
            if strategy != .landscape {
                actions.append(
                    PhotographyAction(
                        title: strategy == .night ? "保留冷暖关系" : "校正偏冷色温",
                        reason: strategy == .night
                            ? "夜景允许保留环境冷色，不通过整体增饱和破坏灯光关系。"
                            : "画面偏冷，轻微提高色温，让中性色和肤色更自然。"
                    )
                )
            }
        case .neutral:
            break
        case .warm:
            if strategy != .sunset && strategy != .food {
                recipe.temperatureShift -= 80
                recipe.saturation -= 0.008
                actions.append(
                    PhotographyAction(
                        title: "控制暖色偏移",
                        reason: "画面整体偏暖，轻微回正色温，避免黄色滤镜感。"
                    )
                )
            }
        case .green:
            if strategy != .landscape {
                recipe.tintShift += 5
                recipe.saturation -= 0.01
                actions.append(
                    PhotographyAction(
                        title: "控制偏绿",
                        reason: "通道平衡显示画面可能偏绿，因此向洋红方向轻微校正，而不是增加全局饱和度。"
                    )
                )
            }
        }
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
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.16)
            if analysis.averageLuminance < 0.48 || analysis.shadowRatio > 0.28 {
                recipe.faceExposureEV = 0.12
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
            recipe.faceExposureEV = 0.24
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.22)
            actions.append(
                PhotographyAction(
                    title: "保天空并单独补亮人物",
                    reason: "高光和暗部同时占比较高，按逆光人像处理：压住背景高光，只对人脸做柔和补光。"
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

