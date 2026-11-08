import CryptoKit
import Foundation
import UIKit

/// Builds a self-contained, uncompressed ZIP so TestFlight evidence can be
/// exported through the native share sheet without adding a third-party archive
/// dependency.  Every rendered image is tied to the same source SHA-256.
final class DiagnosticBundleExporter {
    func makeArchive(for photo: CapturedPhoto) throws -> URL {
        guard photo.isDiagnosticImport else {
            throw DiagnosticBundleExportError.notDiagnosticImport
        }

        let sourceHash = sha256(photo.originalImageData)
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

        add("images/A_original.jpg", photo.originalImageData, "A source original")
        add("images/B_formal_output.jpg", photo.editedImageData, "B formal algorithm output")

        let comparisonPrefixes = ["A ", "B ", "C ", "D ", "M 人工参数真实渲染"]
        for identifier in ["C", "D", "M"] {
            let candidate = photo.diagnosticCandidates.first { $0.identifier == identifier }
            let preview = Self.resolvedPreview(
                for: candidate,
                in: photo.processingStagePreviews
            )
            if let preview {
                add(
                    "images/\(identifier)_\(identifier == "D" ? "automatic_diagnostic" : identifier == "M" ? "manual_render" : "reference_candidate").jpg",
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

        let inventory = entries.map { entry -> [String: Any] in
            [
                "path": entry.path,
                "role": entry.role,
                "bytes": entry.data.count,
                "sha256": sha256(entry.data)
            ]
        }
        let metadata: [String: Any] = [
            "schemaVersion": 1,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "sourceSha256": sourceHash,
            "sameSourceRequirement": "A/B/D/M and probes were produced from the source identified above in one diagnostic import.",
            "app": [
                "name": Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "小苏相机",
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            ],
            "device": [
                "model": UIDevice.current.model,
                "name": UIDevice.current.name,
                "systemName": UIDevice.current.systemName,
                "systemVersion": UIDevice.current.systemVersion
            ],
            "candidateMeaning": [
                "A": "original source",
                "B": "formal algorithm result shown by the top B button",
                "C": "reference-calibrated diagnostic; unavailable when licensing/index gates fail",
                "D": "measured automatic aesthetic diagnostic; never replaces B",
                "M": "human-declared renderer verification; never replaces B or D",
                "difference": "A versus B, amplified five times"
            ],
            "files": inventory
        ]
        add("manifest.json", try jsonData(metadata), "bundle manifest")
        add(
            "README.txt",
            Data(readme(sourceHash: sourceHash).utf8),
            "human-readable evidence guide"
        )

        let stamp = Self.fileTimestamp.string(from: Date())
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("XiaoSuCamera_Diagnostic_\(stamp)_\(sourceHash.prefix(10)).zip")
        try? FileManager.default.removeItem(at: destination)
        try NativeZipArchiveWriter.write(entries: entries, to: destination)
        return destination
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
        }
        if let decision = photo.decision {
            object["formalBDecision"] = [
                "sceneStrategy": decision.sceneStrategy.rawValue,
                "adaptiveTarget": decision.adaptiveTarget.summaryText,
                "targetRationale": decision.adaptiveTarget.rationale,
                "aestheticPlan": decision.aestheticPlan?.traceSummary ?? "unavailable",
                "recipe": decision.recipe.traceSummary,
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
                    "changedPixelRatio": impact.changedPixelRatio
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
                    "selected": evaluation.selected
                ] as [String: Any]
            }
            object["fallbackReason"] = diagnostics.fallbackReason ?? "none"
        }
        object["diagnosticCandidateQuality"] = photo.diagnosticCandidates.map { candidate in
            [
                "identifier": candidate.identifier,
                "qualityStatus": candidate.qualityStatus ?? "notRun",
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

    private func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func readme(sourceHash: String) -> String {
        """
        小苏相机诊断证据包

        同源原图 SHA-256：\(sourceHash)
        A = 原图
        B = 顶部“B 正式成片”按钮显示的正式算法输出
        C = 摄影参考候选；许可或索引不可用时只有 UNAVAILABLE 记录
        D = 逐图自动后期诊断输出，不替换 B
        M = 人工声明参数的渲染表达能力验证，不替换 B/D
        差异图 = A 与 B 的五倍放大差异，不代表 D 或 M

        candidate_states_and_parameters.json 明确区分 planned、executed、rejected、fallback、unavailable。
        屏幕截图不是实际成片文件；images 目录中的 JPEG 才是本次处理实际输出。
        """
    }

    private func sanitized(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let transformed = name.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let value = String(transformed).replacingOccurrences(of: "__", with: "_")
        return String(value.prefix(96))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

private enum DiagnosticBundleExportError: LocalizedError {
    case notDiagnosticImport
    case archiveTooLarge

    var errorDescription: String? {
        switch self {
        case .notDiagnosticImport: return "只有诊断导入照片可以导出证据包。"
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

    static func write(entries: [DiagnosticExportEntry], to url: URL) throws {
        guard entries.count <= Int(UInt16.max) else {
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
        for byte in data {
            var value = (crc ^ UInt32(byte)) & 0xff
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0xedb88320 : value >> 1
            }
            crc = (crc >> 8) ^ value
        }
        return crc ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
