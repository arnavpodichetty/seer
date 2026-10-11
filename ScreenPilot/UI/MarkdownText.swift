import SwiftUI

/// Renders the Markdown that answers use: headings, bullet and numbered lists,
/// paragraphs with inline styling (bold, italic, `code`), and fenced code blocks.
struct MarkdownText: View {
    let text: String
    var font: Font = .body

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case numbered(String, String)
        case code(String, language: String?)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { index, block in
                view(for: block, isFirst: index == 0)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: Block, isFirst: Bool) -> some View {
        switch block {
        case let .heading(level, content):
            Text(Self.inline(content))
                .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, isFirst ? 0 : 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .paragraph(content):
            Text(Self.inline(content))
                .font(font)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .bullet(content):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").font(font).foregroundStyle(.secondary)
                Text(Self.inline(content)).font(font).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case let .numbered(marker, content):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).font(font.monospacedDigit()).foregroundStyle(.secondary)
                Text(Self.inline(content)).font(font).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case let .code(content, language):
            CodeBlock(code: content, language: language)
        }
    }

    // MARK: - Parsing

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String] = []
        var language: String?
        var inCode = false

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph.removeAll()
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(code.joined(separator: "\n"), language: language))
                    code.removeAll()
                    inCode = false
                } else {
                    flushParagraph()
                    let lang = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = lang.isEmpty ? nil : lang
                    inCode = true
                }
                continue
            }
            if inCode {
                code.append(rawLine)
                continue
            }
            if line.isEmpty {
                flushParagraph()
            } else if let heading = headingMatch(line) {
                flushParagraph()
                blocks.append(heading)
            } else if let item = listMatch(line) {
                flushParagraph()
                blocks.append(item)
            } else {
                paragraph.append(line)
            }
        }
        if inCode, !code.isEmpty { blocks.append(.code(code.joined(separator: "\n"), language: language)) }
        flushParagraph()
        return blocks
    }

    private static func headingMatch(_ line: String) -> Block? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
            return .heading(level: hashes, text: line.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
        }
        // A line that is entirely bold ("**Situation**" or "**Situation:**") acts as a heading.
        if line.hasPrefix("**"), line.hasSuffix("**") || line.hasSuffix("**:"), line.count > 4 {
            let inner = line.trimmingCharacters(in: CharacterSet(charactersIn: "*:"))
            if !inner.isEmpty, !inner.contains("**"), inner.count <= 60 { return .heading(level: 3, text: inner) }
        }
        return nil
    }

    private static func listMatch(_ line: String) -> Block? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            return .bullet(String(line.dropFirst(marker.count)))
        }
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 2 {
            let rest = line.dropFirst(digits.count)
            if let punct = rest.first, punct == "." || punct == ")", rest.dropFirst().first == " " {
                return .numbered(digits + ".", String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    static func inline(_ string: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: string, options: options)) ?? AttributedString(string)
    }
}

private struct CodeBlock: View {
    let code: String
    let language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.uppercased() ?? "CODE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
                    .textSelection(.enabled)
            }
        }
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
