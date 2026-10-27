// The check run by scripts/check-claude-code-engine.sh.

import Foundation
import AppKit

@main
struct EngineHarness {
    static func main() async {
        let mode = CommandLine.arguments.dropFirst().first ?? "all"
        let t0 = Date()
        func ms(_ since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }

        if mode == "setup" || mode == "all" {
            let state = await ClaudeCodeCLI.checkSetupState()
            print("SETUP: \(state) (\(ms(t0))ms)")
            if let inst = try? await ClaudeCodeCLI.installation() {
                print("BINARY: \(inst.binaryURL.path)")
                print("PATH has homebrew: \(inst.processEnvironment["PATH"]?.contains("/opt/homebrew/bin") == true), no API key: \(inst.processEnvironment["ANTHROPIC_API_KEY"] == nil)")
            }
        }

        if mode == "chat" || mode == "all" {
            let imagePath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
            let imageData = (try? Data(contentsOf: URL(fileURLWithPath: imagePath))) ?? Data()
            let client = ClaudeCodeChatClient(model: "claude-sonnet-4-6", isExtendedThinkingEnabled: false)
            let system = "you're a voice assistant. answer in one short spoken sentence, all lowercase."
            for turn in 1...2 {
                let start = Date()
                var firstChunkAt: Int?
                do {
                    let (text, _) = try await client.analyzeImageStreaming(
                        images: imageData.isEmpty ? [] : [(data: imageData, label: "screen 1 of 1")],
                        systemPrompt: system,
                        conversationHistory: turn == 2 ? [(userPlaceholder: "my name is sam", assistantResponse: "nice to meet you sam")] : [],
                        userPrompt: turn == 1 ? "what colors do you see in this image?" : "what's my name?",
                        onTextChunk: { _ in if firstChunkAt == nil { firstChunkAt = ms(start) } }
                    )
                    print("CHAT turn \(turn): first chunk \(firstChunkAt ?? -1)ms, total \(ms(start))ms: \(text)")
                } catch { print("CHAT turn \(turn) ERROR: \(error)") }
                if turn == 1 { try? await Task.sleep(nanoseconds: 2_000_000_000) } // let the replacement start
            }

            // cancellation: start a long answer and cancel after first chunk
            let cancelStart = Date()
            let longTask = Task { () -> String in
                do {
                    let (text, _) = try await client.analyzeImageStreaming(images: [], systemPrompt: "you write long essays.", conversationHistory: [], userPrompt: "write 600 words about the ocean", onTextChunk: { _ in })
                    return "finished unexpectedly: \(text.count) chars"
                } catch { return "threw \(type(of: error)): \(error)" }
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            longTask.cancel()
            let outcome = await longTask.value
            print("CANCEL: \(outcome) after \(ms(cancelStart))ms")
            try? await Task.sleep(nanoseconds: 500_000_000)
            client.shutDown()
        }

        if mode == "voice" || mode == "all" {
            let start = Date()
            do {
                let wav = try await MacSystemVoiceSpeechAudioSource().fetchSpeechAudio(for: "hey, this is a voice test, nothing to worry about.")
                let header = String(decoding: wav.prefix(4), as: UTF8.self)
                print("VOICE: \(wav.count) bytes, header \(header), \(ms(start))ms")
            } catch { print("VOICE ERROR: \(error)") }
        }
    }
}
