import Foundation
import Testing
@testable import SpeakUp

/// How the annotated transcript turns words and events into what it draws.
struct TranscriptLayoutTests {
    private func marks(_ token: TranscriptToken) -> [String] {
        guard case .word(_, _, _, let marks) = token else { return [] }
        return marks.map(\.event.id)
    }

    @Test func contractAnalysisLaysOutWordsAndPauses() throws {
        let analysis = try Fixture.decode(Analysis.self, "analysis")
        let tokens = TranscriptLayout.tokens(for: analysis)

        // 18 words, plus the block before word 9 and the boundary pause before word 14.
        #expect(tokens.count == 20)
        #expect(tokens.map(\.id) == [
            "w0", "w1", "w2", "w3", "w4", "w5", "w6", "w7", "w8", "pe3", "w9", "w10", "w11",
            "w12", "w13", "pe4", "w14", "w15", "w16", "w17",
        ])
        #expect(Set(tokens.map(\.id)).count == tokens.count)

        let byID = Dictionary(uniqueKeysWithValues: tokens.map { ($0.id, $0) })
        #expect(marks(byID["w1"]!) == ["e0"])
        #expect(marks(byID["w2"]!) == ["e1"])
        #expect(marks(byID["w3"]!) == ["e1"])
        #expect(marks(byID["w4"]!) == [])
        #expect(marks(byID["w8"]!) == ["e2"])
        #expect(marks(byID["w14"]!) == ["e5"])
        #expect(marks(byID["w15"]!) == ["e6"])
        #expect(marks(byID["w16"]!) == ["e6"])
        #expect(marks(byID["w17"]!) == [])

        guard case .pause(let block) = byID["pe3"]!, case .pause(let boundary) = byID["pe4"]! else {
            Issue.record("Expected pauses")
            return
        }
        #expect(block.kind == .block)
        #expect(block.title == "Block, 1.1 s")
        #expect(boundary.kind == .boundaryPause)
        #expect(boundary.explanation.contains("normal"))
    }

    @Test func eventsOutsideTheWordListAreDropped() throws {
        // The contract example's off_topic event covers words 74 to 121 of a longer take.
        let analysis = try Fixture.decode(Analysis.self, "analysis")
        let tokens = TranscriptLayout.tokens(for: analysis)
        #expect(!tokens.flatMap(marks).contains("c0"))
        #expect(TranscriptLayout.kindsPresent(in: analysis) == [
            .filler, .repetition, .restart, .block, .boundaryPause, .offTopic,
        ])
    }

    @Test func coachingNoteWinsOverTheGenericExplanation() throws {
        let analysis = try Fixture.decode(Analysis.self, "analysis")
        let offTopic = try #require(analysis.events.first { $0.id == "c0" })
        let mark = TranscriptMark(event: offTopic, kind: .offTopic)
        #expect(mark.explanation.hasPrefix("The story about the old team"))
    }

    @Test func lexicalFillerRuledNotAFillerIsUnmarked() throws {
        var object = Fixture.object("analysis")
        var events = object["events"] as! [[String: Any]]
        events[2]["is_filler"] = false
        object["events"] = events
        let analysis = try Fixture.decode(Analysis.self, object: object)
        let tokens = TranscriptLayout.tokens(for: analysis)
        #expect(marks(tokens[8]) == [])
        #expect(TranscriptLayout.fillers(in: analysis).map(\.text) == ["um", "Uh"])
    }

    @Test func countedFillersCarryTheirWords() throws {
        let analysis = try Fixture.decode(Analysis.self, "analysis")
        let fillers = TranscriptLayout.fillers(in: analysis)
        #expect(fillers.map(\.text) == ["um", "like,", "Uh"])
        #expect(fillers.map(\.event.start) == [1.1, 4.0, 7.8])
    }

    @Test func unknownEventTypesShowAsPlainText() throws {
        var object = Fixture.object("analysis")
        var events = object["events"] as! [[String: Any]]
        events[0]["type"] = "throat_clear"
        object["events"] = events
        let analysis = try Fixture.decode(Analysis.self, object: object)
        let tokens = TranscriptLayout.tokens(for: analysis)
        #expect(marks(tokens[1]) == [])
    }

    @Test func pauseAfterTheLastWordIsKept() throws {
        var object = Fixture.object("analysis")
        var events = object["events"] as! [[String: Any]]
        events[4]["word_start"] = 18
        events[4]["word_end"] = 18
        object["events"] = events
        let analysis = try Fixture.decode(Analysis.self, object: object)
        let tokens = TranscriptLayout.tokens(for: analysis)
        #expect(tokens.last?.id == "pe4")
    }
}
