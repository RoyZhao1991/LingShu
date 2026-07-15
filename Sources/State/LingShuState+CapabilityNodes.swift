import Foundation

@MainActor
extension LingShuState {
    /// Unified capability-node view. This is the thin-kernel boundary: concrete abilities are
    /// represented as schedulable nodes before the planner/task system treats them as available.
    func capabilityNodes() -> [LingShuCapabilityNode] {
        let runtime = enumerateCapabilities().map {
            LingShuCapabilityNodeRegistry.node(from: $0, status: .verified)
        }
        let acquired = acquiredCapabilities().map {
            LingShuCapabilityNodeRegistry.node(from: $0)
        }
        let probed = taskExecutionRecords
            .flatMap { $0.capabilityProbeObservations ?? [] }
            .filter { LingShuCapabilityVerb.parse($0.verb) != .humanConfirm }
            .filter { !Self.referencesKnownNoCredentialBuiltInCapability("\($0.capabilityID) \($0.description)") }
            .map { LingShuCapabilityNodeRegistry.node(from: $0) }

        return LingShuCapabilityNodeRegistry.merge([
            Self.builtinCapabilityNodes(),
            runtime,
            acquired,
            probed,
            modelCapabilityNodes(),
            perceptionCapabilityNodes(),
            externalAgentCapabilityNodes()
        ])
    }

    func capabilityLifecycleReport() -> LingShuCapabilityLifecycleReport {
        let nodes = capabilityNodes()
        let events = nodes.map { node in
            LingShuCapabilityLifecycleEvent(
                nodeID: node.id,
                from: nil,
                to: node.status,
                reason: node.isSchedulable ? "已通过最小验证或内核固化,可调度。" : "已发现但尚未完成授权/驱动/最小验证。",
                evidence: node.lastVerifiedAt.map { ["lastVerifiedAt:\($0.timeIntervalSince1970)"] } ?? []
            )
        }
        return .init(nodes: nodes, events: events)
    }

    func capabilityNodeSnapshot(limit: Int = 32) -> String {
        let nodes = capabilityNodes()
        guard !nodes.isEmpty else { return "能力节点:暂无注册节点。" }
        let ready = nodes.filter(\.isSchedulable)
        let blocked = nodes.filter { !$0.isSchedulable }
        var lines = ["能力节点:\(nodes.count) 个,可调度 \(ready.count),待补齐 \(blocked.count)。"]
        let grouped = Dictionary(grouping: nodes.prefix(limit), by: \.kind)
        for kind in LingShuCapabilityNodeKind.allCases {
            guard let items = grouped[kind], !items.isEmpty else { continue }
            lines.append("【\(kind.rawValue)】")
            for node in items {
                let mark = node.isSchedulable ? "可调度" : node.status.rawValue
                lines.append("- \(node.name) [\(mark), risk=\(node.risk.rawValue), permission=\(node.permissionSummary)]")
            }
        }
        if nodes.count > limit { lines.append("…其余 \(nodes.count - limit) 个节点按需展开。") }
        return lines.joined(separator: "\n")
    }

    func recordCapabilityNodesInWorldModel() {
        for node in capabilityNodes() {
            recordWorldEntity(.init(
                id: "capability:\(node.id)",
                kind: node.kind == .device ? .device : .service,
                name: node.name,
                attributes: [
                    "kind": node.kind.rawValue,
                    "status": node.status.rawValue,
                    "risk": node.risk.rawValue,
                    "source": node.source,
                    "schedulable": node.isSchedulable ? "true" : "false"
                ],
                confidence: node.isSchedulable ? 0.95 : 0.7
            ))
        }
    }

    func capabilityEntriesFromNodes() -> [LingShuCapabilityEntry] {
        capabilityNodes().compactMap { LingShuCapabilityNodeRegistry.graphEntry(from: $0) }
    }

