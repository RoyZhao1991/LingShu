import Foundation

/// 内置浏览器四肢(browser_*):大脑的"上网+网页自动化"手段——打开URL/多tab/JS执行/滚动/全屏/取正文。
/// 做网页自动化测试:browser_open 打开 → browser_eval 跑 JS 读 DOM/点按/取数据 → browser_navigate/tab 切换。
@MainActor
extension LingShuState {

    func browserTools() -> [LingShuAgentTool] {
        [
            LingShuAgentTool(
                name: "browser_open",
                description: "在**内置浏览器**新标签页打开一个网址(或本地 .html 绝对路径)并显示。做网页演示/自动化测试都先用它。url 不带协议会自动补 https://。",
                parametersJSON: "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\",\"description\":\"网址或本地html绝对路径\"}},\"required\":[\"url\"]}"
            ) { [weak self] args in
                let url = Self.jsonField(args, "url") ?? args
                return await MainActor.run { self?.browserController.openTab(url) ?? "浏览器不可用" }
            },
            LingShuAgentTool(
                name: "browser_navigate",
                description: "当前标签页导航:传网址=打开它;传 back/forward/reload=后退/前进/刷新。",
                parametersJSON: "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\",\"description\":\"网址 或 back/forward/reload\"}},\"required\":[\"url\"]}"
            ) { [weak self] args in
                let url = Self.jsonField(args, "url") ?? args
                return await MainActor.run { self?.browserController.navigate(url) ?? "浏览器不可用" }
            },
            LingShuAgentTool(
                name: "browser_tab",
                description: "多标签页管理。action=new(开新tab,可带url)/switch(切到第index个,1起)/close(关第index个)/list(列出所有tab)。",
                parametersJSON: "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\",\"description\":\"new|switch|close|list\"},\"index\":{\"type\":\"string\",\"description\":\"switch/close 的标签序号(1起)\"},\"url\":{\"type\":\"string\",\"description\":\"new 时要打开的网址(可选)\"}},\"required\":[\"action\"]}"
            ) { [weak self] args in
                let action = (Self.jsonField(args, "action") ?? "list").lowercased()
                let idx = (Int(Self.jsonField(args, "index") ?? "") ?? 1) - 1
                return await MainActor.run {
                    guard let self else { return "浏览器不可用" }
                    switch action {
                    case "new": return self.browserController.openTab(Self.jsonField(args, "url") ?? "about:blank")
                    case "switch": return self.browserController.switchTab(index: idx)
                    case "close": return self.browserController.closeTab(index: idx)
                    default: return self.browserController.listTabs()
                    }
                }
            },
            LingShuAgentTool(
                name: "browser_eval",
                description: "在当前标签页**执行 JavaScript 并返回结果**(网页自动化核心):读 DOM(如 document.title、document.querySelector('h1').innerText)、点按钮(document.querySelector('#btn').click())、填表单、取数据。返回 JS 表达式的值。",
                parametersJSON: "{\"type\":\"object\",\"properties\":{\"js\":{\"type\":\"string\",\"description\":\"要执行的 JavaScript(返回值会回给你)\"}},\"required\":[\"js\"]}"
            ) { [weak self] args in
                let js = Self.jsonField(args, "js") ?? Self.jsonField(args, "script") ?? args
                guard let self else { return "浏览器不可用" }
                return await self.browserController.eval(js)
            },
            LingShuAgentTool(
                name: "browser_read",
                description: "读取当前网页的可见正文(document.body.innerText),一次拿整页文字照着讲/核对,免逐屏截屏。",
                parametersJSON: "{\"type\":\"object\",\"properties\":{}}"
            ) { [weak self] _ in
                guard let self else { return "浏览器不可用" }
                let t = await self.browserController.visibleText()
                return t.isEmpty ? "(页面还在加载或没正文)" : "【当前网页正文】\n\(String(t.prefix(6000)))"
            },
            LingShuAgentTool(
                name: "browser_scroll",
                description: "滚动当前网页。正数下滚、负数上滚(平滑)。",
                parametersJSON: "{\"type\":\"object\",\"properties\":{\"lines\":{\"type\":\"string\",\"description\":\"滚动量,正下负上\"}},\"required\":[\"lines\"]}"
            ) { [weak self] args in
                let n = Int(Self.jsonField(args, "lines") ?? "3") ?? 3
                return await MainActor.run { self?.browserController.scroll(lines: n) ?? "浏览器不可用" }
            },
            LingShuAgentTool(
                name: "browser_fullscreen",
                description: "内置浏览器进/退全屏放映。on=true 进、false 退。",
                parametersJSON: "{\"type\":\"object\",\"properties\":{\"on\":{\"type\":\"string\",\"description\":\"true 进全屏 / false 退\"}},\"required\":[\"on\"]}"
            ) { [weak self] args in
                let on = (Self.jsonField(args, "on") ?? "true").lowercased() != "false"
                return await MainActor.run { self?.browserController.setFullscreen(on) ?? "浏览器不可用" }
            },
            LingShuAgentTool(
                name: "browser_close",
                description: "关闭内置浏览器(所有标签页)。",
                parametersJSON: "{\"type\":\"object\",\"properties\":{}}"
            ) { [weak self] _ in
                await MainActor.run { self?.browserController.close() ?? "浏览器不可用" }
            }
        ]
    }
}
