import Foundation

final class PhotographyDecisionEngine {
    func makeDecision(
        for analysis: PhotoAnalysis,
        problems: PhotoProblemReport,
        targetProfile: PhotographyTargetProfile? = nil
    ) -> PhotographyDecision {
        let strategy = SceneStrategy.choose(for: analysis, problems: problems)
        let context = analysis.photographyContext
        let aestheticPlan = targetProfile.flatMap { profile in
            profile.referenceApplied
                ? AestheticPhotographyPlanner().makePlan(
                    analysis: analysis,
                    problems: problems,
                    targetProfile: profile
                )
                : nil
        }
        let adaptiveSolution = AdaptivePhotographyParameterSolver().solve(
            analysis: analysis,
            problems: problems,
            targetProfile: targetProfile,
            aestheticPlan: aestheticPlan
        )
        // The adaptive solver is the sole source of creative/technical parameters.
        // Legacy scene methods remain below only for source compatibility and are
        // deliberately not called from the production path.
        var recipe = adaptiveSolution.recipe
        var actions = adaptiveSolution.actions
        applyAnalysisReliabilityLimits(
            analysis: analysis,
            recipe: &recipe,
            actions: &actions
        )
        applyProblemSafetyLimits(problems: problems, recipe: &recipe)
        applyColorIntegrityGuards(
            analysis: analysis,
            recipe: &recipe,
            actions: &actions
        )
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
            aestheticTarget: aestheticPlan == nil ? .neutral : .measuredHarmony,
            adaptiveTarget: adaptiveSolution.target,
            intent: aestheticPlan?.primaryObjective
                ?? "依据当前照片测量结果生成专属摄影目标与参数，不按场景加载预设。",
            actions: actions,
            treatmentPlan: treatmentPlan(
                analysis: analysis,
                context: context,
                target: adaptiveSolution.target,
                recipe: finalRecipe
            ),
            recipe: finalRecipe,
            parameterEvidence: adaptiveSolution.parameterEvidence.map {
                $0.refreshingActualValue(from: finalRecipe)
            },
            aestheticPlan: aestheticPlan
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

    /// V8.1 selects one of two photographic production modes from measured
    /// subject evidence. A missing subject is not treated as a reason to do
    /// almost nothing: reliable semantic regions still receive a coordinated,
    /// bounded treatment.
    private func applyCoordinationMode(
        analysis: PhotoAnalysis,
        context: PhotographyContext,
        recipe: inout AutomaticEditingRecipe,
        actions: inout [PhotographyAction]
    ) {
        let priority = analysis.subjectPriorityProfile
        if priority.mode == .primarySubject, analysis.containsPersonEvidence {
            actions.append(PhotographyAction(
                title: "人物主体模式：交由严格人物保护链",
                reason: "可靠整人物蒙版建立人物与环境关系，但禁止人脸专属提亮、美颜、几何或生成式修改。"
            ))
            return
        }
        if priority.mode == .primarySubject,
           !analysis.containsPersonEvidence,
           let subjectStatistics = analysis.nonPersonPrimarySubjectStatistics {
            let subjectDeficit = max(0, analysis.averageLuminance - subjectStatistics.averageLuminance)
            let requestedLift = min(0.11, 0.035 + subjectDeficit * 0.28)
            recipe.subjectExposureEV = max(recipe.subjectExposureEV, requestedLift)
            recipe.localContrastAmount = min(
                0.115,
                max(recipe.localContrastAmount, analysis.noiseEstimate > 0.22 ? 0.055 : 0.075)
            )
            recipe.backgroundSeparation = min(0.095, max(recipe.backgroundSeparation, 0.045))
            actions.append(PhotographyAction(
                title: "主体优先模式：显著主体进入真实局部渲染",
                reason: String(
                    format: "主体置信度 %.0f%%、覆盖 %.1f%%；按主体实测亮度、色彩和局部对比生成独立蒙版参数，同时轻度降低背景竞争。",
                    priority.confidence * 100,
                    analysis.salientSubjectCoverage * 100
                )
            ))
            return
        }

        let reliableRegionCount = [
            analysis.skyMask,
            analysis.groundMask,
            analysis.vegetationMask,
            analysis.waterMask,
            analysis.architectureMask
        ].compactMap { mask -> NormalizedPhotoMask? in
            guard let mask, mask.isValid, mask.activeCoverage >= 0.004, mask.activeCoverage <= 0.86 else {
                return nil
            }
            return mask
        }.count
        guard reliableRegionCount > 0 else {
            actions.append(PhotographyAction(
                title: "整图协调降级：仅使用实测影调",
                reason: "没有可靠单一主体或语义区域蒙版，只执行直方图、曲线、白平衡与亮度蒙版处理。"
            ))
            return
        }

        if analysis.contrastProfile == .flat {
            recipe.toneCurveAmount = min(0.5, max(recipe.toneCurveAmount, 0.28))
            recipe.localContrastAmount = min(0.1, max(recipe.localContrastAmount, 0.065))
        } else if analysis.contrastProfile == .highContrast {
            recipe.contrast = min(recipe.contrast, 1.02)
            recipe.shadowRollOff = max(recipe.shadowRollOff, 0.22)
            recipe.highlightRollOff = max(recipe.highlightRollOff, 0.28)
        }
        if analysis.averageSaturation < 0.32 {
            recipe.vibrance = min(0.18, max(recipe.vibrance, 0.075))
        }
        recipe.colorGradeIntensity = min(0.2, max(recipe.colorGradeIntensity, 0.1))
        recipe.luminanceMaskStrength = min(0.76, max(recipe.luminanceMaskStrength, 0.36))
        actions.append(PhotographyAction(
            title: "整图协调模式：区域关系共同驱动成片",
            reason: "主体证据不足；以 \(reliableRegionCount) 个可靠区域协调天空高光、植被层次、地面引导和背景竞争，而不是回退到极弱全局轻调。Scene Profile：\(context.sceneProfile.weightSummary)"
        ))
    }

    /// 人物保护必须最后执行，确保任何场景、风格或问题修正规则都不能重新开启
    /// 人脸专属提亮、过强皮肤细节处理或疑似美颜式的橙色明度提升。
    private func enforcePortraitProtection(
        analysis: PhotoAnalysis,
        recipe: inout AutomaticEditingRecipe,
        actions: inout [PhotographyAction]
    ) {
        guard analysis.containsPersonEvidence else { return }

        recipe.faceExposureEV = 0
        recipe.subjectExposureEV = analysis.personMask?.isValid == true
            ? min(recipe.subjectExposureEV, 0.16)
            : 0
        recipe.skinTextureProtection = max(recipe.skinTextureProtection, 0.72)
        recipe.noiseReductionAmount = min(recipe.noiseReductionAmount, 0.025)
        recipe.sharpeningAmount = min(recipe.sharpeningAmount, 0.085)
        recipe.localContrastAmount = min(recipe.localContrastAmount, 0.07)
        recipe.temperatureShift = recipe.temperatureShift.clamped(to: -35...35)
        recipe.tintShift = recipe.tintShift.clamped(to: -2...2)
        recipe.saturation = min(recipe.saturation, 1)
        recipe.vibrance = min(recipe.vibrance, 0.055)
        recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.055)
        recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.025)
        recipe.midtoneWarmAmount = min(recipe.midtoneWarmAmount, 0.025)
        recipe.highlightWarmAmount = min(recipe.highlightWarmAmount, 0.03)
        recipe.colorContrast = min(recipe.colorContrast, 0.025)
        recipe.hsl.orangeHue = 0
        recipe.hsl.orangeLuminance = 0
        recipe.hsl.orangeSaturation = 0
        recipe.skySaturation = min(recipe.skySaturation, 1)

