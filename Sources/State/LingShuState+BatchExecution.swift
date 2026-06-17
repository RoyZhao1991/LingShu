import Foundation

/// 通用「先规划后执行」的**执行**环节。大脑把**已经想好的一串连续动作**一次性交给运行时按顺序跑完,
/// 中途不再每步回到模型——省掉逐步 LLM 往返(这正是"逐页翻 PPT 每页都卡一下"的根因:每翻一页都要模型重新读内容+生成讲稿)。
///
/// **这是通用能力,不是 PPT 专用**:逐页讲文档、逐条念清单、连续点几下界面……凡"已胸有成竹的连贯序列"都能批量跑。
/// 全程可被打断:主人插话(`batchInterruptRequested`)或任务取消(`Task.isCancelled`)→ 批量在下一步边界停下、把控制权交还大脑。
@MainActor
extension LingShuState {

    /// 给一组四肢工具包上一个 `run_steps` 批量执行器(主/自主会话共用)。run_steps 自身不进 lookup,故无递归。
    func withBatchRunner(_ tools: [LingShuAgentTool]) -> [LingShuAgentTool] {
        tools + [runStepsTool(over: tools)]
    }

    /// 取走一次性"批量被插话打断"信号(主人中途说话/下指令的 interject 路径置位)。
    func consumeBatchInterrupt() -> Bool {
        let v = batchInterruptRequested
        batchInterruptRequested = false
        return v
    }

    private func runStepsTool(over tools: [LingShuAgentTool]) -> LingShuAgentTool {
        let lookup = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return LingShuAgentTool(
            name: "run_steps",
            description: "**批量执行你已经想好的一串连续动作**(先规划后执行里的「执行」环节)。把计划好的若干步骤一次性交给运行时按顺序跑完,中间不必每步都回到你这——适合「逐页讲文档、逐条念清单、连续操作界面」这种你已胸有成竹的连贯序列。每步是一个工具调用 {tool:工具名, args:参数对象};speak 步会等念完再走下一步,翻页/推进因此顺滑不卡顿。全程可被主人插话打断(打断就停在当前步、把剩余交还给你)。**演示用法**:先 open_preview + preview_document_text 把整篇读完、把每页讲稿都想好,present_fullscreen(true) 进全屏,再用本工具一次性排上 [speak 第1页讲稿 → preview_next → speak 第2页讲稿 → preview_next → …] 顺滑播完。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"steps\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"tool\":{\"type\":\"string\",\"description\":\"工具名,如 speak / preview_next\"},\"args\":{\"type\":\"object\",\"description\":\"该工具的参数对象,无参给 {}\"}},\"required\":[\"tool\"]},\"description\":\"按顺序执行的步骤列表\"}},\"required\":[\"steps\"]}"
        ) { [weak self] argsJSON in
            guard let data = argsJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawSteps = obj["steps"] as? [[String: Any]], !rawSteps.isEmpty else {
                return "run_steps 参数应为 {\"steps\":[{\"tool\":..,\"args\":{..}}, …]};解析失败或步骤为空。"
            }
            var results: [String] = []
            for (i, step) in rawSteps.enumerated() {
                if Task.isCancelled { return "(任务已取消,停在第 \(i)/\(rawSteps.count) 步)" }
                if await self?.consumeBatchInterrupt() == true {
                    return "(主人中途插话,已停在第 \(i)/\(rawSteps.count) 步,后 \(rawSteps.count - i) 步未执行——先正面处理主人这次插话;要继续就从第 \(i + 1) 步起重新 run_steps。)"
                }
                guard let name = step["tool"] as? String, let tool = lookup[name] else {
                    results.append("✗ 第\(i + 1)步未知工具:\(step["tool"] as? String ?? "?")")
                    continue
                }
                let argDict = step["args"] as? [String: Any] ?? [:]
                let argJSON = (try? JSONSerialization.data(withJSONObject: argDict))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                let r = await tool.handler(argJSON)
                results.append("✓ \(name): \(r.prefix(50))")
            }
            return "批量执行完 \(rawSteps.count) 步:\n" + results.joined(separator: "\n")
        }
    }
}
