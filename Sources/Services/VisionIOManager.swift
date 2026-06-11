@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
@preconcurrency import Vision

enum LingShuVisionError: LocalizedError {
    case cameraUnavailable
    case cannotAddCameraInput
    case cannotAddVideoOutput

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            return "没有检测到可用摄像头。"
        case .cannotAddCameraInput:
            return "无法接入摄像头输入。"
        case .cannotAddVideoOutput:
            return "无法接入视频帧输出。"
        }
    }
}

struct LingShuVisionObservation: Equatable {
    let timestamp: Date
    let summary: String
    let faceCount: Int
    let recognizedText: String
    let brightness: Double
    let motion: Double
    let faceSignature: [Double]
    let frameWidth: Int
    let frameHeight: Int

    var promptContext: String {
        var parts = ["当前视觉观测：\(summary)"]
        if !recognizedText.isEmpty {
            parts.append("画面文字：\(recognizedText)")
        }
        parts.append("请结合这段视觉信息继续判断或回答。")
        return parts.joined(separator: "\n")
    }
}

@MainActor
final class VisionIOManager: ObservableObject {
    @Published var isCameraRunning = false
    @Published var statusMessage = "视觉待机"
    @Published var latestObservation: LingShuVisionObservation?
    @Published var latestFramePacket: LingShuVideoFramePacket?
    @Published var observationHistory: [LingShuVisionObservation] = []

    let captureSession = AVCaptureSession()

    private let frameAnalyzer = VisionFrameAnalyzer()
    private let frameQueue = DispatchQueue(label: "lingshu.vision.frames", qos: .userInitiated)
    private var videoOutput: AVCaptureVideoDataOutput?
    private var isConfigured = false

    init() {
        frameAnalyzer.onObservation = { [weak self] observation in
            self?.accept(observation)
        }
        frameAnalyzer.onFramePacket = { [weak self] packet in
            self?.latestFramePacket = packet
        }
    }

    func requestAuthorization(_ completion: @escaping @MainActor (Bool) -> Void) {
        statusMessage = "正在请求摄像头权限"

        let cameraAuthorizationHandler: @Sendable (Bool) -> Void = { [weak self] allowed in
            Task { @MainActor in
                guard let self else { return }
                self.statusMessage = allowed ? "视觉权限已就绪" : "视觉权限未授权"
                completion(allowed)
            }
        }

        AVCaptureDevice.requestAccess(for: .video, completionHandler: cameraAuthorizationHandler)
    }

    func startCamera() throws {
        if !isConfigured {
            try configureSession()
        }

        if !captureSession.isRunning {
            captureSession.startRunning()
        }

        isCameraRunning = true
        statusMessage = "视觉在线"
    }

    func stopCamera() {
        if captureSession.isRunning {
            captureSession.stopRunning()
        }

        isCameraRunning = false
        statusMessage = "视觉待机"
    }

    private func configureSession() throws {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video) else {
            throw LingShuVisionError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: camera)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(frameAnalyzer, queue: frameQueue)

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .medium

        guard captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            throw LingShuVisionError.cannotAddCameraInput
        }
        captureSession.addInput(input)

        guard captureSession.canAddOutput(output) else {
            captureSession.commitConfiguration()
            throw LingShuVisionError.cannotAddVideoOutput
        }
        captureSession.addOutput(output)

        captureSession.commitConfiguration()
        videoOutput = output
        isConfigured = true
    }

    private func accept(_ observation: LingShuVisionObservation) {
        latestObservation = observation
        observationHistory.append(observation)

        if observationHistory.count > 24 {
            observationHistory.removeFirst(observationHistory.count - 24)
        }

        statusMessage = observation.summary
    }
}

