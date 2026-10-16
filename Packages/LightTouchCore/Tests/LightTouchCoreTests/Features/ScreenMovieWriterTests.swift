import DeviceRuntime
import Foundation
import HostRuntime
import Testing

@testable import LightTouchCore

@testable import LightTouchCore

/// The guest's audio as the helper delivers it: 440 Hz left, 880 Hz right, 44.1 kHz S16LE in 10 ms packets on the
/// capture's own clock, with a one-second pause (1 s to 2 s) and 3 s in all. `now` is the clock the test advances.
nonisolated private final class ToneSource: @unchecked Sendable {  // lock-protected
    private let lock = NSLock()
    private var now = 0.0, frame = 0
    var time: Double {
        get { lock.withLock { now } }
        set { lock.withLock { now = newValue } }
    }

    /// One packet, or 0 bytes when the clock hasn't reached the next one (or the source is done).
    func read(_ buffer: UnsafeMutableRawPointer, _ seconds: inout Double) -> Int {
        lock.withLock {
            if frame == 44100 { frame = 88200 }
            if frame >= 132300 || Double(frame + 441) / 44100 > now { return 0 }
            seconds = Double(frame) / 44100
            let samples = buffer.assumingMemoryBound(to: Int16.self)
            for i in 0..<441 {
                samples[i * 2] = Int16(12000 * sin(2 * .pi * 440 * Double(frame) / 44100))
                samples[i * 2 + 1] = Int16(12000 * sin(2 * .pi * 880 * Double(frame) / 44100))
                frame += 1
            }
            return 1764
        }
    }

    /// LightTouchDevice's AudioPump, in process: drains the source into the GuestAudioCapture the recorder reads,
    /// as the helper's `.audio` and `.audioEnded` events would.
    func capture() -> GuestAudioCapture {
        nonisolated final class Flag: @unchecked Sendable {
            let lock = NSLock()
            var stopped = false
        }  // lock-protected
        let flag = Flag()
        let capture = GuestAudioCapture(
            clock: { [self] in time },
            stop: { _ in flag.lock.withLock { flag.stopped = true } }
        )
        capture.begin(generation: 1)
        Thread.detachNewThread { [self] in
            var buffer = [UInt8](repeating: 0, count: 16384)
            while true {
                var seconds = -1.0
                let n = buffer.withUnsafeMutableBytes { read($0.baseAddress!, &seconds) }
                if n > 0 || seconds >= 0 {
                    capture.receive(.audio(generation: 1, seconds: seconds, pcm: Data(buffer[0..<n])))
                    if n > 0 { continue }
                }
                if flag.lock.withLock({ flag.stopped }) {
                    return capture.receive(.audioEnded(generation: 1, failed: false))
                }
                usleep(5000)
            }
        }
        return capture
    }
}