    nonisolated static func builtinCapabilityNodes() -> [LingShuCapabilityNode] {
        [
            .init(
                id: "kernel:local_file.scan",
                name: "本机文件扫描",
                kind: .kernel,
                verb: .localFileScan,
                inputTypes: [.text],
                outputTypes: [.text, .json],
                requiredPermissions: [.readLocalFiles],
                source: "builtin",
                status: .verified,
                verificationProbe: .init(kind: .fileRoundTrip, summary: "读取一个已知本机文件"),
                lastVerifiedAt: Date(timeIntervalSince1970: 0),
                description: "内核原语:本机文件读取/搜索/扫描"
            ),
            .init(
                id: "kernel:document.generate",
                name: "本地文档生成",
                kind: .document,
                verb: .documentGenerate,
                inputTypes: [.text, .markdown, .json],
                outputTypes: [.markdown, .pdf, .presentation, .document, .spreadsheet],
                requiredPermissions: [.writeLocalFiles],
                source: "builtin",
                status: .verified,
                verificationProbe: .init(kind: .fileRoundTrip, summary: "生成文件并确认可读"),
                lastVerifiedAt: Date(timeIntervalSince1970: 0),
                description: "内核原语:本地生成文档、代码、报告、演示材料"
            ),
            .init(
                id: "kernel:compute",
                name: "本地计算",
                kind: .kernel,
                verb: .compute,
                inputTypes: [.text, .json],
                outputTypes: [.text, .json],
                requiredPermissions: [],
                source: "builtin",
                status: .verified,
                verificationProbe: .init(kind: .commandExitZero, summary: "执行安全纯计算样例"),
                lastVerifiedAt: Date(timeIntervalSince1970: 0),
                description: "内核原语:本地计算与数据处理"
            ),
            .init(
                id: "kernel:browser.operate",
                name: "内置浏览器自动化",
                kind: .browser,
                verb: .browserOperate,
                inputTypes: [.text, .ui],
                outputTypes: [.text, .image, .json],
                requiredPermissions: [.network],
                risk: .medium,
                source: "builtin",
                status: .verified,
                verificationProbe: .init(kind: .browserDOM, summary: "打开页面并读取 DOM"),
                lastVerifiedAt: Date(timeIntervalSince1970: 0),
                description: "内核四肢:浏览器自动化、网页读取与交互"
            ),
            .init(
                id: "kernel:device.discover",
                name: "设备发现",
                kind: .device,
                verb: .deviceDiscover,
                inputTypes: [.task],
                outputTypes: [.deviceSignal, .json],
                requiredPermissions: [.network],
                risk: .medium,
                source: "builtin",
                status: .verified,
                verificationProbe: .init(kind: .deviceReadback, summary: "枚举本机/局域网低风险设备信号"),
                lastVerifiedAt: Date(timeIntervalSince1970: 0),
                description: "内核四肢:发现本机硬件、外设与传感器"
            ),
            .init(
                id: "kernel:memory.recall",
                name: "长期记忆与本地知识召回",
                kind: .memory,
                verb: nil,
                inputTypes: [.text],
                outputTypes: [.text],
                requiredPermissions: [.readLocalFiles],
                source: "builtin",
                status: .verified,
                verificationProbe: .init(kind: .toolCall, summary: "召回一条本地记忆或空结果"),
                lastVerifiedAt: Date(timeIntervalSince1970: 0),
                description: "内核记忆:长期记忆、本地文件知识、冷备检索"
            ),
            .init(
                id: "kernel:scheduler",
                name: "定时与后台守候",
                kind: .scheduler,
                verb: .compute,
                inputTypes: [.task],
                outputTypes: [.task],
                requiredPermissions: [],
                source: "builtin",
                status: .verified,
                verificationProbe: .init(kind: .toolCall, summary: "创建并列出一个安全调度项"),
                lastVerifiedAt: Date(timeIntervalSince1970: 0),
                description: "内核编排:定时任务、后台条件守候、任务续跑"
            ),
            .init(
                id: "kernel:computer.control",
                name: "电脑直接操作",
                kind: .computerControl,
                verb: .browserOperate,
                inputTypes: [.ui, .task],
                outputTypes: [.ui, .image],
                requiredPermissions: [.screenCapture, .computerControl],
                risk: .high,
                source: "builtin",
                status: .needsAuth,
                verificationProbe: .init(kind: .toolCall, summary: "按应用读取 AX 快照并通过元素索引操作;高风险动作需授权"),
                description: "授权后可按应用观察原生 UI、用元素索引点击/输入/滚动，并在动作后回读验证；坐标操作仅作兜底"
            )
        ]
    }

