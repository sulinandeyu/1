import Foundation

final class PhotographyDecisionEngine {
    func makeDecision(
        for analysis: PhotoAnalysis,
        problems: PhotoProblemReport
    ) -> PhotographyDecision {
        let strategy = SceneStrategy.choose(for: analysis, problems: problems)
        let context = analysis.photographyContext
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
        applyCinematicStrategy(
            analysis: analysis,
            strategy: strategy,
            problems: problems,
            recipe: &recipe,
            actions: &actions
        )
        applyContextStrategy(
            context: context,
            analysis: analysis,
            recipe: &recipe,
            actions: &actions
        )
        applyAnalysisReliabilityLimits(
            analysis: analysis,
            recipe: &recipe,
            actions: &actions
        )
        applyProblemSafetyLimits(problems: problems, recipe: &recipe)
        reconcileQualitySignals(analysis: analysis, recipe: &recipe, actions: &actions)
        enforcePortraitProtection(analysis: analysis, recipe: &recipe, actions: &actions)

        if actions.isEmpty {
            actions.append(
                PhotographyAction(
                    title: "保留原片观感",
                    reason: "照片曝光、层次和色彩已经均衡，正确处理是避免不必要的滤镜和提亮。"
                )
            )
        }

        let finalRecipe = recipe.clamped()
        return PhotographyDecision(
            sceneStrategy: strategy,
            context: context,
            aestheticTarget: aestheticTarget(for: strategy),
            intent: intent(for: strategy),
            actions: actions,
            treatmentPlan: treatmentPlan(
                analysis: analysis,
                strategy: strategy,
                context: context,
                recipe: finalRecipe
            ),
            recipe: finalRecipe
        )
    }

