import Foundation
import Testing
@testable import SpeakUp

/// "done" and the between-take commands, over word timelines like a recognizer's.
struct CommandSpotterTests {
    typealias Word = CommandSpotter.TimedWord

    private func w(_ text: String, _ start: Double, _ end: Double) -> Word {
        Word(text, start: start, end: end)
    }

    /// Words spoken back to back, `gap` seconds apart, `length` seconds each.
    private func run(
        _ text: String, from start: Double, length: Double = 0.3, gap: Double = 0.05
    ) -> [Word] {
        var time = start
        return text.split(separator: " ").map { token in
            defer { time += length + gap }
            return Word(String(token), start: time, end: time + length)
        }
    }

    private func finalUpdate(_ words: [Word], progress: Double? = nil) -> CommandSpotter.Update {
        .init(words: words, isFinal: true, progress: progress)
    }

    private func volatileUpdate(_ words: [Word], progress: Double? = nil) -> CommandSpotter.Update {
        .init(words: words, isFinal: false, progress: progress)
    }

    private func recording(from start: Double = 0) -> CommandSpotter {
        var spotter = CommandSpotter()
        spotter.listen(mode: .recording, from: start)
        return spotter
    }

    private func betweenTakes(from start: Double = 0) -> CommandSpotter {
        var spotter = CommandSpotter()
        spotter.listen(mode: .betweenTakes, from: start)
        return spotter
    }

    // MARK: - done

    @Test func doneAfterPauseAndFollowedBySilenceEndsTheTakeAtItsStart() {
        var spotter = recording()
        let answer = run("so we chose postgres", from: 0)  // ends 1.35
        let done = w("Done.", 2.5, 2.9)
        // Not yet: the recognizer has only got as far as the word.
        #expect(spotter.receive(finalUpdate(answer + [done])) == [])
        #expect(spotter.advance(progress: 3.5) == [])
        #expect(spotter.advance(progress: 4.1) == [.done(cutAt: 2.5)])
    }

    @Test func recognizerProgressBeyondSilenceConfirmsInOneUpdate() {
        var spotter = recording()
        let words = run("we chose postgres", from: 0) + [w("done", 2.0, 2.4)]
        #expect(spotter.receive(volatileUpdate(words, progress: 3.7)) == [.done(cutAt: 2.0)])
    }

    @Test func nothingFiresAfterTheFirstDone() {
        var spotter = recording()
        let words = run("we chose postgres", from: 0) + [w("done", 2.0, 2.4)]
        _ = spotter.receive(finalUpdate(words, progress: 4))
        #expect(!spotter.isListening)
        #expect(spotter.advance(progress: 20) == [])
        #expect(spotter.receive(finalUpdate([w("done", 9, 9.4)], progress: 12)) == [])
    }

    @Test func doneInsideASentenceWithNoPauseBeforeItIsRejected() {
        var spotter = recording()
        // "we got it done" in one breath, then a long thinking pause.
        let words = run("we got it done", from: 0)
        #expect(spotter.receive(finalUpdate(words, progress: 8)) == [])
        #expect(spotter.advance(progress: 20) == [])
    }

    @Test func doneJustUnderThePauseThresholdIsRejected() {
        var spotter = recording()
        let head = run("we got it", from: 0)
        let start = head.last!.end + 0.59
        let words = head + [w("done", start, start + 0.4)]
        #expect(spotter.receive(finalUpdate(words, progress: 9)) == [])
    }

    @Test func doneJustOverThePauseThresholdCounts() {
        var spotter = recording()
        let head = run("we got it", from: 0)
        let start = head.last!.end + 0.61
        let words = head + [w("done", start, start + 0.4)]
        #expect(spotter.receive(finalUpdate(words, progress: 9)) == [.done(cutAt: start)])
    }