        actions.append(
            PhotographyAction(
                title: "执行最高优先级人物保护",
                reason: "禁止人脸专属提亮、几何变形、生成式修复和磨皮；只允许整个人物与环境的摄影光影关系调整，并保留真实皮肤纹理。"
            )
        )
    }

    /// Keeps white/grey materials and the source-relative skin relationship neutral.
    /// This is deliberately applied after scene styling so a style cannot re-introduce
    /// the orange skin, cyan sky or yellow-green neutral drift found in V8.1 captures.
    private func applyColorIntegrityGuards(
        analysis: PhotoAnalysis,
        recipe: inout AutomaticEditingRecipe,
        actions: inout [PhotographyAction]
    ) {
        let context = analysis.photographyContext
        let isOvercast = context.lightingConditions.contains(.overcast)
        let neutralArchitecture = (analysis.architectureStatistics?.averageSaturation ?? 1) < 0.18
            && (analysis.architectureMask?.activeCoverage ?? 0) >= 0.08
        let neutralDominant = analysis.averageSaturation < 0.2 || neutralArchitecture

        if isOvercast {
            let neutralCoverage = analysis.architectureMask?.activeCoverage ?? 0
            let gradeLimit: Float = max(0.04, 0.065 - neutralCoverage * 0.06)
            let coolLimit: Float = max(0.012, 0.025 - neutralCoverage * 0.03)
            recipe.temperatureShift = recipe.temperatureShift.clamped(to: -25...25)
            recipe.tintShift = recipe.tintShift.clamped(to: -1.5...1.5)
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, gradeLimit)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, coolLimit)
            recipe.midtoneWarmAmount = min(recipe.midtoneWarmAmount, 0.025)
            recipe.highlightWarmAmount = min(recipe.highlightWarmAmount, 0.03)
            recipe.colorContrast = min(recipe.colorContrast, 0.035)
            recipe.hsl.cyanSaturation = min(0, max(recipe.hsl.cyanSaturation, -0.035))
            recipe.hsl.blueSaturation = min(0, max(recipe.hsl.blueSaturation, -0.035))
            recipe.hsl.greenSaturation = min(0.01, recipe.hsl.greenSaturation)
            recipe.skySaturation = min(recipe.skySaturation, 1)
            recipe.exposureEV = max(recipe.exposureEV, -0.025)
            actions.append(PhotographyAction(
                title: "阴天中性色保护",
                reason: "阴天与低色度天空不具备蓝天证据，因此禁止强制青蓝或暖黄分离，只保留动态范围、结构和局部层次。"
            ))
        }

        if neutralDominant {
            recipe.temperatureShift = recipe.temperatureShift.clamped(to: -45...45)
            recipe.tintShift = recipe.tintShift.clamped(to: -2.5...2.5)
            recipe.saturation = min(recipe.saturation, 1.005)
            recipe.vibrance = min(recipe.vibrance, 0.075)
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.09)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.04)
            recipe.midtoneWarmAmount = min(recipe.midtoneWarmAmount, 0.035)
            recipe.highlightWarmAmount = min(recipe.highlightWarmAmount, 0.045)
            recipe.colorContrast = min(recipe.colorContrast, 0.045)
            actions.append(PhotographyAction(
                title: "白色与灰色材质保护",
                reason: "画面包含大面积低色度或建筑中性色，限制全局色偏，避免白车、灰墙和阴天天空被染色。"
            ))
        }
    }

    private func treatmentPlan(
        analysis: PhotoAnalysis,
        context: PhotographyContext,
        target: AdaptivePhotographyTarget,
        recipe: AutomaticEditingRecipe
    ) -> PhotographyTreatmentPlan {
        var regions = [
            RegionalTreatment(
                region: .global,
                objective: "依据当前照片测量完成曝光、动态范围、白平衡、曲线和全图色彩关系的整体制作。"
            )
        ]
        let sceneRegionsAllowed = !analysis.containsPersonEvidence || analysis.personMask?.isValid == true
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
        if sceneRegionsAllowed {
            let measuredRegions: [(TreatmentRegion, String)] = [
                (.subject, "围绕可靠显著主体建立局部明暗、色彩分离和材质层次，不把背景元素一并强化。"),
                (.ground, "在道路与地面蒙版内恢复可用阴影并建立材质层次。"),
                (.vegetation, "在植被蒙版内按区域实测调整绿黄关系，不用全图增绿或增黄。"),
                (.water, "在水面蒙版内控制高光、色彩与局部对比，保留真实反射。"),
                (.architecture, "在建筑与室内结构蒙版内控制光源并增强线条和材质，不影响人物。")
            ]
            for (region, objective) in measuredRegions {
                guard let adjustment = RegionalPixelAdjustment.make(
                    region: region,
                    analysis: analysis,
                    recipe: recipe
                ) else { continue }
                regions.append(RegionalTreatment(
                    region: region,
                    objective: objective,
                    reason: adjustment.reason,
                    parameters: adjustment.traceSummary,
                    maximumSafeAdjustment: "区域曝光不超过 ±0.14 EV；饱和度变化不超过 7.5%；局部清晰度不超过 0.075。",
                    confidence: adjustment.confidence,
                    fallback: adjustment.fallback
                ))
            }
        }
        if analysis.containsPersonEvidence, analysis.personMask?.isValid == true {
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
        }

        let lighting = context.lightingConditions.map(\.rawValue).joined(separator: ",")
        return PhotographyTreatmentPlan(
            finalLook: "按逐图目标协调影调、色彩和区域关系：\(target.summaryText)",
            lightingDesign: "\(context.lightDirection.rawValue) · \(lighting.isEmpty ? "unclassified" : lighting)",
            regionalTreatments: regions,
            portraitProtection: analysis.containsPersonEvidence ? .strict : .inactive
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
            let vegetationSaturation = analysis.vegetationStatistics?.averageSaturation ?? analysis.averageSaturation
            let skySaturation = analysis.skyStatistics?.averageSaturation ?? analysis.averageSaturation
            recipe.hsl.greenSaturation = max(-0.08, min(recipe.hsl.greenSaturation, vegetationSaturation > 0.38 ? -0.04 : 0.025))
            recipe.hsl.blueSaturation = max(-0.07, min(recipe.hsl.blueSaturation, skySaturation > 0.42 ? -0.035 : 0.035))
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
            recipe.shadowRollOff = max(recipe.shadowRollOff, 0.1)
            recipe.lowerMidtoneLift = max(recipe.lowerMidtoneLift, 0.004)
            recipe.upperMidtoneSeparation = max(recipe.upperMidtoneSeparation, 0.008)
            recipe.highlightRollOff = max(recipe.highlightRollOff, 0.12)
            recipe.whitePoint = min(recipe.whitePoint, 0.995)
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.1)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.04)
            recipe.midtoneWarmAmount = min(recipe.midtoneWarmAmount, 0.04)
            recipe.highlightWarmAmount = min(recipe.highlightWarmAmount, 0.05)
            recipe.colorContrast = min(recipe.colorContrast, 0.05)
            recipe.bloomIntensity = min(recipe.bloomIntensity, 0.002)
            recipe.backgroundSeparation = min(recipe.backgroundSeparation, analysis.containsFaces ? 0.045 : 0.025)
        case .standard:
            recipe.shadowRollOff = max(recipe.shadowRollOff, 0.22)
            recipe.lowerMidtoneLift = max(recipe.lowerMidtoneLift, 0.007)
            recipe.midtoneBias = max(recipe.midtoneBias, 0.002)
            recipe.upperMidtoneSeparation = max(recipe.upperMidtoneSeparation, 0.016)
            recipe.highlightRollOff = max(recipe.highlightRollOff, 0.28)
            recipe.whitePoint = min(recipe.whitePoint, 0.988)
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.18)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.09)
            recipe.midtoneWarmAmount = min(recipe.midtoneWarmAmount, 0.08)
            recipe.highlightWarmAmount = min(recipe.highlightWarmAmount, 0.11)
            recipe.colorContrast = min(recipe.colorContrast, 0.09)
            recipe.bloomIntensity = min(recipe.bloomIntensity, 0.004)
            recipe.halationIntensity = min(recipe.halationIntensity, 0.0015)
            recipe.grainAmount = min(recipe.grainAmount, 0.006)
            recipe.backgroundSeparation = min(recipe.backgroundSeparation, 0.065)
        case .dramatic:
            recipe.shadowRollOff = max(recipe.shadowRollOff, 0.36)
            recipe.lowerMidtoneLift = min(recipe.lowerMidtoneLift, -0.005)
            recipe.midtoneBias = min(recipe.midtoneBias, -0.008)
            recipe.upperMidtoneSeparation = max(recipe.upperMidtoneSeparation, 0.045)
            recipe.highlightRollOff = max(recipe.highlightRollOff, 0.58)
            recipe.whitePoint = min(recipe.whitePoint, 0.965)
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.28)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.16)
            recipe.midtoneWarmAmount = min(recipe.midtoneWarmAmount, 0.12)
            recipe.highlightWarmAmount = min(recipe.highlightWarmAmount, 0.2)
            recipe.colorContrast = min(recipe.colorContrast, 0.16)
            recipe.bloomIntensity = min(recipe.bloomIntensity, 0.007)
            recipe.halationIntensity = min(recipe.halationIntensity, 0.003)
            recipe.grainAmount = min(recipe.grainAmount, 0.012)
            recipe.backgroundSeparation = min(recipe.backgroundSeparation, 0.09)
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
        let skyStatistics = analysis.skyStatistics
        let skyHighlightRatio = skyStatistics?.highlightRatio ?? analysis.highlightRatio
        let skyContrast = skyStatistics?.contrastRange ?? analysis.contrastRange
        let skySaturation = skyStatistics?.averageSaturation ?? analysis.averageSaturation
        let recoverableHighlights = max(0, skyHighlightRatio - analysis.whiteRatio)
        let recoveryStrength = min(1, max(0, recoverableHighlights * 3.2 + max(0, skyContrast - 0.42)))
        let saturationHeadroom = min(1, max(0, (0.48 - skySaturation) * 2.5))

        switch strategy {
        case .landscape, .outdoor, .brightOutdoor, .highContrast:
            recipe.skyExposureEV = -(0.025 + 0.105 * recoveryStrength)
            recipe.skyHighlightAmount = 0.78 - 0.26 * recoveryStrength
            recipe.skySaturation = 1 + 0.08 * saturationHeadroom
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
        problems: PhotoProblemReport,
        recipe: inout AutomaticEditingRecipe,
        actions: inout [PhotographyAction]
    ) {
        switch strategy {
        case .portrait:
            recipe.hsl.orangeHue = 0
            recipe.hsl.orangeSaturation = 0
            recipe.hsl.orangeLuminance = 0
            recipe.hsl.cyanSaturation = -0.035
            recipe.saturation = min(recipe.saturation, 1.01)
            recipe.vibrance = min(max(recipe.vibrance, 0.035), 0.075)
            recipe.sharpeningAmount = min(max(recipe.sharpeningAmount, 0.1), 0.16)
            recipe.noiseReductionAmount = max(recipe.noiseReductionAmount, 0.012)
            recipe.skinTextureProtection = 0.56
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.38)
            recipe.toneCurveStyle = .portrait
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.055)
            recipe.highlightWarmAmount = min(recipe.highlightWarmAmount, 0.03)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.025)
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
            recipe.hsl.orangeHue = 0
            recipe.hsl.orangeSaturation = 0
            recipe.hsl.orangeLuminance = 0
            recipe.exposureEV = min(recipe.exposureEV, -0.04)
            recipe.highlightAmount = min(recipe.highlightAmount, 0.5)
            recipe.shadowAmount = min(max(recipe.shadowAmount, 0.12), 0.28)
            recipe.saturation = min(recipe.saturation, 1.01)
            recipe.vibrance = min(max(recipe.vibrance, 0.035), 0.075)
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
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.06)
            recipe.highlightWarmAmount = min(recipe.highlightWarmAmount, 0.035)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.025)
            actions.append(
                PhotographyAction(
                    title: "保天空并协调人物与环境光比",
                    reason: "分区测光确认人物暗于背景；只在可靠人物蒙版内调整整个人物，同时压住背景高光，不单独提亮人脸。"
                )
            )
        case .landscape:
            let recoverableHighlights = max(0, analysis.highlightRatio - analysis.whiteRatio)
            let recoverableShadows = max(0, analysis.shadowRatio - analysis.blackRatio)
            recipe.hsl.greenSaturation = 0.035
            recipe.hsl.greenLuminance = 0.012
            recipe.hsl.blueSaturation = 0.03
            recipe.hsl.blueLuminance = -0.012
            if !problems.contains(.clippedHighlights) {
                let highlightTarget = max(0.78, 1 - min(0.2, recoverableHighlights * 1.4))
                recipe.highlightAmount = min(recipe.highlightAmount, highlightTarget)
            }
            if !problems.contains(.blockedShadows), recoverableShadows > 0.24 {
                recipe.shadowAmount = max(recipe.shadowAmount, min(0.13, (recoverableShadows - 0.24) * 0.5))
            }
            let contrastLift: Float = analysis.contrastRange < 0.48
                ? 0.045
                : (analysis.contrastRange < 0.72 ? 0.03 : 0.012)
            recipe.contrast += contrastLift
            recipe.saturation += analysis.averageSaturation < 0.3 ? 0.008 : 0
            recipe.vibrance += min(0.15, max(0.07, (0.42 - analysis.averageSaturation) * 0.5))
            recipe.toneCurveAmount = max(recipe.toneCurveAmount, 0.62)
            recipe.toneCurveStyle = .landscape
            recipe.colorGradeIntensity = max(recipe.colorGradeIntensity, 0.34)
            recipe.shadowCoolAmount = max(recipe.shadowCoolAmount, 0.28)
            recipe.highlightWarmAmount = max(recipe.highlightWarmAmount, 0.12)
            recipe.localContrastAmount = max(
                recipe.localContrastAmount,
                min(0.13, 0.075 + max(0, analysis.detailScore - analysis.noiseEstimate) * 0.2)
            )
            recipe.sharpeningAmount = max(recipe.sharpeningAmount, 0.16)
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