final class VisionFrameAnalyzer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onObservation: (@MainActor (LingShuVisionObservation) -> Void)?
    var onFramePacket: (@MainActor (LingShuVideoFramePacket) -> Void)?

    private struct FaceAnalysis {
        let count: Int
        let signature: [Double]
    }

    private var previousBrightness: Double?
    private var lastFrameAt = Date.distantPast
    private static let ciContext = CIContext()
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastFrameAt) >= 1.0 else { return }
        lastFrameAt = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let brightness = Self.averageBrightness(pixelBuffer)
        let motion = previousBrightness.map { abs(brightness - $0) } ?? 0
        previousBrightness = brightness

        let faceAnalysis = Self.analyzeFaces(in: pixelBuffer)
        let recognizedText = Self.recognizeText(in: pixelBuffer)
        let framePacket = Self.makeJPEGFramePacket(
            from: pixelBuffer,
            timestamp: now,
            width: width,
            height: height
        )
        let summary = Self.makeSummary(
            faceCount: faceAnalysis.count,
            recognizedText: recognizedText,
            brightness: brightness,
            motion: motion
        )

        let observation = LingShuVisionObservation(
            timestamp: now,
            summary: summary,
            faceCount: faceAnalysis.count,
            recognizedText: recognizedText,
            brightness: brightness,
            motion: motion,
            faceSignature: faceAnalysis.signature,
            frameWidth: width,
            frameHeight: height
        )

        Task { @MainActor [onObservation, onFramePacket] in
            onObservation?(observation)
            if let framePacket {
                onFramePacket?(framePacket)
            }
        }
    }

    private static func averageBrightness(_ pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
        let sampleStep = max(1, min(width, height) / 36)

        var total = 0.0
        var sampleCount = 0

        for y in stride(from: 0, to: height, by: sampleStep) {
            let row = buffer + y * bytesPerRow

            for x in stride(from: 0, to: width, by: sampleStep) {
                let pixel = row + x * 4
                let blue = Double(pixel[0])
                let green = Double(pixel[1])
                let red = Double(pixel[2])
                total += (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255.0
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else { return 0 }
        return total / Double(sampleCount)
    }

    private static func analyzeFaces(in pixelBuffer: CVPixelBuffer) -> FaceAnalysis {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([request])
        let results = request.results ?? []

        guard results.count == 1,
              let face = results.first,
              let landmarks = face.landmarks else {
            return .init(count: results.count, signature: [])
        }

        return .init(
            count: results.count,
            signature: makeFaceSignature(face: face, landmarks: landmarks)
        )
    }

    private static func makeFaceSignature(face: VNFaceObservation, landmarks: VNFaceLandmarks2D) -> [Double] {
        var features = [
            face.boundingBox.width,
            face.boundingBox.height,
            face.boundingBox.midX,
            face.boundingBox.midY
        ].map(Double.init)

        let regions = [
            landmarks.faceContour,
            landmarks.leftEye,
            landmarks.rightEye,
            landmarks.nose,
            landmarks.noseCrest,
            landmarks.outerLips,
            landmarks.innerLips,
            landmarks.leftEyebrow,
            landmarks.rightEyebrow
        ]

        for region in regions.compactMap({ $0 }) {
            features += sampledLandmarkPoints(region)
        }

        return features
    }

    private static func sampledLandmarkPoints(_ region: VNFaceLandmarkRegion2D) -> [Double] {
        let points = region.normalizedPoints
        guard !points.isEmpty else { return [0, 0, 0, 0, 0, 0] }

        let indexes = [
            0,
            points.count / 2,
            max(points.count - 1, 0)
        ]

        return indexes.flatMap { index in
            [
                Double(points[min(index, points.count - 1)].x),
                Double(points[min(index, points.count - 1)].y)
            ]
        }
    }

    private static func recognizeText(in pixelBuffer: CVPixelBuffer) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.minimumTextHeight = 0.035

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([request])

        let fragments = (request.results ?? [])
            .prefix(4)
            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return fragments.joined(separator: " / ")
    }

    private static func makeJPEGFramePacket(
        from pixelBuffer: CVPixelBuffer,
        timestamp: Date,
        width: Int,
        height: Int
    ) -> LingShuVideoFramePacket? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.42
        ]

        guard let jpegData = ciContext.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: options
        ) else {
            return nil
        }

        return LingShuVideoFramePacket(
            timestamp: timestamp,
            jpegData: jpegData,
            width: width,
            height: height
        )
    }

    private static func makeSummary(
        faceCount: Int,
        recognizedText: String,
        brightness: Double,
        motion: Double
    ) -> String {
        let brightnessLabel: String
        if brightness < 0.24 {
            brightnessLabel = "画面偏暗"
        } else if brightness > 0.74 {
            brightnessLabel = "画面偏亮"
        } else {
            brightnessLabel = "光线正常"
        }

        let motionLabel: String
        if motion > 0.20 {
            motionLabel = "画面变化明显"
        } else if motion > 0.08 {
            motionLabel = "画面有轻微变化"
        } else {
            motionLabel = "画面稳定"
        }

        var parts = ["\(brightnessLabel)，\(motionLabel)"]

        if faceCount > 0 {
            parts.append("检测到 \(faceCount) 张人脸")
        } else {
            parts.append("未检测到人脸")
        }

        if !recognizedText.isEmpty {
            parts.append("识别到文字")
        }

        return parts.joined(separator: "，")
    }
}
