import CryptoKit
import Darwin
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Release builds distributed through the internal TestFlight workflow opt in
/// explicitly. App Store/ordinary Release builds do not define this condition,
/// so normal-capture evidence UI is not compiled into those products.
enum InternalCaptureEvidenceBuildPolicy {
#if XIAOSU_INTERNAL_CAPTURE_EVIDENCE
    static let isEnabled = true
#else
    static let isEnabled = false
#endif
}

struct ProductionCaptureEvidenceIdentity: Equatable, Sendable {
    let captureID: UUID
    let sourceSHA256: String
    let formalBSHA256: String
    let sourceByteCount: Int
    let formalBByteCount: Int
}

/// Builds a self-contained, uncompressed ZIP so TestFlight evidence can be
/// exported through the native share sheet without adding a third-party archive
/// dependency.  Every rendered image is tied to the same source SHA-256.
final class DiagnosticBundleExporter {
    private let allowsProductionCaptureEvidence: Bool

    init(
        allowsProductionCaptureEvidence: Bool = InternalCaptureEvidenceBuildPolicy.isEnabled
    ) {
        self.allowsProductionCaptureEvidence = allowsProductionCaptureEvidence
    }

    static func sourceSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Packages the already-delivered normal-capture A/B bytes and their exact
    /// retained execution record. It never invokes a renderer or save API.
    func makeProductionCaptureArchive(for photo: CapturedPhoto) throws -> URL {
        guard allowsProductionCaptureEvidence else {
            throw DiagnosticBundleExportError.internalEvidenceDisabled
        }
        guard !photo.isDiagnosticImport else {
            throw DiagnosticBundleExportError.notNormalCapture
        }
        guard
            !photo.originalImageData.isEmpty,
            !photo.editedImageData.isEmpty,
            photo.analysis != nil,
            photo.decision != nil,
            photo.qualityCheck != nil,
            photo.processingDiagnostics != nil
        else {
            throw DiagnosticBundleExportError.incompleteProductionEvidence
        }

        let identity = try productionCaptureEvidenceIdentity(for: photo)
        let sourcePath = "images/A_original.\(Self.imageFileExtension(photo.originalImageData))"
        let formalBPath = "images/B_formal_output.\(Self.imageFileExtension(photo.editedImageData))"
        var entries = [
            DiagnosticExportEntry(
                path: sourcePath,
                data: photo.originalImageData,
                role: "A exact original capture bytes retained for this capture ID"
            ),
            DiagnosticExportEntry(
                path: formalBPath,
                data: photo.editedImageData,
                role: "B exact formal output bytes already displayed by the preview"
            )
        ]

        let execution = productionExecutionObject(photo: photo, identity: identity)
        entries.append(DiagnosticExportEntry(
            path: "evidence/formal_b_execution.json",
            data: try jsonData(execution),
            role: "formal B target, final recipe, regional execution and selection provenance"
        ))
        entries.append(DiagnosticExportEntry(
            path: "evidence/scene_analysis_and_targets.json",
            data: try jsonData(sceneAnalysisObject(
                photo: photo,
                sourceHash: identity.sourceSHA256
            )),
            role: "analysis and target evidence retained by the production pipeline"
        ))
        entries.append(DiagnosticExportEntry(
            path: "evidence/quality_checks.json",
            data: try jsonData(qualityObject(photo: photo)),
            role: "formal B technical quality, candidate selection and fallback evidence"
        ))
        entries.append(DiagnosticExportEntry(
            path: "evidence/performance.json",
            data: try jsonData(performanceObject(photo: photo)),
            role: "production processing stage duration evidence"
        ))

        let inventory = entries.map { entry -> [String: Any] in
            var record: [String: Any] = [
                "path": entry.path,
                "role": entry.role,
                "bytes": entry.data.count,
                "sha256": Self.sourceSHA256(entry.data)
            ]
            if let size = Self.encodedPixelSize(entry.data) {
                record["encodedPixelWidth"] = size.width
                record["encodedPixelHeight"] = size.height
            }
            record.merge(Self.encodedImageIdentity(entry.data)) { current, _ in current }
            return record
        }
        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "evidenceType": "internal_normal_capture_formal_b",
            "captureID": identity.captureID.uuidString,
            "capturedAt": ISO8601DateFormatter().string(from: photo.capturedAt),
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "sourceSha256": identity.sourceSHA256,
            "formalBSha256": identity.formalBSHA256,
            "sameCaptureIDVerified": true,
            "renderPolicy": "read_existing_bytes_only_no_rerender",
            "uploadPolicy": "local_archive_only_user_initiated_share",
            "app": appIdentityObject(),
            "device": deviceIdentityObject(),
            "files": inventory
        ]
        entries.append(DiagnosticExportEntry(
            path: "manifest.json",
            data: try jsonData(manifest),
            role: "normal-capture evidence manifest"
        ))
        let readme = """
        小苏相机内部正常拍照 A/B 取证包

        capture ID：\(identity.captureID.uuidString)
        A SHA-256：\(identity.sourceSHA256)
        B SHA-256：\(identity.formalBSHA256)

        A 与 B 直接来自本次正常快门的 CapturedPhoto，导出过程不重新分析、不重新渲染、不保存到 Photos。
        本包不包含 M、V2、T 或其他研究候选。formal_b_execution.json 记录正式 B 的最终目标、实际配方、
        候选选择、区域执行、质量回退和处理耗时。分享仅由用户在 iOS 系统分享菜单中主动完成。
        摄影审美状态仍为 pending_human_review；技术成功不代表专业摄影效果已获认可。
        """
        entries.append(DiagnosticExportEntry(
            path: "README.txt",
            data: Data(readme.utf8),
            role: "human-readable normal capture evidence guide"
        ))

