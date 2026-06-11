import Foundation

enum LingShuOwnerEnrollmentState: String, Codable, Equatable, Sendable {
    case notEnrolled
    case enrolling
    case enrolled
}

struct LingShuBiometricTemplate: Codable, Equatable, Sendable {
    var vector: [Double]
    var source: String
    var capturedAt: Date
}

struct LingShuOwnerIdentityProfile: Codable, Equatable, Sendable {
    var ownerName: String
    var createdAt: Date
    var updatedAt: Date
    var faceTemplates: [LingShuBiometricTemplate]
    var voiceTemplates: [LingShuBiometricTemplate]
    var faceThreshold: Double
    var voiceThreshold: Double
    var combinedThreshold: Double
    var lockEnabled: Bool
}

struct LingShuOwnerIdentitySnapshot: Codable, Equatable, Sendable {
    var ownerName: String
    var enrollmentState: LingShuOwnerEnrollmentState
    var lockEnabled: Bool
    var faceSampleCount: Int
    var voiceSampleCount: Int
    var faceConfidence: Double?
    var voiceConfidence: Double?
    var combinedConfidence: Double?
    var isLocked: Bool
    var statusText: String
    var detailText: String
    var updatedAt: Date

    static let empty = LingShuOwnerIdentitySnapshot(
        ownerName: "主人",
        enrollmentState: .notEnrolled,
        lockEnabled: false,
        faceSampleCount: 0,
        voiceSampleCount: 0,
        faceConfidence: nil,
        voiceConfidence: nil,
        combinedConfidence: nil,
        isLocked: false,
        statusText: "未认主",
        detailText: "开启认主后，我会采集面容和声线样本作为身份锁。",
        updatedAt: Date(timeIntervalSince1970: 0)
    )

    var shortStatus: String {
        if isLocked { return "已锁定" }
        if lockEnabled {
            return enrollmentState == .enrolled ? "待确认" : "未认主"
        }
        return "未启用"
    }

    var promptContext: String {
        guard lockEnabled else {
            return "身份锁未启用。"
        }

        return [
            "身份锁：\(statusText)",
            "主人：\(ownerName)",
            "面容置信度：\(faceConfidence.map(Self.percent) ?? "--")",
            "声线置信度：\(voiceConfidence.map(Self.percent) ?? "--")",
            "综合置信度：\(combinedConfidence.map(Self.percent) ?? "--")"
        ].joined(separator: "\n")
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", min(max(value, 0), 1) * 100)
    }
}

final class LingShuOwnerIdentityService {
    private let storageDirectory: URL
    private let profileFileName: String
    private let requiredFaceSamples = 3
    private let requiredVoiceSamples = 3

    private var profile: LingShuOwnerIdentityProfile?
    private var draftOwnerName = "主人"
    private var draftFaceTemplates: [LingShuBiometricTemplate] = []
    private var draftVoiceTemplates: [LingShuBiometricTemplate] = []
    private var enrollmentState: LingShuOwnerEnrollmentState = .notEnrolled
    private var latestVisionObservation: LingShuVisionObservation?
    private var latestFaceConfidence: Double?
    private var latestVoiceConfidence: Double?
    private var latestCombinedConfidence: Double?

    init(
        storageDirectory: URL = LingShuOwnerIdentityService.defaultStorageDirectory(),
        profileFileName: String = "owner-profile.json"
    ) {
        self.storageDirectory = storageDirectory
        self.profileFileName = profileFileName
        loadProfile()
    }

    var profileFileURL: URL {
        storageDirectory.appendingPathComponent(profileFileName)
    }

    var currentSnapshot: LingShuOwnerIdentitySnapshot {
        makeSnapshot(now: Date())
    }

