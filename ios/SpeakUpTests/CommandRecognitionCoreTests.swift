import Foundation
import Testing
@testable import SpeakUp

/// The recognizer's pure decisions: results to spotter updates, and when to finalize.
struct CommandRecognitionCoreTests {
    typealias Word = CommandSpotter.TimedWord
    typealias Core = CommandRecognitionCore

    /// `Config.engineLag`: a finalization waits until the input is this far past its time.
    private let lag = 1.5

    private func final(_ words: [Word], range: ClosedRange<Double>, finalizedThrough: Double? = nil) -> RecognizedResult {
        RecognizedResult(
            text: words.map(\.text).joined(separator: " "), timedWords: words, range: range, isFinal: true,
            finalizedThrough: finalizedThrough ?? range.upperBound)
    }

    /// A volatile result as `SpeechAnalyzer` gives it: one run for the whole text.
    private func volatile(_ text: String, range: ClosedRange<Double>, finalizedThrough: Double = 0) -> RecognizedResult {
        RecognizedResult(
            text: text, timedWords: text.isEmpty ? [] : [Word(text, start: range.lowerBound, end: range.upperBound)],
            range: range, isFinal: false, finalizedThrough: finalizedThrough)
    }

    /// A core listening from `start`, whose window-start finalization has completed.
    private func listening(_ mode: CommandSpotter.Mode, from start: Double = 0, fedTo fed: Double = 0) -> Core {
        var core = Core()
        core.listen(mode: mode, from: start)
        _ = core.fed(through: fed)
        core.finalized(through: start)
        return core
    }

    private func finalizes(_ actions: [Core.Action]) -> [Double] {
        actions.compactMap {
            if case .finalize(let time) = $0 { return time }
            return nil
        }
    }

    private func updates(_ actions: [Core.Action]) -> [CommandSpotter.Update] {
        actions.compactMap {
            if case .update(let update) = $0 { return update }
            return nil
        }
    }

    /// A core and a spotter listening together, as the drive loop runs them.
    private struct Pair {
        var core: Core
        var spotter = CommandSpotter()

        init(_ mode: CommandSpotter.Mode, core: Core) {
            self.core = core
            spotter.listen(mode: mode, from: 0)
        }

        mutating func receive(_ result: RecognizedResult) -> [CommandSpotter.Event] {
            give(core.receive(result))
        }

        mutating func give(_ actions: [Core.Action]) -> [CommandSpotter.Event] {
            actions.flatMap { action -> [CommandSpotter.Event] in
                guard case .update(let update) = action else { return [] }
                return spotter.receive(update)
            }
        }
    }

    // MARK: Updates

