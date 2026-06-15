// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Testing
import Foundation
@testable import DeepFinderCLILib
import DeepFinderDaemon

@Suite("DuplicateCommand detection")
struct DuplicateCommandTests {

    @Test("bare keywords map to strategies")
    func bareKeywords() {
        #expect(DuplicateCommand.detect("dupe") == .name)
        #expect(DuplicateCommand.detect("sizedupe") == .size)
        #expect(DuplicateCommand.detect("hashdupe") == .hash)
        #expect(DuplicateCommand.detect("empty") == .empty)
    }

    @Test("colon form maps to strategies")
    func colonForm() {
        #expect(DuplicateCommand.detect("dupe:") == .name)
        #expect(DuplicateCommand.detect("sizedupe:") == .size)
        #expect(DuplicateCommand.detect("hashdupe:") == .hash)
        #expect(DuplicateCommand.detect("empty:") == .empty)
    }

    @Test("trailing tokens ignored — whole-index scan")
    func trailingTokens() {
        #expect(DuplicateCommand.detect("dupe: ext:pdf") == .name)
        #expect(DuplicateCommand.detect("dupe  ") == .name)
    }

    @Test("case-insensitive")
    func caseInsensitive() {
        #expect(DuplicateCommand.detect("DUPE") == .name)
        #expect(DuplicateCommand.detect("SizeDupe:") == .size)
    }

    @Test("sizedupe/hashdupe not shadowed by dupe")
    func noShadowing() {
        #expect(DuplicateCommand.detect("sizedupe") == .size)
        #expect(DuplicateCommand.detect("hashdupe:") == .hash)
    }

    @Test("regular queries return nil")
    func regularQueries() {
        #expect(DuplicateCommand.detect("report") == nil)
        #expect(DuplicateCommand.detect("ext:pdf") == nil)
        #expect(DuplicateCommand.detect("") == nil)
        #expect(DuplicateCommand.detect("dupes") == nil)  // not an exact keyword
    }
}
