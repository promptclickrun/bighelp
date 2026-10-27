import Foundation
import PhononCore
import Synchronization

/// Where the flow LM runs. The Neural Engine is the fast path; the CPU is a fallback that
/// produces slightly different audio (it computes in fp32 where the ANE computes in fp16).
public enum ComputeUnit: Sendable {
    case neuralEngine
    case cpu

    var raw: UInt32 { self == .neuralEngine ? UInt32(PTTS_UNIT_ANE) : UInt32(PTTS_UNIT_CPU) }
}

/// Text normalization. It makes the model noticeably better, but how `@`, `+` or `=` are read
/// out depends on the language, so there is no default: normalizing German as English says
/// "at" where it should say "ät". `.none` hands the text to the model as written.
public enum Language: String, Sendable {
    case english = "en", french = "fr", german = "de", spanish = "es", portuguese = "pt"
    case none
}

/// How one utterance went.
@available(iOS 18.0, macOS 15.0, *)
public struct SpeechStats: Sendable {
    /// Seconds of audio produced.
    public let audioSeconds: Double
    /// Seconds of audio per second of wall time. Above 1 is faster than playback.
    public let realtimeFactor: Double
    /// From the call to the first audio being delivered.
    public let timeToFirstAudio: Duration
    /// Codec frames produced, 80 ms each.
    public let frames: Int

    init(_ r: PttsResult) {
        audioSeconds = Double(r.samples) / Phonon.sampleRate
        realtimeFactor = r.total_ms > 0 ? audioSeconds * 1000 / r.total_ms : 0
        timeToFirstAudio = .milliseconds(r.ttfa_ms)
        frames = Int(r.frames)
    }
}

public struct PhononError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(description: String) { self.description = description }
}

/// A C pointer, vouched for: it is only ever used on the instance's serial queue.
private struct Pointer<P>: @unchecked Sendable {
    let p: P
}

/// Text to speech with Phonon, on the Neural Engine.
///
/// Load once and keep it: loading reads the models and, on the first launch after an
/// install or a model update, compiles them for this device (about 10 s on an iPhone 16 Pro).
/// Speaking is then much faster than real time, and audio is delivered as it is generated.
///
/// Calls are serialized: an instance speaks one utterance at a time, and concurrent calls wait
/// their turn. All methods may be called from any thread or task.
@available(iOS 18.0, macOS 15.0, *)
public final class Phonon: @unchecked Sendable {
    /// Every sample is mono Float32 at this rate.
    public static let sampleRate: Double = 24_000

    /// The voices the models were exported with, sorted.
    public let voices: [String]

    /// The languages the model was trained for, as its config lists them.
    public let languages: [String]

    private let handle: OpaquePointer
    // Every call into the handle runs here: the Rust side is not reentrant.
    private let queue: DispatchQueue
    private let current: Mutex<String>
    private let currentLanguage: Mutex<Language>

    /// The voice speaking, one of `voices`.
    public var voice: String { current.withLock { $0 } }

    /// How text is normalized, as given to `load` or `setLanguage(_:)`.
    public var language: Language { currentLanguage.withLock { $0 } }

    private init(handle: OpaquePointer, queue: DispatchQueue, language: Language) {
        self.handle = handle
        self.queue = queue
        let names = Self.names(ptts_voices(handle))
        voices = names
        languages = Self.names(ptts_languages(handle))
        current = Mutex(names.first ?? "")
        currentLanguage = Mutex(language)
    }

    private static func names(_ block: UnsafePointer<CChar>?) -> [String] {
        var names: [String] = []
        if var p = block {
            while true {
                let s = String(cString: p)
                if s.isEmpty { break }
                names.append(s)
                p = p.advanced(by: s.utf8.count + 1)
            }
        }
        return names
    }

    deinit {
        let h = Pointer(p: handle)
        queue.async { ptts_free(h.p) }
    }

