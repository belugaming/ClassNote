import XCTest
@testable import ClassNote

/// The transcript budgeting the local-model note/Q&A paths depend on. Pure
/// string work, so these run anywhere — no database, no sidecar, no network.
final class TranscriptChunkerTests: XCTestCase {
    /// A transcript is one segment per line; a chunk that starts mid-sentence
    /// would make the model summarize half a thought.
    func testSplitsOnLineBoundaries() {
        let lines = (1...20).map { "[00:\(String(format: "%02d", $0))] line number \($0)" }
        let text = lines.joined(separator: "\n")
        let chunks = TranscriptChunker.split(text: text, maxChars: 80)

        XCTAssertGreaterThan(chunks.count, 1)
        // Rejoining the chunks must reproduce the transcript exactly.
        XCTAssertEqual(chunks.joined(separator: "\n"), text)
        for chunk in chunks {
            for line in chunk.split(separator: "\n") {
                XCTAssertTrue(lines.contains(String(line)), "chunk cut a line in half: \(line)")
            }
        }
    }

    func testChunksNeverExceedTheBudget() {
        let text = (1...200).map { "segment \($0) with a few more words of lecture text" }
            .joined(separator: "\n")
        for budget in [60, 120, 500, 4000] {
            for chunk in TranscriptChunker.split(text: text, maxChars: budget) {
                XCTAssertLessThanOrEqual(chunk.count, budget)
            }
        }
    }

    /// A single line longer than the whole budget still has to be split, or the
    /// chunk it lands in blows the context it was meant to fit.
    func testOverlongSingleLineIsStillSplit() {
        let line = String(repeating: "字", count: 500)
        let chunks = TranscriptChunker.split(text: line, maxChars: 100)

        XCTAssertEqual(chunks.count, 5)
        XCTAssertEqual(chunks.joined(), line)
        for chunk in chunks { XCTAssertLessThanOrEqual(chunk.count, 100) }
    }

    func testTextWithinBudgetIsOneChunk() {
        let text = "one\ntwo\nthree"
        XCTAssertEqual(TranscriptChunker.split(text: text, maxChars: 1000), [text])
    }

    func testEmptyInputProducesNoChunks() {
        XCTAssertTrue(TranscriptChunker.split(text: "", maxChars: 100).isEmpty)
        let (text, wasTruncated) = TranscriptChunker.truncate(text: "", maxChars: 100)
        XCTAssertEqual(text, "")
        XCTAssertFalse(wasTruncated)
    }

    func testTruncateLeavesShortTextAlone() {
        let text = "short transcript"
        let (out, wasTruncated) = TranscriptChunker.truncate(text: text, maxChars: 100)
        XCTAssertEqual(out, text)
        XCTAssertFalse(wasTruncated)
    }

    /// The last minutes of a lecture carry the summary and the assignment, so
    /// truncation keeps the tail as well as the head.
    func testTruncateKeepsHeadAndTail() {
        let head = String(repeating: "H", count: 400)
        let tail = String(repeating: "T", count: 400)
        let (out, wasTruncated) = TranscriptChunker.truncate(text: head + tail, maxChars: 400)

        XCTAssertTrue(wasTruncated)
        XCTAssertLessThanOrEqual(out.count, 400)
        XCTAssertTrue(out.hasPrefix("H"))
        XCTAssertTrue(out.hasSuffix("T"))
        XCTAssertTrue(out.contains("omitted"), "the elision must be visible to the model")
    }

    /// With no room for head, marker and tail, keeping the head alone beats
    /// emitting a marker and nothing else.
    func testTruncateWithNoRoomForTheMarkerKeepsTheHead() {
        let text = String(repeating: "x", count: 200)
        let (out, wasTruncated) = TranscriptChunker.truncate(text: text, maxChars: 10)

        XCTAssertTrue(wasTruncated)
        XCTAssertEqual(out, String(repeating: "x", count: 10))
    }
}

/// The search-hit → transcript contract between `SearchResultsView` and
/// `SessionDetailView`.
final class SegmentJumpTargetTests: XCTestCase {
    /// Two clicks on the same hit must be two distinct values, or SwiftUI's
    /// `.onChange` sees no change and the second click does nothing.
    func testEveryTargetIsDistinct() {
        let first = SegmentJumpTarget(sessionId: "s1", segmentId: 7, startMs: 1_000)
        let second = SegmentJumpTarget(sessionId: "s1", segmentId: 7, startMs: 1_000)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, first)
        XCTAssertEqual(first.segmentId, 7)
        XCTAssertEqual(first.sessionId, "s1")
        XCTAssertEqual(first.startMs, 1_000)
    }

    /// `ScrollViewProxy.scrollTo` matches the id type exactly, so the transcript
    /// `ForEach` is keyed on this non-optional value rather than `Segment.id`.
    func testRowKeyIsNonOptional() {
        var segment = Segment(id: nil,
                              sessionId: "s1",
                              startMs: 0,
                              endMs: 1_000,
                              speakerId: nil,
                              textOriginal: "hello",
                              textTranslated: "",
                              isFinal: true,
                              confidence: 1,
                              version: 1)
        XCTAssertEqual(segment.rowKey, -1)
        segment.id = 42
        XCTAssertEqual(segment.rowKey, 42)
    }
}
