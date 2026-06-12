// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

/// A generic Trie (prefix tree) for O(k) prefix lookup, where k is the query length.
///
/// Used for filename indexing as `Trie<UnicodeScalar, Set<UInt32>>` where the value is
/// a set of `FileRecord.ID`s. All input should be NFC-normalized before insertion.
///
/// Copy-on-write: this is a value type (struct). Copying a Trie shares the
/// underlying node graph; the first mutation after a copy deep-clones the
/// affected path so that the original remains unchanged.
///
/// Thread safety: When used inside an actor (e.g. `InMemoryIndex`), no internal
/// synchronization is needed beyond the COW guarantee.
public struct Trie<Key: Hashable, Value> {

    /// Internal node — holds an optional value at this node and children keyed
    /// by the next element. Reference type enables COW via isKnownUniquelyReferenced.
    private final class Node {
        public var value: Value?
        public var children: [Key: Node] = [:]

        public init(value: Value? = nil) {
            self.value = value
        }

        /// Deep-copy this node and all descendants.
        public func deepCopy() -> Node {
            let copy = Node(value: value)
            for (key, child) in children {
                copy.children[key] = child.deepCopy()
            }
            return copy
        }
    }

    private var root = Node()
    /// Number of complete entries (keys with associated values) in the trie.
    private var _count = 0

    public var count: Int { _count }

    public var isEmpty: Bool { _count == 0 }

    public init() {}

    /// Ensure `root` is uniquely referenced. If not, deep-copy the entire
    /// node tree so that subsequent mutations do not affect other Trie copies.
    private mutating func ensureUnique() {
        if !isKnownUniquelyReferenced(&root) {
            root = root.deepCopy()
        }
    }

    /// Insert a key associated with a value. If the key already exists, its
    /// value is updated (the old value is discarded).
    mutating func insert(_ key: [Key], value: Value) {
        ensureUnique()
        var node = root
        for element in key {
            if let child = node.children[element] {
                node = child
            } else {
                let child = Node()
                node.children[element] = child
                node = child
            }
        }
        if node.value == nil {
            _count += 1
        }
        node.value = value
    }

    /// Return the value stored at exactly this key, or nil if no value exists at this node.
    /// Unlike search(prefix:), this does NOT traverse into child nodes.
    public func get(key: [Key]) -> Value? {
        var node = root
        for element in key {
            guard let child = node.children[element] else { return nil }
            node = child
        }
        return node.value
    }

    /// Search for all values whose keys start with the given prefix.
    /// Returns results in depth-first order.
    public func search(prefix: [Key]) -> [Value] {
        // Walk to the node corresponding to the prefix
        var node = root
        for element in prefix {
            guard let child = node.children[element] else {
                return []
            }
            node = child
        }
        // Collect all values in the subtree rooted at this node
        var results: [Value] = []
        collectValues(from: node, into: &results)
        return results
    }

    /// Remove the entry for the given key. Returns the associated value, or
    /// nil if the key was not present. Does not prune unused internal nodes
    /// (acceptable trade-off for an in-memory index that grows, not shrinks).
    @discardableResult
    mutating func remove(_ key: [Key]) -> Value? {
        ensureUnique()
        var node = root
        for element in key {
            guard let child = node.children[element] else {
                return nil
            }
            node = child
        }
        let removed = node.value
        if removed != nil {
            _count -= 1
            node.value = nil
        }
        return removed
    }

    // MARK: - Private

    /// Depth-first traversal collecting all non-nil values.
    private func collectValues(from node: Node, into results: inout [Value]) {
        if let value = node.value {
            results.append(value)
        }
        for child in node.children.values {
            collectValues(from: child, into: &results)
        }
    }
}
