import DeckhandCore
import SwiftUI

/// Renders an agent reply: block structure from `MarkdownBlocks`, inline styling from `AttributedString`.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    init(_ text: String) { blocks = MarkdownBlocks.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(level <= 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 4)
        case .paragraph(let text):
            Text(inline(text))
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(item))
                    }
                }
            }
        case .numberedList(let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(start + i).").monospacedDigit().foregroundStyle(.secondary)
                        Text(inline(item))
                    }
                }
            }
        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 4) {
                if let language {
                    Text(language).font(Theme.monoSmall).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(text).font(Theme.monoSmall).fixedSize()
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .quote(let text):
            Text(inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 2) }
        case .table(let header, let rows):
            if header.count <= 3 {
                table(header: header, rows: rows)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ScrollView(.horizontal, showsIndicators: false) { table(header: header, rows: rows) }
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
        case .rule:
            Divider()
        }
    }

    private func table(header: [String], rows: [[String]]) -> some View {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell)).font(.subheadline.weight(.semibold))
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(inline(cell)).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(10)
    }

    private func inline(_ text: String) -> AttributedString {
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        return Self.autolinked(parsed)
    }

    /// Makes bare URLs tappable too (agents often write `http://localhost:3000` without Markdown link syntax).
    static func autolinked(_ text: AttributedString) -> AttributedString {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
              let ns = try? NSMutableAttributedString(text, including: \.foundation) else { return text }
        let plain = ns.string
        var changed = false
        for match in detector.matches(in: plain, range: NSRange(location: 0, length: (plain as NSString).length)) {
            guard let url = match.url, ns.attribute(.link, at: match.range.location, effectiveRange: nil) == nil else { continue }
            ns.addAttribute(.link, value: url, range: match.range)
            changed = true
        }
        guard changed, let result = try? AttributedString(ns, including: \.foundation) else { return text }
        return result
    }
}
