import Testing
@testable import CopilotChat

@Suite("MarkdownParser")
struct MarkdownParserTests {

    // MARK: - Headings

    @Test("Parses h1 through h6")
    func headings() {
        #expect(MarkdownParser.parse("# Title") == [.heading(level: 1, text: "Title")])
        #expect(MarkdownParser.parse("## Sub") == [.heading(level: 2, text: "Sub")])
        #expect(MarkdownParser.parse("###### Deep") == [.heading(level: 6, text: "Deep")])
    }

    @Test("Rejects headings without space after #")
    func headingNoSpace() {
        #expect(MarkdownParser.parse("#NoSpace") == [.paragraph("#NoSpace")])
    }

    @Test("Rejects more than 6 hashes")
    func headingTooManyHashes() {
        #expect(MarkdownParser.parse("####### Seven") == [.paragraph("####### Seven")])
    }

    // MARK: - Code Blocks

    @Test("Parses fenced code block with language")
    func codeBlockWithLanguage() {
        let input = "```swift\nlet x = 1\n```"
        #expect(MarkdownParser.parse(input) == [.codeBlock(language: "swift", code: "let x = 1")])
    }

    @Test("Parses fenced code block without language")
    func codeBlockNoLanguage() {
        let input = "```\nhello\nworld\n```"
        #expect(MarkdownParser.parse(input) == [.codeBlock(language: nil, code: "hello\nworld")])
    }

    @Test("Handles unclosed code block")
    func unclosedCodeBlock() {
        let input = "```\ncode without close"
        let blocks = MarkdownParser.parse(input)
        #expect(blocks.count == 1)
        if case .codeBlock(_, let code) = blocks[0] {
            #expect(code == "code without close")
        } else {
            Issue.record("Expected codeBlock")
        }
    }

    // MARK: - Lists

    @Test("Parses unordered list with dash")
    func unorderedListDash() {
        let input = "- One\n- Two\n- Three"
        #expect(MarkdownParser.parse(input) == [.unorderedList(["One", "Two", "Three"])])
    }

    @Test("Parses unordered list with asterisk")
    func unorderedListAsterisk() {
        let input = "* Alpha\n* Beta"
        #expect(MarkdownParser.parse(input) == [.unorderedList(["Alpha", "Beta"])])
    }

    @Test("Parses ordered list")
    func orderedList() {
        let input = "1. First\n2. Second\n3. Third"
        let blocks = MarkdownParser.parse(input)
        #expect(blocks.count == 1)
        if case .orderedList(let items) = blocks[0] {
            #expect(items.count == 3)
            #expect(items[0].1 == "First")
            #expect(items[2].1 == "Third")
        } else {
            Issue.record("Expected orderedList")
        }
    }

    // MARK: - Blockquotes

    @Test("Parses blockquote")
    func blockquote() {
        let input = "> Line one\n> Line two"
        #expect(MarkdownParser.parse(input) == [.blockquote("Line one\nLine two")])
    }

    // MARK: - Horizontal Rule

    @Test("Parses horizontal rules")
    func horizontalRules() {
        #expect(MarkdownParser.parse("---") == [.horizontalRule])
        #expect(MarkdownParser.parse("***") == [.horizontalRule])
        #expect(MarkdownParser.parse("___") == [.horizontalRule])
    }

    @Test("Rejects mixed chars as horizontal rule")
    func notHorizontalRule() {
        #expect(MarkdownParser.parse("-*-") == [.paragraph("-*-")])
    }

    // MARK: - Paragraphs

    @Test("Parses plain text as paragraph")
    func paragraph() {
        #expect(MarkdownParser.parse("Hello world") == [.paragraph("Hello world")])
    }

    @Test("Joins consecutive lines into one paragraph")
    func multiLineParagraph() {
        let input = "Line one\nLine two\nLine three"
        #expect(MarkdownParser.parse(input) == [.paragraph("Line one\nLine two\nLine three")])
    }

    @Test("Splits paragraphs on blank lines")
    func paragraphSplit() {
        let input = "Para one\n\nPara two"
        #expect(MarkdownParser.parse(input) == [.paragraph("Para one"), .paragraph("Para two")])
    }

    // MARK: - Mixed Content

    @Test("Parses mixed markdown document")
    func mixedContent() {
        let input = """
        # Title

        Some text here.

        - Item A
        - Item B

        ```python
        print("hi")
        ```

        > A quote

        ---

        End.
        """
        let blocks = MarkdownParser.parse(input)
        #expect(blocks.count == 7)
        #expect(blocks[0] == .heading(level: 1, text: "Title"))
        #expect(blocks[1] == .paragraph("Some text here."))
        #expect(blocks[2] == .unorderedList(["Item A", "Item B"]))
        if case .codeBlock(let lang, let code) = blocks[3] {
            #expect(lang == "python")
            #expect(code == "print(\"hi\")")
        }
        #expect(blocks[4] == .blockquote("A quote"))
        #expect(blocks[5] == .horizontalRule)
        #expect(blocks[6] == .paragraph("End."))
    }

    // MARK: - Edge Cases

    @Test("Handles empty string")
    func emptyInput() {
        #expect(MarkdownParser.parse("").isEmpty)
    }

    @Test("Handles only whitespace")
    func whitespaceOnly() {
        #expect(MarkdownParser.parse("   \n  \n   ").isEmpty)
    }

    // MARK: - Line Classifiers

    @Test("isUnorderedListItem")
    func listItemClassifier() {
        #expect(MarkdownParser.isUnorderedListItem("- item"))
        #expect(MarkdownParser.isUnorderedListItem("* item"))
        #expect(MarkdownParser.isUnorderedListItem("+ item"))
        #expect(!MarkdownParser.isUnorderedListItem("-no space"))
        #expect(!MarkdownParser.isUnorderedListItem("not a list"))
    }

    @Test("isOrderedListItem")
    func orderedListClassifier() {
        #expect(MarkdownParser.isOrderedListItem("1. item"))
        #expect(MarkdownParser.isOrderedListItem("99. item"))
        #expect(!MarkdownParser.isOrderedListItem("1.no space"))
        #expect(!MarkdownParser.isOrderedListItem("a. item"))
    }

    // MARK: - Performance

    @Test("Parses large document without timeout")
    func performance() {
        var lines: [String] = []
        for i in 0..<1000 {
            lines.append("This is line number \(i) with some **bold** and *italic* text.")
        }
        let input = lines.joined(separator: "\n")
        let blocks = MarkdownParser.parse(input)
        #expect(!blocks.isEmpty)
    }
}
