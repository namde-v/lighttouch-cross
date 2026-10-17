// The screen-recording writer: an ffmpeg subprocess pipeline, the
// cross-platform replacement for the AVFoundation implementation.
//
// A take is H.264 video (libx264, yuv420p) in a .mov, with optional AAC audio.
// Video frames arrive as BGRA bitmaps (see LTMImage); the canvas compositing
// the old writer did in a CGContext (black base, aspect-fill background,
// aspect-fit frame) is done in Swift on the same buffers, then fed to
// ffmpeg's stdin as rawvideo at 30 fps. Timestamps become frame positions:
// each appended frame is held (duplicated) until its target 30 fps slot,
// so irregular producer pacing still yields the right duration.
//
// Audio arrives as timestamped S16LE stereo packets on GuestAudioCapture;
// gaps are silence-filled on the same clock, and the PCM timeline is fed to
// ffmpeg through a FIFO as its second input. ffmpeg missing at runtime is an
// honest CaptureError, never a crash.
//
// The writer and its ffmpeg session stay on one actor. The producer awaits
// each append; the OS pipe behind stdin applies the backpressure
// AVAssetWriterInput.isReadyForMoreMediaData used to.
#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif
import DeviceRuntime
import Foundation
import HostRuntime
import Subprocess
import Synchronization
#if canImport(System)
import System
#else
import SystemPackage
#endif

