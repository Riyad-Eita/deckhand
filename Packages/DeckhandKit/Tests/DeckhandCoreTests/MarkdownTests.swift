import Testing
@testable import DeckhandCore

@Suite struct MarkdownTests {
    @Test func parsesAgentReply() {
        let md = """
        ## Disk

        The filesystem has **16 GB free**.

        | Directory | Size |
        |---|---:|
        | `.vscode-server` | 5.4 GB |
        | .npm | 1.7 GB |

        - first
        - second
          continued
        1. one
        2. two

        ```bash
        df -h
        ```
        > note
        ---
        """
        #expect(MarkdownBlocks.parse(md) == [
            .heading(level: 2, text: "Disk"),
            .paragraph("The filesystem has **16 GB free**."),
            .table(header: ["Directory", "Size"], rows: [["`.vscode-server`", "5.4 GB"], [".npm", "1.7 GB"]]),
            .bulletList(["first", "second\ncontinued"]),
            .numberedList(start: 1, items: ["one", "two"]),
            .code(language: "bash", text: "df -h"),
            .quote("note"),
            .rule,
        ])
    }

    @Test func unterminatedFenceKeepsText() {
        #expect(MarkdownBlocks.parse("```\nabc") == [.code(language: nil, text: "abc")])
    }

    @Test func hashWithoutSpaceIsText() {
        #expect(MarkdownBlocks.parse("#hashtag") == [.paragraph("#hashtag")])
    }
}
