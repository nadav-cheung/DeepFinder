import Testing
import Foundation
@testable import DeepFinderIndex

@Suite("CIndex path hash")
struct CIndexHashResizeTests {

    @Test("Small-cap constructor builds a working index")
    func smallCapConstructorWorks() async {
        let index = InMemoryIndex(pathHashCap: 16)
        await index.insert(
            name: "hello.txt",
            path: "/tmp/hello.txt",
            parentPath: "/tmp",
            isDirectory: false,
            extension: "txt"
        )
        let results = await index.searchSubstring(query: "hello")
        #expect(results.count == 1)
        #expect(results.first?.path == "/tmp/hello.txt")
    }
}
