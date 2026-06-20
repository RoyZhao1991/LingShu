import Foundation

/// # 真实结果后置校验(verifyOutcome)纯逻辑 —— 方案 §2/§4 #6
///
/// 动作型任务(接入设备、开关灯、操作电脑、控外设…)的交付是**真实世界效果**,不是文件。
/// 验收必须校"真做到了吗",而不是"产出了一篇文档/说了完成"——根治"写指南文档冒充接入"。
///
/// 这里只放**确定性、零领域关键词**的判据,交给独立 verifier 当事实用;
/// "这到底是不是动作型请求"由 verifier 据用户意图判(壳不写意图关键词)。
enum LingShuOutcomeVerification {

    /// 不算"真实动作"的内核产出/读取/元工具(成功调用它们**不**构成"做到了某个真实效果")。
    /// 任何**不在此集合**里的工具成功执行 = 真实动作(自编执行器、计算机操作 click/type/scroll、外设控制…)。
    static let nonActionKernelTools: Set<String> = [
        "read_file", "write_file", "edit_file", "list_directory", "fetch_url", "run_command",
        "web_search", "recall_memory", "remember_credential", "list_credentials",
        "update_plan", "ask_user", "ask_choice", "perceive",
        "discover_devices", "peripherals", "label_peripheral",
        "discover_skill", "apply_skill", "author_component",
        "find_images", "acquire_resource", "review_design", "spawn_task",
        "set_digital_human", "speak", "get_current_time", "get_location",
        "push_notification", "watch_until", "schedule_task", "list_scheduled_tasks", "cancel_scheduled_task",
        "open_preview", "present_fullscreen"
    ]

    /// 一个工具是否属于"真实动作"(作用于真实世界/设备/界面)。未知工具按动作对待(偏保守:少误报"冒充")。
    static func isActionTool(_ name: String) -> Bool {
        !nonActionKernelTools.contains(name)
    }

    /// **"写文档冒充"高危信号**(确定性):本回合**有产出物且全是文档/指南类**(无源码/数据/可执行产物),
    /// 且**没有任何真实动作工具成功执行**。
    /// → 交独立 verifier:若用户要的是真实效果(接入/控制/操作设备),写一篇文档 ≠ 做到,判未达标、不收。
    /// 注:无任何产出物时**不**触发(纯动作任务可以没有文件);只在"唯一交付是文档"时才报警。
    static func isDocumentImpersonationSignal(artifactExtensions: [String], hadActionToolSuccess: Bool) -> Bool {
        guard !hadActionToolSuccess else { return false }
        let docExts: Set<String> = ["md", "markdown", "txt", "pdf", "docx", "doc", "html", "htm", "rtf", "rtfd"]
        let exts = artifactExtensions.map { ($0 as NSString).pathExtension.isEmpty ? $0.lowercased() : ($0 as NSString).pathExtension.lowercased() }
            .filter { !$0.isEmpty }
        guard !exts.isEmpty else { return false }
        return exts.allSatisfy { docExts.contains($0) }
    }
}
