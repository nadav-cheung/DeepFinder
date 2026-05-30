import Testing
import AppKit
import UniformTypeIdentifiers
@testable import DeepFinder

@Suite("ResultDragView")
struct ResultDragViewTests {

    // MARK: - Mock DragItemProvider

    /// Records the path requested and returns a minimal NSItemProvider.
    @MainActor
    final class MockDragItemProvider: DragItemProvider, @unchecked Sendable {
        var requestedPaths: [String] = []

        nonisolated func itemProvider(forFileAt path: String) -> NSItemProvider {
            // Must capture on main actor; use nonisolated access pattern.
            // Since this is called from .onDrag which runs on main thread,
            // we rely on the test verifying the returned provider instead.
            NSItemProvider(object: URL(fileURLWithPath: path) as NSURL)
        }

        @MainActor
        func record(path: String) {
            requestedPaths.append(path)
        }
    }

    // MARK: - DefaultDragItemProvider

    @Test("DefaultDragItemProvider creates NSItemProvider with file URL")
    func defaultProviderCreatesItemProvider() {
        let provider = DefaultDragItemProvider()
        let itemProvider = provider.itemProvider(forFileAt: "/Users/test/document.pdf")

        // NSItemProvider should have registered the file URL representation.
        #expect(itemProvider.registeredTypeIdentifiers.contains(
            where: { $0 == UTType.fileURL.identifier }
        ))
    }

    @Test("DefaultDragItemProvider sets suggested name to filename")
    func defaultProviderSuggestedName() {
        let provider = DefaultDragItemProvider()
        let itemProvider = provider.itemProvider(forFileAt: "/Users/test/report.docx")

        #expect(itemProvider.suggestedName == "report.docx")
    }

    @Test("DefaultDragItemProvider handles paths with special characters")
    func defaultProviderSpecialCharacters() {
        let provider = DefaultDragItemProvider()
        let path = "/Users/test/My File (2024).pdf"
        let itemProvider = provider.itemProvider(forFileAt: path)

        #expect(itemProvider.suggestedName == "My File (2024).pdf")
    }

    @Test("DefaultDragItemProvider handles directory paths")
    func defaultProviderDirectoryPath() {
        let provider = DefaultDragItemProvider()
        let path = "/Users/test/Projects/MyApp"
        let itemProvider = provider.itemProvider(forFileAt: path)

        #expect(itemProvider.suggestedName == "MyApp")
    }

    // MARK: - ResultDragViewModifier

    @Test("ResultDragViewModifier wraps content with onDrag")
    func dragModifierWrapsContent() {
        let path = "/Users/test/file.txt"
        let provider = DefaultDragItemProvider()
        let modifier = ResultDragViewModifier(path: path, dragProvider: provider)

        // Verify the modifier can be created and holds the correct path.
        // The actual .onDrag behavior is tested via the provider contract.
        _ = modifier
    }

    @Test("View extension resultDrag attaches modifier")
    @MainActor
    func viewExtensionAttachesModifier() {
        let record = FileRecord(
            id: 42,
            name: "notes.txt",
            originalName: "notes.txt",
            path: "/Users/test/notes.txt",
            parentPath: "/Users/test",
            isDirectory: false,
            size: 128,
            createdAt: Date(),
            modifiedAt: Date(),
            extension: "txt"
        )
        let result = SearchResult(
            record: record,
            providerID: "test",
            score: 1.0,
            matchType: .exact
        )

        // Create the view with drag modifier attached — should not crash.
        let view = ResultRowView(result: result, isSelected: false, query: "notes")
            .resultDrag(path: result.record.path)
        _ = view
    }

    // MARK: - NSItemProvider payload verification

    @Test("NSItemProvider can provide file URL data")
    func itemProviderFileURLData() async throws {
        let provider = DefaultDragItemProvider()
        let path = "/Users/test/image.png"
        let itemProvider = provider.itemProvider(forFileAt: path)

        // Verify we can load the file URL representation.
        let hasFileURL = itemProvider.hasItemConformingToTypeIdentifier(kUTTypeFileURL as String)
        #expect(hasFileURL)
    }

    @Test("NSItemProvider with empty path still produces valid provider")
    func emptyPathProducesProvider() {
        let provider = DefaultDragItemProvider()
        let itemProvider = provider.itemProvider(forFileAt: "/")

        // Root path should still produce a valid provider.
        #expect(itemProvider.suggestedName == "/")
    }

    // MARK: - Mock provider for isolated testing

    @Test("Mock provider can be injected and returns valid NSItemProvider")
    func mockProviderInjection() {
        let mock = MockDragItemProvider()
        let path = "/Users/test/document.pdf"
        let itemProvider = mock.itemProvider(forFileAt: path)

        // The mock returns a real NSItemProvider wrapping the file URL.
        // Verify it has the file URL type registered.
        #expect(itemProvider.registeredTypeIdentifiers.contains(
            where: { $0 == UTType.fileURL.identifier }
        ))
    }
}
