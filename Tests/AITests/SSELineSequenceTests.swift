import Foundation
import Testing
@testable import DeepFinderAI

@Suite("SSELineSequence")
struct SSELineSequenceTests {

    // MARK: - Basic single-line SSE

    @Test("Basic single-line SSE yields one line")
    func basicSingleLine() async {
        let data = Data("data: hello\n\n".utf8)
        let lines = await collect(SSELineSequence(data: data))
        #expect(lines == ["data: hello"])
    }

    // MARK: - Multiple events

    @Test("Multiple SSE events yield multiple lines")
    func multipleEvents() async {
        let data = Data("data: a\n\ndata: b\n\n".utf8)
        let lines = await collect(SSELineSequence(data: data))
        #expect(lines == ["data: a", "data: b"])
    }

    // MARK: - Lines without data: prefix are not filtered

    @Test("Lines without data: prefix are still yielded")
    func linesWithoutDataPrefix() async {
        let input = "event: ping\ndata: hello\n\n"
        let data = Data(input.utf8)
        let lines = await collect(SSELineSequence(data: data))
        #expect(lines == ["event: ping", "data: hello"])
    }

    // MARK: - [DONE] sentinel

    @Test("[DONE] sentinel is yielded as a line")
    func doneSentinel() async {
        let data = Data("data: hello\n\ndata: [DONE]\n\n".utf8)
        let lines = await collect(SSELineSequence(data: data))
        #expect(lines == ["data: hello", "data: [DONE]"])
    }

    // MARK: - Empty input

    @Test("Empty input yields no lines")
    func emptyInput() async {
        let data = Data("".utf8)
        let lines = await collect(SSELineSequence(data: data))
        #expect(lines.isEmpty)
    }

    // MARK: - Only blank lines

    @Test("Only blank lines yields no lines")
    func onlyBlankLines() async {
        let data = Data("\n\n\n".utf8)
        let lines = await collect(SSELineSequence(data: data))
        #expect(lines.isEmpty)
    }

    // MARK: - Partial line (no trailing newline)

    @Test("Partial line without trailing newline is still yielded")
    func partialLine() async {
        let data = Data("data: partial".utf8)
        let lines = await collect(SSELineSequence(data: data))
        #expect(lines == ["data: partial"])
    }

    // MARK: - Lines with trailing whitespace are trimmed

    @Test("Trailing whitespace is trimmed from lines")
    func trailingWhitespaceTrimmed() async {
        let data = Data("data: hello   \n   \n".utf8)
        let lines = await collect(SSELineSequence(data: data))
        #expect(lines == ["data: hello"])
    }

    // MARK: - Helper

    /// Collects all elements from an AsyncSequence into an array.
    private func collect(_ seq: SSELineSequence) async -> [String] {
        var result: [String] = []
        for await line in seq {
            result.append(line)
        }
        return result
    }
}
