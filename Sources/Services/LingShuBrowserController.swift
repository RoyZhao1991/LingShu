import Foundation
import WebKit
import AppKit

/// **内置多 tab 浏览器(2026-06-20)**:app 内真·浏览器(多 WKWebView tab + 地址栏导航 + 前进后退 + HTML5 全屏 + JS 执行)。
/// 用途:① HTML/网页演示在 app 内稳定渲染(免丢去 Chrome + 计算机控制滚的慢/焦点问题);② **给大脑一套 web 自动化四肢**
/// (browser_open/navigate/tab/eval/scroll)做网页自动化测试——打开页面、读 DOM、JS 点按、取结果,全在进程内确定性控制。
/// 与 `LingShuPreviewController`(本地 PPT/PDF 演示)分工:这条是"上网/自动化",那条是"看本地文档"。
@MainActor
final class LingShuBrowserController: NSObject, ObservableObject, WKNavigationDelegate {

    struct Tab: Identifiable {
        let id: UUID
        let webView: WKWebView
        var title: String
        var url: String
        var loading: Bool
    }

    @Published var isPresented = false
    @Published private(set) var tabs: [Tab] = []
    @Published var activeTabID: UUID?
    @Published var fullscreen = false

    var activeTab: Tab? { tabs.first { $0.id == activeTabID } }
    private var activeWebView: WKWebView? { activeTab?.webView }

    /// 共享配置:开 HTML5 全屏 API(视频/游戏 element.requestFullscreen)+ 内联播放。
    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        if #available(macOS 12.3, *) { config.preferences.isElementFullscreenEnabled = true }
        config.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self   // 处理 window.open 弹窗(第三方/OAuth 登录:Google/Apple/Microsoft 都靠它)
        view.allowsBackForwardNavigationGestures = true
        return view
    }

    // MARK: - tab / 导航(给 UI 和工具共用)

    /// 打开新 tab 并导航到 url(没带协议自动补 https://;本地 .html 路径用 file://)。返回简述。
    @discardableResult
    func openTab(_ raw: String) -> String {
        let view = makeWebView()
        let id = UUID()
        tabs.append(Tab(id: id, webView: view, title: "新标签页", url: raw, loading: true))
        activeTabID = id
        isPresented = true
        loadURL(raw, in: view)
        return "已开新标签页(第 \(tabs.count) 个)并打开:\(raw)"
    }

    /// 当前 tab 导航到 url / 前进 / 后退。
    func navigate(_ raw: String) -> String {
        guard let view = activeWebView else { return openTab(raw) }
        let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cmd == "back" || cmd == "后退" { if view.canGoBack { view.goBack(); return "已后退。" }; return "没有可后退的历史。" }
        if cmd == "forward" || cmd == "前进" { if view.canGoForward { view.goForward(); return "已前进。" }; return "没有可前进的历史。" }
        if cmd == "reload" || cmd == "刷新" { view.reload(); return "已刷新。" }
        loadURL(raw, in: view)
        return "当前标签页正在打开:\(raw)"
    }

    private func loadURL(_ raw: String, in view: WKWebView) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("file:") {   // 本地文件
            let url = trimmed.hasPrefix("file:") ? URL(string: trimmed)! : URL(fileURLWithPath: trimmed)
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            return
        }
        let withScheme = (trimmed.contains("://") ? trimmed : "https://\(trimmed)")
        guard let url = URL(string: withScheme) else { return }
        view.load(URLRequest(url: url))
    }

    func switchTab(index: Int) -> String {
        guard tabs.indices.contains(index) else { return "没有第 \(index + 1) 个标签页(共 \(tabs.count) 个)。" }
        activeTabID = tabs[index].id
        return "已切到第 \(index + 1) 个标签页:\(tabs[index].title)"
    }

    func closeTab(index: Int) -> String {
        guard tabs.indices.contains(index) else { return "没有第 \(index + 1) 个标签页。" }
        let closing = tabs.remove(at: index)
        closing.webView.navigationDelegate = nil
        if activeTabID == closing.id { activeTabID = tabs.last?.id }
        if tabs.isEmpty { isPresented = false }
        return "已关闭第 \(index + 1) 个标签页。\(tabs.isEmpty ? "(已无标签页,浏览器关闭)" : "")"
    }

    func listTabs() -> String {
        guard !tabs.isEmpty else { return "当前没有打开任何标签页。" }
        return "共 \(tabs.count) 个标签页:\n" + tabs.enumerated().map { i, t in
            "\(i + 1). \(t.id == activeTabID ? "▶ " : "  ")\(t.title) — \(t.url)\(t.loading ? "(加载中)" : "")"
        }.joined(separator: "\n")
    }

    /// 在当前 tab 执行 JS 并返回结果字符串(web 自动化核心:读 DOM / 点按 / 取数据)。
    func eval(_ js: String) async -> String {
        guard let view = activeWebView else { return "还没打开任何网页,先 browser_open。" }
        return await withCheckedContinuation { cont in
            view.evaluateJavaScript(js) { result, error in
                if let error { cont.resume(returning: "JS 出错:\(error.localizedDescription)"); return }
                switch result {
                case let s as String: cont.resume(returning: s.isEmpty ? "(空字符串)" : String(s.prefix(4000)))
                case let n as NSNumber: cont.resume(returning: n.stringValue)
                case .none: cont.resume(returning: "(undefined/null)")
                case let other?: cont.resume(returning: String(describing: other).prefix(4000).description)
                }
            }
        }
    }

    func scroll(lines: Int) -> String {
        guard let view = activeWebView else { return "还没打开网页。" }
        view.evaluateJavaScript("window.scrollBy({top: \(lines * 110), left:0, behavior:'smooth'})", completionHandler: nil)
        return "已\(lines >= 0 ? "向下" : "向上")滚动 \(abs(lines)) 段。"
    }

    func setFullscreen(_ on: Bool) -> String {
        guard isPresented else { return "浏览器没打开。" }
        fullscreen = on
        return on ? "浏览器已进入全屏。" : "浏览器已退出全屏。"
    }

    /// 当前页可见正文(供大脑照着读/核对)。
    func visibleText() async -> String {
        await eval("document.body && document.body.innerText || ''")
    }

    func close() -> String {
        for t in tabs { t.webView.navigationDelegate = nil }
        tabs.removeAll()
        activeTabID = nil
        isPresented = false
        fullscreen = false
        return "已关闭内置浏览器。"
    }

    // MARK: - WKNavigationDelegate:更新 tab 的标题/URL/加载态

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateTab(for: webView, loading: false)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        updateTab(for: webView, loading: true)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        updateTab(for: webView, loading: false)
    }

    private func updateTab(for webView: WKWebView, loading: Bool) {
        guard let idx = tabs.firstIndex(where: { $0.webView === webView }) else { return }
        tabs[idx].title = webView.title?.isEmpty == false ? webView.title! : tabs[idx].title
        tabs[idx].url = webView.url?.absoluteString ?? tabs[idx].url
        tabs[idx].loading = loading
    }
}