    @Test func doneWithAPauseBeforeButWordsAfterWithinTheWindowIsRejected() {
        var spotter = recording()
        let words = run("we chose postgres", from: 0)
            + [w("done", 2.5, 2.9)]
            + [w("with", 3.9, 4.1)]  // starts 1.0 s after "done" ends
        #expect(spotter.receive(finalUpdate(words, progress: 12)) == [])
    }

    @Test func doneFollowedByWordsFarAwayStillEndsTheTake() {
        var spotter = recording()
        let words = run("we chose postgres", from: 0)
            + [w("done", 2.5, 2.9), w("sorry", 4.2, 4.5)]
        #expect(spotter.receive(finalUpdate(words)) == [.done(cutAt: 2.5)])
    }

    @Test func aLateWordFromTheLaggingRecognizerCancelsAPendingDone() {
        var spotter = recording()
        let head = run("we chose postgres", from: 0) + [w("done", 2.5, 2.9)]
        #expect(spotter.receive(volatileUpdate(head, progress: 3.2)) == [])
        // The recognizer catches up: the speaker kept going.
        let more = head + run("with the reporting", from: 3.0)
        #expect(spotter.receive(volatileUpdate(more, progress: 5)) == [])
        #expect(spotter.advance(progress: 30) == [])
    }

    @Test func aVolatileDoneThatTheFinalResultChangesDoesNotFire() {
        var spotter = recording()
        let head = run("we chose postgres", from: 0)
        #expect(spotter.receive(volatileUpdate(head + [w("done", 2.5, 2.9)], progress: 3)) == [])
        #expect(spotter.receive(volatileUpdate(head + [w("dunn", 2.5, 2.9)], progress: 5)) == [])
        #expect(spotter.receive(finalUpdate(head + [w("Don", 2.5, 2.9)], progress: 6)) == [])
    }

