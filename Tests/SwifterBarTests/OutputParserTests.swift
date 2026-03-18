import Foundation
import Testing
@testable import SwifterBar

@Suite("OutputParser")
struct OutputParserTests {

    // MARK: - Basic Parsing

    @Test func parsesSimpleHeaderAndBody() {
        let output = "Hello World\n---\nItem 1\nItem 2"
        let items = OutputParser.parse(output)

        #expect(items.count == 3)
        #expect(items[0].text == "Hello World")
        #expect(items[0].isHeader == true)
        #expect(items[1].text == "Item 1")
        #expect(items[1].isHeader == false)
        #expect(items[2].text == "Item 2")
        #expect(items[2].isHeader == false)
    }

    @Test func parsesHeaderOnly() {
        let output = "Just a header"
        let items = OutputParser.parse(output)

        #expect(items.count == 1)
        #expect(items[0].text == "Just a header")
        #expect(items[0].isHeader == true)
    }

    @Test func parsesMultipleHeaders() {
        let output = "Header 1\nHeader 2\n---\nBody"
        let items = OutputParser.parse(output)

        #expect(items[0].isHeader == true)
        #expect(items[1].isHeader == true)
        #expect(items[2].isHeader == false)
    }

    @Test func parsesSeparatorsInBody() {
        let output = "Header\n---\nItem 1\n---\nItem 2"
        let items = OutputParser.parse(output)

        #expect(items.count == 4) // header, item1, separator, item2
        #expect(items[0].isHeader == true)
        #expect(items[1].text == "Item 1")
        #expect(items[2].isSeparator == true)
        #expect(items[3].text == "Item 2")
    }

    @Test func parsesEmptyOutput() {
        let items = OutputParser.parse("")
        #expect(items.isEmpty)
    }

    // MARK: - Parameter Parsing

    @Test func parsesColorParam() {
        let item = OutputParser.parseLine("Hello | color=#ff0000")
        #expect(item.text == "Hello")
        #expect(item.params.color == "#ff0000")
    }

    @Test func parsesDarkLightColors() {
        let item = OutputParser.parseLine("Hello | color=#ff0000,#00ff00")
        #expect(item.params.color == "#ff0000")
        #expect(item.params.colorDark == "#00ff00")
    }

    @Test func parsesSfimage() {
        let item = OutputParser.parseLine("Status | sfimage=wifi")
        #expect(item.params.sfimage == "wifi")
    }

    @Test func parsesHref() {
        let item = OutputParser.parseLine("Click me | href=https://example.com")
        #expect(item.params.href == "https://example.com")
    }

    @Test func parsesBashWithParams() {
        let item = OutputParser.parseLine("Run | bash=/usr/bin/echo param1=hello param2=world")
        #expect(item.params.bash == "/usr/bin/echo")
        #expect(item.params.bashParams == ["hello", "world"])
    }

    @Test func parsesRefresh() {
        let item = OutputParser.parseLine("Refresh | refresh=true")
        #expect(item.params.refresh == true)
    }

    @Test func parsesSize() {
        let item = OutputParser.parseLine("Big text | size=24")
        #expect(item.params.size == 24)
    }

    @Test func clampsSize() {
        let item = OutputParser.parseLine("Huge | size=999")
        #expect(item.params.size == 200)  // clamped to max 200
    }

    @Test func parsesFont() {
        let item = OutputParser.parseLine("Mono | font=Menlo")
        #expect(item.params.font == "Menlo")
    }

    @Test func parsesMultipleParams() {
        let item = OutputParser.parseLine("Hello | color=#ff0000 size=14 sfimage=star.fill")
        #expect(item.params.color == "#ff0000")
        #expect(item.params.size == 14)
        #expect(item.params.sfimage == "star.fill")
    }

    @Test func parsesQuotedValues() {
        let item = OutputParser.parseLine("Run | bash='/usr/bin/say' param1='hello world'")
        #expect(item.params.bash == "/usr/bin/say")
        #expect(item.params.bashParams == ["hello world"])
    }

    // MARK: - Input Validation

    @Test func stripsNullBytes() {
        let output = "Hello\0World\n---\nItem\0here"
        let items = OutputParser.parse(output)

        #expect(items[0].text == "HelloWorld")
        #expect(items[1].text == "Itemhere")
    }

    @Test func enforcesMaxLineCount() {
        var lines: [String] = []
        for i in 0..<600 {
            lines.append("Line \(i)")
        }
        let output = lines.joined(separator: "\n")
        let items = OutputParser.parse(output)

        #expect(items.count == 500)  // capped at maxLineCount
    }