struct AestheticPhotographyPlan: Equatable, Sendable {
    let confidence: Float
    let visualUnderstanding: VisualSceneUnderstandingResult
    let primaryObjective: String
    let emphasizedRegions: [String]
    let subduedRegions: [String]
    let protectedRegions: [String]
    let subjectBackgroundDeltaTarget: Float?
    let localContrastTarget: Float
    let shadowCoolTarget: Float
    let midtoneWarmTarget: Float
    let colorSeparationStrength: Float
    let risks: [String]
    let rationale: [String]

    var traceSummary: String {
        String(
            format: "confidence=%.3f objective=%@ subjectDelta=%@ localContrast=%.3f shadowCool=%.3f midtoneWarm=%.3f colorSeparation=%.3f emphasize=[%@] subdue=[%@] protect=[%@] risks=[%@] rationale=[%@]",
            confidence,
            primaryObjective,
            subjectBackgroundDeltaTarget.map { String(format: "%.3f", $0) } ?? "n/a",
            localContrastTarget,
            shadowCoolTarget,
            midtoneWarmTarget,
            colorSeparationStrength,
            emphasizedRegions.joined(separator: ","),
            subduedRegions.joined(separator: ","),
            protectedRegions.joined(separator: ","),
            risks.joined(separator: ","),
            rationale.joined(separator: " | ")
        )
    }
}

/// Turns measured scene evidence into relationships the solver can pursue. It
/// never selects a preset: every target is a bounded residual from this image.
/// This is used only by the isolated C validation path until real iPhone blind
/// tests show that it is preferable to the current B result.
struct AestheticPhotographyPlanner {
    func makePlan(
        analysis: PhotoAnalysis,
        problems: PhotoProblemReport,
        targetProfile: PhotographyTargetProfile
    ) -> AestheticPhotographyPlan {
        let understanding = analysis.visualSceneUnderstanding
        let subjectStatistics = reliableSubjectStatistics(analysis)
        let currentSubjectDelta: Float? = {
            if analysis.containsPersonEvidence {
                return analysis.faceToBackgroundLuminanceDelta
            }
            guard let subjectStatistics else { return nil }
            return subjectStatistics.averageLuminance - analysis.averageLuminance
        }()
        let subjectReliability = understanding.subjectConfidence
        let desiredSubjectDelta = currentSubjectDelta.map { current -> Float in
            let darkSubjectNeed = max(0, -0.035 - current)
            let excessiveBrightness = max(0, current - 0.18)
            let correction = darkSubjectNeed * 0.38 - excessiveBrightness * 0.18
            return bounded(current + correction * subjectReliability, -0.08...0.18)
        }
        let contrastResidual = max(
            0,
            targetProfile.localContrastTarget - analysis.contrastRange
        )
        let noiseProtection = max(0.22, 1 - analysis.noiseEstimate * 2.8)
        let localContrastTarget = bounded(
            analysis.contrastRange + contrastResidual * 0.46 * noiseProtection,
            analysis.contrastRange...(analysis.contrastRange + 0.08)
        )

        let hasMixedLightEvidence = analysis.mixedLightScore >= 0.12
            && analysis.highlightSourceCount > 0
        let channelWarmth = analysis.redAverage - analysis.blueAverage
        let colorHeadroom = max(0, 0.10 - abs(channelWarmth))
        let portraitProtection = analysis.containsPersonEvidence ? Float(0.45) : 1
        let colorSeparation = hasMixedLightEvidence
            ? bounded(
                analysis.mixedLightScore * colorHeadroom * portraitProtection,
                0...0.035
            )
            : 0
        let shadowCool = bounded(
            max(0, channelWarmth) * 0.10 * colorSeparation,
            0...0.018
        )
        let midtoneWarm = bounded(
            max(0, -channelWarmth) * 0.08 * colorSeparation,
            0...0.014
        )

        var emphasized: [String] = []
        if understanding.subjectConfidence >= 0.58 {
            emphasized.append(understanding.primarySubjectDescription)
        }
        if analysis.groundMask?.qualityAssessment.isUsable == true,
           (analysis.groundMask?.activeCoverage ?? 0) > 0.08 {
            emphasized.append("地面/道路空间引导")
        }
        var subdued: [String] = []
        if analysis.architectureMask?.qualityAssessment.isUsable == true,
           analysis.subjectPriorityProfile.mode == .primarySubject,
           (analysis.architectureMask?.activeCoverage ?? 0) < 0.12 {
            subdued.append("低覆盖建筑背景")
        }
        var risks = understanding.unknowns
        if analysis.noiseEstimate > 0.12 { risks.append("暗部提亮可能放大噪声") }
        if analysis.mixedLightScore > 0.18 { risks.append("混合光下禁止强行统一色温") }
        if analysis.containsPersonEvidence { risks.append("人物区域禁止美颜与局部生成式修改") }

        let objective = understanding.subjectConfidence >= 0.58
            ? "在保持真实氛围与人物/物体颜色身份的前提下，建立主体和环境的可读层次。"
            : "主体证据不足，使用影调、颜色关系和可靠区域完成整图协调。"
        let rationale = [
            "视觉理解：\(understanding.primarySubjectDescription)，置信度 \(String(format: "%.1f", understanding.subjectConfidence * 100))%。",
            String(format: "原图亮度 %.3f、反差 %.3f、阴影 %.3f、高光 %.3f、噪声 %.3f。", analysis.averageLuminance, analysis.contrastRange, analysis.shadowRatio, analysis.highlightRatio, analysis.noiseEstimate),
            "参考特征只校准目标关系，影响 \(String(format: "%.1f", targetProfile.referenceInfluence * 100))%；不复制曲线、HSL 或白平衡。"
        ]
        return AestheticPhotographyPlan(
            confidence: min(targetProfile.referenceMatch.confidence, max(0.42, subjectReliability)),
            visualUnderstanding: understanding,
            primaryObjective: objective,
            emphasizedRegions: emphasized,
            subduedRegions: subdued,
            protectedRegions: understanding.protectedRegions,
            subjectBackgroundDeltaTarget: desiredSubjectDelta,
            localContrastTarget: localContrastTarget,
            shadowCoolTarget: shadowCool,
            midtoneWarmTarget: midtoneWarm,
            colorSeparationStrength: colorSeparation,
            risks: Array(Set(risks)).sorted(),
            rationale: rationale
        )
    }

    private func reliableSubjectStatistics(_ analysis: PhotoAnalysis) -> PhotoRegionStatistics? {
        analysis.nonPersonPrimarySubjectStatistics
    }

    private func bounded(_ value: Float, _ range: ClosedRange<Float>) -> Float {
        min(range.upperBound, max(range.lowerBound, value))
    }
}

struct AdaptivePhotographySolution: Equatable, Sendable {
    let target: AdaptivePhotographyTarget
    let recipe: AutomaticEditingRecipe
    let parameterEvidence: [PhotographyParameterEvidence]
    let actions: [PhotographyAction]
}

