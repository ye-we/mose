//
//  CompanionSentenceSpeaker.swift
//  leanring-buddy
//
//  Speaks an answer one sentence at a time, starting with the first sentence
//  while Claude is still writing the rest, and reports when each sentence
//  starts so Clicky's marks appear exactly as their sentence is spoken.
//
//  Two ways to speak: sentence audio rendered ahead of time and played back
//  to back (the default: macOS `say` with the Mac's system voice, which can be
//  a Siri voice, or ElevenLabs through an HTTP bridge), or the in-app speech
//  engine (instant, but AVSpeechSynthesizer can't use Siri voices, so it often
//  sounds robotic).
//

import AVFoundation
import Foundation

@MainActor
protocol CompanionSentenceSpeaker: AnyObject {
    /// Called with a sentence's index the moment it starts playing.
    var onSentenceStartedSpeaking: ((Int) -> Void)? { get set }
    /// Called when everything queued has been spoken.
    var onFinishedSpeaking: (() -> Void)? { get set }
    /// True while anything is playing or still queued.
    var isSpeaking: Bool { get }
    func enqueueSentence(_ sentenceText: String, sentenceIndex: Int)
    func stopSpeaking()
}

// MARK: - Mac speech engine

@MainActor
final class SystemVoiceSentenceSpeaker: NSObject, CompanionSentenceSpeaker, AVSpeechSynthesizerDelegate {
    var onSentenceStartedSpeaking: ((Int) -> Void)?
    var onFinishedSpeaking: (() -> Void)?

    private let speechSynthesizer = AVSpeechSynthesizer()
    private let speechVoice: AVSpeechSynthesisVoice?
    private var sentenceIndicesByUtterance: [ObjectIdentifier: Int] = [:]

    /// Set "clickySpeechVoiceIdentifier" in the app's defaults to pick a voice;
    /// otherwise the best installed English voice is used.
    static let preferredVoiceIdentifierDefaultsKey = "clickySpeechVoiceIdentifier"

    override init() {
        speechVoice = Self.chooseSpeechVoice()
        super.init()
        speechSynthesizer.delegate = self
        print("🔊 Speech: \(speechVoice.map { "\($0.name) (\($0.language), \(Self.qualityDescription($0.quality)))" } ?? "system default voice")")
    }

    var isSpeaking: Bool {
        speechSynthesizer.isSpeaking || !sentenceIndicesByUtterance.isEmpty
    }

    func enqueueSentence(_ sentenceText: String, sentenceIndex: Int) {
        let sentenceUtterance = AVSpeechUtterance(string: sentenceText)
        sentenceUtterance.voice = speechVoice
        // A touch quicker than the default, which sounds slow for quick answers
        sentenceUtterance.rate = min(AVSpeechUtteranceDefaultSpeechRate * 1.06, AVSpeechUtteranceMaximumSpeechRate)
        sentenceIndicesByUtterance[ObjectIdentifier(sentenceUtterance)] = sentenceIndex
        speechSynthesizer.speak(sentenceUtterance)
    }

    func stopSpeaking() {
        sentenceIndicesByUtterance.removeAll()
        speechSynthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let utteranceIdentifier = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let sentenceIndex = self.sentenceIndicesByUtterance[utteranceIdentifier] else { return }
            self.onSentenceStartedSpeaking?(sentenceIndex)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceIdentifier = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.sentenceIndicesByUtterance.removeValue(forKey: utteranceIdentifier) != nil else { return }
            if self.sentenceIndicesByUtterance.isEmpty {
                self.onFinishedSpeaking?()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceIdentifier = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.sentenceIndicesByUtterance.removeValue(forKey: utteranceIdentifier)
        }
    }

    /// The voice to speak with: the one picked in defaults, else the highest
    /// quality English voice installed (Premium and Enhanced voices sound far
    /// better; they're downloaded in System Settings → Accessibility → Spoken
    /// Content), preferring the user's own English region. Novelty voices
    /// like "Bubbles" are never picked.
    static func chooseSpeechVoice() -> AVSpeechSynthesisVoice? {
        if let preferredVoiceIdentifier = UserDefaults.standard.string(forKey: preferredVoiceIdentifierDefaultsKey),
           let preferredVoice = AVSpeechSynthesisVoice(identifier: preferredVoiceIdentifier) {
            return preferredVoice
        }

        let preferredEnglishLanguage = Locale.preferredLanguages.first { $0.hasPrefix("en") } ?? "en-US"
        let englishVoices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            voice.language.hasPrefix("en")
                && !voice.voiceTraits.contains(.isNoveltyVoice)
                && !voice.voiceTraits.contains(.isPersonalVoice)
        }
        func qualityRank(_ voice: AVSpeechSynthesisVoice) -> Int {
            switch voice.quality {
            case .premium: return 2
            case .enhanced: return 1
            default: return 0
            }
        }

