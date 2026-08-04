import Foundation

struct LingShuTaskThreadHierarchyItem: Identifiable, Equatable, Sendable {
    var id: String { record.id }
    var record: LingShuTaskExecutionRecord
    var depth: Int
}

struct LingShuTaskThreadHierarchyGroup: Identifiable, Equatable, Sendable {
    var id: String { root.id }
    var root: LingShuTaskExecutionRecord
    var descendants: [LingShuTaskThreadHierarchyItem]

    var isRootTask: Bool { root.threadCommit?.parentTaskId == nil }
}

enum LingShuTaskThreadHierarchy {
    static func groups(_ records: [LingShuTaskExecutionRecord]) -> [LingShuTaskThreadHierarchyGroup] {
        let ordered = records.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt { return lhs.id < rhs.id }
            return lhs.updatedAt > rhs.updatedAt
        }
        let byID = ordered.reduce(into: [String: LingShuTaskExecutionRecord]()) { result, record in
            result[record.id] = record
        }
        let childrenByParent = Dictionary(grouping: ordered.compactMap { record -> (String, LingShuTaskExecutionRecord)? in
            guard let parentID = record.threadCommit?.parentTaskId, !parentID.isEmpty else { return nil }
            return (parentID, record)
        }, by: { $0.0 }).mapValues { pairs in
            pairs.map(\.1).sorted { $0.updatedAt > $1.updatedAt }
        }

        var visited = Set<String>()
        func makeGroup(root: LingShuTaskExecutionRecord) -> LingShuTaskThreadHierarchyGroup {
            visited.insert(root.id)
            var descendants: [LingShuTaskThreadHierarchyItem] = []
            func appendChildren(of parentID: String, depth: Int) {
                for child in childrenByParent[parentID] ?? [] where !visited.contains(child.id) {
                    visited.insert(child.id)
                    descendants.append(.init(record: child, depth: depth))
                    appendChildren(of: child.id, depth: depth + 1)
                }
            }
            appendChildren(of: root.id, depth: 1)
            return .init(root: root, descendants: descendants)
        }

        var result: [LingShuTaskThreadHierarchyGroup] = []
        for record in ordered {
            let parentID = record.threadCommit?.parentTaskId
            if parentID == nil || parentID.flatMap({ byID[$0] }) == nil {
                if !visited.contains(record.id) { result.append(makeGroup(root: record)) }
            }
        }
        // Corrupt or cyclic legacy parent links must not make records disappear from the task page.
        for record in ordered where !visited.contains(record.id) {
            result.append(makeGroup(root: record))
        }
        return result.sorted { $0.root.updatedAt > $1.root.updatedAt }
    }
}