/// Generates a measurable destination from the current image. Lighting labels
/// contribute only an atmosphere-preservation weight; no label selects a recipe.
struct AdaptivePhotographyTargetGenerator {
    func makeTarget(
        analysis: PhotoAnalysis,
        problems: PhotoProblemReport
    ) -> AdaptivePhotographyTarget {
        let conditions = Set(analysis.photographyContext.lightingConditions)
        let measuredDarkness = ((0.36 - analysis.averageLuminance) / 0.22).clamped(to: 0...1)
        let nightEvidence: Float = conditions.contains(.night) ? max(0.72, measuredDarkness) : measuredDarkness * 0.42
        let atmosphereProtection = (
            nightEvidence * 0.58
                + analysis.mixedLightScore * 0.24
                + analysis.highlightConcentration * 0.18
        ).clamped(to: 0...1)
        let underexposureEvidence = problems.problems
            .filter { $0.kind == .underexposed }
            .map { $0.confidence * Float($0.severity.rawValue) / 3 }
            .max() ?? 0
        let overexposureEvidence = problems.problems
            .filter { $0.kind == .overexposed }
            .map { $0.confidence * Float($0.severity.rawValue) / 3 }
            .max() ?? 0
        let luminanceCenter = (
            0.455
                + (analysis.midtoneRatio - 0.58) * 0.07
                - atmosphereProtection * 0.14
                - min(0.03, analysis.spatialLuminanceVariance * 0.08)
                + underexposureEvidence * 0.018
                - overexposureEvidence * 0.018
        ).clamped(to: 0.28...0.52)
        let luminanceHalfWidth = (0.045 + atmosphereProtection * 0.02).clamped(to: 0.04...0.07)
        let noisePenalty = (analysis.noiseEstimate * 0.16).clamped(to: 0...0.05)
        let desiredContrastGain = max(0, 0.57 - analysis.contrastRange) * (1 - noisePenalty * 8)
        let targetContrast = (
            analysis.contrastRange + desiredContrastGain * 0.72
                - max(0, analysis.contrastRange - 0.7) * 0.55
        ).clamped(to: 0.46...0.66)
        let recoverableShadow = max(0, analysis.shadowRatio - analysis.blackRatio)
        let shadowFloor = min(analysis.blackRatio, analysis.shadowRatio)
        let targetShadow = (
            analysis.shadowRatio - recoverableShadow * (0.18 + (1 - atmosphereProtection) * 0.12) * max(0.3, 1 - analysis.noiseEstimate * 2.5)
        ).clamped(to: shadowFloor...analysis.shadowRatio)
        let recoverableHighlight = max(0, analysis.highlightRatio - analysis.whiteRatio)
        let highlightFloor = min(analysis.whiteRatio, analysis.highlightRatio)
        let targetHighlight = (
            analysis.highlightRatio - recoverableHighlight * (0.22 + analysis.highlightConcentration * 0.32)
        ).clamped(to: highlightFloor...analysis.highlightRatio)
        let saturationCenter: Float = analysis.containsPersonEvidence ? 0.25 : 0.29
        let saturationTarget = (
            analysis.averageSaturation
                + (saturationCenter - analysis.averageSaturation) * (analysis.averageSaturation < saturationCenter ? 0.28 : 0.16)
        ).clamped(to: 0.12...0.48)

        return AdaptivePhotographyTarget(
            luminance: luminanceCenter,
            luminanceMinimum: luminanceCenter - luminanceHalfWidth,
            luminanceMaximum: luminanceCenter + luminanceHalfWidth,
            contrast: targetContrast,
            shadowRatio: targetShadow,
            highlightRatio: targetHighlight,
            saturation: saturationTarget,
            atmosphereProtection: atmosphereProtection,
            rationale: String(
                format: "由本图亮度 %.3f、中间调 %.3f、反差 %.3f、阴影/黑位 %.3f/%.3f、高光/白位 %.3f/%.3f、饱和度 %.3f、噪声 %.3f、混合光 %.3f共同求得；场景标签只提供氛围保护信号。",
                analysis.averageLuminance,
                analysis.midtoneRatio,
                analysis.contrastRange,
                analysis.shadowRatio,
                analysis.blackRatio,
                analysis.highlightRatio,
                analysis.whiteRatio,
                analysis.averageSaturation,
                analysis.noiseEstimate,
                analysis.mixedLightScore
            )
        )
    }
}