    @Test func handlesLineWithNoParams() {
        let item = OutputParser.parseLine("Just plain text")
        #expect(item.text == "Just plain text")
        #expect(item.params == .empty)
    }

    @Test func handlesPipeInText() {
        // Pipe with spaces around it separates params
        let item = OutputParser.parseLine("CPU: 50% | color=red")
        #expect(item.text == "CPU: 50%")
        #expect(item.params.color == "red")
    }
}

@Suite("Nested Submenus")
struct NestedSubmenuTests {

    @Test func parsesSubmenuDepth() {
        let output = "Header\n---\nTop item\n--Sub item\n----Sub-sub item"
        let items = OutputParser.parse(output)

        #expect(items[0].isHeader == true)
        #expect(items[1].text == "Top item")
        #expect(items[1].depth == 0)
        #expect(items[2].text == "Sub item")
        #expect(items[2].depth == 1)
        #expect(items[3].text == "Sub-sub item")
        #expect(items[3].depth == 2)
    }

    @Test func submenuDepthOnlyInBody() {
        let output = "--Not a submenu\n---\n--This is a submenu"
        let items = OutputParser.parse(output)

        // In header, -- is literal text
        #expect(items[0].text == "--Not a submenu")
        #expect(items[0].depth == 0)
        // In body, -- indicates submenu
        #expect(items[1].text == "This is a submenu")
        #expect(items[1].depth == 1)
    }

    @Test func submenuWithParams() {
        let output = "Header\n---\n--Sub item | color=#ff0000"
        let items = OutputParser.parse(output)

        #expect(items[1].text == "Sub item")
        #expect(items[1].depth == 1)
        #expect(items[1].params.color == "#ff0000")
    }
}

@Suite("Metadata Parsing")
struct MetadataTests {

    @Test func parsesMetadataFromContent() {
        // Create a temp file with metadata
        let content = """
        #!/bin/bash
        # <swiftbar.title>My Plugin</swiftbar.title>
        # <swiftbar.author>Test Author</swiftbar.author>
        # <swiftbar.type>streamable</swiftbar.type>
        # <swiftbar.alwaysVisible>true</swiftbar.alwaysVisible>
        echo "hello"
        """
        let tempURL = FileManager.default.temporaryDirectory.appending(path: "test_meta_\(UUID()).sh")
        try! content.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let meta = PluginMetadata.parse(from: tempURL)
        #expect(meta.title == "My Plugin")
        #expect(meta.author == "Test Author")
        #expect(meta.type == "streamable")
        #expect(meta.isStreamable == true)
        #expect(meta.alwaysVisible == true)
    }

    @Test func returnsEmptyMetadataForNonexistentFile() {
        let url = URL(filePath: "/nonexistent/path/plugin.sh")
        let meta = PluginMetadata.parse(from: url)
        #expect(meta.title == nil)
        #expect(meta.isStreamable == false)
    }
}

@Suite("Plugin Filename Parsing")
struct PluginFilenameTests {

    @Test func parsesBasicFilename() {
        let result = Plugin.parseFilename("weather.5s.sh")
        #expect(result?.name == "weather")
        #expect(result?.interval == .seconds(5))
        #expect(result?.ext == "sh")
    }

    @Test func parsesMinuteInterval() {
        let result = Plugin.parseFilename("status.2m.py")
        #expect(result?.interval == .seconds(120))
    }

    @Test func parsesHourInterval() {
        let result = Plugin.parseFilename("daily.1h.rb")
        #expect(result?.interval == .seconds(3600))
    }

    @Test func parsesDayInterval() {
        let result = Plugin.parseFilename("report.1d.sh")
        #expect(result?.interval == .seconds(86400))
    }

    @Test func parsesMillisecondInterval() {
        let result = Plugin.parseFilename("fast.500ms.sh")
        // 500ms is below 5s minimum, should be clamped to 5s
        #expect(result?.interval == .seconds(5))
    }

    @Test func clampsMinimumInterval() {
        let result = Plugin.parseFilename("quick.1s.sh")
        #expect(result?.interval == .seconds(5))  // clamped to min 5s
    }

    @Test func rejectsInvalidFilename() {
        #expect(Plugin.parseFilename("nointerval.sh") == nil)
        #expect(Plugin.parseFilename("bad") == nil)
    }

    @Test func rejectsInvalidInterval() {
        #expect(Plugin.parseFilename("test.abc.sh") == nil)
        #expect(Plugin.parseFilename("test.0s.sh") == nil)
    }

    @Test func parsesMultiDotName() {
        let result = Plugin.parseFilename("my.plugin.name.10s.sh")
        // The interval is the second-to-last part
        #expect(result?.interval == .seconds(10))
        #expect(result?.ext == "sh")
    }
}