    private static func run<T: Sendable>(
        on queue: DispatchQueue, _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            queue.async { c.resume(with: Result { try work() }) }
        }
    }

    private static func lastError(_ h: OpaquePointer?) -> PhononError {
        PhononError(description: ptts_last_error(h).map { String(cString: $0) } ?? "unknown error")
    }

    /// Whether the models in `directory` still need compiling for this device, which `load`
    /// then does. Useful to tell the user why the first launch takes longer.
    public static func needsCompiling(_ directory: URL) -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return items.contains { name in
            name.hasSuffix(".mlpackage")
                && !items.contains(String(name.dropLast(".mlpackage".count)) + ".mlmodelc")
        }
    }

    /// Load the models in `directory`, compiling them first if this device has not yet.
    ///
    /// `directory` must be writable, since compiled models are kept beside the packages: use
    /// `PhononModels.install(bundled:)` or `PhononModels.download(from:)` to get one.
    public static func load(
        models directory: URL,
        language: Language,
        computeUnit: ComputeUnit = .neuralEngine
    ) async throws -> Phonon {
        let queue = DispatchQueue(label: "phonon-tts", qos: .userInitiated)
        let path = directory.path
        let h: Pointer<OpaquePointer> = try await run(on: queue) {
            guard let h = path.withCString({ p in
                language.rawValue.withCString { ptts_new(p, computeUnit.raw, $0) }
            }) else { throw lastError(nil) }
            return Pointer(p: h)
        }
        return Phonon(handle: h.p, queue: queue, language: language)
    }

    /// Switch to another of `voices`. This conditions the model on it, up to about 0.6 s on
    /// a phone, so the next utterance does not have to.
    public func setVoice(_ name: String) async throws {
        let h = Pointer(p: handle)
        try await Self.run(on: queue) {
            guard name.withCString({ ptts_set_voice(h.p, $0) }) else { throw Self.lastError(h.p) }
        }
        current.withLock { $0 = name }
    }

    /// Normalize text as `language` from the next utterance on. Nothing is reloaded, so this is
    /// immediate. Pair it with a voice of that language: the voice carries the accent.
    public func setLanguage(_ language: Language) async throws {
        let h = Pointer(p: handle)
        try await Self.run(on: queue) {
            guard language.rawValue.withCString({ ptts_set_language(h.p, $0) }) else {
                throw Self.lastError(h.p)
            }
        }
        currentLanguage.withLock { $0 = language }
    }

    private final class Sink: @unchecked Sendable {
        let onAudio: ([Float]) -> Void
        let stop = Atomic<Bool>(false)
        init(_ onAudio: @escaping ([Float]) -> Void) { self.onAudio = onAudio }
    }

    /// Speak `text`, calling `onAudio` with each chunk of samples (80 ms) as soon as it is
    /// generated, in order, on a background thread. Returns once the utterance is complete.
    ///
    /// Long text is split at sentence ends and spoken sentence by sentence. Cancelling the
    /// calling task stops generation at the next chunk and returns what was produced.
    @discardableResult
    public func speak(
        _ text: String, onAudio: @escaping @Sendable ([Float]) -> Void
    ) async throws -> SpeechStats {
        let sink = Sink(onAudio)
        let box = Unmanaged.passRetained(sink)
        defer { box.release() }
        let (h, raw) = (Pointer(p: handle), Pointer(p: UnsafeMutableRawPointer(box.toOpaque())))
        return try await withTaskCancellationHandler {
            try await Self.run(on: queue) {
                var r = PttsResult()
                let ok = text.withCString { t in
                    ptts_speak(h.p, t, { pcm, n, user in
                        guard let pcm, let user else { return false }
                        let sink = Unmanaged<Sink>.fromOpaque(user).takeUnretainedValue()
                        if sink.stop.load(ordering: .relaxed) { return false }
                        sink.onAudio(Array(UnsafeBufferPointer(start: pcm, count: n)))
                        return true
                    }, raw.p, &r)
                }
                guard ok else { throw Self.lastError(h.p) }
                return SpeechStats(r)
            }
        } onCancel: {
            sink.stop.store(true, ordering: .relaxed)
        }
    }

    /// Speak `text` as a stream of sample chunks. Cancel the consuming task to stop generation.
    /// Breaking out of the loop alone does not reliably terminate the stream's producer.
    public func stream(_ text: String) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.speak(text) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Speak `text` and return all of its samples at once.
    public func synthesize(_ text: String) async throws -> [Float] {
        let samples = Mutex<[Float]>([])
        try await speak(text) { chunk in samples.withLock { $0 += chunk } }
        return samples.withLock { $0 }
    }
}
