import Foundation

/// 本机知识索引·四肢 + 配置(第一刀:文件/文档/代码)。
///
/// 愿景:灵枢学习/蒸馏本机知识,无论"找东西"还是"按本机知识答题"都更准。隐私模型(用户拍板):
/// **本地检索 + 云端脑只发确认片段**——索引哪些目录由用户 opt-in(`lingshu.localKnowledgeFolders`),
/// 向量在本地算(NLEmbedding 零网络),只有 `recall_local` 检索到的片段才作为工具结果进上下文喂大脑(不是整库)。
@MainActor
extension LingShuState {
    private static let foldersKey = "lingshu.localKnowledgeFolders"

    /// 用户 opt-in 的索引目录(consent at folder level)。
    var localKnowledgeFolders: [String] {
        get { (UserDefaults.standard.array(forKey: Self.foldersKey) as? [String]) ?? [] }
        set { UserDefaults.standard.set(Array(Set(newValue)).sorted(), forKey: Self.foldersKey) }
    }

    func addLocalKnowledgeFolder(_ path: String) {
        let p = (path as NSString).expandingTildeInPath
        guard !p.isEmpty else { return }
        var f = localKnowledgeFolders
        guard !f.contains(p) else { return }
        f.append(p); localKnowledgeFolders = f
    }

    /// 本机知识四肢:检索 + 多源索引(文件/浏览器历史/日历/邮件/照片)。挂进 agent 工具集。
    func localKnowledgeTools() -> [LingShuAgentTool] {
        [recallLocalTool(), indexLocalKnowledgeTool(), indexBrowserHistoryTool(),
         indexCalendarTool(), indexMailTool(), indexPhotosTool()]
    }

