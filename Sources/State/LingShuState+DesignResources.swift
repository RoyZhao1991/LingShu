import Foundation

/// 设计资源获取(找高质量素材)——自进化 PPT 模块的"资源层"。
/// `find_images` 走 Openverse(无密钥、CC/公有领域许可,license 干净)搜图并下载到工作目录 `assets/`,
/// 返回本地路径供生成器 `add_picture`。content-type + 体积上限校验;失败不致命(可不配图继续)。
/// 想换 Unsplash/Pexels 只改 `searchImageURLs` 一处即可。
@MainActor
extension LingShuState {

    /// find_images 工具:联网找配图并下载到本地,返回路径。让 PPT 有真实视觉,而不是纯文字。
    func findImagesTool() -> LingShuAgentTool {
        let workingDir = codexWorkingDirectory
        return LingShuAgentTool(
            name: "find_images",
            description: "联网找高质量配图(CC/公有领域许可,Openverse),下载到工作目录 assets/ 并返回本地路径。做 PPT/海报需要真实配图时调用,把返回路径填进 slides.json 的 image 字段。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"配图主题(英文关键词命中率更高,如 'team collaboration office')\"},\"count\":{\"type\":\"string\",\"description\":\"张数,默认 3,上限 6\"}},\"required\":[\"query\"]}"
        ) { argsJSON in
            let query = Self.jsonField(argsJSON, "query") ?? argsJSON
            let count = Int(Self.jsonField(argsJSON, "count") ?? "") ?? 3
            return await Self.fetchLicensedImages(query: query, count: count, workingDirectory: workingDir)
        }
    }