public actor ScreenMovieWriter {
    public init() {}

    private enum Phase {
        case idle, recording, finishing
    }

    private var phase = Phase.idle
    private var canvasSize: CGSize?
    private var background: LTMImage?
    private var outputSize = CGSize(width: 320, height: 480)
    private var capture: GuestAudioCapture?
    private var audioFrame: Int64 = 0
    private var count = 0

    private var frameStream: AsyncStream<[UInt8]>?
    private var frameContinuation: AsyncStream<[UInt8]>.Continuation?
    private var sessionTask: Task<Void, Never>?
    private var sessionError: Error?
    #if os(Windows)
    private let ffmpegPID: Mutex<Int32> = Mutex(-1)
    #else
    private let ffmpegPID: Mutex<pid_t> = Mutex(-1)
    #endif
    private var lastFrameIndex = -1
    #if !os(Windows)
    private var audioFD: Int32 = -1
    private var audioFIFO: URL?
    #endif

    private static let fps = 30.0

    /// `audio`: the device's capture (EmulatorController.startAudioCapture), or nil for a silent movie.
    /// `screenSize`: the screen's pixels as they're upright at the start (320×480 for the shipped iPod in portrait),
    /// a screen-only movie's frame. A movie can't change size: a screen turned later is fitted inside it on black.
    public func start(
        url: URL,
        audio: GuestAudioCapture? = nil,
        canvasSize: CGSize? = nil,
        background: LTMImage? = nil,
        screenSize: CGSize = CGSize(width: 320, height: 480)
    ) throws {
        guard phase == .idle else { throw CaptureError.failed("A recording is already active.") }
        guard FFmpeg.executablePath() != nil else {
            throw CaptureError.failed("Screen recording needs ffmpeg, which isn’t installed.")
        }
        self.canvasSize = canvasSize
        self.background = background
        outputSize = canvasSize ?? screenSize
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        guard width > 0, height > 0 else { throw CaptureError.failed("Invalid recording size.") }

        #if os(Windows)
        if audio != nil {
            throw CaptureError.failed("Screen recording with audio is not supported on Windows.")
        }
        #else
        if audio != nil {
            let fifo = url.deletingLastPathComponent()
                .appendingPathComponent(".ltm-audio-\(UUID().uuidString).fifo")
            guard mkfifo(fifo.path, 0o600) == 0 else {
                throw CaptureError.failed("Couldn’t record the screen.")
            }
            audioFIFO = fifo
            // O_RDWR: the open never blocks, and ffmpeg's read end opens
            // against it at once. Closed at finish: that EOFs the audio input.
            // A 1 MB pipe buffer covers the spawn window, so a write only ever
            // blocks once ffmpeg is draining (best effort: ignore failure).
            audioFD = open(fifo.path, O_RDWR | O_CLOEXEC)
            guard audioFD >= 0 else {
                try? FileManager.default.removeItem(at: fifo)
                audioFIFO = nil
                throw CaptureError.failed("Couldn’t record the screen.")
            }
            // F_SETPIPE_SZ isn't in Swift's Glibc module; the value is 1031.
            _ = fcntl(audioFD, 1031, 1 << 20)
        }
        #endif

        let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
        frameStream = stream
        frameContinuation = continuation
        sessionError = nil
        lastFrameIndex = -1
        count = 0
        audioFrame = 0
        phase = .recording
        #if os(Windows)
        let fifoPath: String? = nil
        #else
        let fifoPath = audioFIFO?.path
        #endif
        sessionTask = Task { [weak self] in
            await self?.runSession(url: url, width: width, height: height, audioFIFO: fifoPath)
        }
        capture = audio
    }

    private func runSession(url: URL, width: Int, height: Int, audioFIFO: String?) async {
        guard let bin = FFmpeg.executablePath() else {
            sessionError = CaptureError.failed("Screen recording needs ffmpeg, which isn’t installed.")
            frameContinuation?.finish()
            return
        }
        var arguments = [
            "-y", "-v", "error",
            "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "\(width)x\(height)",
            "-framerate", "30", "-i", "pipe:0",
        ]
        if let fifo = audioFIFO {
            arguments += ["-f", "s16le", "-ar", "44100", "-ac", "2", "-i", fifo]
        }
        arguments += [
            "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p",
            "-movflags", "+faststart",
        ]
        if audioFIFO != nil {
            arguments += ["-c:a", "aac", "-b:a", "128k"]
        }
        arguments += [url.path]
        do {
            let result = try await Subprocess.run(
                .path(FilePath(bin)),
                arguments: Arguments(arguments),
                input: .inputWriter,
                output: .discarded,
                error: .string(limit: 8192)
            ) { execution in
                #if os(Windows)
                self.ffmpegPID.withLock { $0 = Int32(bitPattern: execution.processIdentifier.value) }
                #else
                self.ffmpegPID.withLock { $0 = execution.processIdentifier.value }
                #endif
                defer { self.ffmpegPID.withLock { $0 = -1 } }
                guard let stream = self.frameStream else { return }
                do {
                    for await frame in stream {
                        _ = try await execution.standardInputWriter.write(frame)
                        try Task.checkCancellation()
                    }
                    try await execution.standardInputWriter.finish()
                } catch {
                    // Cancelled or the pipe broke: finish the input so ffmpeg exits.
                    try? await execution.standardInputWriter.finish()
                    throw error
                }
            }
            switch result.terminationStatus {
            case .exited(0): break
            case .exited(let code):
                sessionError = CaptureError.failed("The recording couldn’t be encoded (ffmpeg exited \(code)).")
            #if !os(Windows)
            case .signaled(let code):
                // SIGKILL on cancel() is expected; anything else is a failure.
                if phase != .idle {
                    sessionError = CaptureError.failed("The recording couldn’t be encoded (signal \(code)).")
                }
            #endif
            }
        } catch is CancellationError {
            // cancel() drives this; the session is over either way.
        } catch {
            sessionError = error
        }
        frameContinuation?.finish()
    }

    public func append(_ image: LTMImage?, seconds: Double) async throws {
        guard phase == .recording else { return }
        if let error = sessionError { throw error }
        #if !os(Windows)
        _ = try await drainAudio()
        #endif
        guard let image else { return }
        let seconds = capture?.seconds ?? seconds
        let target = max(0, Int((seconds * Self.fps).rounded()))
        guard target > lastFrameIndex else { return }  // a late or duplicate frame
        let bgra = ltmComposite(image, into: outputSize, over: background, fit: true, bilinear: true)
        // Hold each frame through its 30 fps slots: irregular pacing still
        // yields the take's real duration.
        if lastFrameIndex >= 0 {
            for _ in (lastFrameIndex + 1)..<target {
                frameContinuation?.yield(bgra)
            }
        }
        frameContinuation?.yield(bgra)
        lastFrameIndex = target
        count += 1
    }

    #if !os(Windows)
    private func drainAudio(through end: Double? = nil) async throws -> Bool {
        guard let capture, audioFD >= 0 else { return true }

        while true {
            guard let packet = try capture.read() else { return true }
            try appendAudio(packet.data, seconds: packet.seconds, through: end)
            if packet.data.isEmpty { return true }
        }
    }
    #endif

    #if !os(Windows)
    private func appendAudio(_ data: Data, seconds: Double, through end: Double? = nil) throws {
        guard audioFD >= 0 else { return }

        guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max / 44100), data.count % 4 == 0 else {
            throw CaptureError.failed("Couldn’t record the device’s audio.")
        }
        let target = Int64((seconds * 44100).rounded())
        let limit = end.map { Int64(max(0, $0 * 44100)) } ?? Int64.max
        // AAC encoding closes timestamp gaps. Supply silence explicitly, in
        // bounded chunks, so pauses and idle periods retain video alignment.
        while audioFrame < min(target, limit) {
            let frames = Int(min(4410, min(target, limit) - audioFrame))
            try writeAudio(Data(count: frames * 4))
            audioFrame += Int64(frames)
        }
        let skipped = Int(min(Int64(data.count / 4), max(0, audioFrame - target)))
        let frames = min(data.count / 4 - skipped, Int(max(0, min(Int64(data.count / 4), limit - audioFrame))))
        guard frames > 0 else { return }
        try writeAudio(data.dropFirst(skipped * 4))
        audioFrame += Int64(frames)
    }
    #endif

    #if !os(Windows)
    private func writeAudio(_ bytes: Data) throws {
        guard audioFD >= 0 else { return }

        try bytes.withUnsafeBytes { buffer in
            var pointer = buffer.baseAddress!
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(audioFD, pointer, remaining)
                guard written > 0 else { throw CaptureError.failed("Couldn’t record the device’s audio.") }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
    }
    #endif

    public func cancel() {
        capture?.stop()
        phase = .idle
        #if !os(Windows)
        if audioFD >= 0 { close(audioFD); audioFD = -1 }
        if let fifo = audioFIFO { try? FileManager.default.removeItem(at: fifo); audioFIFO = nil }
        #endif
        frameContinuation?.finish()
        frameContinuation = nil
        frameStream = nil
        #if !os(Windows)
        let pid = ffmpegPID.withLock { $0 }
        if pid > 0 { kill(pid, SIGKILL) }
        #endif
        capture = nil
    }

    public func finish(seconds: Double) async throws {
        guard phase == .recording else { throw CaptureError.failed("No recording is active.") }
        phase = .finishing
        let end = capture?.seconds ?? seconds
        capture?.stop()
        defer {
            capture = nil
            phase = .idle
            #if !os(Windows)
            if let fifo = audioFIFO { try? FileManager.default.removeItem(at: fifo); audioFIFO = nil }
            #endif
        }
        do {
            guard count > 0 else { throw CaptureError.failed("No device frames were recorded.") }
            #if !os(Windows)
            // The helper drains what the guest had queued after the stop (<= 1 s),
            // then says so (.audioEnded).
            let deadline = ContinuousClock.now + .seconds(10)
            while true {
                let drained = try await drainAudio(through: end)
                if drained, capture?.isFinished ?? true { break }
                guard ContinuousClock.now < deadline else {
                    if drained { break }  // the device never ended its audio: keep what arrived
                    throw CaptureError.failed("Couldn’t record the device’s audio.")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            // The audio timeline ends where the take does.
            try appendAudio(Data(), seconds: end, through: end)
            if audioFD >= 0 { close(audioFD); audioFD = -1 }
            #endif
            frameContinuation?.finish()
            frameContinuation = nil
            frameStream = nil
            await sessionTask?.value
            sessionTask = nil
            if let error = sessionError { throw error }
        } catch {
            cancel()
            throw error
        }
    }
}

public nonisolated enum CaptureError: LocalizedError {
    case failed(String)
    public var errorDescription: String? { if case .failed(let message) = self { message } else { nil } }
}

/// A recording's guest audio, pushed by the device's helper: `.audio` packets
/// (44.1 kHz stereo S16LE; an empty one marks silence through its time) after
/// `audioStart`, until `.audioEnded` once the stop has drained. Events arrive
/// on the main queue; the writer reads under the lock.
public nonisolated final class GuestAudioCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: @Sendable () -> Double
    private let stopSource: @Sendable (UInt64) -> Void
    private var generation: UInt64 = 0
    private var packets: [(data: Data, seconds: Double)] = []
    private var ended = false, failed = false, stopped = false

    /// `clock`: seconds since the capture started, the same monotonic clock the
    /// dylib stamps packets with. `stop`: ask the helper to stop that generation.
    public init(clock: @escaping @Sendable () -> Double, stop: @escaping @Sendable (UInt64) -> Void) {
        self.clock = clock
        stopSource = stop
    }

    /// The helper's capture generation (its audioStart reply).
    public func begin(generation: UInt64) { lock.withLock { self.generation = generation } }

    public func receive(_ event: LinkEvent) {
        lock.withLock {
            switch event {
            // Events can land before `begin`: nothing else is capturing then.
            case .audio(let g, let seconds, let pcm) where generation == 0 || g == generation:
                packets.append((pcm, seconds))
            case .audioEnded(let g, let didFail) where generation == 0 || g == 0 || g == generation:
                ended = true
                failed = didFail
            default: break
            }
        }
    }

    public var seconds: Double { clock() }

    public func stop() {
        let g: UInt64 = lock.withLock {
            stopped = true
            return generation
        }
        if g != 0 { stopSource(g) }
    }

    /// After stop(): the helper has delivered everything.
    public var isFinished: Bool { lock.withLock { ended && packets.isEmpty } }

    public func read() throws -> (data: Data, seconds: Double)? {
        try lock.withLock {
            if !packets.isEmpty { return packets.removeFirst() }
            if ended, failed, !stopped { throw CaptureError.failed("Couldn’t record the device’s audio.") }
            return nil
        }
    }
}