// MARK: - WKUIDelegate:弹窗 / 第三方登录 / JS 对话框
//
// **根治"灵枢浏览器做 Google 登录点了没反应"(2026-06-22)**:OAuth(Google/Apple/Microsoft/SSO)通过
// `window.open` 打开授权弹窗,WKWebView 默认**不**新建弹窗 webView → window.open 返回 nil → 登录按钮点了无任何跳转。
// 实现 `createWebViewWith` 用**传入的 configuration**(共享 process pool/cookie,弹窗才能 postMessage 回 opener)
// 新建一个 tab 承载弹窗,返回它让 WebKit 把授权请求加载进去;弹窗 `window.close()` 时移除该 tab。
extension LingShuBrowserController: WKUIDelegate {

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        popup.allowsBackForwardNavigationGestures = true
        let id = UUID()
        let urlStr = navigationAction.request.url?.absoluteString ?? "about:blank"
        tabs.append(Tab(id: id, webView: popup, title: "登录…", url: urlStr, loading: true))
        activeTabID = id
        isPresented = true
        // 同窗导航(target=_blank 但无 window 特性)时 WebKit 不会自动 load,这里兜底加载请求。
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            popup.load(URLRequest(url: url))
        }
        return popup
    }

    /// 弹窗 `window.close()`(OAuth 完成后常调)→ 关掉该 tab,切回前一个;空了关浏览器。
    func webViewDidClose(_ webView: WKWebView) {
        guard let idx = tabs.firstIndex(where: { $0.webView === webView }) else { return }
        let closing = tabs.remove(at: idx)
        closing.webView.navigationDelegate = nil
        closing.webView.uiDelegate = nil
        if activeTabID == closing.id { activeTabID = tabs.last?.id }
        if tabs.isEmpty { isPresented = false }
    }

    /// JS alert/confirm/prompt:默认 WebKit 不弹会让某些登录流程卡住——给出合理默认(不阻塞)。
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        completionHandler(defaultText)
    }
}
