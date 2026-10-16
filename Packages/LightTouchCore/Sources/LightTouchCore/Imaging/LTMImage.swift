import Foundation
import HostRuntime

/// A decoded bitmap: the cross-platform replacement for `CGImage` in this
/// package's seams (CoreGraphics is Apple-only; HostRuntime's `LTMGeometry`
/// covers only the geometry types).
///
/// Pixels are tightly packed BGRA, top row first — the same layout as
/// `ShmSurface.baseAddress` (DeviceRuntime), so a screen frame can be wrapped
/// without conversion. sRGB throughout, like the transport.
public nonisolated struct LTMImage: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// `width * height * 4` bytes, BGRA, top row first.
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0, "LTMImage: bad size \(width)x\(height)")
        precondition(pixels.count == width * height * 4, "LTMImage: pixel count mismatch")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// A solid fill, for tests and the recorder's padding.
    public init(width: Int, height: Int, b: UInt8, g: UInt8, r: UInt8, a: UInt8 = 255) {
        precondition(width > 0 && height > 0, "LTMImage: bad size \(width)x\(height)")
        self.width = width
        self.height = height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<width * height {
            pixels[i * 4] = b
            pixels[i * 4 + 1] = g
            pixels[i * 4 + 2] = r
            pixels[i * 4 + 3] = a
        }
        self.pixels = pixels
    }

    /// A copy of a BGRA buffer (e.g. `ShmSurface.baseAddress`): `bytesPerRow`
    /// may exceed `width * 4`; padding is dropped.
    public init(
        copyingBGRA base: UnsafeRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) {
        precondition(width > 0 && height > 0 && bytesPerRow >= width * 4, "LTMImage: bad geometry")
        self.width = width
        self.height = height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { dest in
            let d = dest.baseAddress!
            for y in 0..<height {
                let src = base.advanced(by: y * bytesPerRow)
                d.advanced(by: y * width * 4).copyMemory(from: src, byteCount: width * 4)
            }
        }
        self.pixels = pixels
    }

    /// The image turned clockwise by `turns` quarter turns; the image itself for none.
    public func rotated(clockwiseQuarterTurns turns: Int) -> LTMImage {
        let t = ((turns % 4) + 4) % 4
        guard t != 0 else { return self }
        let (w, h) = t % 2 == 0 ? (width, height) : (height, width)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (dx, dy): (Int, Int)
                switch t {
                // Top-left origin. The new size is (w, h); the mapping reads the OLD size: for odd turns
                // the new width is the old height and vice versa, so `w`/`h` are the wrong subtrahends here.
                case 1: (dx, dy) = (height - 1 - y, x)  // clockwise
                case 2: (dx, dy) = (width - 1 - x, height - 1 - y)
                default: (dx, dy) = (y, width - 1 - x)  // counter-clockwise
                }
                let s = (y * width + x) * 4
                let d = (dy * w + dx) * 4
                out[d] = pixels[s]
                out[d + 1] = pixels[s + 1]
                out[d + 2] = pixels[s + 2]
                out[d + 3] = pixels[s + 3]
            }
        }
        return LTMImage(width: w, height: h, pixels: out)
    }

    /// BGRA bytes at a top-left-origin pixel.
    public func bgra(atX x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }
}

/// Bilinear down/upsample of one BGRA image onto a canvas, compositing over
/// `over` (nil: opaque black) — the recorder's fit/fill drawing, in Swift.
public nonisolated func ltmComposite(
    _ image: LTMImage,
    into size: CGSize,
    over background: LTMImage?,
    fit: Bool,
    bilinear: Bool
) -> [UInt8] {
    let width = Int(size.width)
    let height = Int(size.height)
    var canvas = [UInt8](repeating: 0, count: width * height * 4)
    // Opaque black base.
    for i in 0..<width * height { canvas[i * 4 + 3] = 255 }

    func draw(_ src: LTMImage, fill: Bool, canvas: inout [UInt8]) {
        let iw = Double(src.width)
        let ih = Double(src.height)
        let factor = fill ? max(Double(width) / iw, Double(height) / ih) : min(Double(width) / iw, Double(height) / ih)
        let dw = iw * factor
        let dh = ih * factor
        let ox = (Double(width) - dw) / 2
        let oy = (Double(height) - dh) / 2
        src.pixels.withUnsafeBytes { s in
            canvas.withUnsafeMutableBytes { c in
                let sp = s.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let dp = c.baseAddress!.assumingMemoryBound(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let sx = (Double(x) - ox + 0.5) / factor - 0.5
                        let sy = (Double(y) - oy + 0.5) / factor - 0.5
                        guard sx >= 0, sy >= 0, sx < iw - 1, sy < ih - 1 else { continue }
                        let d = (y * width + x) * 4
                        if bilinear {
                            let x0 = Int(sx), y0 = Int(sy)
                            let fx = sx - Double(x0), fy = sy - Double(y0)
                            for ch in 0..<4 {
                                let s00 = Double(sp[(y0 * src.width + x0) * 4 + ch])
                                let s10 = Double(sp[(y0 * src.width + x0 + 1) * 4 + ch])
                                let s01 = Double(sp[((y0 + 1) * src.width + x0) * 4 + ch])
                                let s11 = Double(sp[((y0 + 1) * src.width + x0 + 1) * 4 + ch])
                                let v = s00 * (1 - fx) * (1 - fy) + s10 * fx * (1 - fy)
                                    + s01 * (1 - fx) * fy + s11 * fx * fy
                                dp[d + ch] = UInt8(max(0, min(255, v.rounded())))
                            }
                        } else {
                            let s = ((Int(sy.rounded()) * src.width) + Int(sx.rounded())) * 4
                            dp[d] = sp[s]
                            dp[d + 1] = sp[s + 1]
                            dp[d + 2] = sp[s + 2]
                            dp[d + 3] = sp[s + 3]
                        }
                    }
                }
            }
        }
    }

    if let background { draw(background, fill: true, canvas: &canvas) }
    let native = background == nil
        && image.width == width && image.height == height
    if native {
        // Pixel for pixel, like the writer's native path.
        let byteCount = canvas.count
        image.pixels.withUnsafeBytes { s in
            canvas.withUnsafeMutableBytes { c in
                c.baseAddress!.copyMemory(from: s.baseAddress!, byteCount: byteCount)
            }
        }
    } else {
        draw(image, fill: !fit, canvas: &canvas)
    }
    return canvas
}
