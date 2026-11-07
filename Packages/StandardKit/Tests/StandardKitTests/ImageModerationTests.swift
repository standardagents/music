import Foundation
import Testing
@testable import StandardKit

/// The Images endpoint's safety system sometimes rejects a cover (e.g. a posed dance-pop shot flagged
/// `sexual` at the output stage). Retrying the same prompt fails the same way, so the artist used to be
/// marked failed and the library build ended with a generic "Something went wrong."
@Suite struct ImageModerationTests {
    /// The body ChatGPT's Images endpoint returned for a real blocked cover (request id elided).
    static let blockedBody = Data("""
        {
          "error": {
            "message": "Your request was rejected by the safety system. If you believe this is an error, contact us at help.openai.com and include the request ID x. safety_violations=[sexual].",
            "type": "image_generation_user_error",
            "param": null,
            "code": "moderation_blocked",
            "moderation_details": { "moderation_stage": "output", "categories": ["sexual"] }
          }
        }
        """.utf8)

    @Test func moderationBlockIsRecognized() {
        let error = ChatGPTError.from(status: 400, body: Self.blockedBody)
        guard case .moderationBlocked(let categories) = error else {
            Issue.record("Expected moderationBlocked, got \(error)")
            return
        }
        #expect(categories == ["sexual"])
        #expect(!error.isRetryable)
    }

    @Test func otherHTTPErrorsKeepTheirBody() {
        let error = ChatGPTError.from(status: 400, body: Data(#"{"error":{"code":"invalid_request"}}"#.utf8))
        guard case .http(400, let body) = error else {
            Issue.record("Expected http(400), got \(error)")
            return
        }
        #expect(body.contains("invalid_request"))
    }

    @Test func blockedArtFallsBackToTheSafePrompt() async throws {
        let prompts = PromptLog()
        let data = try await LibraryBuilder.paint("risky", fallback: "safe") { prompt in
            await prompts.append(prompt)
            if prompt == "risky" { throw ChatGPTError.moderationBlocked(["sexual"]) }
            return Data("ok".utf8)
        }
        #expect(data == Data("ok".utf8))
        #expect(await prompts.all == ["risky", "safe"])
    }

    @Test func otherErrorsDoNotTriggerTheFallback() async {
        let prompts = PromptLog()
        await #expect(throws: ChatGPTError.self) {
            try await LibraryBuilder.paint("prompt", fallback: "safe") { prompt in
                await prompts.append(prompt)
                throw ChatGPTError.failed("No image was returned.")
            }
        }
        #expect(await prompts.all == ["prompt"])
    }

    @Test func safeCoverLeavesOutTheArtDirection() {
        let prompt = LibraryBuilder.safeCoverPrompt(
            title: "Plastic Tiara", artist: "Vellora", year: 2024, genre: "Dance-pop", kind: "album")
        #expect(prompt.contains("\"Plastic Tiara\""))
        #expect(prompt.contains("\"Vellora\""))
        #expect(prompt.contains("No people"))
    }

    @Test func partialFailureSaysWhatHappened() {
        #expect(LibraryBuilder.unfinishedMessage(1) == "1 artist couldn’t be finished.")
        #expect(LibraryBuilder.unfinishedMessage(4) == "4 artists couldn’t be finished.")
    }
}

private actor PromptLog {
    var all: [String] = []
    func append(_ prompt: String) { all.append(prompt) }
}
