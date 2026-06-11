@preconcurrency import AVFoundation
import AppKit
import SwiftUI

struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewNSView {
        CameraPreviewNSView(session: session)
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.updateSession(session)
    }
}

final class CameraPreviewNSView: NSView {
    private var previewLayer: AVCaptureVideoPreviewLayer?

    init(session: AVCaptureSession) {
        super.init(frame: .zero)
        wantsLayer = true
        updateSession(session)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }

    func updateSession(_ session: AVCaptureSession) {
        if let previewLayer {
            previewLayer.session = session
        } else {
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            self.layer = layer
            previewLayer = layer
        }

        previewLayer?.frame = bounds
    }
}
