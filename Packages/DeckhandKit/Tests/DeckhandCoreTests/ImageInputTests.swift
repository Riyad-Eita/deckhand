import Foundation
import Testing
@testable import DeckhandCore

struct ImageInputTests {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
    var message: Message { Message(role: .user, blocks: [.image(mediaType: "image/png", data: png), .text("What does this error mean?")]) }

    @Test func anthropicGetsABase64ImageBlock() {
        let blocks = AnthropicProvider.encode(message)["content"]?.arrayValue ?? []
        #expect(blocks.count == 2)
        #expect(blocks[0]["type"]?.stringValue == "image")
        #expect(blocks[0]["source"]?["media_type"]?.stringValue == "image/png")
        #expect(blocks[0]["source"]?["data"]?.stringValue == png.base64EncodedString())
        #expect(blocks[1]["text"]?.stringValue == "What does this error mean?")
    }

    @Test func openAIGetsADataURL() {
        let out = OpenAIChatProvider.encode(message)
        let content = out.first?["content"]?.arrayValue ?? []
        #expect(content.first?["text"]?.stringValue == "What does this error mean?")
        #expect(content.last?["image_url"]?["url"]?.stringValue == "data:image/png;base64,\(png.base64EncodedString())")
        // Without images the content stays a plain string.
        #expect(OpenAIChatProvider.encode(.user("hi")).first?["content"]?.stringValue == "hi")
    }

    @Test func imagesSurviveStorageAndCountForCompaction() throws {
        let decoded = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message))
        #expect(decoded.blocks == message.blocks)
        #expect(Compaction.estimate([message]) > 1_600)
        #expect(Compaction.transcript([message]).contains("User attached an image."))
    }
}