/// The only production parameter source. It starts from a neutral recipe and
/// solves every control from current-image measurements and the generated target.
struct AdaptivePhotographyParameterSolver {
    func solve(
        analysis: PhotoAnalysis,
        problems: PhotoProblemReport,
        targetProfile: PhotographyTargetProfile? = nil,
        aestheticPlan: AestheticPhotographyPlan? = nil
    ) -> AdaptivePhotographySolution {
        let target = targetProfile?.resolvedTarget
            ?? AdaptivePhotographyTargetGenerator().makeTarget(
                analysis: analysis,
                problems: problems
            )
        var recipe = AutomaticEditingRecipe.naturalEnhancement
        var actions: [PhotographyAction] = []
        let conditions = Set(analysis.photographyContext.lightingConditions)
        let isNight = conditions.contains(.night) || target.atmosphereProtection > 0.62
        let isOvercast = conditions.contains(.overcast)
        let hasPerson = analysis.containsPersonEvidence
        let reliability = analysis.sceneRecognitionDiagnostics.status == .failed ? Float(0.72) : 1

        let targetLuminance = target.luminance
        let luminanceDelta = targetLuminance - analysis.averageLuminance
        let needsExposure = problems.contains(.underexposed) || problems.contains(.overexposed)
        recipe.exposureEV = needsExposure
            ? bounded(luminanceDelta * (isNight ? 0.34 : 0.52) * reliability, -0.28...0.28)
            : bounded(luminanceDelta * 0.18 * reliability, -0.045...0.045)

        let recoverableHighlights = max(0, analysis.highlightRatio - analysis.whiteRatio)
        let highlightCompression = min(0.5, recoverableHighlights * 1.8 + analysis.whiteRatio * 0.7)
        recipe.highlightAmount = bounded(1 - highlightCompression, 0.46...1)
        recipe.highlightRollOff = bounded(highlightCompression * 0.9, 0...0.55)
        recipe.whitePoint = bounded(1 - analysis.whiteRatio * 0.18, 0.965...1)
        recipe.blackPoint = analysis.blackRatio < 0.006 && contrastDeficitForBlackPoint(analysis) > 0.1
            ? bounded((0.006 - analysis.blackRatio) * 0.55, 0...0.004)
            : 0

        let recoverableShadows = max(0, analysis.shadowRatio - analysis.blackRatio)
        let noiseHeadroom = max(0.28, 1 - analysis.noiseEstimate * 2.4)
        let shadowCeiling: Float = isNight ? 0.18 : 0.46
        recipe.shadowAmount = bounded(recoverableShadows * 0.72 * noiseHeadroom, 0...shadowCeiling)
        recipe.shadowRollOff = bounded(recoverableShadows * 0.55, 0...0.42)

        let depthTarget = target.contrast
        let contrastDeficit = depthTarget - analysis.contrastRange
        recipe.contrast = bounded(1 + contrastDeficit * 0.16, 0.97...1.095)
        recipe.toneCurveAmount = abs(contrastDeficit) < 0.025
            ? 0
            : bounded(abs(contrastDeficit) * 0.9, 0...0.62)
        recipe.toneCurveStyle = contrastDeficit >= 0 ? .landscape : .softHighlights
        recipe.localContrastAmount = bounded(
            max(0, contrastDeficit) * 0.22 * noiseHeadroom,
            0...0.13
        )
        recipe.brightness = bounded(luminanceDelta * 0.075, -0.035...0.035)
        recipe.lowerMidtoneLift = bounded(
            (target.shadowRatio - analysis.shadowRatio) * -0.12 * noiseHeadroom,
            0...0.06
        )
        recipe.midtoneBias = bounded(luminanceDelta * 0.08, -0.035...0.035)
        recipe.upperMidtoneSeparation = bounded(
            max(0, contrastDeficit) * 0.13,
            0...0.07
        )

        let neutralEvidence = analysis.neutralColorStatistics
        let hasReliableNeutralEvidence = neutralEvidence?.isReliable == true
        let redBlueDelta: Float = hasReliableNeutralEvidence
            ? (neutralEvidence?.warmBias ?? 0)
            : 0
        let greenExcess: Float = hasReliableNeutralEvidence
            ? (neutralEvidence?.greenBias ?? 0)
            : 0
        let mixedLightProtection = max(0.35, 1 - analysis.mixedLightScore * 1.8)
        if hasReliableNeutralEvidence,
           (problems.contains(.coolCast) || problems.contains(.warmCast)) {
            recipe.temperatureShift = bounded(
                -redBlueDelta * 1_450 * mixedLightProtection,
                -260...260
            )
        } else {
            recipe.temperatureShift = 0
        }
        recipe.tintShift = hasReliableNeutralEvidence && problems.contains(.greenCast)
            ? bounded(greenExcess * 92 * mixedLightProtection, -7...7)
            : 0

        if problems.contains(.oversaturated) {
            recipe.saturation = bounded(1 - (analysis.averageSaturation - 0.5) * 0.22, 0.96...1)
            recipe.vibrance = 0
        } else {
            recipe.saturation = 1
            let colorHeadroom = max(0, 0.31 - analysis.averageSaturation)
            recipe.vibrance = bounded(colorHeadroom * (hasPerson ? 0.2 : 0.42), 0...0.14)
        }

        recipe.noiseReductionAmount = bounded(
            max(0, analysis.noiseEstimate - 0.055) * 0.24 + (isNight ? 0.008 : 0),
            0...0.055
        )
        let detailDeficit = max(0, 0.2 - analysis.detailScore)
        recipe.sharpeningAmount = bounded(
            detailDeficit * 0.32 - max(0, analysis.noiseEstimate - 0.04) * 0.12,
            0...(hasPerson ? 0.075 : 0.13)
        )

        recipe.shadowZoneExposureEV = bounded(
            recoverableShadows * 0.24 * noiseHeadroom,
            0...(isNight ? 0.1 : 0.18)
        )
        recipe.highlightZoneExposureEV = -bounded(recoverableHighlights * 0.7, 0...0.2)
        let luminanceResidual = recoverableShadows + recoverableHighlights
        recipe.luminanceMaskStrength = luminanceResidual < 0.08
            ? 0
            : bounded(luminanceResidual * 1.1, 0...0.82)

        if !hasPerson,
           analysis.subjectPriorityProfile.mode == .primarySubject,
           let subject = reliableSubjectStatistics(analysis) {
            let subjectDeficit = analysis.averageLuminance - subject.averageLuminance
            recipe.subjectExposureEV = bounded(
                subjectDeficit * 0.42 * analysis.subjectPriorityProfile.confidence,
                0...0.15
            )
            recipe.backgroundSeparation = bounded(
                max(0, subjectDeficit) * 0.32 * analysis.subjectPriorityProfile.confidence,
                0...0.11
            )
        }

        if let targetProfile, targetProfile.referenceApplied {
            let localContrastResidual = max(0, (
                aestheticPlan?.localContrastTarget
                    ?? targetProfile.localContrastTarget
            ) - analysis.contrastRange)
            recipe.localContrastAmount = max(
                recipe.localContrastAmount,
                bounded(localContrastResidual * 0.16, 0...0.045)
            )
            if !hasPerson,
               analysis.subjectPriorityProfile.confidence >= 0.58,
               let subject = reliableSubjectStatistics(analysis),
               let desiredDelta = aestheticPlan?.subjectBackgroundDeltaTarget
                    ?? targetProfile.subjectBackgroundDeltaTarget {
                let currentDelta = subject.averageLuminance - analysis.averageLuminance
                let residual = desiredDelta - currentDelta
                recipe.subjectExposureEV = bounded(
                    recipe.subjectExposureEV + residual * 0.18,
                    -0.035...0.15
                )
                recipe.backgroundSeparation = bounded(
                    recipe.backgroundSeparation + abs(residual) * 0.08,
                    0...0.11
                )
            }
        }

        // HSL is rebuilt from measured regional colour. No scene name is allowed
        // to inject a stock orange/teal/green treatment.
        recipe.hsl = .neutral
        if !hasPerson,
           analysis.subjectPriorityProfile.confidence >= 0.54 || !analysis.semanticObjectRegions.isEmpty,
           let subject = reliableSubjectStatistics(analysis) {
            let orangeHeadroom = max(0, 0.42 - subject.averageSaturation)
            recipe.hsl.orangeSaturation = bounded(orangeHeadroom * 0.16, 0...0.055)
            recipe.hsl.orangeLuminance = bounded(
                max(0, analysis.averageLuminance - subject.averageLuminance) * 0.09,
                0...0.035
            )
        }
        if let vegetation = analysis.vegetationStatistics {
            recipe.hsl.greenSaturation = bounded(
                (0.27 - vegetation.averageSaturation) * 0.14,
                -0.045...0.035
            )
            recipe.hsl.greenLuminance = bounded(
                (analysis.averageLuminance - 0.045 - vegetation.averageLuminance) * 0.08,
                -0.025...0.025
            )
        }
        if let sky = analysis.skyStatistics,
           analysis.skyMask?.qualityAssessment.isUsable == true {
            let skyColorHeadroom = (0.28 - sky.averageSaturation) * 0.12
            let allowedBlueGain = isOvercast ? min(0, skyColorHeadroom) : skyColorHeadroom
            recipe.hsl.cyanSaturation = bounded(allowedBlueGain * 0.6, -0.035...0.035)
            recipe.hsl.blueSaturation = bounded(allowedBlueGain, -0.045...0.045)
            let skyTarget = bounded(
                analysis.averageLuminance + (isOvercast ? 0.12 : 0.08),
                0.48...0.72
            )
            recipe.skyExposureEV = bounded((skyTarget - sky.averageLuminance) * 0.24, -0.12...0.045)
            recipe.skyHighlightAmount = bounded(
                1 - max(0, sky.highlightRatio - 0.08) * 1.1,
                0.58...1
            )
            recipe.skySaturation = 1 + recipe.hsl.blueSaturation * 0.35
        } else {
            recipe.skyExposureEV = 0
            recipe.skyHighlightAmount = 1
            recipe.skySaturation = 1
        }

        // Colour grading is enabled only when the measured channel relationship has
        // enough headroom. It is never populated from a style or scene preset.
        let channelSpread = max(
            abs(analysis.redAverage - analysis.blueAverage),
            abs(analysis.greenAverage - (analysis.redAverage + analysis.blueAverage) * 0.5)
        )
        let gradeHeadroom = max(0, 0.075 - channelSpread) * (1 - target.atmosphereProtection)
        let measuredGrade = bounded(gradeHeadroom * 0.35, 0...0.025)
        recipe.colorGradeIntensity = bounded(
            max(measuredGrade, aestheticPlan?.colorSeparationStrength ?? 0),
            0...0.035
        )
        recipe.shadowCoolAmount = aestheticPlan?.shadowCoolTarget ?? bounded(
            max(0, analysis.redAverage - analysis.blueAverage) * 0.08 * recipe.colorGradeIntensity,
            0...0.012
        )
        recipe.midtoneWarmAmount = aestheticPlan?.midtoneWarmTarget ?? bounded(
            max(0, analysis.blueAverage - analysis.redAverage) * 0.07 * recipe.colorGradeIntensity,
            0...0.012
        )
        recipe.highlightWarmAmount = 0
        recipe.colorContrast = bounded(recipe.colorGradeIntensity * 0.5, 0...0.014)
        recipe.grainAmount = 0

        actions.append(PhotographyAction(
            title: "自适应逐图参数求解",
            reason: String(
                format: "由本图亮度 %.1f%%→目标 %.1f%%、动态范围 %.1f%%、高光 %.1f%%、阴影 %.1f%%、饱和度 %.1f%%、噪声 %.1f%%分别求值；场景标签仅约束意图和安全边界。",
                analysis.averageLuminance * 100,
                targetLuminance * 100,
                analysis.contrastRange * 100,
                analysis.highlightRatio * 100,
                analysis.shadowRatio * 100,
                analysis.averageSaturation * 100,
                analysis.noiseEstimate * 100
            )
        ))
        if let targetProfile, targetProfile.referenceApplied {
            actions.append(PhotographyAction(
                title: "摄影参考目标校准（验证模式）",
                reason: targetProfile.rationale.joined(separator: " ")
            ))
        }
        if let aestheticPlan {
            actions.append(PhotographyAction(
                title: "逐图摄影审美规划（验证模式）",
                reason: aestheticPlan.traceSummary
            ))
        }

        let solved = recipe.clamped()
        let parameterEvidence = evidence(
            recipe: solved,
            analysis: analysis,
            targetLuminance: targetLuminance,
            targetContrast: depthTarget,
            targetSaturation: target.saturation,
            noiseHeadroom: noiseHeadroom
        ).map { item -> PhotographyParameterEvidence in
            guard targetProfile?.referenceApplied == true else { return item }
            let targetDrivenKeys: Set<PhotographyParameterKey> = [
                .exposure, .brightness, .highlights, .shadows, .contrast,
                .toneCurve, .saturation, .vibrance, .localContrast,
                .midtoneContrast, .localExposure
            ]
            guard targetDrivenKeys.contains(item.key) else { return item }
            var rules: [PhotographyKnowledgeRuleID] = [
                .referenceApplicabilityGate,
                .referenceTargetCalibration,
                .referenceValidationIsolation
            ]
            if aestheticPlan != nil {
                rules += [
                    .semanticEvidenceBoundary,
                    .measuredVisualHierarchy,
                    .regionalColorHarmony,
                    .atmospherePreservation
                ]
            }
            return item.appendingKnowledgeRules(rules)
        }
        return AdaptivePhotographySolution(
            target: target,
            recipe: solved,
            parameterEvidence: parameterEvidence,
            actions: actions
        )
    }

    private func reliableSubjectStatistics(_ analysis: PhotoAnalysis) -> PhotoRegionStatistics? {
        analysis.nonPersonPrimarySubjectStatistics
    }

