import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onTapToFocus: (CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill

        let tapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        view.addGestureRecognizer(tapGesture)

        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTapToFocus: onTapToFocus)
    }

    final class Coordinator: NSObject {
        private let onTapToFocus: (CGPoint) -> Void

        init(onTapToFocus: @escaping (CGPoint) -> Void) {
            self.onTapToFocus = onTapToFocus
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let previewView = gesture.view as? PreviewView else { return }
            let point = gesture.location(in: previewView)
            let devicePoint = previewView.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: point)
            onTapToFocus(devicePoint)
        }
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

