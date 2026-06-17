import Foundation

/// 预览四肢:把"打开文件预览 + 翻页 + 滚动"做成大脑可调度的工具(`LingShuPreviewController` 的薄包装)。
/// 这是灵枢"独立演讲"的视觉手段(开稿+翻页)与"拖动看文档"的统一实现——大脑自己决定何时翻、何时讲。
@MainActor
extension LingShuState {

    /// 全部预览四肢(挂进主会话 + 自主运行工具集)。
    func previewTools() -> [LingShuAgentTool] {
        [
            LingShuAgentTool(
                name: "open_preview",
                description: "在 app 内打开文件预览(PPT/PDF/Word/Excel 都行,office 会自动转 PDF)。做演示/讲解/带人看文档时先用它打开。**返回里带【本页实际内容】——讲解必须照这页真实内容讲,别凭记忆/编**。正式演讲流程:open_preview → present_fullscreen(true) 进全屏演示 → 逐页 speak 讲(照本页内容)+ preview_next 翻 → 讲完 present_fullscreen(false) 退出。",
                parametersJSON: "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"文件绝对路径\"}},\"required\":[\"path\"]}"
            ) { [weak self] args in
                let path = Self.jsonField(args, "path") ?? args
                return await self?.previewController.open(path: path) ?? "预览不可用"
            },
            LingShuAgentTool(
                name: "preview_document_text",
                description: "一次性读取当前预览文档**所有页**的文字(先理解全篇、再规划讲稿——做演示/讲解前先用它把整篇读完,而不是逐页翻着边读边讲)。返回每页 内容。配合 run_steps:读全 → 想好每页讲稿 → 批量顺滑播。",
                parametersJSON: "{\"type\":\"object\",\"properties\":{}}"
            ) { [weak self] _ in
                await MainActor.run {
                    guard let self, self.previewController.pageCount > 0 else { return "还没打开任何预览,先 open_preview。" }
                    var out = "【全文共 \(self.previewController.pageCount) 页】\n"
                    for i in 0..<self.previewController.pageCount {
                        let t = self.previewController.pageText(i).trimmingCharacters(in: .whitespacesAndNewlines)
                        out += "—— 第 \(i + 1) 页 ——\n\(t.isEmpty ? "(无可提取文字,可能是图片页,讲前可 screen_capture 看一眼)" : t)\n"
                        if out.count > 9000 { out += "…(已截断,余下页讲到时再看)"; break }
                    }
                    return out
                }
            },
            LingShuAgentTool(
                name: "preview_next",
                description: "预览翻到下一页(演示时:讲完一页 speak 后翻页)。**返回里带新页的【实际内容】——照它讲。**",
                parametersJSON: "{\"type\":\"object\",\"properties\":{}}"
            ) { [weak self] _ in await MainActor.run { self?.previewController.next() ?? "预览不可用" } },
            LingShuAgentTool(
                name: "preview_prev",
                description: "预览翻到上一页。",
                parametersJSON: "{\"type\":\"object\",\"properties\":{}}"
            ) { [weak self] _ in await MainActor.run { self?.previewController.prev() ?? "预览不可用" } },
            LingShuAgentTool(
                name: "preview_goto",
                description: "预览跳到指定页(从 1 开始)。",
                parametersJSON: "{\"type\":\"object\",\"properties\":{\"page\":{\"type\":\"string\",\"description\":\"页码(从 1 开始)\"}},\"required\":[\"page\"]}"
            ) { [weak self] args in
                let page = Int(Self.jsonField(args, "page") ?? "1") ?? 1
                return await MainActor.run { self?.previewController.goto(page - 1) ?? "预览不可用" }
            },
            LingShuAgentTool(
                name: "preview_scroll",
                description: "滚动当前预览(长文档/Excel 拖动浏览)。lines 正数向下、负数向上。",
                parametersJSON: "{\"type\":\"object\",\"properties\":{\"lines\":{\"type\":\"string\",\"description\":\"滚动行数,正=下、负=上,默认 5\"}},\"required\":[]}"
            ) { [weak self] args in
                let lines = Int(Self.jsonField(args, "lines") ?? "5") ?? 5
                return await MainActor.run { self?.previewController.scroll(lines: lines) ?? "预览不可用" }
            },
            LingShuAgentTool(
                name: "present_fullscreen",
                description: "进入/退出**全屏演示模式**(把幻灯片放大铺满整个屏幕讲,像 PPT/Keynote 放映,不是在小预览窗里讲)。**做正式演讲/演示时必须先 present_fullscreen(true) 再开讲**,讲完 present_fullscreen(false) 退出。on=true 进、false 出。",
                parametersJSON: "{\"type\":\"object\",\"properties\":{\"on\":{\"type\":\"string\",\"description\":\"true 进入全屏演示 / false 退出,默认 true\"}},\"required\":[]}"
            ) { [weak self] args in
                let on = !((Self.jsonField(args, "on") ?? "true").lowercased() == "false")
                return await MainActor.run { self?.previewController.setSlideshow(on) ?? "预览不可用" }
            },
            LingShuAgentTool(
                name: "close_preview",
                description: "关闭预览面板。",
                parametersJSON: "{\"type\":\"object\",\"properties\":{}}"
            ) { [weak self] _ in await MainActor.run { self?.previewController.close() ?? "预览不可用" } }
        ]
    }
}