    private func evidence(
        recipe: AutomaticEditingRecipe,
        analysis: PhotoAnalysis,
        targetLuminance: Float,
        targetContrast: Float,
        targetSaturation: Float,
        noiseHeadroom: Float
    ) -> [PhotographyParameterEvidence] {
        let entries: [(PhotographyParameterKey, String, String, String, Float, Float, String, String)] = [
            (.exposure, "使整体亮度进入当前光照的自然区间", String(format: "实测亮度 %.3f", analysis.averageLuminance), String(format: "目标亮度 %.3f", targetLuminance), -0.35, 0.35, "整体中间调接近目标且不改变真实时段", "无明确曝光问题时限制为微调"),
            (.brightness, "微调中间调亮度而不移动黑白端点", String(format: "亮度差 %+.3f", targetLuminance - analysis.averageLuminance), "只承担曝光之后的细微中间调残差", -0.06, 0.06, "中间调更接近目标", "残差很小时保持 0"),
            (.highlights, "保护可恢复高光过渡", String(format: "高光 %.3f / 纯白 %.3f", analysis.highlightRatio, analysis.whiteRatio), "降低高光风险但不伪造已剪切细节", 0.32, 1, "亮部层次改善", "真实光源与纯白端点优先保护"),
            (.shadows, "恢复可用阴影", String(format: "阴影 %.3f / 纯黑 %.3f", analysis.shadowRatio, analysis.blackRatio), String(format: "噪声余量 %.3f", noiseHeadroom), 0, 0.68, "暗部可读且不灰雾", "夜景与高噪声照片自动降低"),
            (.contrast, "协调全局反差", String(format: "实测跨度 %.3f", analysis.contrastRange), String(format: "目标跨度 %.3f", targetContrast), 0.96, 1.14, "建立层次而不制造 HDR", "高反差时只压缩两端"),
            (.toneCurve, "分离中间调", String(format: "跨度差 %+.3f", targetContrast - analysis.contrastRange), "按差值选择曲线幅度", 0, 1, "中间调层次改善", "差值很小时保持低强度"),
            (.whitePoint, "保护白色端点与高光余量", String(format: "纯白占比 %.3f", analysis.whiteRatio), "有纯白风险时轻度收回端点", 0.88, 1, "白色保留层次且不过灰", "没有端点风险时保持 1"),
            (.blackPoint, "避免灰雾同时保护真实黑位", String(format: "纯黑占比 %.3f", analysis.blackRatio), "只有黑位稀少且反差不足时轻微建立黑位", 0, 0.035, "暗部有锚点但不死黑", "夜景或已有黑位时保持 0"),
            (.temperature, "只校正确认的非场景性色偏", neutralEvidenceDescription(analysis, component: .temperature), "中性关系或保留现场光", -600, 600, "不产生统一黄滤镜或蓝滤镜", "没有可靠中性色证据时为 0"),
            (.tint, "只校正确认的偏绿", neutralEvidenceDescription(analysis, component: .tint), "中性色不偏绿", -15, 15, "白色和灰色保持中性", "没有可靠中性色证据时为 0"),
            (.hue, "仅在可靠色域内修正色相关系", String(format: "全图 RGB %.3f/%.3f/%.3f", analysis.redAverage, analysis.greenAverage, analysis.blueAverage), "不旋转全图色相，只允许区域 HSL 的微小色相校正", 0, 0.03, "颜色关系自然且不改变物体真实性", "无可靠区域统计时为 0"),
            (.saturation, "限制全局色彩失真", String(format: "平均饱和度 %.3f", analysis.averageSaturation), "全局饱和只做保护性修正", 0.96, 1.08, "保持真实颜色关系", "低饱和照片改用自然饱和度"),
            (.vibrance, "补充低饱和颜色分离", String(format: "颜色余量 %.3f", max(0, 0.31 - analysis.averageSaturation)), "优先作用于低饱和颜色", 0, 0.32, "色彩可感知但不荧光", "人物照片进一步限制"),
            (.localContrast, "补充可恢复局部层次", String(format: "细节 %.3f / 噪声 %.3f", analysis.detailScore, analysis.noiseEstimate), "由反差缺口与噪声余量共同决定", 0, 0.28, "纹理更清楚且无光晕", "噪声高时降低"),
            (.midtoneContrast, "分离中间调结构", String(format: "中间调 %.3f / 反差差 %+.3f", analysis.midtoneRatio, targetContrast - analysis.contrastRange), "仅补足可恢复的中间调分离", -0.06, 0.1, "主体与环境层次更清楚", "高反差或高噪声时保持低强度"),
            (.shadowColor, "协调阴影颜色", String(format: "R-B %+.3f", analysis.redAverage - analysis.blueAverage), "仅在通道关系存在安全余量时微调", 0, 1, "阴影与整体冷暖协调", "混合光或色偏风险时关闭"),
            (.midtoneColor, "协调中间调颜色", String(format: "B-R %+.3f", analysis.blueAverage - analysis.redAverage), "仅在通道关系存在安全余量时微调", 0, 1, "中间调保持自然", "人物或混合光风险时限制"),
            (.highlightColor, "保护亮部现场光颜色", String(format: "高光 %.3f / 混合光 %.3f", analysis.highlightRatio, analysis.mixedLightScore), "默认不染色真实光源", 0, 1, "亮部不出现统一暖黄", "当前求解器默认关闭"),
            (.localExposure, "建立可靠主体与背景的亮度关系", analysis.salientSubjectStatistics.map { String(format: "主体 %.3f / 全图 %.3f", $0.averageLuminance, analysis.averageLuminance) } ?? "无可靠主体统计", "只修正可靠主体的相对亮度差", 0, 0.3, "主体更清楚且不改变人物面部", "主体不可靠或人物蒙版不足时关闭"),
            (.localHighlights, "按亮度蒙版压制局部高光", String(format: "可恢复高光 %.3f", max(0, analysis.highlightRatio - analysis.whiteRatio)), "高光残差接近目标", 0, 0.24, "亮部过渡更完整", "无高光问题时为 0"),
            (.localShadows, "按亮度蒙版恢复局部阴影", String(format: "可恢复阴影 %.3f / 噪声 %.3f", max(0, analysis.shadowRatio - analysis.blackRatio), analysis.noiseEstimate), "在噪声允许范围内接近阴影目标", 0, 0.22, "暗部可读且不灰雾", "高噪声或夜景氛围时降低"),
            (.localColor, "协调可靠区域色彩", String(format: "饱和度 %.3f / 目标 %.3f", analysis.averageSaturation, targetSaturation), "只在可靠区域统计中调整 HSL", 0, 0.2, "区域色彩有分离且不污染全图", "人物、空蒙版或低置信度时关闭"),
            (.localTexture, "恢复可靠区域材质", String(format: "细节 %.3f / 噪声 %.3f", analysis.detailScore, analysis.noiseEstimate), "局部纹理受噪声余量约束", 0, 0.28, "材质清楚且无光晕", "高噪声或人物纹理风险时降低"),
            (.noiseReduction, "控制暗部高频残差", String(format: "噪声代理 %.3f", analysis.noiseEstimate), "仅超过基线后增加", 0, 0.06, "噪点受控并保留纹理", "人物皮肤与低噪照片保持低强度"),
            (.sharpening, "补充真实边缘清晰度", String(format: "细节分数 %.3f", analysis.detailScore), "与噪声反向联动", 0, 0.22, "细节清晰且无白边", "噪声或人物照片降低上限"),
            (.luminanceMask, "分开处理高光与阴影", String(format: "可恢复阴影 %.3f / 高光 %.3f", max(0, analysis.shadowRatio - analysis.blackRatio), max(0, analysis.highlightRatio - analysis.whiteRatio)), "强度随两端问题增加", 0, 1, "不依赖统一曝光解决局部问题", "区域分割失败时仍可安全使用亮度蒙版"),
            (.orangeHSL, "只在可靠非人物主体中调整橙色关系", analysis.salientSubjectStatistics.map { String(format: "主体饱和度 %.3f", $0.averageSaturation) } ?? "无可靠主体统计", "按主体颜色余量求值", -0.18, 0.18, "果实等暖色主体与环境分离", "人物或主体不可靠时为 0"),
            (.greenHSL, "协调植被颜色层次", analysis.vegetationStatistics.map { String(format: "植被饱和度 %.3f", $0.averageSaturation) } ?? "无可靠植被统计", "接近自然植被色彩范围", -0.2, 0.2, "绿色有层次且不荧光", "无可靠植被统计时为 0"),
            (.blueHSL, "协调可靠天空颜色", analysis.skyStatistics.map { String(format: "天空饱和度 %.3f", $0.averageSaturation) } ?? "无可靠天空统计", "阴天不得增加蓝色，晴空按余量求值", -0.2, 0.16, "天空自然且不青蓝化", "无可靠天空统计时为 0")
        ]
        return entries.map { item in
            let value = actualValue(item.0, recipe: recipe)
            let region: TreatmentRegion
            switch item.0 {
            case .localExposure: region = .subject
            case .orangeHSL: region = .subject
            case .greenHSL: region = .vegetation
            case .blueHSL: region = .sky
            default: region = .global
            }
            return PhotographyParameterEvidence(
                key: item.0,
                purpose: item.1,
                inputEvidence: item.2,
                target: item.3,
                minimumValue: item.4,
                maximumValue: item.5,
                actualValue: value,
                expectedResult: item.6,
                fallbackBehavior: item.7,
                affectedRegion: region,
                decisionStatus: decisionStatus(for: item.0, value: value, analysis: analysis),
                knowledgeRuleIDs: knowledgeRules(for: item.0)
            )
        }
    }

    private enum WhiteBalanceEvidenceComponent {
        case temperature
        case tint
    }

    private func neutralEvidenceDescription(
        _ analysis: PhotoAnalysis,
        component: WhiteBalanceEvidenceComponent
    ) -> String {
        guard let neutral = analysis.neutralColorStatistics else {
            return "无中性色样本；全图 RGB 均值不作为白平衡证据"
        }
        guard neutral.isReliable else {
            return String(
                format: "中性色证据不足：覆盖 %.3f、空间 %.3f、置信度 %.3f",
                neutral.coverage,
                neutral.spatialZoneCoverage,
                neutral.confidence
            )
        }
        switch component {
        case .temperature:
            return String(
                format: "中性色 R-B %+.3f / 覆盖 %.3f / 置信度 %.3f / 混合光 %.3f",
                neutral.warmBias,
                neutral.coverage,
                neutral.confidence,
                analysis.mixedLightScore
            )
        case .tint:
            return String(
                format: "中性色 G-RB %+.3f / 覆盖 %.3f / 置信度 %.3f / 混合光 %.3f",
                neutral.greenBias,
                neutral.coverage,
                neutral.confidence,
                analysis.mixedLightScore
            )
        }
    }

    private func knowledgeRules(
        for key: PhotographyParameterKey
    ) -> [PhotographyKnowledgeRuleID] {
        switch key {
        case .exposure, .brightness, .highlights, .whitePoint, .blackPoint:
            return [.toneHistogramRegions]
        case .shadows:
            return [.toneHistogramRegions, .noiseAwareShadowRecovery]
        case .contrast, .toneCurve, .midtoneContrast:
            return [.measuredToneCurve]
        case .temperature, .tint:
            return [.neutralEvidenceWhiteBalance, .mixedLightPreservation, .colorSpaceIntegrity, .skinIsNotNeutralReference]
        case .hue, .saturation, .vibrance, .shadowColor, .midtoneColor, .highlightColor:
            return [.colorSpaceIntegrity]
        case .localExposure, .localColor, .localTexture, .orangeHSL, .greenHSL, .blueHSL:
            return [.reliableSemanticMask, .saliencyIsNotIdentity]
        case .localHighlights, .localShadows, .luminanceMask:
            return [.luminanceMaskFallback, .noiseAwareShadowRecovery]
        case .localContrast, .noiseReduction:
            return [.noiseAwareDetail]
        case .sharpening:
            return [.noiseAwareDetail, .edgeAwareSharpening]
        }
    }

    private func decisionStatus(
        for key: PhotographyParameterKey,
        value: Float,
        analysis: PhotoAnalysis
    ) -> PhotographyParameterDecisionStatus {
        if analysis.containsPersonEvidence,
           [.orangeHSL, .localExposure, .localColor].contains(key),
           analysis.personMask?.isValid != true {
            return .disabledBySafety
        }
        let neutral: Float
        switch key {
        case .highlights, .whitePoint, .saturation: neutral = 1
        case .shadows, .brightness, .contrast, .toneCurve, .blackPoint,
             .temperature, .tint, .hue, .vibrance, .localContrast, .midtoneContrast,
             .shadowColor, .midtoneColor, .highlightColor, .localExposure,
             .localHighlights, .localShadows, .localColor, .localTexture,
             .noiseReduction, .sharpening, .luminanceMask, .orangeHSL,
             .greenHSL, .blueHSL, .exposure:
            neutral = key == .contrast ? 1 : 0
        }
        return abs(value - neutral) > 0.0005 ? .planned : .notNeeded
    }

