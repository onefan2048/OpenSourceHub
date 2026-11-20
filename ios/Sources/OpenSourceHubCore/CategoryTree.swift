import Foundation

public struct CategoryTreeNode: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let parentId: Int64?
    public let depth: Int
    public let path: String
    public let directCount: Int
    public let totalCount: Int
    public let childrenCount: Int
    public let ancestorIds: [Int64]

    public var pickerLabel: String {
        let indent = depth > 0 ? String(repeating: "　", count: depth) + "└ " : ""
        return "\(indent)\(name) (\(totalCount))"
    }
}

public enum CategoryTree {
    /// Builds a flattened DFS tree of categories with recursive repo counts and breadcrumb paths.
    public static func build(categories: [CategoryItem], repos: [RepositoryItem]) -> [CategoryTreeNode] {
        var directCounts: [Int64: Int] = [:]
        for r in repos {
            if let cid = r.categoryId { directCounts[cid, default: 0] += 1 }
        }

        let byId = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        var childrenMap: [Int64?: [CategoryItem]] = [:]
        for cat in categories {
            let validParent: Int64? = (cat.parentId != nil && byId[cat.parentId!] != nil && cat.parentId != cat.id) ? cat.parentId : nil
            childrenMap[validParent, default: []].append(cat)
        }
        for (k, v) in childrenMap {
            childrenMap[k] = v.sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
        }

        var totalCache: [Int64: Int] = [:]
        var visiting = Set<Int64>()
        func computeTotal(_ id: Int64) -> Int {
            if let cached = totalCache[id] { return cached }
            guard visiting.insert(id).inserted else { return directCounts[id] ?? 0 }
            var sum = directCounts[id] ?? 0
            for child in childrenMap[id] ?? [] {
                sum += computeTotal(child.id)
            }
            visiting.remove(id)
            totalCache[id] = sum
            return sum
        }

        var out: [CategoryTreeNode] = []
        var visited = Set<Int64>()

        func dfs(parentId: Int64?, depth: Int, ancestors: [Int64], pathParts: [String]) {
            for cat in childrenMap[parentId] ?? [] {
                guard visited.insert(cat.id).inserted else { continue }
                let newPath = pathParts + [cat.name]
                let kids = childrenMap[cat.id] ?? []
                out.append(CategoryTreeNode(
                    id: cat.id,
                    name: cat.name,
                    parentId: parentId,
                    depth: depth,
                    path: newPath.joined(separator: " / "),
                    directCount: directCounts[cat.id] ?? 0,
                    totalCount: computeTotal(cat.id),
                    childrenCount: kids.count,
                    ancestorIds: ancestors
                ))
                dfs(parentId: cat.id, depth: depth + 1, ancestors: ancestors + [cat.id], pathParts: newPath)
            }
        }

        dfs(parentId: nil, depth: 0, ancestors: [], pathParts: [])
        return out
    }

    public static func descendantIds(of categoryId: Int64, in nodes: [CategoryTreeNode]) -> Set<Int64> {
        var result: Set<Int64> = [categoryId]
        for node in nodes {
            if node.ancestorIds.contains(categoryId) {
                result.insert(node.id)
            }
        }
        return result
    }
}
