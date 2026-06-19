// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

// MARK: - Sorted Array Utilities

/// Insert `id` into a sorted UInt32 array, maintaining sort order.
/// Duplicates are silently skipped. Uses binary search to find position.
func sortedInsert(_ arr: inout [UInt32], _ id: UInt32) {
    // Binary search for insertion point
    var lo = 0
    var hi = arr.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if arr[mid] < id {
            lo = mid + 1
        } else if arr[mid] > id {
            hi = mid
        } else {
            return // duplicate — already present
        }
    }
    arr.insert(id, at: lo)
}

/// Remove `id` from a sorted UInt32 array.
/// Uses binary search. Returns true if the element was found and removed.
@discardableResult
func sortedRemove(_ arr: inout [UInt32], _ id: UInt32) -> Bool {
    var lo = 0
    var hi = arr.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if arr[mid] < id {
            lo = mid + 1
        } else if arr[mid] > id {
            hi = mid
        } else {
            arr.remove(at: mid)
            return true
        }
    }
    return false
}

/// Check if a sorted array contains `id`. Binary search.
func containsSorted(_ arr: [UInt32], _ id: UInt32) -> Bool {
    var lo = 0
    var hi = arr.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if arr[mid] < id {
            lo = mid + 1
        } else if arr[mid] > id {
            hi = mid
        } else {
            return true
        }
    }
    return false
}

/// Merge two sorted UInt32 arrays, deduplicating. O(n+m).
func mergeSorted(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
    guard !a.isEmpty else { return b }
    guard !b.isEmpty else { return a }
    var result: [UInt32] = []
    result.reserveCapacity(a.count + b.count)
    var i = 0, j = 0
    while i < a.count && j < b.count {
        let va = a[i], vb = b[j]
        if va < vb {
            result.append(va)
            i += 1
        } else if vb < va {
            result.append(vb)
            j += 1
        } else {
            result.append(va) // dedup
            i += 1
            j += 1
        }
    }
    while i < a.count { result.append(a[i]); i += 1 }
    while j < b.count { result.append(b[j]); j += 1 }
    return result
}

/// Intersect two sorted UInt32 arrays. Returns elements present in both.
func intersectSorted(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
    guard !a.isEmpty, !b.isEmpty else { return [] }
    var result: [UInt32] = []
    var i = 0, j = 0
    while i < a.count && j < b.count {
        let va = a[i], vb = b[j]
        if va < vb {
            i += 1
        } else if vb < va {
            j += 1
        } else {
            result.append(va)
            i += 1
            j += 1
        }
    }
    return result
}

/// Merge multiple sorted UInt32 arrays into one sorted, deduplicated result.
func unionAll(_ arrays: [[UInt32]]) -> [UInt32] {
    guard !arrays.isEmpty else { return [] }
    if arrays.count == 1 { return arrays[0] }
    // Merge progressively
    var result = arrays[0]
    for i in 1..<arrays.count {
        result = mergeSorted(result, arrays[i])
    }
    return result
}
