// Portable memmem(3): byte-substring search over raw memory.
//
// memmem is a GNU extension. The Swift 6.4.1 ubuntu22.04 toolchain's Glibc overlay
// does not expose it (the ubuntu24.04 overlay does), so on Linux we bind the C
// symbol directly. The symbol itself exists in every glibc; only the Swift name
// binding was missing. Darwin exposes memmem natively; Windows has no memmem,
// so it gets a small portable fallback.

import Foundation

#if os(Linux)
    import Glibc

    @_silgen_name("memmem")
    private func c_memmem(
        _ haystack: UnsafeRawPointer?,
        _ haystackLen: Int,
        _ needle: UnsafeRawPointer?,
        _ needleLen: Int
    ) -> UnsafeRawPointer?
#elseif os(Windows)
    import WinSDK
#else
    import Darwin
#endif

/// Returns a pointer to the first occurrence of `needle` in `haystack`, or nil.
/// - Parameters:
///   - haystack/haystackLen: the bytes to search.
///   - needle/needleLen: the bytes to find; empty needle returns nil.
func ltc_memmem(
    _ haystack: UnsafeRawPointer,
    _ haystackLen: Int,
    _ needle: UnsafeRawPointer,
    _ needleLen: Int
) -> UnsafeRawPointer? {
    guard needleLen > 0, haystackLen >= needleLen else { return nil }
    #if os(Linux)
        return c_memmem(haystack, haystackLen, needle, needleLen)
    #elseif os(Windows)
        // Portable fallback: naive search. Correct everywhere; used only on Windows.
        let h = haystack.assumingMemoryBound(to: UInt8.self)
        let n = needle.assumingMemoryBound(to: UInt8.self)
        let last = haystackLen - needleLen
        var i = 0
        while i <= last {
            var j = 0
            while j < needleLen && h[i + j] == n[j] { j += 1 }
            if j == needleLen { return haystack + i }
            i += 1
        }
        return nil
    #else
        return memmem(haystack, haystackLen, needle, needleLen)
    #endif
}