    /// 搜图(Openverse,无密钥,商用许可过滤)。换图源只改这一处。
    private nonisolated static func searchImageURLs(query: String, count: Int) async -> [URL] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.openverse.org/v1/images/?q=\(encoded)&page_size=\(count)&license_type=commercial&mature=false") else {
            return []
        }
        var request = URLRequest(url: url)
        request.setValue("LingShu/1.0 (design-resources)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else {
            return []
        }
        return results.compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }
    }

    /// 搜 + 下载 + 校验,返回本地路径汇报。
    nonisolated static func fetchLicensedImages(query: String, count: Int, workingDirectory: String) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "配图关键词为空。" }
        let n = max(1, min(count, 6))
        let urls = await searchImageURLs(query: trimmed, count: n)
        guard !urls.isEmpty else { return "没搜到「\(trimmed)」的可用配图(可换英文关键词,或不配图继续)。" }

        let assetsDir = (workingDirectory as NSString).appendingPathComponent("assets")
        try? FileManager.default.createDirectory(atPath: assetsDir, withIntermediateDirectories: true)
        let slug = trimmed.replacingOccurrences(of: " ", with: "-").prefix(24)
        var saved: [String] = []
        for (index, url) in urls.prefix(n).enumerated() {
            if let path = await downloadImageIfValid(url, into: assetsDir, name: "\(slug)-\(index + 1)") {
                saved.append(path)
            }
        }
        guard !saved.isEmpty else { return "搜到了但下载/校验未通过(可不配图继续或换词)。" }
        return "已下载 \(saved.count) 张配图(CC/公有领域,Openverse)到 assets/,把它们填进 slides.json 的 image 字段:\n"
            + saved.map { "- \($0)" }.joined(separator: "\n")
    }

    /// 下载单张并校验:必须是图片 content-type、体积在 1KB–12MB。否则丢弃返回 nil。
    private nonisolated static func downloadImageIfValid(_ url: URL, into dir: String, name: String) async -> String? {
        var request = URLRequest(url: url)
        request.setValue("LingShu/1.0 (design-resources)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard contentType.hasPrefix("image/"), data.count > 1024, data.count < 12_000_000 else { return nil }
        let ext = contentType.contains("png") ? "png" : (contentType.contains("webp") ? "webp" : "jpg")
        let path = (dir as NSString).appendingPathComponent("\(name).\(ext)")
        guard (try? data.write(to: URL(fileURLWithPath: path))) != nil else { return nil }
        return path
    }

    // MARK: - 通用资源自获取(acquire_resource):本地查不到 → 联网找 → 下载校验 → 入库复用

    /// acquire_resource 工具:做交付前先找现成参考资源(PPT 模板/图标集/字体/参考文档),
    /// 本地资源库有就直接用,没有就联网(git 等)下载、入库,下次复用——别凭空硬造。
    func acquireResourceTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "acquire_resource",
            description: "找现成参考资源(有参考比凭空做强):先查本地资源库,没有就联网(git/开源源)下载、入库、返回本地路径,下次复用。kind:pptx-template / icon-set / font / reference。做 PPT/文档/海报前应先用它找模板或素材。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{\"kind\":{\"type\":\"string\",\"description\":\"资源类型:pptx-template/icon-set/font/reference\"},\"query\":{\"type\":\"string\",\"description\":\"主题/品类关键词(英文命中率更高,如 'business' / 'tech minimal')\"}},\"required\":[\"kind\",\"query\"]}"
        ) { argsJSON in
            let kind = (Self.jsonField(argsJSON, "kind") ?? "reference").trimmingCharacters(in: .whitespaces)
            let query = Self.jsonField(argsJSON, "query") ?? argsJSON
            return await Self.acquireResource(kind: kind, query: query)
        }
    }

    /// 查本地 → 联网取 → 校验入库。返回给模型的说明(含本地路径)。
    nonisolated static func acquireResource(kind: String, query: String) async -> String {
        let registry = LingShuResourceRegistry.shared
        if let hit = registry.lookup(kind: kind, query: query).first {
            return "本地资源库已有「\(kind)」:\(hit.localPath)(\(hit.name))。直接拿它做底/参考,别再联网。"
        }
        let exts = LingShuResourceRegistry.allowedExtensions(forKind: kind)
        let links = await webSearchLinks(LingShuResourceRegistry.onlineQuery(kind: kind, query: query))
        guard !links.isEmpty else {
            return "联网没搜到「\(kind)」候选(\(query))。本次先用内置方式产出(如 PPT 走 DesignKB 版式库),别空等。"
        }
        let destDir = registry.resourceDir(forKind: kind)
        let slug = String(query.replacingOccurrences(of: " ", with: "-").prefix(24))
        for link in links.prefix(6) {
            if let path = await downloadResourceCandidate(link, allowedExts: exts, into: destDir, name: "\(slug.isEmpty ? kind : slug)-\(UUID().uuidString.prefix(4))") {
                registry.register(kind: kind, name: slug.isEmpty ? kind : slug,
                                  tags: query.lowercased().split(whereSeparator: { " ,，、/".contains($0) }).map(String.init),
                                  localPath: path, source: link.absoluteString, license: "web(未核实许可,注意版权)")
                return "已联网获取「\(kind)」并入库:\(path)(来源 \(link.host ?? "web"))。下次同类直接复用——请拿它做底/参考再产出。"
            }
        }
        return "联网找到了页面但没拿到可直接下载的「\(kind)」文件。本次先用内置方式产出,别空等。"
    }

    /// 下载候选:链接本身是目标文件就下;否则抓页面找第一个目标扩展名的直链再下。校验类型/体积/魔数(只收数据/素材)。
    private nonisolated static func downloadResourceCandidate(_ link: URL, allowedExts: [String], into dir: URL, name: String) async -> String? {
        if allowedExts.contains(link.pathExtension.lowercased()),
           let path = await downloadAndValidate(link, allowedExts: allowedExts, into: dir, name: name) {
            return path
        }
        // 链接是页面 → 抓 HTML 找直链(href 指向目标扩展名)。
        var request = URLRequest(url: link)
        request.setValue("Mozilla/5.0 (Macintosh) LingShu/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8) else { return nil }
        for ext in allowedExts {
            let pattern = "href=\"([^\"]+\\.\(ext)(?:\\?[^\"]*)?)\""
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: html) else { continue }
            let raw = String(html[r])
            let resolved = raw.hasPrefix("http") ? URL(string: raw) : URL(string: raw, relativeTo: link)?.absoluteURL
            if let u = resolved, let path = await downloadAndValidate(u, allowedExts: allowedExts, into: dir, name: name) {
                return path
            }
        }
        return nil
    }

    /// 下载 + 校验(扩展名 in allowed、体积 4KB–50MB、魔数对得上)→ 存盘返回路径;否则 nil。
    private nonisolated static func downloadAndValidate(_ url: URL, allowedExts: [String], into dir: URL, name: String) async -> String? {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh) LingShu/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count > 4096, data.count < 50_000_000 else { return nil }
        let ext = url.pathExtension.lowercased()
        guard allowedExts.contains(ext), magicMatches(data, ext: ext) else { return nil }
        let path = (dir.path as NSString).appendingPathComponent("\(name).\(ext)")
        guard (try? data.write(to: URL(fileURLWithPath: path))) != nil else { return nil }
        return path
    }

    /// 魔数校验:确认下载的是真文件、不是伪装的脚本/HTML(安全 + 防垃圾)。
    private nonisolated static func magicMatches(_ data: Data, ext: String) -> Bool {
        let b = [UInt8](data.prefix(8))
        func has(_ sig: [UInt8]) -> Bool { b.count >= sig.count && Array(b.prefix(sig.count)) == sig }
        switch ext {
        case "pptx", "potx", "zip": return has([0x50, 0x4B, 0x03, 0x04]) || has([0x50, 0x4B, 0x05, 0x06])  // ZIP(PK)
        case "png":  return has([0x89, 0x50, 0x4E, 0x47])
        case "svg":  return (String(data: data.prefix(512), encoding: .utf8)?.lowercased().contains("<svg") ?? false)
        case "ttf":  return has([0x00, 0x01, 0x00, 0x00]) || has([0x74, 0x72, 0x75, 0x65])  // 0x00010000 / 'true'
        case "otf":  return has([0x4F, 0x54, 0x54, 0x4F])  // 'OTTO'
        case "woff": return has([0x77, 0x4F, 0x46, 0x46])  // 'wOFF'
        case "woff2": return has([0x77, 0x4F, 0x46, 0x32]) // 'wOF2'
        case "pdf":  return has([0x25, 0x50, 0x44, 0x46])  // '%PDF'
        case "md", "txt": return true   // 文本类不卡魔数
        default: return true
        }
    }
}
