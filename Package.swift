// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MasterCameraDecisionCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "MasterCameraDecisionCore", targets: ["MasterCameraDecisionCore"])
    ],
    targets: [
        .target(
            name: "MasterCameraDecisionCore",
            path: "MasterCamera",
            exclude: [
                "App",
                "Assets.xcassets",
                "Camera",
                "Configuration",
                "MLModels",
                "Models",
                "Processing",
                "QualityControl",
                "Storage",
                "Utilities",
                "ViewModels",
                "Views",
                "Analysis/PhotoAnalyzer.swift",
                "Analysis/SkySegmentationService.swift",
                "ImageEngine/CinematicImagingEngines.swift",
                "ImageEngine/CoreImageRenderer.swift",
                "ImageEngine/LocalAdjustmentProcessor.swift",
                "ImageEngine/SkinTextureProtectionProcessor.swift",
                "ImageEngine/SkyAdjustmentProcessor.swift"
            ],
            sources: [
                "Analysis/PhotoAnalysis.swift",
                "Analysis/PhotoProblemDetector.swift",
                "ImageEngine/AutomaticEditingRecipe.swift",
                "PhotographerAI/PhotographyDecision.swift",
                "PhotographerAI/PhotographyDecisionEngine.swift",
                "PhotographerAI/SceneStrategy.swift"
            ]
        ),
        .testTarget(
            name: "MasterCameraDecisionCoreTests",
            dependencies: ["MasterCameraDecisionCore"],
            path: "MasterCameraDecisionCoreTests"
        )
    ]
)