    @Test func volatileResultsReviseAndAFinalOneCommits() {
        var spotter = recording()
        let head = run("we chose postgres", from: 0)
        #expect(spotter.receive(volatileUpdate(head + [w("dun", 2.5, 2.9)])) == [])
        #expect(spotter.receive(volatileUpdate(head + [w("done", 2.5, 2.9)])) == [])
        // The final result covers the same span; the volatile copy must not double it.
        #expect(
            spotter.receive(finalUpdate(head + [w("done", 2.5, 2.9)], progress: 4.2))
                == [.done(cutAt: 2.5)])
    }

    @Test func caseAndPunctuationAreIgnored() {
        for text in ["Done.", "DONE!", "done,", "\u{201C}Done\u{201D}", "done..."] {
            var spotter = recording()
            let words = run("we chose postgres", from: 0) + [w(text, 2.5, 2.9)]
            #expect(
                spotter.receive(finalUpdate(words, progress: 4.3)) == [.done(cutAt: 2.5)],
                "\(text)")
        }
    }

    @Test func imDoneIsCutAtTheStartOfImDone() {
        for spoken in ["I'm", "I\u{2019}m", "Im"] {
            var spotter = recording()
            let words = run("we chose postgres", from: 0)
                + [w(spoken, 2.5, 2.7), w("done", 2.75, 3.1)]
            #expect(
                spotter.receive(finalUpdate(words, progress: 4.4)) == [.done(cutAt: 2.5)],
                "\(spoken)")
        }
    }

    @Test func iAmDoneIsCutAtTheI() {
        var spotter = recording()
        let words = run("we chose postgres", from: 0)
            + [w("I", 2.5, 2.6), w("am", 2.65, 2.8), w("done", 2.85, 3.2)]
        #expect(spotter.receive(finalUpdate(words, progress: 4.5)) == [.done(cutAt: 2.5)])
    }

    @Test func imDoneInsideASentenceIsRejected() {
        var spotter = recording()
        let words = run("well", from: 0) + [w("I'm", 0.4, 0.6), w("done", 0.65, 1.0)]
            + run("with that part", from: 1.3)
        #expect(spotter.receive(finalUpdate(words, progress: 10)) == [])
    }

    @Test func imAndDoneSplitByAPauseCutsAtDoneAlone() {
        var spotter = recording()
        let words = run("we chose postgres", from: 0) + [w("I'm", 2.0, 2.2), w("done", 3.0, 3.4)]
        #expect(spotter.receive(finalUpdate(words, progress: 5)) == [.done(cutAt: 3.0)])
    }

    @Test func doneRightAfterTheTakeOpensIsRejectedButAfterAPauseItCounts() {
        var early = recording(from: 10)
        #expect(early.receive(finalUpdate([w("done", 10.3, 10.6)], progress: 13)) == [])

        var later = recording(from: 10)
        #expect(
            later.receive(finalUpdate([w("done", 11.0, 11.3)], progress: 13))
                == [.done(cutAt: 11.0)])
    }

    @Test func wordsBeforeTheListeningWindowAreIgnored() {
        var spotter = recording(from: 5)
        // The tone, or the app's own "answer after the tone", heard by the microphone.
        let heard = [w("tone", 4.0, 4.4), w("done", 4.9, 5.2)]
        #expect(spotter.receive(finalUpdate(heard, progress: 9)) == [])
    }

    @Test func aSecondDoneAfterARejectedFirstOneStillWorks() {
        var spotter = recording()
        // The first "done" has no pause before it; the second follows a long one.
        let words = run("the work is done", from: 0) + [w("done", 3.5, 3.9)]
        #expect(spotter.receive(finalUpdate(words, progress: 6)) == [.done(cutAt: 3.5)])
    }

    @Test func commandWordsAreNotCommandsWhileRecording() {
        var spotter = recording()
        let words = [w("stop", 1.0, 1.4), w("again", 3.0, 3.4), w("next", 5.0, 5.4)]
        #expect(spotter.receive(finalUpdate(words, progress: 9)) == [])
        #expect(spotter.isListening)
    }

    // MARK: - Commands between takes

    @Test(arguments: [
        ("again", CommandSpotter.Command.again),
        ("Again.", CommandSpotter.Command.again),
        ("try again", CommandSpotter.Command.again),
        ("next", CommandSpotter.Command.next),
        ("Next question", CommandSpotter.Command.next),
        ("repeat that", CommandSpotter.Command.repeatThat),
        ("Repeat that.", CommandSpotter.Command.repeatThat),
        ("say that again", CommandSpotter.Command.repeatThat),
        ("read the better version", CommandSpotter.Command.betterVersion),
        ("Read the better version.", CommandSpotter.Command.betterVersion),
        ("better version", CommandSpotter.Command.betterVersion),
        ("stop", CommandSpotter.Command.stop),
        ("STOP!", CommandSpotter.Command.stop),
    ])
    func eachCommandPhraseIsRecognized(phrase: String, command: CommandSpotter.Command) {
        var spotter = betweenTakes()
        let words = run(phrase, from: 1)
        let last = words.last!.end
        #expect(spotter.receive(finalUpdate(words, progress: last + 0.9)) == [.command(command)])
        #expect(!spotter.isListening)
    }

    @Test func aCommandWaitsForTheEndOfItsUtterance() {
        var spotter = betweenTakes()
        let words = run("repeat that", from: 1)  // ends 1.65
        #expect(spotter.receive(volatileUpdate(words, progress: 2.0)) == [])
        #expect(spotter.advance(progress: 2.4) == [])
        #expect(spotter.advance(progress: 2.5) == [.command(.repeatThat)])
    }

    @Test func aFollowingUtteranceClosesTheCommandBeforeIt() {
        var spotter = betweenTakes()
        let words = [w("next", 1.0, 1.4), w("hello", 3.0, 3.3)]
        #expect(spotter.receive(volatileUpdate(words)) == [.command(.next)])
    }

    @Test func sayThatAgainIsRepeatNotAgain() {
        var spotter = betweenTakes()
        let words = run("say that again", from: 1)
        #expect(spotter.receive(finalUpdate(words, progress: 4)) == [.command(.repeatThat)])
    }

    @Test func aCommandInsideALongerUtteranceIsNotACommand() {
        let texts = [
            "stop the car", "I think we should go next", "do not stop",
            "next next next next next next",
        ]
        for text in texts {
            var spotter = betweenTakes()
            let words = run(text, from: 1)
            let events = spotter.receive(finalUpdate(words, progress: words.last!.end + 2))
            #expect(events == [.unrecognizedSpeech], "\(text)")
            #expect(spotter.isListening)
        }
    }

    @Test func unrecognizedSpeechIsReportedOncePerUtterance() {
        var spotter = betweenTakes()
        let words = run("what was that", from: 1)
        #expect(spotter.receive(volatileUpdate(words, progress: 4)) == [.unrecognizedSpeech])
        #expect(spotter.advance(progress: 9) == [])
        #expect(spotter.receive(finalUpdate(words, progress: 10)) == [])
        // A later command still works.
        let command = [w("stop", 12, 12.4)]
        #expect(spotter.receive(finalUpdate(command, progress: 13.5)) == [.command(.stop)])
    }

    @Test func aCommandAfterChatterReportsBoth() {
        var spotter = betweenTakes()
        let words = run("hello there", from: 1) + [w("again", 4, 4.4)]
        #expect(
            spotter.receive(finalUpdate(words, progress: 6))
                == [.unrecognizedSpeech, .command(.again)])
    }

    @Test func aRevisedCommandIsPickedUp() {
        var spotter = betweenTakes()
        #expect(
            spotter.receive(volatileUpdate([w("nest", 1, 1.4)], progress: 3))
                == [.unrecognizedSpeech])
        #expect(
            spotter.receive(finalUpdate([w("next", 1, 1.4)], progress: 3)) == [.command(.next)])
    }

    @Test func wordsBeforeTheWindowAreIgnoredBetweenTakes() {
        var spotter = betweenTakes(from: 6)
        // The app's own "say next, again, or stop" leaking into the microphone.
        let own = [w("stop", 5.0, 5.4)]
        #expect(spotter.receive(finalUpdate(own, progress: 8)) == [])
    }

    @Test func doneIsNotACommandBetweenTakes() {
        var spotter = betweenTakes()
        #expect(
            spotter.receive(finalUpdate([w("done", 1, 1.4)], progress: 4)) == [.unrecognizedSpeech])
    }

    @Test func relistenResetsEverything() {
        var spotter = betweenTakes()
        _ = spotter.receive(finalUpdate([w("stop", 1, 1.4)], progress: 3))
        #expect(!spotter.isListening)
        spotter.listen(mode: .recording, from: 20)
        #expect(spotter.isListening)
        #expect(spotter.mode == .recording)
        let words = [w("done", 21, 21.4)]
        #expect(spotter.receive(finalUpdate(words, progress: 23)) == [.done(cutAt: 21)])
    }

    // MARK: - Thresholds and words

    @Test func thresholdsCanBeTuned() {
        var config = CommandSpotter.Config()
        config.silenceBeforeDone = 0.3
        config.silenceAfterDone = 0.5
        var spotter = CommandSpotter(config: config)
        spotter.listen(mode: .recording, from: 0)
        let words = run("we chose postgres", from: 0) + [w("done", 1.4, 1.8)]
        #expect(spotter.receive(finalUpdate(words, progress: 2.4)) == [.done(cutAt: 1.4)])
    }

    @Test func aRecognizerWordHoldingSeveralTokensIsSplitEvenly() {
        var spotter = betweenTakes()
        #expect(
            spotter.receive(finalUpdate([w("Read the better version.", 1, 3)], progress: 4))
                == [.command(.betterVersion)])
    }

    @Test func normalizeStripsCasePunctuationAndApostrophes() {
        #expect(CommandSpotter.normalize("I'm DONE!") == ["im", "done"])
        #expect(
            CommandSpotter.normalize("\u{201C}Read-the better version...\u{201D}")
                == ["read", "the", "better", "version"])
        #expect(CommandSpotter.normalize("...") == [])
    }
}