    private func modelCapabilityNodes() -> [LingShuCapabilityNode] {
        let connected = isModelConnected
        return [.init(
            id: "model:primary",
            name: "\(modelProvider) / \(modelName)",
            kind: .model,
            verb: .compute,
            inputTypes: [.text, .image, .task],
            outputTypes: [.text, .json],
            requiredPermissions: endpoint.isEmpty ? [] : [.network],
            risk: .medium,
            source: "model-gateway",
            adapterID: selectedModelPreset?.id,
            status: connected ? .verified : .needsAuth,
            verificationProbe: .init(kind: .apiHealth, summary: "发送一次健康探针并收到合法响应"),
            lastVerifiedAt: connected ? mainRemoteLastSuccessAt : nil,
            description: "主脑模型通道,用于目标理解、规划、审议与回复",
            tags: [selectedModelPreset?.id ?? modelProvider]
        )]
    }

    private func perceptionCapabilityNodes() -> [LingShuCapabilityNode] {
        let ttsPermissions: [LingShuCapabilityPermission] = ttsLocalModeEnabled ? [.speaker] : [.speaker, .network]
        return [
            .init(
                id: "perception:asr",
                name: asrLocalModeEnabled ? "本地听觉 ASR" : "云端/混合听觉 ASR",
                kind: .voiceInput,
                verb: .compute,
                inputTypes: [.audio],
                outputTypes: [.text],
                requiredPermissions: [.microphone],
                risk: .medium,
                source: asrLocalModeEnabled ? "local" : "model-gateway",
                status: .verified,
                verificationProbe: .init(kind: .audioTranscription, summary: "识别一段短音频样例"),
                lastVerifiedAt: Date(timeIntervalSince1970: 0),
                description: "语音输入转文本,作为对话插件复用文本主逻辑"
            ),
            .init(
                id: "perception:tts",
                name: ttsLocalModeEnabled ? "本机语音输出" : "云端情绪语音输出",
                kind: .voiceOutput,
                verb: .compute,
                inputTypes: [.text],
                outputTypes: [.audio],
                requiredPermissions: ttsPermissions,
                risk: .low,
                source: ttsLocalModeEnabled ? "local" : "model-gateway",
                status: .verified,
                verificationProbe: .init(kind: .audioPlayback, summary: "播放一段短句并确认音频管线可用"),
                lastVerifiedAt: Date(timeIntervalSince1970: 0),
                description: "语音输出/朗读/流式播放"
            ),
            .init(
                id: "perception:vision",
                name: "视觉解析",
                kind: .vision,
                verb: .compute,
                inputTypes: [.image, .video],
                outputTypes: [.text, .json],
                requiredPermissions: [.camera, .network],
                risk: .medium,
                source: "perception-gateway",
                status: .discovered,
                verificationProbe: .init(kind: .imageUnderstanding, summary: "解析测试图像并返回结构化描述"),
                description: "摄像头/截图/图片视频解析能力"
            )
        ]
    }

    private func externalAgentCapabilityNodes() -> [LingShuCapabilityNode] {
        let snapshot = externalAgentRegistrySnapshot
        guard snapshot.registered > 0 else { return [] }
        return [.init(
            id: "external-agent:gateway",
            name: "外部 agent 网关",
            kind: .externalAgent,
            verb: .compute,
            inputTypes: [.task],
            outputTypes: [.text, .json],
            requiredPermissions: [.network],
            risk: .medium,
            source: "external-agent",
            adapterID: "gateway",
            status: snapshot.enabled > 0 ? .discovered : .disabled,
            verificationProbe: .init(kind: .apiHealth, summary: "向已启用外部 agent 发送低风险任务并收到结构化结果"),
            description: snapshot.statusText,
            tags: snapshot.transports.map(\.rawValue)
        )]
    }
}