private func solid(_ width: Int, _ height: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> LTMImage {
    LTMImage(width: width, height: height, b: b, g: g, r: r)
}

/// A movie's audio as 44.1 kHz stereo floats, and its frames' pixels, via ffmpeg.
private struct Movie {
    let url: URL
    init(_ url: URL) { self.url = url }

    func audio() async throws -> [[Double]] {
        let (stdout, _) = try await FFmpeg.run(
            ["-v", "error", "-i", url.path, "-map", "0:a", "-f", "f32le", "-ac", "2", "-ar", "44100", "-"],
            stdoutLimit: 1 << 26
        )
        let count = stdout.count / 8
        var channels: [[Double]] = [[], []]
        channels[0].reserveCapacity(count / 2)
        channels[1].reserveCapacity(count / 2)
        stdout.withUnsafeBytes { buffer in
            let samples = buffer.bindMemory(to: Float.self)
            for i in 0..<samples.count {
                channels[i % 2].append(Double(samples[i]) * 32768)
            }
        }
        return channels
    }

    func frame(at seconds: Double) async throws -> (width: Int, height: Int, rgb: (Int, Int) -> [Int]) {
        let probe = try await FFmpeg.probe(url)
        let width = probe.video.first?.width ?? 0
        let height = probe.video.first?.height ?? 0
        let (stdout, _) = try await FFmpeg.run(
            ["-v", "error", "-ss", "\(seconds)", "-i", url.path, "-frames:v", "1",
                "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
            stdoutLimit: width * height * 3 + 16
        )
        let bytes = [UInt8](stdout)
        return (width, height, { x, y in (0..<3).map { Int(bytes[(y * width + x) * 3 + $0]) } })
    }

    func probe() async throws -> FFmpeg.Probe { try await FFmpeg.probe(url) }
}

/// TestSupport's temporary directory, for async bodies.
private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ltm-tests-" + UUID().uuidString,
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func rms(_ samples: ArraySlice<Double>) -> Double {
    (samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count)).squareRoot()
}
/// A tone's frequency from its rising zero crossings.
private func frequency(_ samples: ArraySlice<Double>) -> Double {
    let s = Array(samples)
    let rising = (1..<s.count).filter { s[$0 - 1] < 0 && s[$0] >= 0 }
    guard let first = rising.first, let last = rising.last, last > first else { return 0 }
    return Double(rising.count - 1) * 44100 / Double(last - first)
}
private func near(_ a: [Int], _ b: [Int], _ tolerance: Int = 30) -> Bool {
    zip(a, b).allSatisfy { abs($0 - $1) < tolerance }
}

/// The production movie writer: native dimensions through portrait, landscape and rotation, the canvas background,
/// stereo audio on the capture's clock with its pause kept, and a take that survives a crash.
struct ScreenMovieWriterTests {
    enum Mode: String, CaseIterable { case portrait, landscape, rotated, canvas }
    static let orange = [255, 64, 0], blue = [0, 128, 255]

    func record(_ mode: Mode, to url: URL) async throws {
        let portrait = solid(320, 480, 255, 64, 0)
        let landscape = solid(480, 320, 0, 128, 255)
        let tones = ToneSource()
        let writer = ScreenMovieWriter()
        try await writer.start(
            url: url,
            audio: tones.capture(),
            canvasSize: mode == .canvas ? CGSize(width: 640, height: 400) : nil,
            background: mode == .canvas ? landscape : nil,
            screenSize: mode == .landscape ? CGSize(width: 480, height: 320) : CGSize(width: 320, height: 480)
        )
        for tick in 0...30 {
            tones.time = Double(tick) / 10
            let turned = mode == .landscape || ((mode == .rotated || mode == .canvas) && tick > 15)
            // mixer and video share the capture clock
            try await writer.append(turned ? landscape : portrait, seconds: 999)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await writer.finish(seconds: 999)
    }

    @Test(arguments: Mode.allCases)
    func geometryAudioAndPauseGap(_ mode: Mode) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("take.mov")
        do {
            try await record(mode, to: url)
            let movie = Movie(url)
            let probe = try await movie.probe()
            #expect(probe.audio.count == 1)
            #expect(probe.video.count == 1)
            let expected =
                switch mode {
                case .portrait: CGSize(width: 320, height: 480)
                case .landscape: CGSize(width: 480, height: 320)
                case .rotated: CGSize(width: 320, height: 480)  // the screen as it was at the start
                case .canvas: CGSize(width: 640, height: 400)
                }
            let video = try #require(probe.video.first)
            #expect(CGSize(width: video.width, height: video.height) == expected)
            #expect(abs(probe.duration - 3) < 0.1, "\(probe.duration) s")

            let audio = try await movie.audio()
            #expect(abs(Double(audio[0].count) / 44100 - 3) < 0.1, "\(Double(audio[0].count) / 44100) s of audio")
            for start in [0.2, 2.2] {
                let range = Int(start * 44100)..<Int((start + 0.5) * 44100)
                for (channel, hz) in [(0, 440.0), (1, 880.0)] {
                    #expect(abs(frequency(audio[channel][range]) - hz) < 3, "\(mode) at \(start) s, channel \(channel)")
                    #expect(rms(audio[channel][range]) > 7000)
                }
            }
            let gap = Int(1.2 * 44100)..<Int(1.8 * 44100)
            #expect(rms(audio[0][gap]) < 50 && rms(audio[1][gap]) < 50, "pause gap lost")

            for seconds in [0.5, 2.5] {
                let frame = try await movie.frame(at: seconds)
                let turned = mode == .landscape || ((mode == .rotated || mode == .canvas) && seconds > 1.5)
                let color = turned ? Self.blue : Self.orange
                #expect(
                    near(frame.rgb(frame.width / 2, frame.height / 2), color),
                    "\(mode) at \(seconds) s: \(frame.rgb(frame.width / 2, frame.height / 2))"
                )
                switch mode {
                case .portrait, .landscape:  // the screen reaches every corner: no padding, no scaling
                    #expect(near(frame.rgb(4, 4), color) && near(frame.rgb(frame.width - 5, frame.height - 5), color))
                case .canvas:
                    #expect(near(frame.rgb(4, 4), Self.blue), "canvas lost its background")
                case .rotated where turned:  // fitted, centered on black
                    #expect(frame.rgb(4, 4).max()! < 12, "turned screen lost its padding")
                    #expect(near(frame.rgb(4, frame.height / 2), color), "turned screen not fitted to the width")
                case .rotated:
                    #expect(near(frame.rgb(4, 4), color) && near(frame.rgb(frame.width - 5, frame.height - 5), color))
                }
            }
        }
    }
}