    @Test func aFinalGivesItsTimedWordsCoveringItsRangeWithItsEndAsProgress() {
        var core = Core()
        let words = [Word("Well,", start: 1, end: 1.4), Word(".", start: 1.4, end: 1.5), Word("done.", start: 2, end: 2.4)]
        let actions = core.receive(final(words, range: 0.9...2.6, finalizedThrough: 2.6))
        #expect(
            actions == [
                .update(
                    .init(
                        words: [Word("Well,", start: 1, end: 1.4), Word("done.", start: 2, end: 2.4)], isFinal: true,
                        covering: 0.9...2.6, progress: 2.6))
            ])
    }

    /// A volatile range runs to the end of the audio the engine processed, past its words, so
    /// it retracts from its start but never claims the silence after them.
    @Test func aVolatileRetractsFromItsStartAndTakesProgressOnlyFromTheFinalizationTime() {
        var core = Core()
        #expect(
            core.receive(volatile("so that is", range: 3...4.2, finalizedThrough: 3)) == [
                .update(.init(words: [Word("so that is", start: 3, end: 4.2)], isFinal: false, covering: 3...3, progress: 3))
            ])
        #expect(
            core.receive(volatile("", range: 3...4.6, finalizedThrough: 3)) == [
                .update(.init(words: [], isFinal: false, covering: 3...3, progress: 3))
            ])
    }

    /// The reviewer's `stop-sentence` trace: a volatile "Stop." spanning audio where "at the
    /// next" was already said must not close the utterance.
    @Test func aVolatileRangeDoesNotCloseAnUtterance() {
        var pair = Pair(.betweenTakes, core: listening(.betweenTakes))
        #expect(pair.receive(volatile("Stop.", range: 0...1.64)).isEmpty)
        #expect(pair.receive(final([Word("Stop.", start: 0.32, end: 0.8)], range: 0.32...0.86)).isEmpty)
    }

    @Test func donIsNotDone() {
        let result = final([Word("answer,", start: 5.6, end: 6.1), Word("Don.", start: 6.1, end: 6.8)], range: 0...7.5)
        #expect(Core.words(in: result) == result.timedWords)
        var core = listening(.recording)
        _ = core.receive(volatile("my answer, Don", range: 0...3))
        #expect(finalizes(core.fed(through: 10)).isEmpty)
    }

    /// `SpeechTranscriber` ran "trade-offs." from 1.04 s to the end of its result at 2.54 s;
    /// the speech ended at 1.72 s. Only a last word that reaches the end of a final is trimmed.
    @Test func theLastWordOfAFinalIsTrimmedToAPlausibleLength() {
        var core = Core()
        let words = [Word("covers", start: 0.6, end: 1.4), Word("trade-offs.", start: 1.4, end: 2.54)]
        let actions = core.receive(final(words, range: 0...2.6))
        #expect(updates(actions).first?.words == [Word("covers", start: 0.6, end: 1.4), Word("trade-offs.", start: 1.4, end: 1.9)])
        // Not at the end of the result, or short enough: left alone.
        #expect(Core.trimmingStretchedEnd(of: words, in: 0...3, longest: 0.5) == words)
        #expect(Core.trimmingStretchedEnd(of: words, in: 0...2.6, longest: 2) == words)
    }

    // MARK: What a final leaves of the volatile text

    /// A volatile result often runs into the silence after the last word, and the spotter
    /// spreads its words over that range. A final that covers less clears the rest.
    @Test func aFinalClearsTheRestOfTheVolatileRange() {
        var pair = Pair(.betweenTakes, core: listening(.betweenTakes))
        #expect(pair.receive(volatile("what is the weather today", range: 0.6...4.1)).isEmpty)
        let today = [
            Word("What", start: 0.9, end: 1.2), Word("is", start: 1.2, end: 1.4), Word("the", start: 1.4, end: 1.6),
            Word("weather", start: 1.6, end: 2.4), Word("today?", start: 2.4, end: 2.9),
        ]
        let actions = pair.core.receive(final(today, range: 0.9...3))
        #expect(updates(actions).last == .init(words: [], isFinal: false, covering: 3...3))
        #expect(pair.give(actions).isEmpty)
        // Without the clearing, the volatile "today", spread to 4.1 s, would hold the utterance open.
        #expect(pair.spotter.advance(progress: 3.7) == [.unrecognizedSpeech])
    }

    @Test func wordsAfterTheFinalAreRestatedAndStillPending() {
        var core = listening(.recording)
        _ = core.receive(volatile("that is my answer done", range: 0...5))
        let answer = [
            Word("that", start: 1, end: 1.2), Word("is", start: 1.2, end: 1.4), Word("my", start: 1.4, end: 1.6),
            Word("answer.", start: 1.6, end: 2),
        ]
        let restated = updates(core.receive(final(answer, range: 0.9...3)))
        #expect(restated[1] == .init(words: [Word("done", start: 3, end: 5)], isFinal: false, covering: 3...3))
        // The rest is a candidate, finalized once the engine has had time to report more.
        #expect(finalizes(core.fed(through: 5 + lag - 0.1)).isEmpty)
        #expect(finalizes(core.fed(through: 5 + lag)) == [5])
    }

    /// The final is lined up with the volatile text by its last word, not by counting words:
    /// "trade-offs" is two tokens where the volatile "tradeoffs" is one.
    @Test func theRestIsFoundByTheFinalsLastWord() {
        var pair = Pair(.recording, core: listening(.recording))
        _ = pair.receive(final([Word("covers", start: 0.1, end: 0.6)], range: 0...0.7))
        _ = pair.receive(volatile("tradeoffs done actually", range: 0.7...5))
        let words = [Word("trade-offs.", start: 0.8, end: 1.4), Word("Done.", start: 2.4, end: 2.9)]
        let actions = pair.core.receive(final(words, range: 0.8...3.1))
        #expect(updates(actions)[1] == .init(words: [Word("actually", start: 3.1, end: 5)], isFinal: false, covering: 3.1...3.1))
        #expect(pair.give(actions).isEmpty)
        #expect(pair.spotter.advance(progress: 10).isEmpty)

        #expect(Core.alignedEnd(of: ["trade", "offs", "done"], in: ["tradeoffs", "done", "actually"]) == 2)
        #expect(Core.alignedEnd(of: ["tradeoffs"], in: ["the", "trade", "offs", "done"]) == 3)
        #expect(Core.alignedEnd(of: [], in: ["actually"]) == 0)
        #expect(Core.alignedEnd(of: ["don"], in: ["done"]) == nil)
    }

    @Test func whenTheyDoNotLineUpEveryVolatileWordIsRestated() {
        var core = listening(.recording)
        _ = core.receive(volatile("so that was it", range: 0...4))
        let restated = updates(core.receive(final([Word("Okay.", start: 0.2, end: 0.6)], range: 0...1)))
        #expect(restated[1] == .init(words: [Word("so that was it", start: 1, end: 4)], isFinal: false, covering: 1...1))
    }

    /// The reviewer's `done-then-more` trace: a finalization ahead of the engine came back empty
    /// over a volatile "Actually." said 0.6 s after "done". The word is kept, so the take goes on.
    @Test func wordsAFinalDroppedAreKeptAsFinalWords() {
        var pair = Pair(.recording, core: listening(.recording))
        _ = pair.receive(final([Word("trade-offs.", start: 0.92, end: 1.42)], range: 0...2.6))
        _ = pair.receive(final([Word("Done.", start: 2.72, end: 3.22)], range: 2.72...3.62))
        _ = pair.receive(volatile("Actually.", range: 3.69...4.63, finalizedThrough: 3.62))
        let actions = pair.core.receive(final([], range: 3.81...4.63))
        #expect(
            updates(actions) == [
                .init(words: [Word("actually", start: 3.81, end: 4.63)], isFinal: true, covering: 3.81...4.63, progress: 4.63)
            ])
        #expect(pair.give(actions).isEmpty)
        #expect(pair.spotter.advance(progress: 10).isEmpty)

        // Fewer words than the volatile text: the ones after the final's last word are kept.
        var core = listening(.recording)
        _ = core.receive(volatile("done actually", range: 2.6...4.63))
        let kept = updates(core.receive(final([Word("Done.", start: 2.72, end: 3.22)], range: 2.72...4.63)))
        #expect(kept[0].words == [Word("Done.", start: 2.72, end: 3.22), Word("actually", start: 3.22, end: 4.63)])
    }

    // MARK: Candidates

    @Test func whileRecordingVolatileTextEndingInDoneIsFinalizedOnceTheEngineHadTimeToReportMore() {
        var core = listening(.recording)
        #expect(finalizes(core.receive(volatile("that is my answer. Done", range: 0...5.9))).isEmpty)
        #expect(finalizes(core.fed(through: 6)).isEmpty)
        #expect(finalizes(core.fed(through: 5.9 + lag)) == [5.9])
        #expect(finalizes(core.fed(through: 8)).isEmpty)
    }

    @Test func iAmDoneIsACandidateToo() {
        var core = listening(.recording)
        _ = core.receive(volatile("I'm done.", range: 0...2))
        #expect(finalizes(core.fed(through: 2 + lag)) == [2])
    }

    /// The engine reports more words before the candidate is finalized: they decide.
    @Test func moreWordsBeforeTheLagCancelTheCandidate() {
        var core = listening(.recording)
        _ = core.receive(volatile("Done.", range: 2.6...3.69))
        _ = core.fed(through: 4.6)
        _ = core.receive(volatile("Done. Actually.", range: 2.6...4.63))
        #expect(finalizes(core.fed(through: 20)).isEmpty)
    }

    /// `SpeechTranscriber` reports a chunk of audio as a burst of growing results. The burst is
    /// judged by its last result, so a mid-sentence "done" is not finalized.
    @Test func aBurstIsJudgedByItsLastResult() {
        var core = listening(.recording)
        _ = core.receive(volatile("We finally got it done", range: 0...3))
        _ = core.receive(volatile("We finally got it done by Friday", range: 0...3))
        #expect(finalizes(core.fed(through: 10)).isEmpty)
    }

    @Test func nothingIsFinalizedWhenNotListening() {
        var core = Core()
        _ = core.receive(volatile("done", range: 0...2))
        #expect(finalizes(core.fed(through: 4)).isEmpty)
        core.listen(mode: .recording, from: 0)
        core.stopListening()
        #expect(finalizes(core.fed(through: 4.2)).isEmpty)
    }

    @Test func aMidSentenceDoneIsNotFinalizedWhileRecording() {
        var core = listening(.recording)
        _ = core.receive(volatile("we got it done by Friday", range: 0...3))
        #expect(finalizes(core.fed(through: 10)).isEmpty)
    }

    /// Between takes every utterance is finalized, so a command is acted on and other speech is
    /// reported, once the engine has reported nothing new for the lag.
    @Test func betweenTakesAnyUtteranceIsFinalizedOnce() {
        var core = listening(.betweenTakes, fedTo: 3)
        _ = core.receive(volatile("what is the weather going to be like", range: 0...3))
        #expect(finalizes(core.fed(through: 4.4)).isEmpty)
        #expect(finalizes(core.fed(through: 3 + lag)) == [3])
        #expect(finalizes(core.fed(through: 6.5)).isEmpty)
    }

    @Test func whileRecordingUnchangedSpeechIsNotFinalized() {
        var core = listening(.recording, fedTo: 3)
        _ = core.receive(volatile("and then we shipped it", range: 0...3))
        #expect(finalizes(core.fed(through: 20)).isEmpty)
    }

    // MARK: Confirming silence

    /// "done", then silence: the recognizer finalizes through the end of "done" plus the
    /// spotter's 1.2 s window and a margin, once the engine has had time to report any word
    /// there, and once that has settled the spotter ends the take.
    @Test func silenceAfterDoneIsConfirmedByAFinalizationThatHasSettled() {
        var pair = Pair(.recording, core: listening(.recording))
        let answer = [Word("my", start: 2.2, end: 2.4), Word("answer.", start: 2.4, end: 3)]
        #expect(pair.receive(final(answer, range: 0.9...3.1)).isEmpty)
        #expect(pair.receive(volatile(" Done", range: 3.1...5.9, finalizedThrough: 3.1)).isEmpty)
        #expect(finalizes(pair.core.fed(through: 5.9 + lag)) == [5.9])
        #expect(pair.receive(final([Word("Done.", start: 4.32, end: 5.1)], range: 4.32...5.16)).isEmpty)

        // "done" is trimmed to 0.5 s (see trimmingStretchedEnd), then 1.2 s and a 0.3 s margin.
        let confirm = 4.32 + 0.5 + 1.2 + 0.3
        #expect(finalizes(pair.core.fed(through: confirm + lag - 0.05)).isEmpty)
        #expect(finalizes(pair.core.fed(through: confirm + lag)) == [confirm])
        pair.core.finalized(through: confirm)
        #expect(pair.give(pair.core.fed(through: confirm + lag + 0.2)).isEmpty)
        #expect(pair.give(pair.core.fed(through: confirm + lag + 0.3)) == [.done(cutAt: 4.32)])
    }

    /// An engine that reports silence as an empty result: it has heard through the confirmation
    /// time, so there is nothing to wait for.
    @Test func anEmptyVolatileOverTheConfirmationTimeConfirmsAtOnce() {
        var core = listening(.recording)
        _ = core.receive(final([Word("Done.", start: 2, end: 2.4)], range: 2...2.5))
        let confirm = 2.4 + 1.2 + 0.3
        _ = core.receive(volatile("", range: 2.5...4.2))
        #expect(finalizes(core.fed(through: 4.2)) == [confirm])
    }

    @Test func speechAfterDoneCancelsTheConfirmation() {
        var core = listening(.recording)
        _ = core.receive(final([Word("done", start: 2, end: 2.3)], range: 0...2.4))
        _ = core.receive(volatile("by Friday", range: 2.4...3.4, finalizedThrough: 2.4))
        #expect(finalizes(core.fed(through: 10)).isEmpty)
    }

    /// A volatile result that restates audio already final is not new speech, and is dropped.
    @Test func aStaleVolatileIsDroppedAndDoesNotCancelTheConfirmation() {
        var core = listening(.recording)
        _ = core.receive(final([Word("Again.", start: 0.96, end: 1.98)], range: 0.96...2.04))
        _ = core.receive(final([Word("done", start: 3, end: 3.3)], range: 2.5...3.4))
        #expect(core.receive(volatile("done.", range: 2.5...3.5)).isEmpty)
        let confirm = 3.3 + 1.2 + 0.3
        #expect(finalizes(core.fed(through: confirm + lag)) == [confirm])
    }

    @Test func whileRecordingAFinalThatDoesNotEndInDoneIsNotConfirmed() {
        var core = listening(.recording)
        _ = core.receive(final([Word("Friday.", start: 2, end: 2.3)], range: 0...2.4))
        #expect(finalizes(core.fed(through: 10)).isEmpty)
    }

    @Test func betweenTakesAnyFinalIsConfirmedAfterTheUtteranceGap() {
        var core = listening(.betweenTakes)
        _ = core.receive(volatile("Again", range: 0...2))
        #expect(finalizes(core.fed(through: 2 + lag)) == [2])
        _ = core.receive(final([Word("Again.", start: 0.96, end: 1.98)], range: 0.96...2.04))
        // "Again." ends 0.5 s after it starts (trimmingStretchedEnd), then the 0.8 s gap and a margin.
        let confirm = 0.96 + 0.5 + 0.8 + 0.3
        #expect(finalizes(core.fed(through: confirm + lag - 0.05)).isEmpty)
        #expect(finalizes(core.fed(through: confirm + lag)) == [confirm])
    }

    @Test func aFinalizationIsBelievedOnlyAfterItSettlesAndEvenWhenNotListening() {
        var core = Core()
        _ = core.fed(through: 1)
        core.finalized(through: 0.9)
        #expect(core.fed(through: 1.2).isEmpty)
        #expect(core.fed(through: 1 + 0.3) == [.update(.init(words: [], isFinal: false, progress: 0.9))])
        #expect(core.fed(through: 1.4).isEmpty)
    }

    // MARK: Other finalizations

    @Test func aWindowFinalizesEverythingBeforeItsStart() {
        var core = Core()
        _ = core.fed(through: 9)
        core.listen(mode: .betweenTakes, from: 10)
        #expect(finalizes(core.fed(through: 9.9)).isEmpty)
        #expect(finalizes(core.fed(through: 10.05)) == [10])
        // A window that starts in the past finalizes at the next feed.
        core.listen(mode: .recording, from: 12)
        #expect(finalizes(core.fed(through: 13)) == [12])
    }

    @Test func aTimeAlreadyFinalizedIsNotRequestedAgain() {
        var core = listening(.recording)
        _ = core.receive(volatile("done", range: 0...5))
        #expect(finalizes(core.fed(through: 5 + lag)) == [5])
        core.listen(mode: .recording, from: 4)
        #expect(finalizes(core.fed(through: 6.6)).isEmpty)
    }

    /// A finalization that never completes would leave a "done" unconfirmed forever.
    @Test func aFinalizationThatDoesNotCompleteIsAFailure() {
        var core = Core()
        core.listen(mode: .recording, from: 10)
        #expect(finalizes(core.fed(through: 10)) == [10])
        #expect(core.fed(through: 15).isEmpty)
        #expect(core.fed(through: 15.1) == [.fail("The speech recognizer did not finalize through 10.00 s.")])

        var completed = Core()
        completed.listen(mode: .recording, from: 10)
        _ = completed.fed(through: 10)
        completed.finalized(through: 10)
        #expect(!completed.fed(through: 20).contains { if case .fail = $0 { true } else { false } })
    }
}