    static func defaultStorageDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LingShu/Identity", isDirectory: true)
    }

    func setLockEnabled(_ enabled: Bool) -> LingShuOwnerIdentitySnapshot {
        if profile == nil {
            enrollmentState = .notEnrolled
            return makeSnapshot(now: Date())
        }

        profile?.lockEnabled = enabled
        profile?.updatedAt = Date()
        saveProfile()
        return makeSnapshot(now: Date())
    }

    func beginEnrollment(ownerName: String, now: Date = Date()) -> LingShuOwnerIdentitySnapshot {
        let cleaned = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        draftOwnerName = cleaned.isEmpty ? "主人" : cleaned
        draftFaceTemplates = []
        draftVoiceTemplates = []
        latestFaceConfidence = nil
        latestVoiceConfidence = nil
        latestCombinedConfidence = nil
        enrollmentState = .enrolling

        return makeSnapshot(now: now)
    }

    func reset(now: Date = Date()) -> LingShuOwnerIdentitySnapshot {
        profile = nil
        draftOwnerName = "主人"
        draftFaceTemplates = []
        draftVoiceTemplates = []
        latestFaceConfidence = nil
        latestVoiceConfidence = nil
        latestCombinedConfidence = nil
        enrollmentState = .notEnrolled
        try? FileManager.default.removeItem(at: profileFileURL)
        return makeSnapshot(now: now)
    }

    @discardableResult
    func ingestVisionObservation(_ observation: LingShuVisionObservation, now: Date = Date()) -> LingShuOwnerIdentitySnapshot {
        latestVisionObservation = observation
        return verifyOrCollect(faceVector: makeFaceVector(observation: observation, framePacket: nil), voiceVector: nil, now: now)
    }

    @discardableResult
    func ingestVideoFrame(_ packet: LingShuVideoFramePacket, now: Date = Date()) -> LingShuOwnerIdentitySnapshot {
        guard let observation = latestVisionObservation else {
            return makeSnapshot(now: now)
        }

        return verifyOrCollect(faceVector: makeFaceVector(observation: observation, framePacket: packet), voiceVector: nil, now: now)
    }

    @discardableResult
    func ingestAudioPacket(_ packet: LingShuAudioStreamPacket, now: Date = Date()) -> LingShuOwnerIdentitySnapshot {
        verifyOrCollect(faceVector: nil, voiceVector: makeVoiceVector(packet), now: now)
    }

    private func verifyOrCollect(faceVector: [Double]?, voiceVector: [Double]?, now: Date) -> LingShuOwnerIdentitySnapshot {
        if enrollmentState == .enrolling {
            collectEnrollmentSamples(faceVector: faceVector, voiceVector: voiceVector, now: now)
        } else {
            verify(faceVector: faceVector, voiceVector: voiceVector)
        }

        return makeSnapshot(now: now)
    }

    private func collectEnrollmentSamples(faceVector: [Double]?, voiceVector: [Double]?, now: Date) {
        if let faceVector,
           draftFaceTemplates.count < requiredFaceSamples {
            draftFaceTemplates.append(.init(vector: faceVector, source: "mac.camera.local-face", capturedAt: now))
        }

        if let voiceVector,
           draftVoiceTemplates.count < requiredVoiceSamples {
            draftVoiceTemplates.append(.init(vector: voiceVector, source: "mac.microphone.voiceprint", capturedAt: now))
        }

        if draftFaceTemplates.count >= requiredFaceSamples,
           draftVoiceTemplates.count >= requiredVoiceSamples {
            let createdAt = profile?.createdAt ?? now
            profile = LingShuOwnerIdentityProfile(
                ownerName: draftOwnerName,
                createdAt: createdAt,
                updatedAt: now,
                faceTemplates: Array(draftFaceTemplates.prefix(requiredFaceSamples)),
                voiceTemplates: Array(draftVoiceTemplates.prefix(requiredVoiceSamples)),
                faceThreshold: 0.76,
                voiceThreshold: 0.78,
                combinedThreshold: 0.78,
                lockEnabled: true
            )
            enrollmentState = .enrolled
            saveProfile()
            verify(faceVector: faceVector, voiceVector: voiceVector)
        }
    }

    private func verify(faceVector: [Double]?, voiceVector: [Double]?) {
        guard let profile else {
            latestFaceConfidence = nil
            latestVoiceConfidence = nil
            latestCombinedConfidence = nil
            enrollmentState = .notEnrolled
            return
        }

        enrollmentState = .enrolled
        if let faceVector {
            latestFaceConfidence = bestSimilarity(faceVector, profile.faceTemplates.map(\.vector))
        }
        if let voiceVector {
            latestVoiceConfidence = bestSimilarity(voiceVector, profile.voiceTemplates.map(\.vector))
        }

        if let face = latestFaceConfidence, let voice = latestVoiceConfidence {
            latestCombinedConfidence = face * 0.52 + voice * 0.48
        }
    }

    private func makeSnapshot(now: Date) -> LingShuOwnerIdentitySnapshot {
        let ownerName = profile?.ownerName ?? draftOwnerName
        let faceCount = profile?.faceTemplates.count ?? draftFaceTemplates.count
        let voiceCount = profile?.voiceTemplates.count ?? draftVoiceTemplates.count
        let lockEnabled = profile?.lockEnabled ?? false
        let isLocked = lockEnabled
            && enrollmentState == .enrolled
            && (latestFaceConfidence ?? 0) >= (profile?.faceThreshold ?? 1)
            && (latestVoiceConfidence ?? 0) >= (profile?.voiceThreshold ?? 1)
            && (latestCombinedConfidence ?? 0) >= (profile?.combinedThreshold ?? 1)

        let statusText: String
        let detailText: String
        switch enrollmentState {
        case .notEnrolled:
            statusText = "未认主"
            detailText = "开启认主后，需要同时采集面容和声线样本。"
        case .enrolling:
            statusText = "认主中"
            detailText = "面容 \(faceCount)/\(requiredFaceSamples)，声线 \(voiceCount)/\(requiredVoiceSamples)。请面向摄像头并连续说几句话。"
        case .enrolled where isLocked:
            statusText = "身份已锁定"
            detailText = "\(ownerName) 已通过面容和声线联合确认。"
        case .enrolled where lockEnabled:
            statusText = "身份待确认"
            detailText = "身份锁已开启，等待面容和声线同时命中。"
        case .enrolled:
            statusText = "认主完成"
            detailText = "身份样本已保存，开启身份锁后会用于唤醒校验。"
        }

        return LingShuOwnerIdentitySnapshot(
            ownerName: ownerName,
            enrollmentState: enrollmentState,
            lockEnabled: lockEnabled,
            faceSampleCount: faceCount,
            voiceSampleCount: voiceCount,
            faceConfidence: latestFaceConfidence,
            voiceConfidence: latestVoiceConfidence,
            combinedConfidence: latestCombinedConfidence,
            isLocked: isLocked,
            statusText: statusText,
            detailText: detailText,
            updatedAt: now
        )
    }

    private func makeFaceVector(observation: LingShuVisionObservation, framePacket: LingShuVideoFramePacket?) -> [Double]? {
        guard observation.faceCount == 1 else { return nil }
        var features = observation.faceSignature.isEmpty ? [1] : observation.faceSignature
        features += [
            min(max(observation.brightness, 0), 1),
            min(max(observation.motion, 0), 1),
            Double(observation.frameWidth) / max(Double(observation.frameHeight), 1),
            Double(observation.recognizedText.count % 31) / 31.0
        ]

        if let framePacket {
            features += byteDistributionFeatures(framePacket.jpegData)
        } else {
            features += [0, 0, 0, 0]
        }

        return normalized(features)
    }

    private func makeVoiceVector(_ packet: LingShuAudioStreamPacket) -> [Double]? {
        let samples = int16Samples(from: packet.pcm16Data, maxCount: 4096)
        guard samples.count >= 128 else { return nil }

        let values = samples.map { Double($0) / 32768.0 }
        let absValues = values.map(abs)
        let rms = sqrt(values.reduce(0) { $0 + $1 * $1 } / Double(values.count))
        let meanAbs = absValues.reduce(0, +) / Double(absValues.count)
        let peak = absValues.max() ?? 0
        let positiveRatio = Double(values.filter { $0 >= 0 }.count) / Double(values.count)
        let zeroCrossing = zeroCrossingRate(values)
        let diffMean = adjacentDifferenceMean(values)
        let silenceRatio = Double(absValues.filter { $0 < 0.012 }.count) / Double(absValues.count)

        return normalized([
            rms,
            meanAbs,
            peak,
            positiveRatio,
            zeroCrossing,
            diffMean,
            silenceRatio,
            min(Double(packet.sampleRate) / 48_000.0, 1),
            min(Double(packet.channelCount) / 4.0, 1)
        ])
    }

    private func byteDistributionFeatures(_ data: Data) -> [Double] {
        guard !data.isEmpty else { return [0, 0, 0, 0] }
        let strideSize = max(1, data.count / 512)
        let bytes = data.enumerated().compactMap { index, byte -> Double? in
            index.isMultiple(of: strideSize) ? Double(byte) / 255.0 : nil
        }
        let mean = bytes.reduce(0, +) / Double(bytes.count)
        let variance = bytes.reduce(0) { $0 + pow($1 - mean, 2) } / Double(bytes.count)
        let highRatio = Double(bytes.filter { $0 > 0.66 }.count) / Double(bytes.count)
        let lowRatio = Double(bytes.filter { $0 < 0.33 }.count) / Double(bytes.count)
        return [mean, sqrt(variance), highRatio, lowRatio]
    }

    private func int16Samples(from data: Data, maxCount: Int) -> [Int16] {
        var samples: [Int16] = []
        samples.reserveCapacity(min(maxCount, data.count / 2))
        var index = 0
        while index + 1 < data.count, samples.count < maxCount {
            let low = UInt16(data[index])
            let high = UInt16(data[index + 1]) << 8
            samples.append(Int16(bitPattern: high | low))
            index += 2
        }
        return samples
    }

    private func zeroCrossingRate(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        var crossings = 0
        for index in 1..<values.count where (values[index - 1] >= 0) != (values[index] >= 0) {
            crossings += 1
        }
        return Double(crossings) / Double(values.count - 1)
    }

    private func adjacentDifferenceMean(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        var total = 0.0
        for index in 1..<values.count {
            total += abs(values[index] - values[index - 1])
        }
        return total / Double(values.count - 1)
    }

    private func bestSimilarity(_ vector: [Double], _ templates: [[Double]]) -> Double {
        templates.map { cosineSimilarity(vector, $0) }.max() ?? 0
    }

    private func cosineSimilarity(_ left: [Double], _ right: [Double]) -> Double {
        let count = min(left.count, right.count)
        guard count > 0 else { return 0 }

        var dot = 0.0
        var leftNorm = 0.0
        var rightNorm = 0.0
        for index in 0..<count {
            dot += left[index] * right[index]
            leftNorm += left[index] * left[index]
            rightNorm += right[index] * right[index]
        }

        guard leftNorm > 0, rightNorm > 0 else { return 0 }
        return min(max(dot / (sqrt(leftNorm) * sqrt(rightNorm)), 0), 1)
    }

    private func normalized(_ values: [Double]) -> [Double] {
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return values }
        return values.map { $0 / norm }
    }

    private func loadProfile() {
        guard let data = try? Data(contentsOf: profileFileURL),
              let decoded = try? JSONDecoder().decode(LingShuOwnerIdentityProfile.self, from: data) else {
            profile = nil
            enrollmentState = .notEnrolled
            return
        }

        profile = decoded
        enrollmentState = .enrolled
    }

    private func saveProfile() {
        guard let profile else { return }
        do {
            try FileManager.default.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(profile)
            try data.write(to: profileFileURL, options: [.atomic])
        } catch {
            assertionFailure("Failed to save owner identity profile: \(error.localizedDescription)")
        }
    }
}
