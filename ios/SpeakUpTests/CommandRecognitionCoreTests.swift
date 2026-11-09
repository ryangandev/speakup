import Foundation
import Testing
@testable import SpeakUp

/// The recognizer's pure decisions: results to spotter updates, and when to finalize.
struct CommandRecognitionCoreTests {
    typealias Word = CommandSpotter.TimedWord
    typealias Core = CommandRecognitionCore

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

    private func listening(_ mode: CommandSpotter.Mode, from start: Double = 0, fedTo fed: Double = 0) -> Core {
        var core = Core()
        core.listen(mode: mode, from: start)
        _ = core.fed(through: fed)
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

    @Test func aVolatileSpansItsRangeAndTakesProgressFromTheFinalizationTime() {
        var core = Core()
        let actions = core.receive(volatile("so that is", range: 3...4.2, finalizedThrough: 3))
        #expect(
            actions == [
                .update(
                    .init(words: [Word("so that is", start: 3, end: 4.2)], isFinal: false, covering: 3...4.2, progress: 3))
            ])
    }

    @Test func anEmptyVolatileRetractsItsRange() {
        var core = Core()
        let actions = core.receive(volatile("", range: 3...4.2, finalizedThrough: 3))
        #expect(actions == [.update(.init(words: [], isFinal: false, covering: 3...4.2, progress: 3))])
    }

    @Test func donIsHeardAsDoneButOtherWordsAreLeftAlone() {
        let result = final(
            [Word("answer,", start: 5.6, end: 6.1), Word("Don.", start: 6.1, end: 6.8), Word("Donald", start: 7, end: 7.4)],
            range: 0...7.5)
        #expect(
            Core.words(in: result) == [
                Word("answer,", start: 5.6, end: 6.1), Word("done", start: 6.1, end: 6.8), Word("Donald", start: 7, end: 7.4),
            ])
        #expect(Core.words(in: volatile("my answer Don", range: 0...2)) == [Word("my answer done", start: 0, end: 2)])
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

    /// A volatile result often runs into the silence after the last word, and the spotter
    /// spreads its words over that range. A final that covers less clears the rest, or keeps
    /// there the words it did not account for.
    @Test func aFinalClearsOrRestatesTheRestOfTheVolatileRange() {
        var core = listening(.betweenTakes)
        var spotter = CommandSpotter()
        spotter.listen(mode: .betweenTakes, from: 6)
        for update in updates(core.receive(volatile("what is the weather today", range: 6.6...10.1))) {
            #expect(spotter.receive(update).isEmpty)
        }
        let today = [
            Word("What", start: 6.9, end: 7.2), Word("is", start: 7.2, end: 7.4), Word("the", start: 7.4, end: 7.6),
            Word("weather", start: 7.6, end: 8.4), Word("today?", start: 8.4, end: 8.9),
        ]
        let cleared = updates(core.receive(final(today, range: 6.9...9)))
        #expect(cleared.count == 2)
        #expect(cleared[1] == .init(words: [], isFinal: false, covering: 9...10.1, progress: 9))
        // Without the clearing, the volatile "today", spread to 9.4 s, would hold the utterance open.
        #expect(spotter.receive(cleared[0]).isEmpty)
        #expect(spotter.receive(cleared[1]) == [.unrecognizedSpeech])

        var more = listening(.recording)
        _ = more.receive(volatile("that is my answer done", range: 0...5))
        let answer = [Word("that", start: 1, end: 1.2), Word("is", start: 1.2, end: 1.4), Word("my", start: 1.4, end: 1.6),
            Word("answer.", start: 1.6, end: 2)]
        let restated = updates(more.receive(final(answer, range: 0.9...3)))
        #expect(restated[1] == .init(words: [Word("done", start: 3, end: 5)], isFinal: false, covering: 3...5, progress: 3))
        // The rest is still pending speech: a candidate, and no confirmation of the final.
        #expect(finalizes(more.fed(through: 5.1)) == [5])
    }

    // MARK: Candidates

    @Test func whileRecordingVolatileTextEndingInDoneIsFinalizedWhenAudioIsFed() {
        var core = listening(.recording)
        #expect(finalizes(core.receive(volatile("that is my answer. Done", range: 0...5.9))).isEmpty)
        #expect(finalizes(core.fed(through: 6)) == [5.9])
        #expect(finalizes(core.fed(through: 6.1)).isEmpty)
    }

    @Test func iAmDoneAndDonAreCandidatesToo() {
        var core = listening(.recording)
        _ = core.receive(volatile("I'm done.", range: 0...2))
        #expect(finalizes(core.fed(through: 2.1)) == [2])
        var misheard = listening(.recording)
        _ = misheard.receive(volatile("my answer, Don", range: 0...3))
        #expect(finalizes(misheard.fed(through: 3.1)) == [3])
    }

    /// `SpeechTranscriber` reports a chunk of audio as a burst of growing results. The burst is
    /// judged by its last result, so a mid-sentence "done" is not finalized.
    @Test func aBurstIsJudgedByItsLastResult() {
        var core = listening(.recording)
        _ = core.receive(volatile("We finally got it done", range: 0...3))
        _ = core.receive(volatile("We finally got it done by Friday", range: 0...3))
        #expect(finalizes(core.fed(through: 3.1)).isEmpty)
    }

    @Test func nothingIsFinalizedWhenNotListening() {
        var core = Core()
        _ = core.receive(volatile("done", range: 0...2))
        #expect(finalizes(core.fed(through: 2.1)).isEmpty)
        core.listen(mode: .recording, from: 0)
        core.stopListening()
        #expect(finalizes(core.fed(through: 2.2)).isEmpty)
    }