        let stamp = Self.fileTimestamp.string(from: Date())
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
            "XiaoSuCamera_FormalB_Evidence_\(stamp)_\(identity.captureID.uuidString.prefix(8)).zip"
        )
        try? FileManager.default.removeItem(at: destination)
        try NativeZipArchiveWriter.write(entries: entries, to: destination)
        return destination
    }

    /// Exports a technically rejected formal-B render for local diagnosis. The
    /// rejected bytes are labelled explicitly and are never written to Photos or
    /// exposed as `editedImageData`.
    func makeRejectedProductionCaptureArchive(for photo: CapturedPhoto) throws -> URL {
        guard allowsProductionCaptureEvidence else {
            throw DiagnosticBundleExportError.internalEvidenceDisabled
        }
        guard !photo.isDiagnosticImport else {
            throw DiagnosticBundleExportError.notNormalCapture
        }
        guard !photo.originalImageData.isEmpty,
              let evidence = photo.rejectedFormalBEvidence,
              !evidence.candidateImageData.isEmpty
        else { throw DiagnosticBundleExportError.incompleteProductionEvidence }

        let sourceHash = Self.sourceSHA256(photo.originalImageData)
        let rejectedHash = Self.sourceSHA256(evidence.candidateImageData)
        let color = evidence.finalQualityCheck.colorIntegrity
        var entries = [
            DiagnosticExportEntry(
                path: "images/A_original.\(Self.imageFileExtension(photo.originalImageData))",
                data: photo.originalImageData,
                role: "A exact original capture bytes"
            ),
            DiagnosticExportEntry(
                path: "rejected/B_candidate_REJECTED.\(Self.imageFileExtension(evidence.candidateImageData))",
                data: evidence.candidateImageData,
                role: "rejected formal-B candidate; diagnostic only; never an accepted or saved B"
            )
        ]
        let quality: [String: Any] = [
            "schemaVersion": 1,
            "state": "rejected",
            "captureID": photo.id.uuidString,
            "sourceSha256": sourceHash,
            "rejectedCandidateSha256": rejectedHash,
            "reason": evidence.rejectionReason,
            "initialIssues": evidence.initialQualityCheck.issues.map(\.rawValue),
            "finalIssues": evidence.finalQualityCheck.issues.map(\.rawValue),
            "sourceAverageLuminance": evidence.analysis.averageLuminance,
            "rejectedAverageLuminance": evidence.finalQualityCheck.measuredAnalysis.averageLuminance,
            "protectedNeutralCoverage": color.protectedNeutralCoverage,
            "protectedNeutralLuminanceShift": color.protectedNeutralLuminanceShift,
            "intentionalToneNeutralCoverage": color.intentionalToneNeutralCoverage,
            "intentionalToneNeutralLuminanceShift": color.intentionalToneNeutralLuminanceShift,
            "recipe": evidence.recipe.traceSummary,
            "regionalExecutionDetails": evidence.regionalExecutionDetails,
            "issues": evidence.finalQualityCheck.issues.map(\.rawValue),
            "app": appIdentityObject(),
            "device": deviceIdentityObject(),
            "uploadPolicy": "local_archive_only_user_initiated_share"
        ]
        entries.append(DiagnosticExportEntry(
            path: "evidence/rejected_formal_b.json",
            data: try jsonData(quality),
            role: "quality attribution, executed recipe and rejection evidence"
        ))
        entries.append(DiagnosticExportEntry(
            path: "REJECTED_NOT_A_FORMAL_B.txt",
            data: Data("该候选未通过技术质检，不是正式 B，不会自动保存。仅供内部定位。".utf8),
            role: "mandatory rejected-state marker"
        ))
        let stamp = Self.fileTimestamp.string(from: Date())
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
            "XiaoSuCamera_RejectedB_Evidence_\(stamp)_\(photo.id.uuidString.prefix(8)).zip"
        )
        try? FileManager.default.removeItem(at: destination)
        try NativeZipArchiveWriter.write(entries: entries, to: destination)
        return destination
    }

    func productionCaptureEvidenceIdentity(
        for photo: CapturedPhoto
    ) throws -> ProductionCaptureEvidenceIdentity {
        guard !photo.originalImageData.isEmpty, !photo.editedImageData.isEmpty else {
            throw DiagnosticBundleExportError.incompleteProductionEvidence
        }
        return ProductionCaptureEvidenceIdentity(
            captureID: photo.id,
            sourceSHA256: Self.sourceSHA256(photo.originalImageData),
            formalBSHA256: Self.sourceSHA256(photo.editedImageData),
            sourceByteCount: photo.originalImageData.count,
            formalBByteCount: photo.editedImageData.count
        )
    }

    func makeArchive(
        for photo: CapturedPhoto,
        externalResearchTargetData: Data? = nil
    ) throws -> URL {
        guard photo.isDiagnosticImport else {
            throw DiagnosticBundleExportError.notDiagnosticImport
        }

        let sourceHash = Self.sourceSHA256(photo.originalImageData)
        let sourcePath = "images/A_original.\(Self.imageFileExtension(photo.originalImageData))"
        var entries: [DiagnosticExportEntry] = []
        var usedPaths = Set<String>()

        func uniquePath(_ requested: String) -> String {
            if usedPaths.insert(requested).inserted { return requested }
            let extensionName = (requested as NSString).pathExtension
            let stem = (requested as NSString).deletingPathExtension
            var suffix = 2
            while true {
                let candidate = extensionName.isEmpty
                    ? "\(stem)_\(suffix)"
                    : "\(stem)_\(suffix).\(extensionName)"
                if usedPaths.insert(candidate).inserted { return candidate }
                suffix += 1
            }
        }

        func add(_ path: String, _ data: Data, _ role: String) {
            entries.append(DiagnosticExportEntry(
                path: uniquePath(path),
                data: data,
                role: role
            ))
        }

        add(sourcePath, photo.originalImageData, "A source original in its real encoded format")
        add("images/B_formal_output.jpg", photo.editedImageData, "B formal algorithm output")
        let targetHash: String?
        let targetPath: String?
        if let externalResearchTargetData, !externalResearchTargetData.isEmpty {
            targetHash = Self.sourceSHA256(externalResearchTargetData)
            let path = "research/T_external_reference.\(Self.imageFileExtension(externalResearchTargetData))"
            targetPath = path
            add(
                path,
                externalResearchTargetData,
                "user-selected local research target; evaluation only, never a render input"
            )
        } else {
            targetHash = nil
            targetPath = nil
        }
        var renderedImages: [String: Data] = [
            "A": photo.originalImageData,
            "B": photo.editedImageData
        ]

        let comparisonPrefixes = [
            "A ", "B ", "C ", "D ", "E1 ", "E2 ", "M 人工参数真实渲染",
            "V2-1 ", "V2-2 ", "V2-3 ", "V2-AUTO "
        ]
        let diagnosticImageIdentifiers = ["C", "D", "E1", "E2", "M", "V2-1", "V2-2", "V2-3", "V2-AUTO"]
        for identifier in diagnosticImageIdentifiers {
            let candidate = photo.diagnosticCandidates.first { $0.identifier == identifier }
            let preview = Self.resolvedPreview(
                for: candidate,
                in: photo.processingStagePreviews
            )
            if let preview {
                renderedImages[identifier] = preview.imageData
                add(
                    "images/\(candidateFileStem(identifier)).jpg",
                    preview.imageData,
                    "\(identifier) full-resolution diagnostic output"
                )
            } else {
                let reason = candidate?.unavailable.joined(separator: "\n")
                    ?? candidate?.rejected.joined(separator: "\n")
                    ?? "No image was rendered."
                add(
                    "images/\(identifier)_UNAVAILABLE.txt",
                    Data("state=unavailable\nreason=\(reason)\n".utf8),
                    "\(identifier) unavailable marker"
                )
            }
        }

        if let analysis = photo.analysis, !analysis.faceRegions.isEmpty {
            for (faceIndex, faceRegion) in analysis.faceRegions.prefix(4).enumerated() {
                for identifier in ["A", "B", "V2-1", "V2-2", "V2-3", "V2-AUTO"] {
                    guard let imageData = renderedImages[identifier],
                          let crop = Self.faceCropJPEG(
                            imageData,
                            normalizedVisionRegion: faceRegion
                          )
                    else { continue }
                    add(
                        "portrait_100pct/face_\(faceIndex + 1)_\(identifier).jpg",
                        crop,
                        "native-resolution face-region crop for source-relative portrait review"
                    )
                }
            }
        }

        for preview in photo.processingStagePreviews {
            if comparisonPrefixes.contains(where: { preview.name.hasPrefix($0) }) { continue }
            let safeName = sanitized(preview.name)
            if preview.name.hasPrefix("M 探针") {
                add("probes/\(safeName).jpg", preview.imageData, "single-parameter renderer probe")
            } else if preview.name.hasPrefix("蒙版") {
                add("masks/\(safeName).jpg", preview.imageData, "segmentation mask or overlay")
            } else {
                add("stages/\(safeName).jpg", preview.imageData, "intermediate processing stage")
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        add(
            "evidence/candidate_states_and_parameters.json",
            try encoder.encode(photo.diagnosticCandidates),
            "planned/executed/rejected/fallback/unavailable candidate evidence"
        )
        add(
            "evidence/candidate_generation_and_selection.json",
            try jsonData(candidateSetAssessmentObject(photo: photo)),
            "separate candidate-generation and candidate-selection evidence"
        )
        add(
            "evidence/scene_analysis_and_targets.json",
            try jsonData(sceneAnalysisObject(photo: photo, sourceHash: sourceHash)),
            "scene analysis, masks, target and decision rationale"
        )
        add(
            "evidence/quality_checks.json",
            try jsonData(qualityObject(photo: photo)),
            "technical quality check evidence"
        )
        add(
            "evidence/performance.json",
            try jsonData(performanceObject(photo: photo)),
            "processing duration and memory evidence"
        )
        let task2ACandidate = photo.diagnosticCandidates.first { $0.identifier == "M" }
        let task2APreview = Self.resolvedPreview(
            for: task2ACandidate,
            in: photo.processingStagePreviews
        )
        let task2AImageFile = task2APreview == nil ? "unavailable" : "images/M_manual_render.jpg"
        let task2AStatus: [String: Any] = [
            "source": "\(sourcePath) identified by sourceSha256",
            "professionalTargetT": targetHash == nil
                ? "external_research_reference_not_selected"
                : targetPath ?? "external_research_reference_format_unknown",
            "professionalTargetSha256": targetHash ?? "unavailable",
            "professionalTargetReason": targetHash == nil
                ? "No local T was selected for this evidence archive."
                : "T was explicitly selected by the user and is packaged only in this local share archive; it never entered rendering or automatic decision.",
            "coreImageCandidate": task2AImageFile,
            "coreImageCandidateSha256": task2APreview.map { Self.sourceSHA256($0.imageData) } ?? "unavailable",
            "renderActuallyExecuted": task2ACandidate?.states.contains(.executed) == true && task2APreview != nil,
            "parameterIdentifier": ManualPhotographyParameters.task2ACinematicExpression.identifier,
            "experiment": "Task 2-A manual cinematic rendering expression; not automatic photography decision",
            "candidateStates": task2ACandidate?.states.map(\.rawValue) ?? ["unavailable"],
            "parameterLifecycle": task2ACandidate?.parameterLifecycle.map {
                ["stage": $0.stage, "recipeSummary": $0.recipeSummary, "changes": $0.changes]
            } ?? [],
            "executedPixelEvidence": task2ACandidate?.executed ?? [],
            "rejectedOrSkippedEvidence": (task2ACandidate?.rejected ?? [])
                + (task2ACandidate?.unavailable ?? []),
            "technicalQualityStatus": task2ACandidate?.qualityStatus ?? "notRun",
            "humanAestheticStatus": "pending_human_review",
            "recordedCandidateHumanStatus": task2ACandidate?.humanAestheticStatus ?? "notEvaluated"
        ]
        add(
            "evidence/TASK2A_RENDER_VALIDATION_STATUS.json",
            try jsonData(task2AStatus),
            "Task 2-A Core Image expression provenance; T is intentionally external"
        )

        let inventory = entries.map { entry -> [String: Any] in
            var record: [String: Any] = [
                "path": entry.path,
                "role": entry.role,
                "bytes": entry.data.count,
                "sha256": Self.sourceSHA256(entry.data)
            ]
            if let size = Self.encodedPixelSize(entry.data) {
                record["encodedPixelWidth"] = size.width
                record["encodedPixelHeight"] = size.height
            }
            record.merge(Self.encodedImageIdentity(entry.data)) { current, _ in current }
            return record
        }
        let metadata: [String: Any] = [
            "schemaVersion": 2,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "sourceSha256": sourceHash,
            "externalResearchTargetSha256": targetHash ?? "not_selected",
            "sameSourceRequirement": "A/B/D/E1/E2/M/V2-1/V2-2/V2-3/V2-AUTO and probes were produced from the source identified above in one diagnostic import.",
            "app": [
                "name": Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "小苏相机",
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "gitCommitSha": Bundle.main.object(forInfoDictionaryKey: "XGitCommitSHA") as? String ?? "unknown"
            ],
            "device": [
                "model": UIDevice.current.model,
                "hardwareIdentifier": Self.deviceHardwareIdentifier(),
                "name": UIDevice.current.name,
                "systemName": UIDevice.current.systemName,
                "systemVersion": UIDevice.current.systemVersion
            ],
            "candidateMeaning": [
                "A": "original source",
                "B": "formal algorithm result shown by the top B button",
                "C": "reference-calibrated diagnostic; unavailable when licensing/index gates fail",
                "D": "measured automatic aesthetic diagnostic; never replaces B",
                "E1": "independently solved spatial-emphasis target experiment; human preference pending",
                "E2": "independently solved restrained-depth target experiment; human preference pending",
                "M": "Task 2-A human-declared Core Image cinematic expression; never replaces B or D",
                "V2-1": "Automatic Photography Director V2 natural-documentary candidate",
                "V2-2": "Automatic Photography Director V2 dimensional-hierarchy candidate",
                "V2-3": "Automatic Photography Director V2 atmospheric-cinematic candidate",
                "V2-AUTO": "provisional V2 automatic selection; human preference still pending",
                "difference": "A versus B, amplified five times"
            ],
            "files": inventory
        ]
        add("manifest.json", try jsonData(metadata), "bundle manifest")
        add(
            "README.txt",
            Data(readme(sourceHash: sourceHash, includesLocalTarget: targetHash != nil).utf8),
            "human-readable evidence guide"
        )
        add(
            "task2a-comparison.html",
            Data(task2AComparisonHTML(
                sourcePath: sourcePath,
                targetPath: targetPath,
                includesLocalTarget: targetHash != nil,
                includesRenderedCandidate: task2AImageFile != "unavailable",
                technicalStatus: task2ACandidate?.qualityStatus ?? "notRun",
                executionState: task2ACandidate?.states.map(\.rawValue).joined(separator: ",") ?? "unavailable"
            ).utf8),
            "local A/T/R-I full-resolution comparison page"
        )

        let stamp = Self.fileTimestamp.string(from: Date())
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("XiaoSuCamera_Diagnostic_\(stamp)_\(sourceHash.prefix(10)).zip")
        try? FileManager.default.removeItem(at: destination)
        try NativeZipArchiveWriter.write(entries: entries, to: destination)
        return destination
    }

    private func candidateFileStem(_ identifier: String) -> String {
        switch identifier {
        case "C": return "C_reference_candidate"
        case "D": return "D_automatic_diagnostic"
        case "E1": return "E1_spatial_emphasis"
        case "E2": return "E2_restrained_depth"
        case "M": return "M_manual_render"
        case "V2-1": return "V2_1_natural_documentary"
        case "V2-2": return "V2_2_dimensional_hierarchy"
        case "V2-3": return "V2_3_atmospheric_cinematic"
        case "V2-AUTO": return "V2_AUTO_provisional_selection"
        default: return "\(identifier)_diagnostic"
        }
    }

    /// PT-PREF-002: D/E1/E2 are the three source-measured automatic target
    /// hypotheses.  This evidence deliberately refuses to infer photographic
    /// quality from a render success or an engineering proxy score.  A real
    /// human blind review is required before generation or selection can be
    /// called successful.
    private func candidateSetAssessmentObject(photo: CapturedPhoto) -> [String: Any] {
        let expected = ["D", "E1", "E2"]
        let records = expected.map { identifier -> PhotographyCandidateReviewEvidence in
            let candidate = photo.diagnosticCandidates.first { $0.identifier == identifier }
            let rendered = candidate?.states.contains(.executed) == true
                && Self.resolvedPreview(for: candidate, in: photo.processingStagePreviews) != nil
            let qualityText = candidate?.qualityStatus?.lowercased() ?? ""
            let technicalStatus: CandidateEvaluationStatus
            if qualityText.contains("failed") || candidate?.states.contains(.rejected) == true {
                technicalStatus = .rejected
            } else if qualityText.contains("warning") {
                technicalStatus = .warning
            } else if qualityText.contains("passed") {
                technicalStatus = .passed
            } else {
                technicalStatus = .skipped
            }
            let humanText = candidate?.humanAestheticStatus.lowercased() ?? ""
            let preferenceStatus: PhotographyPreferenceEvidenceStatus
            if humanText.contains("humansupported") || humanText.contains("human_supported") {
                preferenceStatus = .humanSupported
            } else if humanText.contains("humanrejected") || humanText.contains("human_rejected") {
                preferenceStatus = .humanRejected
            } else if humanText.contains("inconclusive") {
                preferenceStatus = .inconclusive
            } else {
                preferenceStatus = .notEvaluated
            }
            return PhotographyCandidateReviewEvidence(
                identifier: identifier,
                rendered: rendered,
                technicalStatus: technicalStatus,
                preferenceStatus: preferenceStatus,
                automaticallySelected: false
            )
        }
        let assessment = PhotographyCandidateSetAssessor().assess(
            expectedCandidateIdentifiers: expected,
            evidence: records,
            explorationAssessment: targetExplorationAssessment(from: photo)
        )
        let exploration = targetExplorationAssessment(from: photo)
        let v2Identifiers = ["V2-1", "V2-2", "V2-3"]
        let v2Records = v2Identifiers.map { identifier -> [String: Any] in
            let candidate = photo.diagnosticCandidates.first { $0.identifier == identifier }
            return [
                "identifier": identifier,
                "rendered": candidate?.states.contains(.executed) == true
                    && Self.resolvedPreview(for: candidate, in: photo.processingStagePreviews) != nil,
                "technicalStatus": candidate?.qualityStatus ?? "not_run",
                "humanAestheticStatus": candidate?.humanAestheticStatus ?? "not_evaluated",
                "states": candidate?.states.map(\.rawValue) ?? [DiagnosticCandidateState.unavailable.rawValue],
                "selectionEvidence": candidate?.assessmentEvidence ?? []
            ]
        }
        let v2Auto = photo.diagnosticCandidates.first { $0.identifier == "V2-AUTO" }
        return [
            "knowledgeRule": PhotographyKnowledgeRuleID.humanPreferenceCalibration.rawValue,
            "candidateGenerationSelectionRule": PhotographyKnowledgeRuleID.candidateGenerationSelectionSeparation.rawValue,
            "expectedCandidates": assessment.expectedCandidateIdentifiers,
            "renderedCandidates": assessment.renderedCandidateIdentifiers,
            "technicallyEligibleCandidates": assessment.technicallyEligibleCandidateIdentifiers,
            "humanSupportedCandidates": assessment.humanSupportedCandidateIdentifiers,
            "candidateGenerationOutcome": assessment.generationOutcome.rawValue,
            "automaticPhotographyDirectorV2": [
                "knowledgeRules": [
                    PhotographyKnowledgeRuleID.v2MeasuredIntent.rawValue,
                    PhotographyKnowledgeRuleID.v2AdaptiveLook.rawValue,
                    PhotographyKnowledgeRuleID.v2ProvisionalSelection.rawValue
                ],
                "candidates": v2Records,
                "autoStates": v2Auto?.states.map(\.rawValue) ?? [DiagnosticCandidateState.unavailable.rawValue],
                "autoEvidence": v2Auto?.executed ?? [],
                "autoAssessmentEvidence": v2Auto?.assessmentEvidence ?? [],
                "candidateExplorationStatus": v2Auto?.targetQualityStatus ?? "not_measured",
                "provisional": true,
                "humanAestheticStatus": v2Auto?.humanAestheticStatus ?? "not_evaluated",
                "claimBoundary": "V2-AUTO is an engineering proxy selection, not evidence of professional aesthetic success."
            ],
            "candidateSelectionOutcome": assessment.selectionOutcome.rawValue,
            "targetExplorationStatus": exploration?.status.rawValue ?? "notRecorded",
            "targetExplorationEvidence": photo.diagnosticCandidates
                .flatMap(\.assessmentEvidence)
                .first { $0.contains("[TARGET_EXPLORATION]") } ?? "not recorded",
            "automaticRankingResult": "not_run_for_D_E1_E2_diagnostic_hypotheses",
            "reason": assessment.reason,
            "warning": "Technical pass and engineering scores are not evidence of professional photographic preference."
        ]
    }

    private func targetExplorationAssessment(
        from photo: CapturedPhoto
    ) -> PhotographyTargetExplorationAssessment? {
        guard let line = photo.diagnosticCandidates
            .flatMap(\.assessmentEvidence)
            .first(where: { $0.contains("[TARGET_EXPLORATION]") })
        else { return nil }
        let status: PhotographyTargetExplorationStatus
        if line.contains("status=\(PhotographyTargetExplorationStatus.invalidInsufficientRenderedDifference.rawValue)") {
            status = .invalidInsufficientRenderedDifference
        } else if line.contains("status=\(PhotographyTargetExplorationStatus.effectivePendingHumanReview.rawValue)") {
            status = .effectivePendingHumanReview
        } else {
            status = .incompleteRenderEvidence
        }
        return PhotographyTargetExplorationAssessment(
            status: status,
            pairDifferences: [],
            reason: line
        )
    }

    /// An exported candidate image must be the exact full-resolution stage that
    /// produced an `executed` candidate record. Prefix matching is intentionally
    /// forbidden: it previously allowed a stale low-resolution C preview to be
    /// exported even while the current C record was `indexUnavailable`.
    static func resolvedPreview(
        for candidate: DiagnosticCandidateEvidence?,
        in previews: [ProcessingStagePreview]
    ) -> ProcessingStagePreview? {
        guard let candidate else { return nil }
        guard let stageName = DiagnosticCandidateExportPolicy.resolvedStageName(
            stateNames: candidate.states.map(\.rawValue),
            unavailableReasons: candidate.unavailable,
            imageStageName: candidate.imageStageName
        ) else { return nil }

        return previews.first { $0.name == stageName }
    }

    private func sceneAnalysisObject(photo: CapturedPhoto, sourceHash: String) -> [String: Any] {
        var object: [String: Any] = ["sourceSha256": sourceHash]
        if let analysis = photo.analysis {
            object["analysisTrace"] = analysis.traceSummary
            object["visualSceneUnderstanding"] = analysis.visualSceneUnderstanding.traceSummary
            object["visualRegionEvidence"] = analysis.visualSceneUnderstanding.regionEvidence.map { evidence in
                [
                    "kind": evidence.kind.rawValue,
                    "source": evidence.source.rawValue,
                    "status": evidence.status.rawValue,
                    "confidence": evidence.confidence,
                    "coverage": evidence.coverage,
                    "maskReliability": evidence.maskReliability,
                    "boundaryDensity": evidence.boundaryDensity,
                    "localAdjustmentExecutable": evidence.isExecutableForLocalAdjustment,
                    "measurements": evidence.statistics.map { statistics -> Any in
                        [
                            "averageLuminance": statistics.averageLuminance,
                            "contrastRange": statistics.contrastRange,
                            "redAverage": statistics.redAverage,
                            "greenAverage": statistics.greenAverage,
                            "blueAverage": statistics.blueAverage,
                            "averageSaturation": statistics.averageSaturation,
                            "yellowColorRatio": statistics.yellowColorRatio,
                            "greenColorRatio": statistics.greenColorRatio,
                            "shadowRatio": statistics.shadowRatio,
                            "highlightRatio": statistics.highlightRatio
                        ] as [String: Any]
                    } ?? NSNull(),
                    "reason": evidence.reason,
                    "limitations": evidence.limitations
                ] as [String: Any]
            }
            object["visualRegionRelationships"] = analysis.visualSceneUnderstanding.regionRelationships.map { relationship in
                [
                    "identifier": relationship.identifier,
                    "status": relationship.status.rawValue,
                    "sourceRegion": relationship.sourceRegion.rawValue,
                    "comparedRegion": relationship.comparedRegion.rawValue,
                    "luminanceDelta": relationship.luminanceDelta.map { $0 as Any } ?? NSNull(),
                    "saturationDelta": relationship.saturationDelta.map { $0 as Any } ?? NSNull(),
                    "confidence": relationship.confidence,
                    "interpretation": relationship.interpretation
                ] as [String: Any]
            }
            object["sceneRecognition"] = [
                "status": analysis.sceneRecognitionDiagnostics.status.rawValue,
                "topConfidence": analysis.sceneRecognitionDiagnostics.topConfidence,
                "acceptedLabelCount": analysis.sceneRecognitionDiagnostics.acceptedLabelCount,
                "reason": analysis.sceneRecognitionDiagnostics.reason ?? "not recorded"
            ]
            object["segmentation"] = [
                "status": analysis.segmentationDiagnostics.status.rawValue,
                "reason": analysis.segmentationDiagnostics.reason ?? "not recorded",
                "coverage": [
                    "person": analysis.personMask?.activeCoverage ?? 0,
                    "subject": analysis.salientSubjectMask?.activeCoverage ?? 0,
                    "skin": analysis.skinMask?.activeCoverage ?? 0,
                    "sky": analysis.skyMask?.activeCoverage ?? 0,
                    "ground": analysis.groundMask?.activeCoverage ?? 0,
                    "vegetation": analysis.vegetationMask?.activeCoverage ?? 0,
                    "water": analysis.waterMask?.activeCoverage ?? 0,
                    "architecture": analysis.architectureMask?.activeCoverage ?? 0
                ]
            ]
        }
        if let report = photo.problemReport {
            object["problems"] = report.problems.map {
                ["kind": $0.kind.rawValue, "severity": $0.severity.rawValue, "confidence": $0.confidence]
            }
            if let analysis = photo.analysis {
                let diagnosis = PhotoProblemDetector().structuredDiagnosis(
                    in: analysis,
                    report: report
                )
                object["structuredPhotographyDiagnosis"] = [
                    "status": diagnosis.status.rawValue,
                    "unknowns": diagnosis.unknowns,
                    "evidence": diagnosis.evidence.map { item in
                        [
                            "identifier": item.identifier,
                            "status": item.status.rawValue,
                            "problemKind": item.problemKind?.rawValue ?? "measuredRelationship",
                            "severity": item.severity.rawValue,
                            "affectedRegions": item.affectedRegions.map(\.rawValue),
                            "measurementBasis": item.measurementBasis,
                            "photographicMeaning": item.photographicMeaning,
                            "adjustmentDirection": item.adjustmentDirection,
                            "sideEffects": item.sideEffects,
                            "confidence": item.confidence,
                            "executionStatus": item.executionStatus.rawValue,
                            "eligibilityStatus": item.executionStatus == .executable ? "eligible" : "notEligible",
                            "parameterPlanningStatus": "notEvaluatedAtDiagnosisStage",
                            "pixelExecutionStatus": "notEvaluatedAtDiagnosisStage",
                            "executionStatusMeaning": "diagnosis executable means eligible only; D records planned/executed/rejected after planning and rendering",
                            "knowledgeRuleIDs": item.knowledgeRuleIDs.map(\.rawValue)
                        ] as [String: Any]
                    }
                ] as [String: Any]
            }
        }
        if let decision = photo.decision {
            object["formalBDecision"] = [
                "sceneStrategy": decision.sceneStrategy.rawValue,
                "adaptiveTarget": decision.adaptiveTarget.summaryText,
                "targetRationale": decision.adaptiveTarget.rationale,
                "aestheticPlan": decision.aestheticPlan?.traceSummary ?? "unavailable",
                "recipe": decision.recipe.traceSummary,
                "parameterLifecycle": decision.recipeLifecycle.map { snapshot in
                    [
                        "stage": snapshot.stage,
                        "recipe": snapshot.recipeSummary,
                        "changes": snapshot.changes
                    ] as [String: Any]
                },
                "actions": decision.actions.map { ["title": $0.title, "reason": $0.reason] }
            ]
        }
        return object
    }

    private func qualityObject(photo: CapturedPhoto) -> [String: Any] {
        var object: [String: Any] = [:]
        if let quality = photo.qualityCheck {
            object["formalB"] = [
                "status": quality.status.rawValue,
                "issues": quality.issues.map(\.rawValue),
                "fallbackApplied": quality.fallbackApplied,
                "rgbMAE": quality.processingImpact.normalizedMeanAbsoluteRGBDifference,
                "changedPixelRatio": quality.processingImpact.changedPixelRatio,
                "neutralChromaIncrease": quality.colorIntegrity.neutralChromaIncrease,
                "neutralWarmShift": quality.colorIntegrity.neutralWarmShift,
                "neutralGreenShift": quality.colorIntegrity.neutralGreenShift,
                "neutralLuminanceShift": quality.colorIntegrity.neutralLuminanceShift,
                "protectedNeutralCoverage": quality.colorIntegrity.protectedNeutralCoverage,
                "protectedNeutralLuminanceShift": quality.colorIntegrity.protectedNeutralLuminanceShift,
                "intentionalToneNeutralCoverage": quality.colorIntegrity.intentionalToneNeutralCoverage,
                "intentionalToneNeutralLuminanceShift": quality.colorIntegrity.intentionalToneNeutralLuminanceShift,
                "skinColorDifference": quality.colorIntegrity.skinColorDifference,
                "skinWarmShift": quality.colorIntegrity.skinWarmShift
            ]
        }
        if let diagnostics = photo.processingDiagnostics {
            object["AtoBPixelDifference"] = [
                "rgbMAE": diagnostics.difference.normalizedMeanAbsoluteRGBDifference,
                "luminanceMAE": diagnostics.difference.meanAbsoluteLuminanceDifference,
                "colorMAE": diagnostics.difference.meanAbsoluteColorDifference,
                "changedPixelRatio": diagnostics.difference.changedPixelRatio
            ]
            object["regionalImpacts"] = diagnostics.finalRegionImpacts.map { impact in
                [
                    "region": impact.region.rawValue,
                    "maskCoverage": impact.maskCoverage,
                    "luminanceDelta": impact.luminanceDelta,
                    "colorDelta": impact.colorDelta,
                    "contrastDelta": impact.contrastDelta,
                    "changedPixelRatio": impact.changedPixelRatio,
                    "sourceShadowRatio": impact.sourceShadowRatio,
                    "editedShadowRatio": impact.editedShadowRatio,
                    "sourceHighlightRatio": impact.sourceHighlightRatio,
                    "editedHighlightRatio": impact.editedHighlightRatio,
                    "detailEnergyRatio": impact.detailEnergyRatio
                ]
            }
            object["candidateEvaluations"] = diagnostics.candidateEvaluations.map { evaluation in
                [
                    "planID": evaluation.planID,
                    "title": evaluation.title,
                    "status": evaluation.status.rawValue,
                    "score": evaluation.score,
                    "problemImprovement": evaluation.problemImprovement,
                    "targetAttainmentScore": evaluation.targetAttainmentScore,
                    "preservationScore": evaluation.preservationScore,
                    "subjectPriorityScore": evaluation.subjectPriorityScore,
                    "harmonyScore": evaluation.harmonyScore,
                    "issues": evaluation.issues,
                    "reason": evaluation.reason,
                    "durationMilliseconds": evaluation.durationMilliseconds,
                    "selected": evaluation.selected,
                    "selectionBasis": evaluation.selectionBasis.rawValue,
                    "humanPreferenceStatus": evaluation.preferenceEvidenceStatus.rawValue,
                    "scoreMeaning": "engineering_proxy_not_human_aesthetic_preference"
                ] as [String: Any]
            }
            object["fallbackReason"] = diagnostics.fallbackReason ?? "none"
        }
        object["diagnosticCandidateQuality"] = photo.diagnosticCandidates.map { candidate in
            [
                "identifier": candidate.identifier,
                "qualityStatus": candidate.qualityStatus ?? "notRun",
                "targetQualityStatus": candidate.targetQualityStatus,
                "humanAestheticStatus": candidate.humanAestheticStatus,
                "assessmentEvidence": candidate.assessmentEvidence,
                "states": candidate.states.map(\.rawValue),
                "rejected": candidate.rejected,
                "fallback": candidate.fallback,
                "unavailable": candidate.unavailable
            ]
        }
        return object
    }

    private func performanceObject(photo: CapturedPhoto) -> [String: Any] {
        guard let diagnostics = photo.processingDiagnostics else {
            return ["status": "unavailable", "reason": "processing diagnostics were not retained"]
        }
        return [
            "stages": diagnostics.stages.map {
                [
                    "name": $0.name,
                    "durationMilliseconds": $0.durationMilliseconds,
                    "executed": $0.executed,
                    "detail": $0.detail
                ]
            },
            "candidateDurations": photo.diagnosticCandidates.map {
                [
                    "identifier": $0.identifier,
                    "durationMilliseconds": $0.durationMilliseconds.map(String.init) ?? "notRun"
                ]
            }
        ]
    }

    private func productionExecutionObject(
        photo: CapturedPhoto,
        identity: ProductionCaptureEvidenceIdentity
    ) -> [String: Any] {
        guard let decision = photo.decision else {
            return [
                "captureID": identity.captureID.uuidString,
                "status": "unavailable",
                "reason": "formal B decision was not retained"
            ]
        }
        let diagnostics = photo.processingDiagnostics
        return [
            "captureID": identity.captureID.uuidString,
            "sourceSha256": identity.sourceSHA256,
            "formalBSha256": identity.formalBSHA256,
            "sameCaptureIDVerified": true,
            "formalBBytesWereRerenderedForExport": false,
            "sceneStrategy": decision.sceneStrategy.rawValue,
            "intent": decision.intent,
            "target": [
                "summary": decision.adaptiveTarget.summaryText,
                "rationale": decision.adaptiveTarget.rationale,
                "luminance": decision.adaptiveTarget.luminance,
                "luminanceMinimum": decision.adaptiveTarget.luminanceMinimum,
                "luminanceMaximum": decision.adaptiveTarget.luminanceMaximum,
                "contrast": decision.adaptiveTarget.contrast,
                "shadowRatio": decision.adaptiveTarget.shadowRatio,
                "highlightRatio": decision.adaptiveTarget.highlightRatio,
                "saturation": decision.adaptiveTarget.saturation,
                "atmosphereProtection": decision.adaptiveTarget.atmosphereProtection,
                "aestheticPlan": decision.aestheticPlan?.traceSummary ?? "unavailable"
            ] as [String: Any],
            "finalRecipe": recipeObject(decision.recipe),
            "recipeLifecycle": decision.recipeLifecycle.map {
                [
                    "stage": $0.stage,
                    "recipeSummary": $0.recipeSummary,
                    "changes": $0.changes
                ] as [String: Any]
            },
            "parameterEvidence": decision.parameterEvidence.map {
                [
                    "parameter": $0.key.rawValue,
                    "purpose": $0.purpose,
                    "sourceMeasurement": $0.inputEvidence,
                    "target": $0.target,
                    "minimumValue": $0.minimumValue,
                    "maximumValue": $0.maximumValue,
                    "actualValue": $0.actualValue,
                    "expectedResult": $0.expectedResult,
                    "fallbackBehavior": $0.fallbackBehavior,
                    "affectedRegion": $0.affectedRegion.rawValue,
                    "status": $0.decisionStatus.rawValue,
                    "knowledgeRuleIDs": $0.knowledgeRuleIDs.map(\.rawValue)
                ] as [String: Any]
            },
            "regionalPlan": [
                "status": decision.adaptiveRegionalTonePlan == nil ? "not_planned" : "planned",
                "evidence": decision.adaptiveRegionalTonePlan?.evidence ?? [],
                "adjustments": decision.adaptiveRegionalTonePlan?.adjustments.map {
                    regionalAdjustmentObject($0)
                } ?? [],
                "executionReceipts": diagnostics?.regionalExecutionDetails ?? [],
                "regionPixelImpacts": diagnostics?.finalRegionImpacts.map { impact in
                    [
                        "region": impact.region.rawValue,
                        "maskCoverage": impact.maskCoverage,
                        "luminanceDelta": impact.luminanceDelta,
                        "colorDelta": impact.colorDelta,
                        "contrastDelta": impact.contrastDelta,
                        "changedPixelRatio": impact.changedPixelRatio,
                        "detailEnergyRatio": impact.detailEnergyRatio
                    ] as [String: Any]
                } ?? []
            ] as [String: Any],
            "executedModules": diagnostics?.executedModules ?? [],
            "parameterExecutionResults": diagnostics?.parameterExecutionResults ?? [],
            "candidateEvaluations": diagnostics?.candidateEvaluations.map { evaluation in
                [
                    "planID": evaluation.planID,
                    "title": evaluation.title,
                    "status": evaluation.status.rawValue,
                    "score": evaluation.score,
                    "selected": evaluation.selected,
                    "reason": evaluation.reason,
                    "selectionBasis": evaluation.selectionBasis.rawValue,
                    "durationMilliseconds": evaluation.durationMilliseconds,
                    "humanPreferenceStatus": evaluation.preferenceEvidenceStatus.rawValue
                ] as [String: Any]
            } ?? [],
            "fallbackReason": diagnostics?.fallbackReason ?? "none",
            "quality": photo.qualityCheck.map {
                [
                    "status": $0.status.rawValue,
                    "issues": $0.issues.map(\.rawValue),
                    "fallbackApplied": $0.fallbackApplied
                ] as [String: Any]
            } ?? ["status": "unavailable"],
            "processingStages": diagnostics?.stages.map {
                [
                    "name": $0.name,
                    "durationMilliseconds": $0.durationMilliseconds,
                    "executed": $0.executed,
                    "detail": $0.detail
                ] as [String: Any]
            } ?? []
        ]
    }

    private func recipeObject(_ recipe: AutomaticEditingRecipe) -> [String: Any] {
        [
            "traceSummary": recipe.traceSummary,
            "global": [
                "exposureEV": recipe.exposureEV,
                "highlightAmount": recipe.highlightAmount,
                "shadowAmount": recipe.shadowAmount,
                "brightness": recipe.brightness,
                "contrast": recipe.contrast,
                "blackPoint": recipe.blackPoint,
                "whitePoint": recipe.whitePoint,
                "shadowRollOff": recipe.shadowRollOff,
                "lowerMidtoneLift": recipe.lowerMidtoneLift,
                "midtoneBias": recipe.midtoneBias,
                "upperMidtoneSeparation": recipe.upperMidtoneSeparation,
                "highlightRollOff": recipe.highlightRollOff,
                "localContrastAmount": recipe.localContrastAmount,
                "saturation": recipe.saturation,
                "vibrance": recipe.vibrance,
                "temperatureShift": recipe.temperatureShift,
                "tintShift": recipe.tintShift,
                "noiseReductionAmount": recipe.noiseReductionAmount,
                "sharpeningAmount": recipe.sharpeningAmount
            ],
            "rgbCurves": [
                "intensity": recipe.rgbCurves.intensity,
                "red": recipe.rgbCurves.red.anchors,
                "green": recipe.rgbCurves.green.anchors,
                "blue": recipe.rgbCurves.blue.anchors,
                "identity": recipe.rgbCurves.isIdentity
            ],
            "hsl": hslObject(recipe.hsl),
            "tonalColorGrade": [
                "shadows": tonalColorVectorObject(recipe.tonalColorGrade.shadows),
                "midtones": tonalColorVectorObject(recipe.tonalColorGrade.midtones),
                "highlights": tonalColorVectorObject(recipe.tonalColorGrade.highlights),
                "neutralChromaProtection": recipe.tonalColorGrade.neutralChromaProtection,
                "highlightNeutralProtection": recipe.tonalColorGrade.highlightNeutralProtection,
                "neutral": recipe.tonalColorGrade.isNeutral
            ],
            "legacyColorGrade": [
                "mode": recipe.cinematicColorGradeMode.rawValue,
                "intensity": recipe.colorGradeIntensity,
                "shadowCoolAmount": recipe.shadowCoolAmount,
                "midtoneCoolAmount": recipe.midtoneCoolAmount,
                "midtoneWarmAmount": recipe.midtoneWarmAmount,
                "highlightWarmAmount": recipe.highlightWarmAmount,
                "colorContrast": recipe.colorContrast,
                "neutralHighlightProtection": recipe.neutralHighlightProtection
            ]
        ]
    }

    private func hslObject(_ hsl: ProfessionalHSLAdjustment) -> [String: Any] {
        [
            "mathMode": hsl.mathMode.rawValue,
            "red": ["hue": hsl.redHue, "saturation": hsl.redSaturation, "luminance": hsl.redLuminance],
            "orange": ["hue": hsl.orangeHue, "saturation": hsl.orangeSaturation, "luminance": hsl.orangeLuminance],
            "yellow": ["hue": hsl.yellowHue, "saturation": hsl.yellowSaturation, "luminance": hsl.yellowLuminance],
            "green": ["hue": hsl.greenHue, "saturation": hsl.greenSaturation, "luminance": hsl.greenLuminance],
            "cyan": ["hue": hsl.cyanHue, "saturation": hsl.cyanSaturation, "luminance": hsl.cyanLuminance],
            "blue": ["hue": hsl.blueHue, "saturation": hsl.blueSaturation, "luminance": hsl.blueLuminance],
            "purple": ["hue": hsl.purpleHue, "saturation": hsl.purpleSaturation, "luminance": hsl.purpleLuminance],
            "magenta": ["hue": hsl.magentaHue, "saturation": hsl.magentaSaturation, "luminance": hsl.magentaLuminance]
        ]
    }

    private func tonalColorVectorObject(_ vector: TonalColorVector) -> [String: Any] {
        ["red": vector.red, "green": vector.green, "blue": vector.blue, "amount": vector.amount]
    }

    private func regionalAdjustmentObject(_ adjustment: ManualRegionalToneAdjustment) -> [String: Any] {
        [
            "region": adjustment.region.rawValue,
            "exposureEV": adjustment.exposureEV,
            "highlightAmount": adjustment.highlightAmount,
            "shadowAmount": adjustment.shadowAmount,
            "blackPoint": adjustment.blackPoint,
            "shadowRollOff": adjustment.shadowRollOff,
            "whitePoint": adjustment.whitePoint,
            "lowerMidtoneLift": adjustment.lowerMidtoneLift,
            "midtoneBias": adjustment.midtoneBias,
            "upperMidtoneSeparation": adjustment.upperMidtoneSeparation,
            "highlightRollOff": adjustment.highlightRollOff,
            "contrast": adjustment.contrast,
            "saturation": adjustment.saturation,
            "hsl": hslObject(adjustment.hsl),
            "luminanceLowerBound": adjustment.luminanceLowerBound,
            "luminanceUpperBound": adjustment.luminanceUpperBound,
            "luminanceFeather": adjustment.luminanceFeather
        ]
    }

    private func appIdentityObject() -> [String: Any] {
        [
            "name": Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "小苏相机",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "gitCommitSha": Bundle.main.object(forInfoDictionaryKey: "XGitCommitSHA") as? String ?? "unknown"
        ]
    }

    private func deviceIdentityObject() -> [String: Any] {
        [
            "model": UIDevice.current.model,
            "hardwareIdentifier": Self.deviceHardwareIdentifier(),
            "name": UIDevice.current.name,
            "systemName": UIDevice.current.systemName,
            "systemVersion": UIDevice.current.systemVersion
        ]
    }

    private func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func readme(sourceHash: String, includesLocalTarget: Bool) -> String {
        let targetDescription = includesLocalTarget
            ? "由用户本次明确选择，仅写入本地分享 ZIP，未进入渲染"
            : "本次未选择，因此未打包"
        return """
        小苏相机诊断证据包

        同源原图 SHA-256：\(sourceHash)
        A = 原图
        B = 顶部“B 正式成片”按钮显示的正式算法输出
        C = 摄影参考候选；许可或索引不可用时只有 UNAVAILABLE 记录
        D = 逐图自动后期诊断输出，不替换 B
        E1 = 由当前照片测量独立求解的空间层次目标实验，人工偏好待评价
        E2 = 由当前照片测量独立求解的克制暗调目标实验，人工偏好待评价
        M / R-I = Task 2-A 人工声明的 Core Image 电影影调表达能力验证，不替换 B/D
        T = 外部专业目标参考；\(targetDescription)；绝不冒充 App 成片
        差异图 = A 与 B 的五倍放大差异，不代表 D、E1、E2 或 M

        candidate_states_and_parameters.json 明确区分 planned、executed、rejected、fallback、unavailable，
        并分别记录技术质检、摄影目标质量状态和人工审美状态。
        TASK2A_RENDER_VALIDATION_STATUS.json 明确区分 A、外部 T 与设备实际 M/R-I。
        屏幕截图不是实际成片文件；images 目录保留 A 的真实原始编码，B/D/E/M/V2 等 JPEG 才是本次处理实际输出。
        """
    }

    private func task2AComparisonHTML(
        sourcePath: String,
        targetPath: String?,
        includesLocalTarget: Bool,
        includesRenderedCandidate: Bool,
        technicalStatus: String,
        executionState: String
    ) -> String {
        let target: String
        if includesLocalTarget, let targetPath {
            target = "<section><h2>T · 独立研究参考（未参与渲染）</h2><img class=\"zoomable\" src=\"\(targetPath)\"></section>"
        } else {
            target = "<section><h2>T · 未选择</h2><p>本证据包不含专业参考 T。</p></section>"
        }
        let rendered = includesRenderedCandidate
            ? "<section><h2>R-I · Task 2-A Core Image</h2><img class=\"zoomable\" src=\"images/M_manual_render.jpg\"><p>技术状态与执行参数见 evidence/TASK2A_RENDER_VALIDATION_STATUS.json；审美状态默认为 pending_human_review。</p></section>"
            : "<section><h2>R-I · 渲染不可用</h2><p>请检查 evidence/TASK2A_RENDER_VALIDATION_STATUS.json 与候选失败记录。</p></section>"
        return """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Task 2-A A/T/R-I 对照</title><style>body{font:15px system-ui;background:#111;color:#eee;margin:0;padding:18px}main{max-width:1500px;margin:auto}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:16px}section{background:#1b1b1b;padding:12px;border-radius:12px;overflow:auto}img{width:100%;height:auto}.zoomable{cursor:zoom-in}.zoomable.zoom{width:auto;max-width:none}.review{display:flex;gap:10px;flex-wrap:wrap;margin:16px 0}button{padding:9px 12px}p{color:#bbb}</style></head>
        <body><main><h1>Task 2-A 本机 Core Image 表达能力证据</h1><p>A 是唯一渲染输入；T 仅供独立人工评价；R-I 来自真实 M 诊断渲染。此页面不代表自动摄影决策或审美验收通过。</p><p><strong>参数来源：</strong>\(ManualPhotographyParameters.task2ACinematicExpression.identifier)（人工声明的隔离表达探针） · <strong>执行状态：</strong>\(executionState) · <strong>技术质检：</strong>\(technicalStatus)。完整实际配方、区域回执和像素证据见 evidence/TASK2A_RENDER_VALIDATION_STATUS.json。</p><div class="review"><button data-v="reached">达到摄影目标</button><button data-v="partially_reached">部分达到</button><button data-v="not_reached">未达到</button><button data-v="pending_human_review">尚无法评价</button><button id="download">导出人工评价 JSON</button><strong id="review">pending_human_review</strong></div><div class="grid"><section><h2>A · 原图</h2><img class="zoomable" src="\(sourcePath)"></section>\(target)\(rendered)<section><h2>B · 正式算法（未修改）</h2><img class="zoomable" src="images/B_formal_output.jpg"></section></div><script>let review='pending_human_review';document.querySelectorAll('.zoomable').forEach(x=>x.onclick=()=>x.classList.toggle('zoom'));document.querySelectorAll('[data-v]').forEach(b=>b.onclick=()=>{review=b.dataset.v;document.getElementById('review').textContent=review});document.getElementById('download').onclick=()=>{const payload={schemaVersion:1,experiment:'task2a_cinematic_expression',humanEntered:true,status:review,recordedAt:new Date().toISOString()};const blob=new Blob([JSON.stringify(payload,null,2)],{type:'application/json'});const a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download='task2a-human-review.json';a.click();URL.revokeObjectURL(a.href)}</script></main></body></html>
        """
    }

    static func imageFileExtension(_ data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              let preferred = UTType(type as String)?.preferredFilenameExtension
        else { return "img" }
        return preferred.lowercased()
    }

    private func sanitized(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let transformed = name.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let value = String(transformed).replacingOccurrences(of: "__", with: "_")
        return String(value.prefix(96))
    }

    private static func encodedPixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else { return nil }
        return (width.intValue, height.intValue)
    }

    private static func encodedImageIdentity(_ data: Data) -> [String: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return ["uniformType": "not_an_image"]
        }
        let uniformType = CGImageSourceGetType(source).map { $0 as String } ?? "unknown"
        var result: [String: Any] = ["uniformType": uniformType]
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            result["orientation"] = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            result["colorModel"] = properties[kCGImagePropertyColorModel] as? String ?? "unknown"
            result["colorProfile"] = properties[kCGImagePropertyProfileName] as? String ?? "unspecified"
        }
        return result
    }

    /// Vision rectangles use a lower-left origin. The JPEG crop is made from
    /// an orientation-normalized native-pixel canvas and is never resized, so
    /// reviewers can inspect face texture at 100% rather than a thumbnail.
    private static func faceCropJPEG(
        _ data: Data,
        normalizedVisionRegion: NormalizedPhotoRegion
    ) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let pixelSize = CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
        guard pixelSize.width >= 1, pixelSize.height >= 1 else { return nil }
        let normalizedX = min(1, max(0, CGFloat(normalizedVisionRegion.x)))
        let normalizedY = min(1, max(0, CGFloat(normalizedVisionRegion.y)))
        let normalizedWidth = min(1, max(0, CGFloat(normalizedVisionRegion.width)))
        let normalizedHeight = min(1, max(0, CGFloat(normalizedVisionRegion.height)))
        let crop = CGRect(
            x: normalizedX * pixelSize.width,
            y: min(1, max(0, 1 - normalizedY - normalizedHeight)) * pixelSize.height,
            width: normalizedWidth * pixelSize.width,
            height: normalizedHeight * pixelSize.height
        ).integral.intersection(CGRect(origin: .zero, size: pixelSize))
        guard crop.width >= 2, crop.height >= 2 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let cropped = UIGraphicsImageRenderer(size: crop.size, format: format).image { _ in
            image.draw(in: CGRect(
                x: -crop.minX,
                y: -crop.minY,
                width: pixelSize.width,
                height: pixelSize.height
            ))
        }
        return cropped.jpegData(compressionQuality: 0.96)
    }

    private static func deviceHardwareIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 1 else {
            return "unavailable"
        }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &value, &size, nil, 0) == 0 else {
            return "unavailable"
        }
        return String(cString: value)
    }

    private static let fileTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()
}