    private func applyAnalysisReliabilityLimits(
        analysis: PhotoAnalysis,
        recipe: inout AutomaticEditingRecipe,
        actions: inout [PhotographyAction]
    ) {
        switch analysis.sceneRecognitionDiagnostics.status {
        case .failed:
            // Keep metric-driven exposure/dynamic-range work, but remove semantic color
            // assumptions when Vision did not produce a result at all.
            recipe.hsl = .neutral
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.12)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.025)
            recipe.midtoneWarmAmount = min(recipe.midtoneWarmAmount, 0.04)
            recipe.highlightWarmAmount = min(recipe.highlightWarmAmount, 0.05)
            recipe.colorContrast = min(recipe.colorContrast, 0.05)
            actions.append(PhotographyAction(
                title: "场景识别失败：采用安全传统后期",
                reason: analysis.sceneRecognitionDiagnostics.reason
                    ?? "只执行实测曝光、动态范围、白平衡和亮度蒙版，不宣称已完成场景化调色。"
            ))
        case .uncertain:
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.2)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.06)
            recipe.midtoneWarmAmount = min(recipe.midtoneWarmAmount, 0.09)
            recipe.highlightWarmAmount = min(recipe.highlightWarmAmount, 0.12)
            recipe.colorContrast = min(recipe.colorContrast, 0.09)
            actions.append(PhotographyAction(
                title: "场景识别不确定：限制风格强度",
                reason: analysis.sceneRecognitionDiagnostics.reason
                    ?? "保留问题驱动的摄影调整，避免按低置信度标签强制套用色彩语言。"
            ))
        case .recognized, .notEvaluated:
            break
        }

        switch analysis.segmentationDiagnostics.status {
        case .failed, .noUsableRegion:
            recipe.skyExposureEV = 0
            recipe.skyHighlightAmount = 1
            recipe.skySaturation = 1
            actions.append(PhotographyAction(
                title: "局部分割降级：改用亮度蒙版",
                reason: analysis.segmentationDiagnostics.reason
                    ?? "没有可靠区域蒙版，因此不宣称完成天空、道路、植被、水面或建筑独立精修。"
            ))
        case .available, .notEvaluated:
            break
        }
    }

    /// 人物保护必须最后执行，确保任何场景、风格或问题修正规则都不能重新开启
    /// 人脸专属提亮、过强皮肤细节处理或疑似美颜式的橙色明度提升。
    private func enforcePortraitProtection(
        analysis: PhotoAnalysis,
        recipe: inout AutomaticEditingRecipe,
        actions: inout [PhotographyAction]
    ) {
        guard analysis.faceCount > 0 else { return }

        recipe.faceExposureEV = 0
        recipe.subjectExposureEV = analysis.personMask?.isValid == true
            ? min(recipe.subjectExposureEV, 0.16)
            : 0
        recipe.skinTextureProtection = max(recipe.skinTextureProtection, 0.72)
        recipe.noiseReductionAmount = min(recipe.noiseReductionAmount, 0.025)
        recipe.sharpeningAmount = min(recipe.sharpeningAmount, 0.085)
        recipe.localContrastAmount = min(recipe.localContrastAmount, 0.07)
        recipe.hsl.orangeLuminance = 0
        recipe.hsl.orangeSaturation = min(max(recipe.hsl.orangeSaturation, -0.02), 0.02)

        actions.append(
            PhotographyAction(
                title: "执行最高优先级人物保护",
                reason: "禁止人脸专属提亮、几何变形、生成式修复和磨皮；只允许整个人物与环境的摄影光影关系调整，并保留真实皮肤纹理。"
            )
        )
    }

    private func treatmentPlan(
        analysis: PhotoAnalysis,
        strategy: SceneStrategy,
        context: PhotographyContext,
        recipe: AutomaticEditingRecipe
    ) -> PhotographyTreatmentPlan {
        var regions = [
            RegionalTreatment(
                region: .global,
                objective: "完成曝光、动态范围、白平衡、曲线和场景化色彩关系的整体制作。"
            )
        ]
        let sceneRegionsAllowed = analysis.faceCount == 0 || analysis.personMask?.isValid == true
        func usable(_ mask: NormalizedPhotoMask?) -> Bool {
            guard let mask, mask.isValid else { return false }
            return mask.activeCoverage >= 0.004 && mask.activeCoverage <= 0.86
        }

        if sceneRegionsAllowed,
           usable(analysis.skyMask),
           abs(recipe.skyExposureEV) > 0.001
                || recipe.skyHighlightAmount < 0.999
                || abs(recipe.skySaturation - 1) > 0.001 {
            regions.append(RegionalTreatment(
                region: .sky,
                objective: "只在可靠天空蒙版内恢复高光、云层和色彩层次。"
            ))
        }
        if sceneRegionsAllowed, usable(analysis.groundMask) {
            regions.append(RegionalTreatment(
                region: .ground,
                objective: "在道路与地面蒙版内恢复可用阴影并建立材质层次。"
            ))
        }
        if sceneRegionsAllowed,
           usable(analysis.vegetationMask),
           !Set(context.sceneFacets).isDisjoint(with: [.forest, .countryRoad, .nature]) {
            regions.append(RegionalTreatment(
                region: .vegetation,
                objective: "在植被蒙版内按当前配方调整绿黄关系，不用全图增绿或增黄。"
            ))
        }
        if sceneRegionsAllowed,
           usable(analysis.waterMask),
           !Set(context.sceneFacets).isDisjoint(with: [.water, .coast]) {
            regions.append(RegionalTreatment(
                region: .water,
                objective: "在水面蒙版内控制色彩与局部对比，保留真实反射。"
            ))
        }
        if sceneRegionsAllowed,
           usable(analysis.architectureMask),
           !Set(context.sceneFacets).isDisjoint(with: [.architecture, .city, .street, .interior, .workspace]) {
            regions.append(RegionalTreatment(
                region: .architecture,
                objective: "在建筑与室内结构蒙版内增强线条和材质，不影响人物。"
            ))
        }
        if analysis.faceCount > 0, analysis.personMask?.isValid == true {
            regions.append(RegionalTreatment(
                region: .person,
                objective: "以整个人物蒙版协调人物与环境明暗，不单独改脸、不改变外貌。"
            ))
            if recipe.backgroundSeparation > 0.001 {
                regions.append(RegionalTreatment(
                    region: .background,
                    objective: "在人物外区域建立空间层次，不对人物区域做变相美颜。"
                ))
            }
        } else if analysis.salientSubjectMask?.isValid == true {
            regions.append(RegionalTreatment(
                region: .subject,
                objective: "围绕显著主体进行克制的局部光影与空间层次调整。"
            ))
        }

        let lighting = context.lightingConditions.map(\.rawValue).joined(separator: ",")
        return PhotographyTreatmentPlan(
            finalLook: intent(for: strategy),
            lightingDesign: "\(context.lightDirection.rawValue) · \(lighting.isEmpty ? "unclassified" : lighting)",
            regionalTreatments: regions,
            portraitProtection: analysis.faceCount > 0 ? .strict : .inactive
        )
    }

    private func applyContextStrategy(
        context: PhotographyContext,
        analysis: PhotoAnalysis,
        recipe: inout AutomaticEditingRecipe,
        actions: inout [PhotographyAction]
    ) {
        let recoverableHighlights = max(0, analysis.highlightRatio - analysis.whiteRatio)
        let recoverableShadows = max(0, analysis.shadowRatio - analysis.blackRatio)

        switch context.style {
        case .blueHour:
            let coolEvidence = min(1, max(0, (analysis.blueAverage - analysis.redAverage) * 5))
            recipe.saturation = min(recipe.saturation, 1.0)
            recipe.vibrance = min(recipe.vibrance, 0.1 + coolEvidence * 0.025)
            recipe.hsl.cyanSaturation = min(recipe.hsl.cyanSaturation, -0.02 - coolEvidence * 0.045)
            recipe.hsl.blueSaturation = min(recipe.hsl.blueSaturation, -0.015 - coolEvidence * 0.035)
            recipe.hsl.orangeSaturation = max(recipe.hsl.orangeSaturation, 0.01)
            recipe.highlightAmount = min(recipe.highlightAmount, 0.62 - recoverableHighlights * 0.3)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.1)
            recipe.midtoneWarmAmount = min(recipe.midtoneWarmAmount, 0.07)
            recipe.highlightWarmAmount = min(recipe.highlightWarmAmount, 0.12)
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.22)
        case .goldenHour:
            let warmEvidence = min(1, max(0, (analysis.redAverage - analysis.blueAverage) * 5))
            recipe.temperatureShift += 35 + 70 * warmEvidence
            recipe.hsl.orangeSaturation = min(0.08, recipe.hsl.orangeSaturation + 0.015 + warmEvidence * 0.025)
            recipe.highlightAmount = min(recipe.highlightAmount, 0.66 - recoverableHighlights * 0.32)
            recipe.highlightWarmAmount = min(recipe.highlightWarmAmount, 0.18)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.06)
            recipe.midtoneWarmAmount = min(recipe.midtoneWarmAmount, 0.12)
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.24)
        case .commercialPortrait, .environmentalPortrait:
            recipe.skinTextureProtection = max(recipe.skinTextureProtection, 0.68)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.055)
            recipe.sharpeningAmount = min(recipe.sharpeningAmount, 0.1)
            recipe.localContrastAmount = min(recipe.localContrastAmount, 0.09)
            recipe.midtoneWarmAmount = min(recipe.midtoneWarmAmount, 0.12)
            recipe.highlightWarmAmount = min(recipe.highlightWarmAmount, 0.18)
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.22)
        case .interiorAtmosphere:
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, analysis.mixedLightScore > 0.18 ? 0.16 : 0.22)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.035)
            recipe.hsl.cyanSaturation = min(recipe.hsl.cyanSaturation, -0.035)
            recipe.hsl.blueSaturation = min(recipe.hsl.blueSaturation, -0.025)
            recipe.shadowAmount = max(recipe.shadowAmount, min(0.3, recoverableShadows * 0.55))
            recipe.midtoneWarmAmount = min(recipe.midtoneWarmAmount, 0.1)
            recipe.highlightWarmAmount = min(recipe.highlightWarmAmount, 0.15)
        case .urbanArchitecture:
            let safeDetail = max(0, analysis.detailScore - analysis.noiseEstimate)
            recipe.localContrastAmount = min(0.12, max(recipe.localContrastAmount, 0.045 + safeDetail * 0.16))
            recipe.sharpeningAmount = min(0.11, max(recipe.sharpeningAmount, 0.055 + safeDetail * 0.12))
            if analysis.highlightSourceCount > 0 {
                recipe.bloomIntensity = min(recipe.bloomIntensity, 0.003)
                recipe.halationIntensity = min(recipe.halationIntensity, 0.001)
                recipe.highlightGlowThreshold = max(recipe.highlightGlowThreshold, 0.965)
            }
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.2)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.06)
            recipe.midtoneWarmAmount = min(recipe.midtoneWarmAmount, 0.1)
            recipe.highlightWarmAmount = min(recipe.highlightWarmAmount, 0.14)
        case .professionalLandscape:
            if analysis.skyMask?.isValid == true {
                recipe.skyExposureEV = min(recipe.skyExposureEV, -min(0.18, recoverableHighlights * 0.8))
            } else {
                recipe.skyExposureEV = 0
            }
            recipe.hsl.greenSaturation = max(-0.08, min(recipe.hsl.greenSaturation, analysis.averageSaturation > 0.38 ? -0.04 : 0.02))
            recipe.hsl.blueSaturation = max(-0.07, min(recipe.hsl.blueSaturation, analysis.averageSaturation > 0.34 ? -0.035 : 0.025))
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.18)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.07)
            recipe.midtoneWarmAmount = min(recipe.midtoneWarmAmount, 0.08)
            recipe.highlightWarmAmount = min(recipe.highlightWarmAmount, 0.12)
            if context.sceneFacets.contains(.forest) || context.sceneFacets.contains(.countryRoad) {
                let naturalWarmth = min(1, max(0, (analysis.redAverage - analysis.blueAverage + 0.04) * 4))
                recipe.hsl.yellowSaturation = min(0.07, -0.015 + naturalWarmth * 0.055)
                recipe.hsl.yellowLuminance = min(0.035, naturalWarmth * 0.025)
                recipe.hsl.orangeSaturation = min(0.065, recipe.hsl.orangeSaturation + naturalWarmth * 0.025)
            }
        case .stillLife:
            recipe.localContrastAmount = min(0.11, max(recipe.localContrastAmount, 0.055))
            recipe.sharpeningAmount = min(0.115, max(recipe.sharpeningAmount, 0.065))
            recipe.saturation = min(recipe.saturation, 1.01)
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.18)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.04)
            recipe.midtoneWarmAmount = min(recipe.midtoneWarmAmount, 0.1)
            recipe.highlightWarmAmount = min(recipe.highlightWarmAmount, 0.14)
        case .lifestyle, .naturalDocumentary:
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.14)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.035)
            recipe.midtoneWarmAmount = min(recipe.midtoneWarmAmount, 0.07)
            recipe.highlightWarmAmount = min(recipe.highlightWarmAmount, 0.09)
        }

        actions.append(PhotographyAction(
            title: "多维摄影语境：\(context.style.rawValue)",
            reason: context.styleReason
        ))
    }

    private func reconcileQualitySignals(
        analysis: PhotoAnalysis,
        recipe: inout AutomaticEditingRecipe,
        actions: inout [PhotographyAction]
    ) {
        let recoverableShadow = max(0, analysis.shadowRatio - analysis.blackRatio)
        recipe.shadowZoneExposureEV = min(
            analysis.semanticScene == .night ? 0.12 : 0.18,
            max(0.025, recoverableShadow * 0.28)
        )
        recipe.highlightZoneExposureEV = -min(0.2, max(0.035, analysis.highlightRatio * 0.9))
        recipe.luminanceMaskStrength = min(
            0.82,
            max(0.3, (recoverableShadow + analysis.highlightRatio) * 1.45)
        )

        if analysis.spatialLuminanceVariance > 0.18 {
            recipe.localContrastAmount = min(recipe.localContrastAmount, 0.1)
            recipe.contrast = min(recipe.contrast, 1.035)
            actions.append(PhotographyAction(
                title: "按空间光比塑造影调",
                reason: "九宫格测光显示局部光比明显，使用亮度蒙版保护亮源并恢复可用阴影，而不是继续增加全局对比度。"
            ))
        }

        if analysis.highlightSourceCount > 0 && analysis.highlightConcentration > 0.28 {
            recipe.highlightZoneExposureEV = min(recipe.highlightZoneExposureEV, -0.1)
            recipe.bloomIntensity = min(recipe.bloomIntensity, 0.004)
            recipe.halationIntensity = min(recipe.halationIntensity, 0.0015)
            recipe.highlightGlowThreshold = max(recipe.highlightGlowThreshold, 0.96)
            actions.append(PhotographyAction(
                title: "保护真实光源形态",
                reason: "检测到集中的高亮光源，优先保留灯具核心和边缘，只允许极弱的高光扩散。"
            ))
        }

        if analysis.noiseEstimate > 0.12 {
            recipe.noiseReductionAmount = max(recipe.noiseReductionAmount, min(0.055, analysis.noiseEstimate * 0.22))
            recipe.sharpeningAmount = min(recipe.sharpeningAmount, 0.09)
            recipe.localContrastAmount = min(recipe.localContrastAmount, 0.09)
            recipe.grainAmount = min(recipe.grainAmount, 0.01)
            actions.append(PhotographyAction(
                title: "按实测高频残差保护细节",
                reason: "画面存在噪点风险，因此限制锐化、清晰度和颗粒，避免把噪点强化成伪纹理。"
            ))
        } else if analysis.detailScore < 0.12 {
            recipe.sharpeningAmount = min(max(recipe.sharpeningAmount, 0.06), 0.12)
        }

        if analysis.mixedLightScore > 0.18 {
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.28)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.12)
            recipe.highlightWarmAmount = min(recipe.highlightWarmAmount, 0.2)
            actions.append(PhotographyAction(
                title: "约束混合光调色",
                reason: "画面同时存在明显冷暖区域，减少统一染色并保留现场光源关系。"
            ))
        }

        if analysis.whiteRatio > 0.025 || analysis.highlightRatio > 0.12 {
            recipe.bloomIntensity = min(recipe.bloomIntensity, 0.006)
            recipe.halationIntensity = min(recipe.halationIntensity, 0.002)
            recipe.highlightGlowThreshold = max(recipe.highlightGlowThreshold, 0.955)
        }

        if analysis.blackRatio > 0.38 && analysis.semanticScene == .night {
            recipe.blackPoint = 0
            recipe.shadowAmount = max(recipe.shadowAmount, 0.18)
            recipe.shadowRollOff = max(recipe.shadowRollOff, 0.24)
            recipe.shadowZoneExposureEV = min(recipe.shadowZoneExposureEV, 0.1)
        }
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
            recipe.bloomIntensity = min(recipe.bloomIntensity, 0.008)
            recipe.halationIntensity = min(recipe.halationIntensity, 0.003)
            recipe.highlightGlowThreshold = max(recipe.highlightGlowThreshold, 0.95)
        }

        if problems.contains(.oversaturated) {
            recipe.saturation = min(recipe.saturation, 0.96)
            recipe.vibrance = min(recipe.vibrance, 0.04)
        }

        if problems.contains(.noiseRisk) {
            recipe.sharpeningAmount = min(recipe.sharpeningAmount, 0.1)
            recipe.localContrastAmount = min(recipe.localContrastAmount, 0.12)
            recipe.grainAmount = min(recipe.grainAmount, 0.014)
        }
    }

    private func applyCinematicStrategy(
        analysis: PhotoAnalysis,
        strategy: SceneStrategy,
        problems: PhotoProblemReport,
        recipe: inout AutomaticEditingRecipe,
        actions: inout [PhotographyAction]
    ) {
        let intensity: CinematicIntensity
        switch strategy {
        case .portrait, .backlitPortrait, .food:
            intensity = .natural
        case .general:
            let isAlreadyBalanced = problems.isEmpty
                && analysis.exposureProfile == .balanced
                && analysis.contrastProfile == .balanced
            intensity = isAlreadyBalanced ? .natural : .standard
        case .night, .street:
            intensity = .standard
        case .sunset:
            intensity = analysis.contrastRange > 0.48 ? .dramatic : .standard
        case .highContrast:
            intensity = problems.contains(.clippedHighlights) ? .standard : .dramatic
        default:
            intensity = .standard
        }
        recipe.cinematicIntensity = intensity

        switch intensity {
        case .natural:
            recipe.shadowRollOff = max(recipe.shadowRollOff, 0.2)
            recipe.lowerMidtoneLift = max(recipe.lowerMidtoneLift, 0.008)
            recipe.upperMidtoneSeparation = max(recipe.upperMidtoneSeparation, 0.012)
            recipe.highlightRollOff = max(recipe.highlightRollOff, 0.2)
            recipe.whitePoint = min(recipe.whitePoint, 0.988)
            recipe.colorGradeIntensity = max(recipe.colorGradeIntensity, 0.24)
            recipe.shadowCoolAmount = max(recipe.shadowCoolAmount, 0.12)
            recipe.midtoneWarmAmount = max(recipe.midtoneWarmAmount, 0.16)
            recipe.highlightWarmAmount = max(recipe.highlightWarmAmount, 0.2)
            recipe.colorContrast = max(recipe.colorContrast, 0.1)
            recipe.bloomIntensity = max(recipe.bloomIntensity, 0.004)
            recipe.backgroundSeparation = analysis.containsFaces ? 0.055 : 0.025
        case .standard:
            recipe.shadowRollOff = max(recipe.shadowRollOff, 0.38)
            recipe.lowerMidtoneLift = max(recipe.lowerMidtoneLift, 0.012)
            recipe.midtoneBias = max(recipe.midtoneBias, 0.004)
            recipe.upperMidtoneSeparation = max(recipe.upperMidtoneSeparation, 0.025)
            recipe.highlightRollOff = max(recipe.highlightRollOff, 0.42)
            recipe.whitePoint = min(recipe.whitePoint, 0.976)
            recipe.colorGradeIntensity = max(recipe.colorGradeIntensity, 0.4)
            recipe.shadowCoolAmount = max(recipe.shadowCoolAmount, 0.28)
            recipe.midtoneWarmAmount = max(recipe.midtoneWarmAmount, 0.24)
            recipe.highlightWarmAmount = max(recipe.highlightWarmAmount, 0.34)
            recipe.colorContrast = max(recipe.colorContrast, 0.22)
            recipe.bloomIntensity = max(recipe.bloomIntensity, 0.008)
            recipe.halationIntensity = max(recipe.halationIntensity, 0.003)
            recipe.grainAmount = max(recipe.grainAmount, 0.012)
            recipe.backgroundSeparation = 0.085
        case .dramatic:
            recipe.shadowRollOff = max(recipe.shadowRollOff, 0.52)
            recipe.lowerMidtoneLift = min(recipe.lowerMidtoneLift, -0.005)
            recipe.midtoneBias = min(recipe.midtoneBias, -0.008)
            recipe.upperMidtoneSeparation = max(recipe.upperMidtoneSeparation, 0.045)
            recipe.highlightRollOff = max(recipe.highlightRollOff, 0.58)
            recipe.whitePoint = min(recipe.whitePoint, 0.965)
            recipe.colorGradeIntensity = max(recipe.colorGradeIntensity, 0.54)
            recipe.shadowCoolAmount = max(recipe.shadowCoolAmount, 0.42)
            recipe.midtoneWarmAmount = max(recipe.midtoneWarmAmount, 0.28)
            recipe.highlightWarmAmount = max(recipe.highlightWarmAmount, 0.48)
            recipe.colorContrast = max(recipe.colorContrast, 0.32)
            recipe.bloomIntensity = max(recipe.bloomIntensity, 0.012)
            recipe.halationIntensity = max(recipe.halationIntensity, 0.005)
            recipe.grainAmount = max(recipe.grainAmount, 0.02)
            recipe.backgroundSeparation = 0.11
        }

        switch strategy {
        case .night, .street, .lowLight:
            recipe.cinematicToneStyle = .lowKey
            recipe.shadowRollOff = min(recipe.shadowRollOff, 0.3)
            recipe.lowerMidtoneLift = max(recipe.lowerMidtoneLift, 0.018)
            recipe.midtoneBias = max(recipe.midtoneBias, 0)
            recipe.highlightRollOff = min(recipe.highlightRollOff, 0.44)
            recipe.whitePoint = max(recipe.whitePoint, 0.98)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.2)
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.38)
            recipe.highlightGlowThreshold = 0.94
            recipe.bloomIntensity = analysis.highlightRatio > 0.012
                ? min(max(recipe.bloomIntensity, 0.008), 0.012)
                : 0
            recipe.halationIntensity = analysis.highlightRatio > 0.012
                ? min(recipe.halationIntensity, 0.004)
                : 0
            recipe.vignetteIntensity = min(recipe.vignetteIntensity, 0.035)
        case .portrait, .food, .outdoor, .brightOutdoor:
            recipe.cinematicToneStyle = .bright
            recipe.halationIntensity = min(recipe.halationIntensity, 0.012)
        case .indoor, .workspace, .architecture:
            recipe.cinematicToneStyle = .natural
            recipe.shadowRollOff = min(recipe.shadowRollOff, 0.3)
            recipe.upperMidtoneSeparation = min(recipe.upperMidtoneSeparation, 0.02)
            recipe.highlightRollOff = min(recipe.highlightRollOff, 0.4)
            recipe.whitePoint = max(recipe.whitePoint, 0.982)
            recipe.highlightGlowThreshold = 0.96
            recipe.bloomIntensity = min(recipe.bloomIntensity, 0.004)
            recipe.halationIntensity = 0
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.08)
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.3)
            recipe.localContrastAmount = min(recipe.localContrastAmount, 0.16)
        case .landscape, .sunset, .backlitPortrait, .flatScene, .highContrast, .general:
            recipe.cinematicToneStyle = .natural
        }

        if analysis.averageSaturation > 0.52 || problems.contains(.oversaturated) {
            recipe.colorContrast = min(recipe.colorContrast, 0.16)
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.4)
        }

        actions.append(
            PhotographyAction(
                title: intensity.title,
                reason: "根据场景、动态范围和原片质量自动选择电影强度，并驱动七段影调、三段色彩、空间层次与可选镜头特征。"
            )
        )
    }

    private func applySkyStrategy(
        analysis: PhotoAnalysis,
        strategy: SceneStrategy,
        problems: PhotoProblemReport,
        recipe: inout AutomaticEditingRecipe,
        actions: inout [PhotographyAction]
    ) {
        guard analysis.skyMask?.isValid == true else { return }

        let context = analysis.photographyContext
        let recoverableHighlights = max(0, analysis.highlightRatio - analysis.whiteRatio)
        let recoveryStrength = min(1, max(0, recoverableHighlights * 4 + max(0, analysis.contrastRange - 0.42)))
        let saturationHeadroom = min(1, max(0, (0.34 - analysis.averageSaturation) * 4))

        switch strategy {
        case .landscape, .outdoor, .brightOutdoor, .highContrast:
            recipe.skyExposureEV = -(0.025 + 0.105 * recoveryStrength)
            recipe.skyHighlightAmount = 0.78 - 0.26 * recoveryStrength
            recipe.skySaturation = 1 + 0.035 * saturationHeadroom
            if context.lightingConditions.contains(.overcast) {
                recipe.skyExposureEV = max(recipe.skyExposureEV, -0.055)
                recipe.skySaturation = min(recipe.skySaturation, 0.995)
            }
            if problems.contains(.oversaturated) { recipe.skySaturation = min(recipe.skySaturation, 0.98) }
        case .sunset:
            recipe.skyExposureEV = -(0.045 + 0.085 * recoveryStrength)
            recipe.skyHighlightAmount = 0.68 - 0.18 * recoveryStrength
            recipe.skySaturation = problems.contains(.oversaturated) ? 0.98 : 1 + 0.025 * saturationHeadroom
        case .backlitPortrait:
            recipe.skyExposureEV = -(0.055 + 0.075 * recoveryStrength)
            recipe.skyHighlightAmount = 0.68 - 0.16 * recoveryStrength
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
            recipe.hsl.orangeSaturation = 0.025
            recipe.hsl.orangeLuminance = 0.018
            recipe.hsl.cyanSaturation = -0.035
            recipe.saturation = min(recipe.saturation, 1.01)
            recipe.vibrance = min(max(recipe.vibrance, 0.06), 0.12)
            recipe.sharpeningAmount = min(max(recipe.sharpeningAmount, 0.1), 0.16)
            recipe.noiseReductionAmount = max(recipe.noiseReductionAmount, 0.012)
            recipe.skinTextureProtection = 0.56
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.38)
            recipe.toneCurveStyle = .portrait
            recipe.colorGradeIntensity = max(recipe.colorGradeIntensity, 0.38)
            recipe.highlightWarmAmount = max(recipe.highlightWarmAmount, 0.42)
            recipe.shadowCoolAmount = max(recipe.shadowCoolAmount, 0.08)
            if let faceLuminance = analysis.faceAverageLuminance, faceLuminance < 0.44 {
                let correction = min(max((0.46 - faceLuminance) * 0.9, 0.06), 0.24)
                recipe.subjectExposureEV = analysis.personMask == nil
                    ? 0.0
                    : min(max(correction * 0.36, 0.03), 0.09)
            } else if analysis.faceAverageLuminance == nil,
                      analysis.averageLuminance < 0.4 {
                recipe.subjectExposureEV = analysis.personMask == nil ? 0.0 : 0.04
            }
            actions.append(
                PhotographyAction(
                    title: "保护肤色与皮肤纹理",
                    reason: "检测到人脸，因此限制饱和度、锐化和降噪强度，只在画面偏暗时进行轻微局部补光。"
                )
            )
        case .backlitPortrait:
            recipe.hsl.orangeSaturation = 0.02
            recipe.hsl.orangeLuminance = 0.022
            recipe.exposureEV = min(recipe.exposureEV, -0.04)
            recipe.highlightAmount = min(recipe.highlightAmount, 0.5)
            recipe.shadowAmount = min(max(recipe.shadowAmount, 0.12), 0.28)
            recipe.saturation = min(recipe.saturation, 1.01)
            recipe.vibrance = min(max(recipe.vibrance, 0.06), 0.12)
            recipe.sharpeningAmount = min(max(recipe.sharpeningAmount, 0.1), 0.16)
            recipe.skinTextureProtection = 0.62
            let faceLuminance = analysis.faceAverageLuminance ?? analysis.averageLuminance
            let backgroundLuminance = analysis.backgroundAverageLuminance ?? analysis.averageLuminance
            let backgroundSeparation = max(0, backgroundLuminance - faceLuminance)
            recipe.subjectExposureEV = analysis.personMask == nil
                ? 0.0
                : min(max(0.1 + (backgroundSeparation * 0.42), 0.1), 0.26)
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.48)
            recipe.toneCurveStyle = .softHighlights
            recipe.colorGradeIntensity = max(recipe.colorGradeIntensity, 0.42)
            recipe.highlightWarmAmount = max(recipe.highlightWarmAmount, 0.38)
            recipe.shadowCoolAmount = max(recipe.shadowCoolAmount, 0.12)
            actions.append(
                PhotographyAction(
                    title: "保天空并协调人物与环境光比",
                    reason: "分区测光确认人物暗于背景；只在可靠人物蒙版内调整整个人物，同时压住背景高光，不单独提亮人脸。"
                )
            )
        case .landscape:
            recipe.hsl.greenSaturation = 0.035
            recipe.hsl.greenLuminance = 0.012
            recipe.hsl.blueSaturation = 0.03
            recipe.hsl.blueLuminance = -0.012
            recipe.highlightAmount = min(recipe.highlightAmount, 0.72)
            recipe.shadowAmount = max(recipe.shadowAmount, 0.14)
            recipe.contrast += 0.035
            recipe.saturation += 0.012
            recipe.vibrance += 0.14
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.62)
            recipe.toneCurveStyle = .landscape
            recipe.colorGradeIntensity = max(recipe.colorGradeIntensity, 0.34)
            recipe.shadowCoolAmount = max(recipe.shadowCoolAmount, 0.28)
            recipe.highlightWarmAmount = max(recipe.highlightWarmAmount, 0.12)
            recipe.sharpeningAmount = max(recipe.sharpeningAmount, 0.2)
            actions.append(
                PhotographyAction(
                    title: "建立风景层次",
                    reason: "按风景场景保护亮部和云层，适度打开暗部，并增强中间调层次与自然色彩。"
                )
            )
        case .night:
            recipe.hsl.cyanSaturation = -0.08
            recipe.hsl.blueSaturation = -0.065
            recipe.hsl.blueLuminance = 0.012
            recipe.highlightAmount = min(recipe.highlightAmount, 0.6)
            recipe.shadowAmount = min(
                max(recipe.shadowAmount, analysis.shadowRatio > 0.55 ? 0.2 : 0.14),
                0.28
            )
            recipe.contrast = min(max(recipe.contrast, 1.01), 1.025)
            recipe.blackPoint = 0
            recipe.saturation = min(recipe.saturation, 0.995)
            recipe.vibrance = min(max(recipe.vibrance, 0.06), 0.1)
            recipe.noiseReductionAmount = max(recipe.noiseReductionAmount, 0.045)
            recipe.sharpeningAmount = min(max(recipe.sharpeningAmount, 0.055), 0.1)
            recipe.temperatureShift -= 35
            recipe.tintShift += 1
            recipe.toneCurveAmount = min(max(recipe.toneCurveAmount, 0.36), 0.46)
            recipe.toneCurveStyle = .cinematic
            recipe.colorGradeIntensity = min(max(recipe.colorGradeIntensity, 0.28), 0.38)
            recipe.shadowCoolAmount = min(max(recipe.shadowCoolAmount, 0.12), 0.2)
            recipe.midtoneWarmAmount = min(recipe.midtoneWarmAmount, 0.16)
            recipe.highlightWarmAmount = min(max(recipe.highlightWarmAmount, 0.18), 0.28)
            recipe.localContrastAmount = min(recipe.localContrastAmount, 0.08)
            recipe.grainAmount = min(max(recipe.grainAmount, 0.01), 0.018)
            recipe.vignetteIntensity = min(recipe.vignetteIntensity, 0.025)
            actions.append(
                PhotographyAction(
                    title: "控制灯光高光与噪点",
                    reason: "夜景不粗暴拉亮暗部，优先保住灯牌和路灯高光，适度降噪并维持冷暖电影感。"
                )
            )
        case .street:
            recipe.hsl.cyanSaturation = -0.055
            recipe.hsl.blueSaturation = -0.04
            recipe.highlightAmount = min(recipe.highlightAmount, 0.58)
            recipe.shadowAmount = min(max(recipe.shadowAmount, 0.1), 0.22)
            recipe.contrast = min(max(recipe.contrast, 1.015), 1.03)
            recipe.saturation = min(recipe.saturation, 0.99)
            recipe.vibrance = max(recipe.vibrance, 0.09)
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.6)
            recipe.toneCurveStyle = .cinematic
            recipe.colorGradeIntensity = max(recipe.colorGradeIntensity, 0.48)
            recipe.shadowCoolAmount = min(max(recipe.shadowCoolAmount, 0.14), 0.22)
            recipe.midtoneWarmAmount = max(recipe.midtoneWarmAmount, 0.2)
            recipe.highlightWarmAmount = max(recipe.highlightWarmAmount, 0.36)
            recipe.localContrastAmount = min(max(recipe.localContrastAmount, 0.08), 0.14)
            actions.append(
                PhotographyAction(
                    title: "建立街头冷暖与光影秩序",
                    reason: "控制招牌和天空高光，保留街道暗部深度，并以克制冷暖分离突出城市氛围。"
                )
            )
        case .outdoor:
            recipe.hsl.greenSaturation = 0.018
            recipe.hsl.blueSaturation = 0.015
            recipe.highlightAmount = min(recipe.highlightAmount, 0.68)
            recipe.shadowAmount = max(recipe.shadowAmount, 0.13)
            recipe.contrast = max(recipe.contrast, 1.025)
            recipe.vibrance = max(recipe.vibrance, 0.085)
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.48)
            recipe.toneCurveStyle = .softHighlights
            recipe.colorGradeIntensity = max(recipe.colorGradeIntensity, 0.3)
            recipe.shadowCoolAmount = max(recipe.shadowCoolAmount, 0.2)
            recipe.highlightWarmAmount = max(recipe.highlightWarmAmount, 0.2)
            actions.append(
                PhotographyAction(
                    title: "塑造自然光电影层次",
                    reason: "保护户外亮部并整理中间调，维持植被、天空和主体的可信颜色。"
                )
            )
        case .food:
            recipe.temperatureShift += 160
            recipe.contrast += 0.03
            recipe.saturation += 0.02
            recipe.vibrance += 0.12
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.48)
            recipe.toneCurveStyle = .portrait
            recipe.colorGradeIntensity = max(recipe.colorGradeIntensity, 0.36)
            recipe.highlightWarmAmount = max(recipe.highlightWarmAmount, 0.5)
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
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.56)
            recipe.toneCurveStyle = .landscape
            recipe.colorGradeIntensity = max(recipe.colorGradeIntensity, 0.28)
            recipe.shadowCoolAmount = max(recipe.shadowCoolAmount, 0.3)
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
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.5)
            recipe.toneCurveStyle = .softHighlights
            recipe.colorGradeIntensity = max(recipe.colorGradeIntensity, 0.46)
            recipe.highlightWarmAmount = max(recipe.highlightWarmAmount, 0.68)
            actions.append(
                PhotographyAction(
                    title: "保护太阳高光与暖色渐变",
                    reason: "日落场景不做强 HDR，压住太阳附近高光并保留自然暖色过渡。"
                )
            )
        case .indoor:
            recipe.hsl.cyanSaturation = -0.09
            recipe.hsl.blueSaturation = -0.07
            recipe.hsl.orangeSaturation = -0.015
            recipe.exposureEV += analysis.averageLuminance < 0.36 ? 0.08 : 0
            recipe.highlightAmount = min(
                recipe.highlightAmount,
                analysis.highlightRatio > 0.1 ? 0.52 : 0.66
            )
            recipe.shadowAmount = max(recipe.shadowAmount, 0.26)
            recipe.contrast = min(max(recipe.contrast, 1.01), 1.025)
            recipe.blackPoint = min(recipe.blackPoint, 0.004)
            recipe.localContrastAmount = min(max(recipe.localContrastAmount, 0.06), 0.12)
            recipe.saturation = min(recipe.saturation, 0.995)
            recipe.vibrance = max(recipe.vibrance, 0.075)
            recipe.noiseReductionAmount = max(recipe.noiseReductionAmount, 0.018)
            recipe.sharpeningAmount = min(max(recipe.sharpeningAmount, 0.055), 0.1)
            recipe.toneCurveAmount = min(max(recipe.toneCurveAmount, 0.38), 0.5)
            recipe.toneCurveStyle = .interior
            recipe.colorGradeIntensity = min(max(recipe.colorGradeIntensity, 0.12), 0.22)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.04)
            recipe.highlightWarmAmount = min(max(recipe.highlightWarmAmount, 0.08), 0.16)
            actions.append(
                PhotographyAction(
                    title: "建立专业室内摄影层次",
                    reason: "压制窗户和屏幕高光、恢复家具与地面有效阴影，并以局部对比增强织物和柜体材质；白平衡只按实测色偏修正。"
                )
            )
        case .workspace:
            recipe.hsl.orangeSaturation = -0.025
            recipe.hsl.greenSaturation = -0.035
            recipe.hsl.cyanSaturation = -0.045
            recipe.exposureEV += analysis.averageLuminance < 0.34 ? 0.06 : 0
            recipe.highlightAmount = min(
                recipe.highlightAmount,
                analysis.highlightRatio > 0.08 ? 0.5 : 0.62
            )
            recipe.shadowAmount = min(max(recipe.shadowAmount, 0.18), 0.3)
            recipe.contrast = max(recipe.contrast, 1.045)
            recipe.blackPoint = max(recipe.blackPoint, 0.014)
            recipe.localContrastAmount = min(max(recipe.localContrastAmount, 0.08), 0.15)
            recipe.saturation = min(recipe.saturation, 0.99)
            recipe.vibrance = max(recipe.vibrance, 0.085)
            recipe.toneCurveAmount = min(max(recipe.toneCurveAmount, 0.42), 0.54)
            recipe.toneCurveStyle = .workspace
            recipe.noiseReductionAmount = max(recipe.noiseReductionAmount, 0.012)
            recipe.sharpeningAmount = min(max(recipe.sharpeningAmount, 0.07), 0.12)
            recipe.vignetteIntensity = max(recipe.vignetteIntensity, 0.04)
            actions.append(
                PhotographyAction(
                    title: "整理桌面高光与黑位",
                    reason: "控制显示器高光，适度打开线缆和键盘暗部，同时保留黑色键盘深度，并增强键帽、桌面和玻璃材质。"
                )
            )
        case .lowLight:
            recipe.noiseReductionAmount = max(recipe.noiseReductionAmount, 0.03)
            recipe.toneCurveStyle = .cinematic
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.32)
            recipe.grainAmount = max(recipe.grainAmount, 0.025)
            recipe.colorGradeIntensity = max(recipe.colorGradeIntensity, 0.22)
            recipe.shadowCoolAmount = max(recipe.shadowCoolAmount, 0.28)
        case .brightOutdoor:
            recipe.highlightAmount = min(recipe.highlightAmount, 0.52)
            recipe.toneCurveStyle = .softHighlights
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.28)
        case .flatScene:
            recipe.contrast += 0.018
            recipe.toneCurveStyle = .neutral
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.4)
            recipe.vibrance = max(recipe.vibrance, 0.07)
        case .highContrast:
            recipe.shadowAmount += 0.04
            recipe.toneCurveStyle = .softHighlights
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.3)
        case .general:
            recipe.toneCurveStyle = .neutral
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.26)
            recipe.vibrance = max(recipe.vibrance, 0.045)
            recipe.sharpeningAmount = max(recipe.sharpeningAmount, 0.08)
            actions.append(
                PhotographyAction(
                    title: "克制的通用摄影润色",
                    reason: "场景置信度不足且没有强问题时，仍执行轻量层次、自然饱和度和亮度锐化，不用固定重滤镜强行改变原片。"
                )
            )
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
        case .street:
            return "控制城市高光与暗部，通过真实冷暖关系形成街头电影氛围。"
        case .outdoor:
            return "保留自然光和真实环境颜色，同时建立清晰的主体与背景层次。"
        case .food:
            return "让食物色彩自然诱人，并保留纹理与真实白平衡。"
        case .architecture:
            return "突出建筑线条、材质与明暗秩序，保持色彩克制。"
        case .sunset:
            return "保护太阳高光和暖色渐变，避免过度 HDR。"
        case .indoor:
            return "校正室内混合光色温，让暗部和主体看起来自然。"
        case .workspace:
            return "控制屏幕高光并保留黑色器材深度，让键帽、桌面与玻璃材质更清晰。"
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
        case .street: return .cinematicStreet
        case .outdoor: return .cinematicOutdoor
        case .food: return .appetizingNatural
        case .architecture: return .architecturalClarity
        case .sunset: return .warmSunset
        case .indoor: return .balancedIndoor
        case .workspace: return .workspaceClarity
        case .general: return .neutral
        }
    }

}

/// 系统级摄影总监入口。上层管线只向总监提交分析与问题证据，
/// 总监返回已经过人物保护硬约束的、可直接执行的摄影制作决策。
final class PhotographyDirector {
    private let decisionEngine: PhotographyDecisionEngine

    init(decisionEngine: PhotographyDecisionEngine = PhotographyDecisionEngine()) {
        self.decisionEngine = decisionEngine
    }

    func direct(
        analysis: PhotoAnalysis,
        problems: PhotoProblemReport
    ) -> PhotographyDecision {
        decisionEngine.makeDecision(for: analysis, problems: problems)
    }
}