        let bestInstalledQuality = englishVoices.map(qualityRank).max() ?? 0
        // Only beat the system's default voice with a genuinely better one
        guard bestInstalledQuality > 0 else {
            return AVSpeechSynthesisVoice(language: preferredEnglishLanguage) ?? AVSpeechSynthesisVoice(language: "en-US")
        }
        let bestQualityVoices = englishVoices.filter { qualityRank($0) == bestInstalledQuality }
        return bestQualityVoices.first { $0.language == preferredEnglishLanguage } ?? bestQualityVoices.first
    }

    private static func qualityDescription(_ voiceQuality: AVSpeechSynthesisVoiceQuality) -> String {
        switch voiceQuality {
        case .premium: return "premium"
        case .enhanced: return "enhanced"
        default: return "standard"
        }
    }
}

// MARK: - Sentence audio played back to back

/// Turns one sentence into playable audio (WAV, MP3 or anything AVAudioPlayer reads).
protocol SentenceSpeechAudioSource {
    func fetchSpeechAudio(for text: String) async throws -> Data
}

extension ElevenLabsTTSClient: SentenceSpeechAudioSource {}

/// The Mac's system voice through `say`, the same voice as Spoken Content in
/// System Settings. That's often a Siri voice, which sounds far more natural
/// than anything AVSpeechSynthesizer can reach. Rendering a sentence takes
/// about a second, so sentences are rendered while earlier ones play.
struct MacSystemVoiceSpeechAudioSource: SentenceSpeechAudioSource {
    func fetchSpeechAudio(for text: String) async throws -> Data {
        let renderedAudioFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-voice-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: renderedAudioFileURL) }

        let sayResult = try await ChildProcessRunner.runToCompletion(
            executableURL: URL(fileURLWithPath: "/usr/bin/say"),
            arguments: ["-o", renderedAudioFileURL.path, "--file-format=WAVE", "--data-format=LEI16@22050"],
            standardInputText: text,
            timeLimitSeconds: 30
        )
        guard sayResult.exitCode == 0 else {
            throw NSError(domain: "MacSystemVoice", code: Int(sayResult.exitCode),
                          userInfo: [NSLocalizedDescriptionKey: "say failed: \(sayResult.standardErrorText)"])
        }
        return try Data(contentsOf: renderedAudioFileURL)
    }
}

/// Fetches each sentence's audio as soon as the sentence arrives (so the next
/// one is ready while the current one plays) and plays them back to back.
@MainActor
final class PrefetchedAudioSentenceSpeaker: CompanionSentenceSpeaker {
    var onSentenceStartedSpeaking: ((Int) -> Void)?
    var onFinishedSpeaking: (() -> Void)?

    private let speechAudioSource: SentenceSpeechAudioSource
    private var sentencesWaitingToPlay: [(sentenceIndex: Int, audioFetchTask: Task<Data?, Never>)] = []
    private var currentAudioPlayer: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?

    init(speechAudioSource: SentenceSpeechAudioSource, voiceDescription: String) {
        self.speechAudioSource = speechAudioSource
        print("🔊 Speech: \(voiceDescription)")
    }

    var isSpeaking: Bool {
        currentAudioPlayer?.isPlaying == true || !sentencesWaitingToPlay.isEmpty || playbackTask != nil
    }

    func enqueueSentence(_ sentenceText: String, sentenceIndex: Int) {
        let speechAudioSource = self.speechAudioSource
        let audioFetchTask = Task<Data?, Never> {
            do {
                return try await speechAudioSource.fetchSpeechAudio(for: sentenceText)
            } catch {
                print("⚠️ Speech audio for sentence \(sentenceIndex) failed: \(error)")
                return nil
            }
        }
        sentencesWaitingToPlay.append((sentenceIndex, audioFetchTask))
        startPlaybackIfNeeded()
    }

    func stopSpeaking() {
        playbackTask?.cancel()
        playbackTask = nil
        currentAudioPlayer?.stop()
        currentAudioPlayer = nil
        for waitingSentence in sentencesWaitingToPlay {
            waitingSentence.audioFetchTask.cancel()
        }
        sentencesWaitingToPlay.removeAll()
    }

    private func startPlaybackIfNeeded() {
        guard playbackTask == nil else { return }
        playbackTask = Task { [weak self] in
            while let self, !Task.isCancelled, !self.sentencesWaitingToPlay.isEmpty {
                let nextSentence = self.sentencesWaitingToPlay.removeFirst()
                guard let sentenceAudio = await nextSentence.audioFetchTask.value,
                      !Task.isCancelled,
                      let sentenceAudioPlayer = try? AVAudioPlayer(data: sentenceAudio) else { continue }

                self.currentAudioPlayer = sentenceAudioPlayer
                sentenceAudioPlayer.play()
                self.onSentenceStartedSpeaking?(nextSentence.sentenceIndex)

                while sentenceAudioPlayer.isPlaying && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 40_000_000)
                }
            }
            let didFinishEverything = !Task.isCancelled
            self?.playbackTask = nil
            if didFinishEverything {
                self?.onFinishedSpeaking?()
            }
        }
    }
}