    private func actualValue(
        _ key: PhotographyParameterKey,
        recipe: AutomaticEditingRecipe
    ) -> Float {
        PhotographyParameterEvidence.actualValue(for: key, recipe: recipe)
    }

    private func bounded(_ value: Float, _ range: ClosedRange<Float>) -> Float {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func contrastDeficitForBlackPoint(_ analysis: PhotoAnalysis) -> Float {
        max(0, 0.54 - analysis.contrastRange)
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
        problems: PhotoProblemReport,
        targetProfile: PhotographyTargetProfile? = nil
    ) -> PhotographyDecision {
        decisionEngine.makeDecision(
            for: analysis,
            problems: problems,
            targetProfile: targetProfile
        )
    }
}

/// Produces bounded alternatives from the one authoritative photographer decision.
/// The candidates are not LUTs: every recipe starts from the current photo's measured
/// recipe and is varied only in response to its diagnosed problems and reliable regions.
struct PhotographyCandidatePlanner {
    func makePlans(
        decision: PhotographyDecision,
        analysis: PhotoAnalysis,
        problems: PhotoProblemReport
    ) -> [PhotographyEditPlan] {
        var intents: [PhotographyCandidateIntent] = [.natural]
        let tonalKinds: Set<PhotoProblemKind> = [
            .underexposed, .overexposed, .clippedHighlights, .blockedShadows,
            .flatContrast, .harshContrast
        ]
        let localKinds: Set<PhotoProblemKind> = [
            .backlitSubject, .regionalUnderexposure, .regionalFlatness,
            .regionalHighlightRisk, .noiseRisk, .coolCast, .warmCast,
            .greenCast, .oversaturated
        ]
        let diagnosedKinds = Set(problems.problems.map(\.kind))
        let tonalResidual = !diagnosedKinds.isDisjoint(with: tonalKinds)
            || abs(decision.adaptiveTarget.luminance - analysis.averageLuminance) > 0.055
            || abs(decision.adaptiveTarget.contrast - analysis.contrastRange) > 0.07
        let localResidual = !diagnosedKinds.isDisjoint(with: localKinds)
            || decision.treatmentPlan.regionalTreatments.contains { $0.region != .global }
        if tonalResidual { intents.append(.dimensional) }
        if localResidual { intents.append(.targeted) }

        return intents.map { intent in
            let recipe: AutomaticEditingRecipe
            if intent == .natural {
                recipe = decision.recipe
            } else {
                recipe = candidateRecipe(
                    from: decision.recipe,
                    intent: intent,
                    target: decision.adaptiveTarget,
                    analysis: analysis,
                    problems: problems
                )
            }
            return PhotographyEditPlan(
                id: intent.rawValue,
                intent: intent,
                adjustments: adjustments(
                    intent: intent,
                    recipe: recipe,
                    decision: decision,
                    problems: problems
                ),
                recipe: recipe,
                rationale: rationale(intent: intent, analysis: analysis, problems: problems),
                parameterEvidence: decision.parameterEvidence.map {
                    $0.refreshingActualValue(from: recipe)
                }
            )
        }
    }

    private func candidateRecipe(
        from base: AutomaticEditingRecipe,
        intent: PhotographyCandidateIntent,
        target: AdaptivePhotographyTarget,
        analysis: PhotoAnalysis,
        problems: PhotoProblemReport
    ) -> AutomaticEditingRecipe {
        var recipe = base
        let kinds = Set(problems.problems.map(\.kind))
        let hasReliablePersonMask = analysis.personMask?.isValid == true
        let contrastDeficit = max(0, target.contrast - analysis.contrastRange)
        let subjectLuminanceDeficit = max(
            0,
            analysis.averageLuminance
                - (analysis.nonPersonPrimarySubjectStatistics?.averageLuminance ?? analysis.averageLuminance)
        )
        switch intent {
        case .natural:
            break
        case .dimensional:
            if kinds.contains(.flatContrast) || analysis.photographyContext.spatialDepthScore < 0.5 {
                recipe.toneCurveAmount = min(0.62, recipe.toneCurveAmount + contrastDeficit * 0.32)
                recipe.localContrastAmount = min(0.13, recipe.localContrastAmount + contrastDeficit * 0.16)
                recipe.upperMidtoneSeparation = min(0.07, contrastDeficit * 0.12)
                recipe.backgroundSeparation = min(
                    0.11,
                    subjectLuminanceDeficit * analysis.subjectPriorityProfile.confidence * 0.42
                )
            }
            if kinds.contains(.harshContrast) {
                recipe.contrast = min(recipe.contrast, 1.025)
                recipe.shadowRollOff = max(recipe.shadowRollOff, 0.22)
                recipe.highlightRollOff = max(recipe.highlightRollOff, 0.28)
            }
        case .targeted:
            applyTargetedProblems(kinds, analysis: analysis, recipe: &recipe)
        }

        if !analysis.containsPersonEvidence {
            switch (analysis.subjectPriorityProfile.mode, intent) {
            case (.primarySubject, .dimensional):
                recipe.subjectExposureEV = min(
                    0.13,
                    max(recipe.subjectExposureEV, subjectLuminanceDeficit * 0.42)
                )
                recipe.localContrastAmount = min(0.125, recipe.localContrastAmount + contrastDeficit * 0.12)
                recipe.backgroundSeparation = min(0.105, subjectLuminanceDeficit * 0.38)
            case (.primarySubject, .targeted):
                recipe.subjectExposureEV = min(
                    0.15,
                    max(recipe.subjectExposureEV, subjectLuminanceDeficit * 0.52)
                )
                recipe.localContrastAmount = min(0.135, recipe.localContrastAmount + contrastDeficit * 0.16)
                recipe.backgroundSeparation = min(0.115, subjectLuminanceDeficit * 0.46)
            case (.globalHarmony, .dimensional):
                recipe.toneCurveAmount = min(0.58, recipe.toneCurveAmount + contrastDeficit * 0.24)
                recipe.localContrastAmount = min(0.115, recipe.localContrastAmount + contrastDeficit * 0.12)
            case (.globalHarmony, .targeted):
                recipe.toneCurveAmount = min(0.64, recipe.toneCurveAmount + contrastDeficit * 0.3)
                recipe.localContrastAmount = min(0.13, recipe.localContrastAmount + contrastDeficit * 0.15)
                if kinds.contains(.regionalUnderexposure) || kinds.contains(.regionalHighlightRisk) {
                    recipe.luminanceMaskStrength = min(0.84, recipe.luminanceMaskStrength + 0.08)
                }
            case (_, .natural):
                break
            }
        }

        if analysis.containsPersonEvidence {
            recipe.faceExposureEV = 0
            recipe.subjectExposureEV = hasReliablePersonMask
                ? min(recipe.subjectExposureEV, 0.15)
                : 0
            recipe.skinTextureProtection = max(recipe.skinTextureProtection, 0.72)
            recipe.localContrastAmount = min(recipe.localContrastAmount, 0.07)
            recipe.sharpeningAmount = min(recipe.sharpeningAmount, 0.085)
            recipe.noiseReductionAmount = min(recipe.noiseReductionAmount, 0.025)
            recipe.temperatureShift = recipe.temperatureShift.clamped(to: -35...35)
            recipe.tintShift = recipe.tintShift.clamped(to: -2...2)
            recipe.saturation = min(recipe.saturation, 1)
            recipe.vibrance = min(recipe.vibrance, 0.055)
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.055)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.025)
            recipe.midtoneWarmAmount = min(recipe.midtoneWarmAmount, 0.025)
            recipe.highlightWarmAmount = min(recipe.highlightWarmAmount, 0.03)
            recipe.colorContrast = min(recipe.colorContrast, 0.025)
            recipe.hsl.orangeHue = 0
            recipe.hsl.orangeLuminance = 0
            recipe.hsl.orangeSaturation = 0
        }

