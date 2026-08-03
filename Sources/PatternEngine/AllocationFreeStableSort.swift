/// Stable bottom-up merge sort backed by caller-owned reusable storage.
///
/// The standard library's stable array sort creates temporary storage. The
/// projection hot path instead pre-reserves `scratch` before interactive input
/// and reuses it for every page. Stability preserves generation order whenever
/// `precedes` considers two distinguishable elements equivalent.
@inline(__always)
func allocationFreeStableSort<Element>(
    _ values: inout [Element],
    scratch: inout [Element],
    by precedes: (Element, Element) -> Bool
) {
    guard values.count > 1 else {
        scratch.removeAll(keepingCapacity: true)
        return
    }
    if scratch.capacity < values.count {
        scratch.reserveCapacity(values.count)
    }

    var width = 1
    while width < values.count {
        scratch.removeAll(keepingCapacity: true)
        var lower = 0
        while lower < values.count {
            let middle = min(lower + width, values.count)
            let upper = min(middle + width, values.count)
            var left = lower
            var right = middle
            while left < middle, right < upper {
                // Prefer the left run on ties to preserve stable ordering.
                if precedes(values[right], values[left]) {
                    scratch.append(values[right])
                    right += 1
                } else {
                    scratch.append(values[left])
                    left += 1
                }
            }
            while left < middle {
                scratch.append(values[left])
                left += 1
            }
            while right < upper {
                scratch.append(values[right])
                right += 1
            }
            lower = upper
        }
        values.removeAll(keepingCapacity: true)
        values.append(contentsOf: scratch)
        width = width > values.count / 2 ? values.count : width * 2
    }
    scratch.removeAll(keepingCapacity: true)
}