    /// index_calendar:把本机日历日程/会议索引进本机知识(EventKit 本地、零上传;需日历授权)。
    func indexCalendarTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "index_calendar",
            description: "把本机日历的日程/会议(标题/时间/地点/参与人/备注)索引进本机知识,之后可用 recall_local 找回\"我跟谁约了什么/那个会几点\"。EventKit 本地读取、零上传;需系统日历授权。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{},\"required\":[]}"
        ) { [weak self] _ in
            let index = await MainActor.run { [weak self] in self?.localKnowledgeIndex }
            guard let index else { return "执行环境不可用" }
            let scan = await LingShuCalendarSource.scan(knownMtime: { index.knownMtime(for: $0) })
            guard !scan.seenPaths.isEmpty else { return "没读到日历事件(可能未授权日历访问,或近期无事件)。" }
            let r = LingShuKnowledgeIngest.ingest(scan, owns: LingShuCalendarSource.owns, into: index)
            return "日历增量索引:新增/更新 \(r.indexed) 条、移除 \(r.removed) 条(共 \(r.seen) 条日程);当前本机知识共 \(index.indexedFileCount) 条 / \(index.chunkCount) 块。"
        }
    }

    /// index_mail:把本机 Mail 邮件(主题/发件人/正文摘要)索引进本机知识(本地、零上传;需完全磁盘访问)。
    func indexMailTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "index_mail",
            description: "把本机 Mail 邮件(主题/发件人/正文摘要)索引进本机知识,之后可用 recall_local 找回\"那封关于X的邮件说了啥\"。本地读取 ~/Library/Mail、零上传;需系统「完全磁盘访问」授权。args: limit(最多取最近多少封,默认3000)。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"limit\":{\"type\":\"integer\",\"description\":\"最多取最近多少封,默认3000\"}},\"required\":[]}"
        ) { [weak self] argsJSON in
            let limit = (LingShuState.parseJSONObject(argsJSON)["limit"] as? Int).map { max(1, min(50_000, $0)) } ?? 3000
            let index = await MainActor.run { [weak self] in self?.localKnowledgeIndex }
            guard let index else { return "执行环境不可用" }
            let scan = await Task.detached { LingShuMailSource.scan(limit: limit, knownMtime: { index.knownMtime(for: $0) }) }.value
            guard !scan.seenPaths.isEmpty else { return "没读到邮件(可能未装 Mail、邮箱为空,或需在『系统设置→隐私与安全性→完全磁盘访问』给灵枢授权)。" }
            let r = LingShuKnowledgeIngest.ingest(scan, owns: LingShuMailSource.owns,
                                                  stillExists: { FileManager.default.fileExists(atPath: String($0.dropFirst(LingShuMailSource.pathPrefix.count))) }, into: index)
            return "邮件增量索引:新增/更新 \(r.indexed) 封、移除 \(r.removed) 封(扫描 \(r.seen) 封);当前本机知识共 \(index.indexedFileCount) 条 / \(index.chunkCount) 块。"
        }
    }

    /// index_photos:给图片本机生成字幕(Vision OCR+场景,零上传)再索引,找回"写着X的截图/照片"。
    func indexPhotosTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "index_photos",
            description: "给一个目录里的图片**本机生成字幕**(Vision OCR 文字 + 场景标签,**全程 on-device、照片绝不上云**)再索引,之后可用 recall_local 找回\"那张写着X的截图/某场景的照片\"。args: folder(图片目录,如 ~/Pictures 或 ~/Desktop;省略=用已配置的本机知识目录),limit(最多处理多少张,默认500)。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"folder\":{\"type\":\"string\",\"description\":\"图片目录绝对路径;省略=用已配置目录\"},\"limit\":{\"type\":\"integer\",\"description\":\"最多处理多少张,默认500\"}},\"required\":[]}"
        ) { [weak self] argsJSON in
            let args = LingShuState.parseJSONObject(argsJSON)
            let limit = (args["limit"] as? Int).map { max(1, min(5000, $0)) } ?? 500
            let main: (LingShuFileKnowledgeIndex, [String])? = await MainActor.run { [weak self] in
                guard let self else { return nil }
                return (self.localKnowledgeIndex, self.localKnowledgeFolders)
            }
            guard let (index, configured) = main else { return "执行环境不可用" }
            var folders = configured
            if let f = (args["folder"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty { folders = [f] }
            guard !folders.isEmpty else { return "没指定图片目录(传 folder,如 ~/Pictures)。" }
            let scan = await Task.detached { LingShuPhotoSource.scan(folders: folders, limit: limit, knownMtime: { index.knownMtime(for: $0) }) }.value
            guard !scan.seenPaths.isEmpty else { return "这些目录里没找到图片。" }
            let r = LingShuKnowledgeIngest.ingest(scan, owns: LingShuPhotoSource.owns,
                                                  stillExists: { FileManager.default.fileExists(atPath: $0) }, into: index)
            return "照片本机识别增量索引(OCR+场景,零上传):新增/更新 \(r.indexed) 张、移除 \(r.removed) 张(共 \(r.seen) 张);当前本机知识共 \(index.indexedFileCount) 条 / \(index.chunkCount) 块。"
        }
    }

    /// index_browser_history:把 Safari/Chrome 本地历史(标题+URL+最近访问)索引进本机知识(全本地、零上传)。
    /// 供"我那天看的那篇关于X的文章在哪"这类找回。Safari 需「完全磁盘访问」;读不到的源静默跳过。
    func indexBrowserHistoryTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "index_browser_history",
            description: "把本机 Safari/Chrome 浏览历史(标题+网址+最近访问)索引进本机知识索引(全本地零上传),之后可用 recall_local 找回看过的网页。Safari 需系统「完全磁盘访问」授权;读不到的浏览器会跳过。args: limit(每浏览器最多取多少条,默认2000)。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"limit\":{\"type\":\"integer\",\"description\":\"每个浏览器取最近多少条,默认2000\"}},\"required\":[]}"
        ) { [weak self] argsJSON in
            guard let self else { return "执行环境不可用" }
            let limit = (LingShuState.parseJSONObject(argsJSON)["limit"] as? Int).map { max(1, min(20_000, $0)) } ?? 2000
            let index = await MainActor.run { [weak self] in self?.localKnowledgeIndex }
            guard let index else { return "执行环境不可用" }
            let scan = await Task.detached { LingShuBrowserHistorySource.scan(limit: limit, knownMtime: { index.knownMtime(for: $0) }) }.value
            guard !scan.seenPaths.isEmpty else {
                return "没读到浏览历史(可能未装 Safari/Chrome,或 Safari 历史需在『系统设置→隐私与安全性→完全磁盘访问』里给灵枢授权)。"
            }
            let r = LingShuKnowledgeIngest.ingest(scan, owns: LingShuBrowserHistorySource.owns, into: index)
            return "浏览历史增量索引:新增/更新 \(r.indexed) 条、移除 \(r.removed) 条(扫描 \(r.seen) 条);当前索引共 \(index.indexedFileCount) 条 / \(index.chunkCount) 块。可用 recall_local 找回看过的网页。"
        }
    }

    /// recall_local:在本机知识索引里检索,返回相关片段(路径 + 摘录)。大脑据此按本机知识答题/找东西。
    func recallLocalTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "recall_local",
            description: "在【本机知识索引】(你已 opt-in 的本地文件/文档/代码,全本地零上传)里语义检索,返回最相关的片段(文件路径+摘录)。用于:① 按本机已有资料回答问题 ② 找东西('那份关于X的文档在哪')。拿到片段后可再 read_file 看全文。若索引为空,先用 index_local_knowledge 建索引。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"要找的内容/问题\"},\"limit\":{\"type\":\"integer\",\"description\":\"返回片段数,默认6\"}},\"required\":[\"query\"]}"
        ) { [weak self] argsJSON in
            let args = LingShuState.parseJSONObject(argsJSON)
            let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !query.isEmpty else { return "缺少 query。" }
            let limit = (args["limit"] as? Int).map { max(1, min(20, $0)) } ?? 6
            let main: (LingShuFileKnowledgeIndex, [String])? = await MainActor.run { [weak self] in
                guard let self else { return nil }
                return (self.localKnowledgeIndex, self.localKnowledgeFolders)
            }
            guard let (index, folders) = main else { return "执行环境不可用" }
            let hits = await Task.detached { index.search(query: query, limit: limit) }.value
            index.recordHits(hits.map(\.path))   // 记召回热度,供 dreaming 蒸馏高频本机知识进图谱(②)
            if hits.isEmpty {
                if index.chunkCount == 0 {
                    return folders.isEmpty
                        ? "本机知识索引为空,且尚未指定任何索引目录。先用 index_local_knowledge 传 folder(如 ~/Documents)建索引。"
                        : "本机知识索引为空(已配置目录:\(folders.joined(separator: "、")))。先用 index_local_knowledge 建索引。"
                }
                return "本机知识里没找到与「\(query)」相关的内容。"
            }
            let body = hits.enumerated().map { i, h in
                "\(i + 1). \(h.path)\n   \(h.snippet.replacingOccurrences(of: "\n", with: " "))"
            }.joined(separator: "\n")
            return "本机知识检索命中 \(hits.count) 条(相关性降序):\n\(body)\n\n(需要全文用 read_file 读对应路径。)"
        }
    }

    /// index_local_knowledge:把目录加入 opt-in 索引(consent)并增量建/更新索引。无 folder 则重索引已配置目录。
    func indexLocalKnowledgeTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "index_local_knowledge",
            description: "把一个目录纳入【本机知识索引】(opt-in 授权)并增量索引其文件/文档/代码(全本地零上传)。无 folder 参数则增量重索引已配置的所有目录。索引后即可用 recall_local 检索。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"folder\":{\"type\":\"string\",\"description\":\"要纳入索引的目录绝对路径(如 ~/Documents);省略=重索引已配置目录\"}},\"required\":[]}"
        ) { [weak self] argsJSON in
            let args = LingShuState.parseJSONObject(argsJSON)
            if let folder = (args["folder"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty {
                let expanded = (folder as NSString).expandingTildeInPath
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
                    return "目录不存在或不是文件夹:\(expanded)"
                }
                await MainActor.run { [weak self] in
                    self?.addLocalKnowledgeFolder(folder)
                    LingShuFolderWatcher.shared.restart()   // 新目录纳入 FSEvents 自动增量监听
                }
            }
            let main: (LingShuFileKnowledgeIndex, [String])? = await MainActor.run { [weak self] in
                guard let self else { return nil }
                return (self.localKnowledgeIndex, self.localKnowledgeFolders)
            }
            guard let (index, folders) = main else { return "执行环境不可用" }
            guard !folders.isEmpty else { return "尚未指定任何索引目录。请传 folder(如 ~/Documents)。" }
            let stats = await Task.detached { LingShuFileKnowledgeIndexer.reindex(folders: folders, into: index) }.value
            return "已增量索引 \(folders.count) 个目录:新建/更新 \(stats.indexed) 个文件、跳过 \(stats.skipped)、移除 \(stats.removed);当前索引共 \(index.indexedFileCount) 文件 / \(index.chunkCount) 块。现在可用 recall_local 检索。"
        }
    }

    /// ②·dreaming 蒸馏高频本机知识进图谱:把被 recall_local 反复命中的本机内容提炼成离散事实并入长期记忆。
    /// 由 dreaming(空闲)调用;无网络/无高频内容时自然空跑。
    func distillFrequentLocalKnowledge() async {
        let index = localKnowledgeIndex
        let adapter = makeAgentModelAdapter()
        let distill: @Sendable (String) async -> String = { prompt in
            let session = LingShuAgentSession(
                id: "dream-local-\(UUID().uuidString.prefix(6))",
                system: "你是事实提炼器,只输出陈述句事实(每行一条),绝不写步骤/指令/代码/客套。",
                tools: [], model: adapter, maxTurns: 1
            )
            if case .completed(let text) = await session.send(prompt) {
                return LingShuReasoningText.stripThinkTags(text)
            }
            return ""
        }
        let remember: @Sendable (String) async -> Void = { [weak self] fact in
            await MainActor.run {
                _ = self?.knowledgeGraph.remember(.init(kind: .fact, title: String(fact.prefix(60)), body: fact, source: .inference, confidence: 0.5))
            }
        }
        let added = await LingShuLocalKnowledgeDistiller.run(index: index, distill: distill, remember: remember)
        if added > 0 {
            appendTrace(kind: .result, actor: "固化", title: "本机知识蒸馏",
                        detail: "把 \(added) 条高频本机知识事实并入长期记忆(下次相关提问更快更准)。")
        }
    }

    /// 纯解析(nonisolated,供 @Sendable handler 在 MainActor 外调用)。
    nonisolated static func parseJSONObject(_ json: String) -> [String: Any] {
        (json.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
    }
}
