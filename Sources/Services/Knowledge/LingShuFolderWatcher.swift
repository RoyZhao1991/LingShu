import Foundation
import CoreServices

/// 本机知识中枢·**FSEvents 自动增量**:监听 opt-in 目录,文件一变(去抖)就增量重索引,
/// 让 `recall_local` 始终是最新的——不用每次手动 index_local_knowledge。全本地。
/// FSEvents 回调是 C 函数指针(无捕获)→ 用 context.info 指针取回 self。
@MainActor
final class LingShuFolderWatcher {
    static let shared = LingShuFolderWatcher()

    private var stream: FSEventStreamRef?
    private weak var state: LingShuState?
    private var debounce: DispatchWorkItem?
    private(set) var watchedFolders: [String] = []

    /// 启动(state 就绪时)。读当前 opt-in 目录开始监听;目录变化经 `restart()` 重挂。
    func start(state: LingShuState) {
        self.state = state
        restart()
    }

    /// 按当前 opt-in 目录重挂监听(添加/移除目录后调)。
    func restart() {
        stop()
        guard let state else { return }
        let folders = state.localKnowledgeFolders
        guard !folders.isEmpty else { return }
        watchedFolders = folders

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<LingShuFolderWatcher>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { watcher.scheduleReindex() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, folders as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    /// 去抖增量重索引(2s 内多次变化合并成一次)。
    private func scheduleReindex() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let state = self.state else { return }
            let folders = state.localKnowledgeFolders
            let index = state.localKnowledgeIndex
            Task.detached { _ = LingShuFileKnowledgeIndexer.reindex(folders: folders, into: index) }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    func stop() {
        debounce?.cancel(); debounce = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        watchedFolders = []
    }
}