    @Test func betweenTakesAShortUtteranceEndingInACommandIsACandidate() {
        #expect(Core.isCandidate(["again"], mode: .betweenTakes, config: .init()))
        #expect(Core.isCandidate(["um", "read", "the", "better", "version"], mode: .betweenTakes, config: .init()))
        #expect(!Core.isCandidate(["read", "the"], mode: .betweenTakes, config: .init()))
        #expect(!Core.isCandidate(["so", "we", "should", "try", "it", "again"], mode: .betweenTakes, config: .init()))
        #expect(!Core.isCandidate(["again"], mode: .recording, config: .init()))
        #expect(!Core.isCandidate(["done"], mode: .betweenTakes, config: .init()))
    }

    @Test func aMidSentenceDoneIsNotFinalizedWhileRecording() {
        var core = listening(.recording)
        _ = core.receive(volatile("we got it done by Friday", range: 0...3))
        #expect(finalizes(core.fed(through: 10)).isEmpty)
    }

    // MARK: Confirming silence

    /// "done", then silence: the recognizer finalizes through the end of "done" plus the
    /// spotter's 1.2 s window, and once that has settled the spotter ends the take.
    @Test func silenceAfterDoneIsConfirmedByAFinalizationThatHasSettled() {
        var core = listening(.recording)
        var spotter = CommandSpotter()
        spotter.listen(mode: .recording, from: 0)
        func give(_ actions: [Core.Action]) -> [CommandSpotter.Event] {
            updates(actions).flatMap { spotter.receive($0) }
        }

        let answer = [Word("my", start: 2.2, end: 2.4), Word("answer.", start: 2.4, end: 3)]
        #expect(give(core.receive(final(answer, range: 0.9...3.1))).isEmpty)
        #expect(give(core.receive(volatile(" Done", range: 3.1...5.9, finalizedThrough: 3.1))).isEmpty)
        #expect(finalizes(core.fed(through: 6)) == [5.9])
        #expect(give(core.receive(final([Word("Done.", start: 4.32, end: 5.1)], range: 4.32...5.16))).isEmpty)

        // Nothing is said after it: finalize through the end of "done" (trimmed to 0.5 s, see
        // trimmingStretchedEnd) plus 1.2 s and a margin.
        let confirm = 4.32 + 0.5 + 1.2 + 0.1
        #expect(finalizes(core.fed(through: confirm - 0.05)).isEmpty)
        #expect(finalizes(core.fed(through: confirm)) == [confirm])
        core.finalized(through: confirm)
        #expect(give(core.fed(through: confirm + 0.2)).isEmpty)
        #expect(give(core.fed(through: confirm + 0.3)) == [.done(cutAt: 4.32)])
    }

    @Test func speechAfterDoneCancelsTheConfirmation() {
        var core = listening(.recording)
        _ = core.receive(final([Word("done", start: 2, end: 2.3)], range: 0...2.4))
        _ = core.receive(volatile("by Friday", range: 2.4...3.4, finalizedThrough: 2.4))
        #expect(finalizes(core.fed(through: 10)).isEmpty)
    }

    /// A volatile result that restates audio already final is not new speech.
    @Test func aStaleVolatileDoesNotCancelTheConfirmation() {
        var core = listening(.recording)
        _ = core.receive(final([Word("Again.", start: 0.96, end: 1.98)], range: 0.96...2.04))
        _ = core.receive(final([Word("done", start: 3, end: 3.3)], range: 2.5...3.4))
        _ = core.receive(volatile("done.", range: 2.5...3.5))
        #expect(finalizes(core.fed(through: 4.7)) == [3.3 + 1.2 + 0.1])
    }

    @Test func whileRecordingAFinalThatDoesNotEndInDoneIsNotConfirmed() {
        var core = listening(.recording)
        _ = core.receive(final([Word("Friday.", start: 2, end: 2.3)], range: 0...2.4))
        #expect(finalizes(core.fed(through: 10)).isEmpty)
    }

    @Test func betweenTakesAnyFinalIsConfirmedAfterTheUtteranceGap() {
        var core = listening(.betweenTakes)
        _ = core.receive(volatile("Again", range: 0...2))
        #expect(finalizes(core.fed(through: 2.1)) == [2])
        _ = core.receive(final([Word("Again.", start: 0.96, end: 1.98)], range: 0.96...2.04))
        // "Again." ends 0.5 s after it starts (trimmingStretchedEnd), then the 0.8 s gap and a margin.
        let confirm = 0.96 + 0.5 + 0.8 + 0.1
        #expect(finalizes(core.fed(through: confirm - 0.05)).isEmpty)
        #expect(finalizes(core.fed(through: confirm)) == [confirm])
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

    @Test func betweenTakesSpeechThatStaysUnchangedIsFinalizedOnce() {
        var core = listening(.betweenTakes, fedTo: 3)
        _ = core.receive(volatile("what is the weather going to be like", range: 0...3))
        #expect(finalizes(core.fed(through: 4.4)).isEmpty)
        #expect(finalizes(core.fed(through: 4.5)) == [4.5])
        #expect(finalizes(core.fed(through: 6.5)).isEmpty)
    }

    @Test func whileRecordingUnchangedSpeechIsNotFinalized() {
        var core = listening(.recording, fedTo: 3)
        _ = core.receive(volatile("and then we shipped it", range: 0...3))
        #expect(finalizes(core.fed(through: 20)).isEmpty)
    }

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
        #expect(finalizes(core.fed(through: 5.1)) == [5])
        core.listen(mode: .recording, from: 4)
        #expect(finalizes(core.fed(through: 5.2)).isEmpty)
    }
}