        if analysis.photographyContext.lightingConditions.contains(.overcast) {
            recipe.temperatureShift = recipe.temperatureShift.clamped(to: -25...25)
            recipe.tintShift = recipe.tintShift.clamped(to: -1.5...1.5)
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.065)
            recipe.shadowCoolAmount = min(recipe.shadowCoolAmount, 0.025)
            recipe.midtoneWarmAmount = min(recipe.midtoneWarmAmount, 0.025)
            recipe.highlightWarmAmount = min(recipe.highlightWarmAmount, 0.03)
            recipe.colorContrast = min(recipe.colorContrast, 0.035)
            recipe.hsl.cyanSaturation = min(0, max(recipe.hsl.cyanSaturation, -0.035))
            recipe.hsl.blueSaturation = min(0, max(recipe.hsl.blueSaturation, -0.035))
            recipe.hsl.greenSaturation = min(0.01, recipe.hsl.greenSaturation)
            recipe.skySaturation = min(recipe.skySaturation, 1)
        }

        if analysis.sceneRecognitionDiagnostics.status == .failed {
            recipe.hsl = .neutral
            recipe.colorGradeIntensity = min(recipe.colorGradeIntensity, 0.1)
        }
        if analysis.segmentationDiagnostics.status == .failed
            || analysis.segmentationDiagnostics.status == .noUsableRegion {
            recipe.skyExposureEV = 0
            recipe.skyHighlightAmount = 1
            recipe.skySaturation = 1
        }
        return recipe.clamped()
    }

    private func applyTargetedProblems(
        _ kinds: Set<PhotoProblemKind>,
        analysis: PhotoAnalysis,
        recipe: inout AutomaticEditingRecipe
    ) {
        if kinds.contains(.underexposed) {
            recipe.exposureEV = min(0.24, max(recipe.exposureEV, (0.43 - analysis.averageLuminance) * 0.42))
        }
        if kinds.contains(.overexposed) {
            recipe.exposureEV = max(-0.24, min(recipe.exposureEV, (0.55 - analysis.averageLuminance) * 0.38))
        }
        if kinds.contains(.clippedHighlights) {
            recipe.highlightAmount = min(recipe.highlightAmount, max(0.42, 0.78 - analysis.highlightRatio * 1.1))
            recipe.highlightRollOff = max(recipe.highlightRollOff, min(0.58, analysis.highlightRatio * 1.8))
            recipe.whitePoint = min(recipe.whitePoint, 0.975)
        }
        if kinds.contains(.blockedShadows) && !analysis.photographyContext.lightingConditions.contains(.night) {
            recipe.shadowAmount = min(0.52, max(recipe.shadowAmount, analysis.shadowRatio * 0.58))
            recipe.shadowZoneExposureEV = min(0.18, max(recipe.shadowZoneExposureEV, 0.055))
        }
        if kinds.contains(.flatContrast) {
            recipe.toneCurveAmount = min(0.68, max(recipe.toneCurveAmount, 0.32))
            recipe.localContrastAmount = min(0.14, max(recipe.localContrastAmount, 0.075))
        }
        if kinds.contains(.harshContrast) {
            recipe.contrast = min(recipe.contrast, 1.02)
            recipe.shadowRollOff = max(recipe.shadowRollOff, 0.26)
            recipe.highlightRollOff = max(recipe.highlightRollOff, 0.3)
        }
        if kinds.contains(.oversaturated) {
            recipe.saturation = min(recipe.saturation, 0.99)
            recipe.vibrance = min(recipe.vibrance, 0.045)
        }
        if kinds.contains(.noiseRisk) {
            recipe.noiseReductionAmount = max(recipe.noiseReductionAmount, 0.025)
            recipe.sharpeningAmount = min(recipe.sharpeningAmount, 0.07)
            recipe.grainAmount = 0
        }
        if kinds.contains(.backlitSubject), analysis.personMask?.isValid == true {
            recipe.subjectExposureEV = min(0.15, max(recipe.subjectExposureEV, 0.07))
            recipe.backgroundSeparation = min(0.1, max(recipe.backgroundSeparation, 0.04))
        }
        if kinds.contains(.regionalUnderexposure) {
            recipe.luminanceMaskStrength = min(0.85, max(recipe.luminanceMaskStrength, 0.5))
            recipe.shadowZoneExposureEV = min(0.17, max(recipe.shadowZoneExposureEV, 0.07))
        }
        if kinds.contains(.regionalFlatness) {
            recipe.localContrastAmount = min(0.14, max(recipe.localContrastAmount, 0.075))
        }
        if kinds.contains(.regionalHighlightRisk) {
            recipe.highlightRollOff = min(0.65, max(recipe.highlightRollOff, 0.28))
            recipe.highlightZoneExposureEV = max(-0.2, min(recipe.highlightZoneExposureEV, -0.075))
        }
    }

    private func adjustments(
        intent: PhotographyCandidateIntent,
        recipe: AutomaticEditingRecipe,
        decision: PhotographyDecision,
        problems: PhotoProblemReport
    ) -> [PhotographyPlannedAdjustment] {
        var result = problems.problems.map { problem in
            plannedAdjustment(for: problem, recipe: recipe, intent: intent)
        }
        for treatment in decision.treatmentPlan.regionalTreatments where treatment.region != .global {
            result.append(PhotographyPlannedAdjustment(
                targetRegion: treatment.region,
                adjustmentType: .localContrast,
                intensity: min(0.14, recipe.localContrastAmount * treatment.confidence),
                confidence: treatment.confidence,
                reason: treatment.reason,
                minimumValue: 0,
                maximumValue: 0.14,
                expectedEffect: treatment.objective,
                fallbackBehavior: treatment.fallback
            ))
        }
        if recipe.vibrance > 0.001 {
            result.append(PhotographyPlannedAdjustment(
                targetRegion: .global,
                adjustmentType: .vibrance,
                intensity: recipe.vibrance,
                confidence: 0.85,
                reason: "依据当前照片平均饱和度补充自然饱和度。",
                minimumValue: 0,
                maximumValue: 0.32,
                expectedEffect: "优先改善低饱和颜色，避免所有颜色同步过饱和。",
                fallbackBehavior: "若候选出现过饱和则降低或关闭。"
            ))
        }
        if recipe.luminanceMaskStrength > 0.001 {
            result.append(PhotographyPlannedAdjustment(
                targetRegion: .global,
                adjustmentType: .dodgeAndBurn,
                intensity: recipe.luminanceMaskStrength,
                confidence: 0.84,
                reason: "按当前照片高光与阴影分布执行亮度蒙版处理。",
                minimumValue: 0,
                maximumValue: 1,
                expectedEffect: "分别控制高光和阴影，不用统一曝光替代。",
                fallbackBehavior: "暗部噪声或高光异常时由质检限制强度。"
            ))
        }
        if recipe.noiseReductionAmount > 0.001 {
            result.append(PhotographyPlannedAdjustment(
                targetRegion: .global,
                adjustmentType: .noiseReduction,
                intensity: recipe.noiseReductionAmount,
                confidence: 0.82,
                reason: "由暗部与高频残差估计触发。",
                minimumValue: 0,
                maximumValue: 0.06,
                expectedEffect: "控制低照度噪点，同时保留真实纹理。",
                fallbackBehavior: "人物纹理风险出现时限制到人物保护上限。"
            ))
        }
        if recipe.sharpeningAmount > 0.001 {
            result.append(PhotographyPlannedAdjustment(
                targetRegion: .global,
                adjustmentType: .sharpening,
                intensity: recipe.sharpeningAmount,
                confidence: 0.8,
                reason: "依据当前细节分数执行有限亮度锐化。",
                minimumValue: 0,
                maximumValue: 0.22,
                expectedEffect: "改善边缘清晰度，不制造锐化白边。",
                fallbackBehavior: "细节过硬或噪声增加时自动降低。"
            ))
        }
        if recipe.grainAmount > 0.001 {
            result.append(PhotographyPlannedAdjustment(
                targetRegion: .global,
                adjustmentType: .filmGrain,
                intensity: recipe.grainAmount,
                confidence: 0.65,
                reason: "仅在当前摄影风格和噪声余量允许时保留轻微颗粒。",
                minimumValue: 0,
                maximumValue: 0.12,
                expectedEffect: "增加克制的摄影质感。",
                fallbackBehavior: "低照度或噪声风险场景立即关闭。"
            ))
        }
        if result.isEmpty {
            result.append(PhotographyPlannedAdjustment(
                targetRegion: .global,
                adjustmentType: .tonalCurve,
                intensity: recipe.toneCurveAmount,
                confidence: 0.8,
                reason: "原片没有明显技术问题，只进行低强度摄影整理。",
                minimumValue: 0,
                maximumValue: 0.32,
                expectedEffect: "保持原有观感并改善细微层次。",
                fallbackBehavior: "若技术质量没有改善则保留最克制方案。"
            ))
        }
        return result
    }

    private func plannedAdjustment(
        for problem: PhotoProblem,
        recipe: AutomaticEditingRecipe,
        intent: PhotographyCandidateIntent
    ) -> PhotographyPlannedAdjustment {
        let definition: (PhotographyAdjustmentType, Float, Float, Float)
        switch problem.kind {
        case .underexposed, .overexposed:
            definition = (.globalExposure, recipe.exposureEV, -0.35, 0.35)
        case .clippedHighlights:
            definition = (.highlightRecovery, 1 - recipe.highlightAmount, 0, 0.68)
        case .blockedShadows:
            definition = (.shadowRecovery, recipe.shadowAmount, 0, 0.68)
        case .flatContrast, .harshContrast:
            definition = (.tonalCurve, recipe.toneCurveAmount, 0, 1)
        case .coolCast, .warmCast, .greenCast:
            definition = (.whiteBalance, recipe.temperatureShift, -600, 600)
        case .oversaturated:
            definition = (.saturation, recipe.saturation, 0.96, 1.08)
        case .noiseRisk:
            definition = (.noiseReduction, recipe.noiseReductionAmount, 0, 0.06)
        case .backlitSubject:
            definition = (.localExposure, recipe.subjectExposureEV, 0, 0.3)
        case .regionalUnderexposure:
            definition = (.dodgeAndBurn, recipe.shadowZoneExposureEV, 0, 0.22)
        case .regionalFlatness:
            definition = (.localContrast, recipe.localContrastAmount, 0, 0.28)
        case .regionalHighlightRisk:
            definition = (.highlightRecovery, abs(recipe.highlightZoneExposureEV), 0, 0.24)
        }
        return PhotographyPlannedAdjustment(
            targetRegion: problem.affectedRegions.first ?? .global,
            adjustmentType: definition.0,
            intensity: definition.1,
            confidence: problem.confidence,
            reason: "\(intent.rawValue)：\(problem.evidence)",
            minimumValue: definition.2,
            maximumValue: definition.3,
            expectedEffect: problem.recommendation,
            fallbackBehavior: problem.risk
        )
    }

    private func rationale(
        intent: PhotographyCandidateIntent,
        analysis: PhotoAnalysis,
        problems: PhotoProblemReport
    ) -> String {
        let evidence = problems.problems
            .map { "\($0.kind.title)(\($0.severity.title))" }
            .joined(separator: "、")
        return String(
            format: "%@候选由本图问题[%@]与实测亮度 %.1f%%、动态范围 %.1f%%、噪声 %.1f%%、主体置信度 %.0f%%共同派生；只改变有证据的轴，不统一缩放白平衡、HSL 或全部参数。",
            intent.rawValue,
            evidence.isEmpty ? "无明显问题" : evidence,
            analysis.averageLuminance * 100,
            analysis.contrastRange * 100,
            analysis.noiseEstimate * 100,
            analysis.subjectPriorityProfile.confidence * 100
        )
    }
}