struct DiagnosticBatchArchive: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let requestedCount: Int
    let completedCount: Int
    let failedCount: Int
}

struct DiagnosticBatchProgress: Equatable, Sendable {
    let completedCount: Int
    let totalCount: Int
    let currentItem: Int
    let failureCount: Int

    var title: String { "正在批量生成真实候选" }
    var subtitle: String {
        "第 \(currentItem)/\(totalCount) 张 · 已完成 \(completedCount) 张 · 失败 \(failureCount) 张"
    }
}

struct DiagnosticBatchCase: Sendable {
    let index: Int
    let sourceHash: String
    let archiveURL: URL
    let candidates: [DiagnosticBatchCandidateSummary]
    let blindImages: [DiagnosticBatchImageFile]
}

struct DiagnosticBatchCandidateSummary: Codable, Sendable {
    let identifier: String
    let states: [String]
    let qualityStatus: String
    let humanAestheticStatus: String
}

struct DiagnosticBatchImageFile: Sendable {
    let identifier: String
    let fileURL: URL
    let technicalStatus: String
    let eligibleForPreference: Bool
}

struct DiagnosticBatchFailure: Codable, Sendable {
    let index: Int
    let sourceHash: String?
    let reason: String
}

/// Combines already-created per-photo evidence archives without loading their
/// full-resolution contents back into memory. Each nested ZIP remains a
/// self-contained, same-source A/B/D/E1/E2/M evidence package.
final class DiagnosticBatchBundleExporter {
    func makeArchive(
        requestedCount: Int,
        cases: [DiagnosticBatchCase],
        failures: [DiagnosticBatchFailure]
    ) throws -> DiagnosticBatchArchive {
        let caseRecords: [[String: Any]] = cases.map { item in
            [
                "index": item.index,
                "sourceSha256": item.sourceHash,
                "archive": casePath(item),
                "candidateStatus": item.candidates.map { candidate in
                    [
                        "identifier": candidate.identifier,
                        "states": candidate.states,
                        "qualityStatus": candidate.qualityStatus,
                        "humanAestheticStatus": candidate.humanAestheticStatus
                    ]
                },
                "blindImages": item.blindImages.map { image in
                    [
                        "identifier": image.identifier,
                        "path": blindImagePath(image, in: item),
                        "technicalStatus": image.technicalStatus,
                        "eligibleForPreference": image.eligibleForPreference
                    ]
                }
            ]
        }
        let failureRecords: [[String: Any]] = failures.map { failure in
            [
                "index": failure.index,
                "sourceSha256": failure.sourceHash ?? "unavailable",
                "reason": failure.reason
            ]
        }
        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "evidenceOrigin": "iPhone production PhotoProcessingPipeline and Apple Core Image",
            "evidenceScope": "internal diagnostic batch; not macOS Runner evidence and not Windows simulation",
            "requestedCount": requestedCount,
            "completedCount": cases.count,
            "failedCount": failures.count,
            "processingPolicy": "serial; each full-resolution case is exported and released before the next case",
            "formalAlgorithmB": "unchanged",
            "humanPreference": "notEvaluated; this archive does not fabricate votes",
            "cases": caseRecords,
            "failures": failureRecords
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let readme = """
        小苏相机批量摄影候选取证包

        - 每个 cases/.../diagnostic.zip 对应一张独立原图。
        - 子 ZIP 内包含同源 A/B/D/E1/E2/M/V2-1/V2-2/V2-3/V2-AUTO 全分辨率图像、实际参数、蒙版与质检证据。
        - comparison.html 明示 A、当前正式 B、三张 V2 与暂定 AUTO；blind-compare.html 只匿名比较 B 与 V2-1/2/3，绝不显示或泄漏 AUTO 选择。
        - 图像由 iPhone 上的生产 PhotoProcessingPipeline 与 Apple Core Image 串行生成。
        - 技术失败候选仍保留取证，但不得视为正式可用候选。
        - 本文件不包含、推断或伪造任何人工摄影偏好。
        - 正式 B、普通拍照和原图保存流程未被批量取证改变。
        """

        let memoryEntries = [
            DiagnosticExportEntry(path: "batch_manifest.json", data: manifestData, role: "batch manifest"),
            DiagnosticExportEntry(path: "README.txt", data: Data(readme.utf8), role: "human-readable guide"),
            DiagnosticExportEntry(
                path: "blind-compare.html",
                data: Data(blindCompareHTML(cases: cases).utf8),
                role: "direct-open human preference page"
            ),
            DiagnosticExportEntry(
                path: "comparison.html",
                data: Data(comparisonHTML(cases: cases).utf8),
                role: "labeled A/B/V2/AUTO evidence comparison"
            )
        ]
        var fileEntries = cases.map { item in
            DiagnosticFileExportEntry(
                path: casePath(item),
                fileURL: item.archiveURL,
                role: "per-photo complete diagnostic archive"
            )
        }
        fileEntries.append(contentsOf: cases.flatMap { item in
            item.blindImages.map { image in
                DiagnosticFileExportEntry(
                    path: blindImagePath(image, in: item),
                    fileURL: image.fileURL,
                    role: "full-resolution blind comparison image"
                )
            }
        })
        let stamp = Self.fileTimestamp.string(from: Date())
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("XiaoSuCamera_BatchDiagnostic_\(stamp)_\(cases.count)of\(requestedCount).zip")
        try? FileManager.default.removeItem(at: destination)
        try NativeZipArchiveWriter.write(entries: memoryEntries, fileEntries: fileEntries, to: destination)
        return DiagnosticBatchArchive(
            url: destination,
            requestedCount: requestedCount,
            completedCount: cases.count,
            failedCount: failures.count
        )
    }

