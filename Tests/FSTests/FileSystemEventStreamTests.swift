import Testing
import Foundation
@testable import DeepFinder

/// Box to allow mutation from @Sendable closures in tests.
/// MockEventStream calls the handler synchronously on the injecting thread,
/// so there is no real concurrency — the box just satisfies Swift 6 checking.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@Suite("FileSystemEventStream")
struct FileSystemEventStreamTests {

    // MARK: - Protocol Conformance

    @Test("MockEventStream conforms to FileSystemEventStream protocol")
    func testProtocolConformance() {
        let stream: any FileSystemEventStream = MockEventStream()
        #expect(type(of: stream) == MockEventStream.self)
    }

    // MARK: - Start / Stop Lifecycle

    @Test("start sets isRunning to true")
    func testStartSetsIsRunning() {
        let stream = MockEventStream()
        #expect(!stream.isRunning)

        stream.start(paths: ["/tmp"]) { _ in }
        #expect(stream.isRunning)
    }

    @Test("stop clears isRunning to false")
    func testStopClearsIsRunning() {
        let stream = MockEventStream()
        stream.start(paths: ["/tmp"]) { _ in }
        #expect(stream.isRunning)

        stream.stop()
        #expect(!stream.isRunning)
    }

    @Test("stop without start does not crash")
    func testStopWithoutStartDoesNotCrash() {
        let stream = MockEventStream()
        stream.stop()
        #expect(!stream.isRunning)
    }

    // MARK: - Event Injection

    @Test("inject created event delivers to handler")
    func testInjectCreatedEvent() {
        let stream = MockEventStream()
        let received = Box<[(path: String, flags: FSEventStreamEventFlags)]>([])

        stream.start(paths: ["/tmp"]) { events in
            received.value = events
        }

        stream.inject(path: "/tmp/newfile.txt", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated))

        #expect(received.value.count == 1)
        #expect(received.value[0].path == "/tmp/newfile.txt")
        #expect(received.value[0].flags == FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated))
    }

    @Test("inject deleted event delivers to handler")
    func testInjectDeletedEvent() {
        let stream = MockEventStream()
        let received = Box<[(path: String, flags: FSEventStreamEventFlags)]>([])

        stream.start(paths: ["/tmp"]) { events in
            received.value = events
        }

        stream.inject(path: "/tmp/oldfile.txt", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved))

        #expect(received.value.count == 1)
        #expect(received.value[0].path == "/tmp/oldfile.txt")
    }

    @Test("inject multiple events delivers all to handler")
    func testInjectMultipleEvents() {
        let stream = MockEventStream()
        let allReceived = Box<[(path: String, flags: FSEventStreamEventFlags)]>([])

        stream.start(paths: ["/tmp"]) { events in
            allReceived.value.append(contentsOf: events)
        }

        stream.inject(path: "/tmp/a.txt", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated))
        stream.inject(path: "/tmp/b.txt", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved))
        stream.inject(path: "/tmp/c.txt", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified))

        #expect(allReceived.value.count == 3)
        #expect(allReceived.value[0].path == "/tmp/a.txt")
        #expect(allReceived.value[1].path == "/tmp/b.txt")
        #expect(allReceived.value[2].path == "/tmp/c.txt")
    }

    @Test("handler receives events via inject")
    func testHandlerReceivesEvents() {
        let stream = MockEventStream()
        let callCount = Box(0)

        stream.start(paths: ["/Users"]) { _ in
            callCount.value += 1
        }

        #expect(callCount.value == 0)

        stream.inject(path: "/Users/test/file.txt", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated))
        #expect(callCount.value == 1)

        stream.inject(path: "/Users/test/file2.txt", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated))
        #expect(callCount.value == 2)
    }

    // MARK: - Flag Parsing

    @Test("parse flags: ItemCreated maps to .created")
    func testParseFSEventFlagsCreated() {
        let events = FileEvent.from(flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated))
        #expect(events == [.created])
    }

    @Test("parse flags: ItemRemoved maps to .deleted")
    func testParseFSEventFlagsDeleted() {
        let events = FileEvent.from(flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved))
        #expect(events == [.deleted])
    }

    @Test("parse flags: ItemRenamed maps to .renamed")
    func testParseFSEventFlagsRenamed() {
        let events = FileEvent.from(flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed))
        #expect(events == [.renamed])
    }

    @Test("parse flags: ItemModified maps to .modified")
    func testParseFSEventFlagsModified() {
        let events = FileEvent.from(flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified))
        #expect(events == [.modified])
    }

    @Test("parse flags: ItemChangeOwner maps to .metadataChanged")
    func testParseFSEventFlagsMetadataChanged() {
        let events = FileEvent.from(flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemChangeOwner))
        #expect(events == [.metadataChanged])
    }

    @Test("parse flags: combined Created + Modified yields both events")
    func testParseFSEventFlagsCombined() {
        let flags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        let events = FileEvent.from(flags: flags)
        #expect(events == [.created, .modified])
    }
}