    private func casePath(_ item: DiagnosticBatchCase) -> String {
        String(format: "cases/%02d_%@/diagnostic.zip", item.index, String(item.sourceHash.prefix(12)))
    }

    private func blindImagePath(_ image: DiagnosticBatchImageFile, in item: DiagnosticBatchCase) -> String {
        let stem: String
        switch image.identifier {
        case "A": stem = "A_original.jpg"
        case "B": stem = "B_formal_output.jpg"
        case "D": stem = "D_automatic.jpg"
        case "E1": stem = "E1_spatial_emphasis.jpg"
        case "E2": stem = "E2_restrained_depth.jpg"
        default: stem = "\(image.identifier)_evidence.jpg"
        }
        return String(format: "blind/case_%02d_%@/%@", item.index, String(item.sourceHash.prefix(12)), stem)
    }

    private func blindCompareHTML(cases: [DiagnosticBatchCase]) -> String {
        let payload: [[String: Any]] = cases.map { item in
            let original = item.blindImages.first { $0.identifier == "A" }
            return [
                "caseId": String(format: "case_%02d", item.index),
                "sourceSha256": item.sourceHash,
                "original": original.map { blindImagePath($0, in: item) } ?? "",
                "candidates": item.blindImages.filter {
                    DiagnosticBatchComparisonPolicy.blindCandidateIdentifiers.contains($0.identifier)
                }.map { image in
                    [
                        "id": image.identifier,
                        "image": blindImagePath(image, in: item),
                        "technicalStatus": image.technicalStatus,
                        "eligible": image.eligibleForPreference
                    ] as [String: Any]
                }
            ]
        }
        let json = (try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>小苏相机跨场景候选盲测</title><style>
        body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;margin:0;background:#101114;color:#f4f4f4}main{max-width:1500px;margin:auto;padding:24px}select,button,textarea{font:inherit;padding:10px;border-radius:9px;border:1px solid #555;background:#202228;color:#fff}button{cursor:pointer}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:18px}.card{background:#191b20;padding:12px;border-radius:14px}.card img{width:100%;max-height:68vh;object-fit:contain;background:#000}.failed{border:2px solid #d85b5b}.eligible{border:2px solid #4d9c72}.badge{font-size:13px;color:#ccc;min-height:38px}.actions{display:flex;flex-wrap:wrap;gap:10px;margin:20px 0}.warn{color:#ffcc80}textarea{width:100%;min-height:80px;box-sizing:border-box}pre{white-space:pre-wrap;background:#17181c;padding:12px;border-radius:10px}
        </style></head><body><main><h1>7 图正式 B / V2 真实候选盲测</h1><p class="warn">候选顺序每次随机；页面不显示候选名称，也不包含或泄漏 V2-AUTO 的选择结果。只有技术合格候选可被选为最好，页面不会自动填写或伪造人工偏好。</p>
        <label>照片：<select id="case"></select></label><section><h2>原图</h2><img id="original" style="max-width:520px;max-height:60vh;object-fit:contain;background:#000"></section><h2>匿名候选</h2><div id="candidates" class="grid"></div>
        <div class="actions"><button data-special="all_bad">全部不好</button><button data-special="difference_not_obvious">差异不明显</button></div><textarea id="issues" placeholder="记录偏色、肤色、黑位、光晕、过饱和、局部错误或其他原因"></textarea><div class="actions"><button id="download">下载人工评价 JSON</button></div><pre id="status"></pre>
        <script>const cases=\(json);let current=null,order=[],results=[];const $=id=>document.getElementById(id);function shuffle(x){return [...x].sort(()=>Math.random()-.5)}function render(){current=cases.find(x=>x.caseId===$('case').value);$('original').src=current.original;order=shuffle(current.candidates);$('candidates').innerHTML='';order.forEach((c,i)=>{const d=document.createElement('div');d.className='card '+(c.eligible?'eligible':'failed');const b=c.eligible?`<button data-win="${i}">选择候选 ${i+1}</button>`:'<strong>技术失败，仅供查看，不可选</strong>';d.innerHTML=`<h3>候选 ${i+1}</h3><img src="${c.image}"><p class="badge">技术状态：${c.technicalStatus}</p>${b}`;$('candidates').appendChild(d)});document.querySelectorAll('[data-win]').forEach(b=>b.onclick=()=>record('best',order[Number(b.dataset.win)]));$('status').textContent=`SHA-256：${current.sourceSha256}\n尚未记录本图人工评价。`;}function record(choice,winner){const entry={schemaVersion:1,caseId:current.caseId,sourceSha256:current.sourceSha256,recordedAt:new Date().toISOString(),blindOrder:order.map(x=>({slot:order.indexOf(x)+1,technicalStatus:x.technicalStatus,eligible:x.eligible})),choice,winner:winner?winner.id:null,issues:$('issues').value.trim(),source:'iphone_batch_core_image_blind_review'};results=results.filter(x=>x.caseId!==current.caseId);results.push(entry);$('status').textContent=`已记录 ${results.length}/${cases.length} 条。本图选择：${choice}${winner?'；揭盲='+winner.id:''}`;}document.querySelectorAll('[data-special]').forEach(b=>b.onclick=()=>record(b.dataset.special,null));$('download').onclick=()=>{const blob=new Blob([JSON.stringify({schemaVersion:1,createdAt:new Date().toISOString(),humanEntered:true,results},null,2)],{type:'application/json'});const a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download='xiaosu-human-preference.json';a.click();URL.revokeObjectURL(a.href)};cases.forEach((c,i)=>{const o=document.createElement('option');o.value=c.caseId;o.textContent=`照片 ${i+1}`;$('case').appendChild(o)});$('case').onchange=render;if(cases.length)render();</script></main></body></html>
        """
    }

    private func comparisonHTML(cases: [DiagnosticBatchCase]) -> String {
        let sections = cases.map { item -> String in
            let cards = DiagnosticBatchComparisonPolicy.labeledComparisonIdentifiers.compactMap { identifier -> String? in
                guard let image = item.blindImages.first(where: { $0.identifier == identifier }) else {
                    return nil
                }
                let path = blindImagePath(image, in: item)
                return """
                <article class="card"><h3>\(identifier)</h3><img src="\(path)">
                <p>技术状态：\(image.technicalStatus)</p></article>
                """
            }.joined(separator: "\n")
            return """
            <section><h2>照片 \(item.index) · SHA-256 \(item.sourceHash)</h2>
            <div class="grid">\(cards)</div></section>
            """
        }.joined(separator: "\n")
        return """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>小苏相机 iPhone A/B/V2 对照</title><style>
        body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;margin:0;background:#101114;color:#f4f4f4}main{max-width:1700px;margin:auto;padding:24px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:16px}.card{background:#191b20;padding:12px;border-radius:14px}.card img{width:100%;max-height:70vh;object-fit:contain;background:#000}h2{margin-top:42px;overflow-wrap:anywhere}p{color:#ccc}.warn{color:#ffcc80}
        </style></head><body><main><h1>同源 iPhone A / 正式 B / V2 对照</h1>
        <p class="warn">V2-AUTO 是暂定工程选择，不代表摄影审美通过；是否更好必须通过独立盲测评价。</p>
        \(sections)</main></body></html>
        """
    }

    private static let fileTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()
}

private struct DiagnosticExportEntry {
    let path: String
    let data: Data
    let role: String
}

private struct DiagnosticFileExportEntry {
    let path: String
    let fileURL: URL
    let role: String
}

private enum DiagnosticBundleExportError: LocalizedError {
    case notDiagnosticImport
    case notNormalCapture
    case internalEvidenceDisabled
    case incompleteProductionEvidence
    case archiveTooLarge

    var errorDescription: String? {
        switch self {
        case .notDiagnosticImport: return "只有诊断导入照片可以导出证据包。"
        case .notNormalCapture: return "普通拍照 A/B 取证不能用于诊断导入照片。"
        case .internalEvidenceDisabled: return "当前构建未启用内部正常拍照取证。"
        case .incompleteProductionEvidence: return "本次拍照缺少完整的 A/B、最终参数或执行记录，不能生成取证包。"
        case .archiveTooLarge: return "诊断证据包超过 ZIP32 可导出范围。"
        }
    }
}

/// Minimal ZIP32 writer using the store method. iOS Files, AirDrop and the share
/// sheet can open the result without external libraries.
private enum NativeZipArchiveWriter {
    private struct CentralRecord {
        let name: Data
        let crc32: UInt32
        let size: UInt32
        let offset: UInt32
    }

    static func write(
        entries: [DiagnosticExportEntry],
        fileEntries: [DiagnosticFileExportEntry] = [],
        to url: URL
    ) throws {
        guard entries.count + fileEntries.count <= Int(UInt16.max) else {
            throw DiagnosticBundleExportError.archiveTooLarge
        }

        let partialURL = url.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partialURL)
        guard FileManager.default.createFile(atPath: partialURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: partialURL)
        } catch {
            try? FileManager.default.removeItem(at: partialURL)
            throw error
        }

        var outputOffset: UInt64 = 0
        var centralRecords: [CentralRecord] = []
        let dos = dosTimestamp(Date())

        func writeChunk(_ data: Data) throws {
            let nextOffset = outputOffset + UInt64(data.count)
            guard nextOffset <= UInt64(UInt32.max) else {
                throw DiagnosticBundleExportError.archiveTooLarge
            }
            try handle.write(contentsOf: data)
            outputOffset = nextOffset
        }

        do {
            for entry in entries {
                guard entry.data.count <= Int(UInt32.max) else {
                    throw DiagnosticBundleExportError.archiveTooLarge
                }
                let name = Data(entry.path.utf8)
                guard name.count <= Int(UInt16.max), outputOffset <= UInt64(UInt32.max) else {
                    throw DiagnosticBundleExportError.archiveTooLarge
                }
                let crc = CRC32.checksum(entry.data)
                let size = UInt32(entry.data.count)
                let offset = UInt32(outputOffset)
                var header = Data()
                header.appendLE(UInt32(0x04034b50))
                header.appendLE(UInt16(20))
                header.appendLE(UInt16(0x0800))
                header.appendLE(UInt16(0))
                header.appendLE(dos.time)
                header.appendLE(dos.date)
                header.appendLE(crc)
                header.appendLE(size)
                header.appendLE(size)
                header.appendLE(UInt16(name.count))
                header.appendLE(UInt16(0))
                header.append(name)
                try writeChunk(header)
                try writeChunk(entry.data)
                centralRecords.append(CentralRecord(name: name, crc32: crc, size: size, offset: offset))
            }

            for entry in fileEntries {
                let attributes = try FileManager.default.attributesOfItem(atPath: entry.fileURL.path)
                guard let fileSizeNumber = attributes[.size] as? NSNumber else {
                    throw CocoaError(.fileReadUnknown)
                }
                let fileSize64 = fileSizeNumber.uint64Value
                guard fileSize64 <= UInt64(UInt32.max), outputOffset <= UInt64(UInt32.max) else {
                    throw DiagnosticBundleExportError.archiveTooLarge
                }
                let name = Data(entry.path.utf8)
                guard name.count <= Int(UInt16.max) else {
                    throw DiagnosticBundleExportError.archiveTooLarge
                }
                let crc = try CRC32.checksum(fileAt: entry.fileURL)
                let size = UInt32(fileSize64)
                let offset = UInt32(outputOffset)
                var header = Data()
                header.appendLE(UInt32(0x04034b50))
                header.appendLE(UInt16(20))
                header.appendLE(UInt16(0x0800))
                header.appendLE(UInt16(0))
                header.appendLE(dos.time)
                header.appendLE(dos.date)
                header.appendLE(crc)
                header.appendLE(size)
                header.appendLE(size)
                header.appendLE(UInt16(name.count))
                header.appendLE(UInt16(0))
                header.append(name)
                try writeChunk(header)

                let input = try FileHandle(forReadingFrom: entry.fileURL)
                do {
                    while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                        try writeChunk(chunk)
                    }
                    try input.close()
                } catch {
                    try? input.close()
                    throw error
                }
                centralRecords.append(CentralRecord(name: name, crc32: crc, size: size, offset: offset))
            }

            let centralOffset64 = outputOffset
            guard centralOffset64 <= UInt64(UInt32.max) else {
                throw DiagnosticBundleExportError.archiveTooLarge
            }
            for record in centralRecords {
                var centralHeader = Data()
                centralHeader.appendLE(UInt32(0x02014b50))
                centralHeader.appendLE(UInt16(20))
                centralHeader.appendLE(UInt16(20))
                centralHeader.appendLE(UInt16(0x0800))
                centralHeader.appendLE(UInt16(0))
                centralHeader.appendLE(dos.time)
                centralHeader.appendLE(dos.date)
                centralHeader.appendLE(record.crc32)
                centralHeader.appendLE(record.size)
                centralHeader.appendLE(record.size)
                centralHeader.appendLE(UInt16(record.name.count))
                centralHeader.appendLE(UInt16(0))
                centralHeader.appendLE(UInt16(0))
                centralHeader.appendLE(UInt16(0))
                centralHeader.appendLE(UInt16(0))
                centralHeader.appendLE(UInt32(0))
                centralHeader.appendLE(record.offset)
                centralHeader.append(record.name)
                try writeChunk(centralHeader)
            }
            let centralSize64 = outputOffset - centralOffset64
            guard centralSize64 <= UInt64(UInt32.max) else {
                throw DiagnosticBundleExportError.archiveTooLarge
            }
            var endRecord = Data()
            endRecord.appendLE(UInt32(0x06054b50))
            endRecord.appendLE(UInt16(0))
            endRecord.appendLE(UInt16(0))
            endRecord.appendLE(UInt16(centralRecords.count))
            endRecord.appendLE(UInt16(centralRecords.count))
            endRecord.appendLE(UInt32(centralSize64))
            endRecord.appendLE(UInt32(centralOffset64))
            endRecord.appendLE(UInt16(0))
            try writeChunk(endRecord)
            try handle.synchronize()
            try handle.close()
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: partialURL, to: url)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: partialURL)
            throw error
        }
    }

    private static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let components = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let year = max(1980, components.year ?? 1980)
        let month = components.month ?? 1
        let day = components.day ?? 1
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = components.second ?? 0
        let dosDate = UInt16((year - 1980) << 9 | month << 5 | day)
        let dosTime = UInt16(hour << 11 | minute << 5 | (second / 2))
        return (dosTime, dosDate)
    }
}

private enum CRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        crc = update(crc, with: data)
        return crc ^ 0xffffffff
    }

    static func checksum(fileAt url: URL) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: url)
        var crc: UInt32 = 0xffffffff
        do {
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                crc = update(crc, with: chunk)
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        return crc ^ 0xffffffff
    }

    private static func update(_ current: UInt32, with data: Data) -> UInt32 {
        var crc = current
        for byte in data {
            var value = (crc ^ UInt32(byte)) & 0xff
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0xedb88320 : value >> 1
            }
            crc = (crc >> 8) ^ value
        }
        return crc
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
