import Foundation
import Testing
@testable import SpeakUp

/// The wording of everything the app says in a drive, built from the contract's examples.
struct DriveScriptTests {
    // MARK: - Builders

    private func makeTake(
        attempt: Int = 1, status: String = "done", coaching: String = "done",
        error: [String: Any]? = nil, summary: [String: Any]?? = nil
    ) throws -> Take {
        var object = Fixture.object("take_done")
        object["attempt"] = attempt
        object["status"] = status
        object["coaching_status"] = coaching
        if let error { object["error"] = error }
        if let summary { object["summary"] = summary.map { $0 as Any } ?? NSNull() }
        return try Fixture.decode(Take.self, object: object)
    }

    private func makeReport() throws -> TakeReport {
        try Fixture.decode(TakeReport.self, object: Fixture.fullReportObject())
    }

    private func makeComparison() throws -> Comparison {
        try Fixture.decode(Comparison.self, "comparison")
    }

    private func json<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }

    private func summaryObject(
        fillers: Double? = 2.9, blocks: Int? = 1, restarts: Int? = 2, wpm: Double? = 171.4
    ) -> [String: Any] {
        [
            "verdict": NSNull(), "focus_titles": [String](),
            "fillers_per_100_words": json(fillers), "blocks": json(blocks),
            "restarts": json(restarts), "wpm_voiced": json(wpm),
        ]
    }

    // MARK: - Coached feedback

    @Test func firstAttemptSpeaksVerdictOneStrengthAndTheFirstFocusItem() throws {
        let feedback = DriveScript.feedback(for: try makeTake(attempt: 1), report: try makeReport())
        #expect(feedback.kind == .coached)
        #expect(feedback.segments.count == 3)
        #expect(
            feedback.segments[0]
                == "You named the decision in the first sentence, which is right, but your reasons came out as one long run and the answer trailed off at the end. Clear enough to follow, not yet crisp."
        )
        #expect(
            feedback.segments[1]
                == "What worked: You said what was chosen before explaining anything, so the listener knew where you were going."
        )
        // The instruction quotes what to say, with an ellipsis; none of that is spoken.
        #expect(
            feedback.segments[2]
                == "Next time: Number your reasons. Say how many reasons there are, then give them in order of weight: Two reasons. First, reporting needs joins. Second."
        )
        #expect(feedback.options == "Say again, next, repeat that, better version, or stop.")
        #expect(feedback.spoken.hasSuffix(feedback.options))
    }

    @Test func onlyTheFirstFocusItemIsSpoken() throws {
        let spoken = DriveScript.feedback(for: try makeTake(), report: try makeReport()).spoken
        #expect(!spoken.contains("Stop silently"))
    }

    @Test func retryLeadsWithTheComparisonThenVerdictAndTheFocusItem() throws {
        let feedback = DriveScript.feedback(
            for: try makeTake(attempt: 2), report: try makeReport(), comparison: try makeComparison())
        #expect(feedback.kind == .coached)
        #expect(feedback.segments.count == 3)
        #expect(
            feedback.segments[0]
                == "The reasons are now numbered and the long block is gone; the ending still trails off."
        )
        #expect(feedback.segments[1].hasPrefix("You named the decision"))
        #expect(feedback.segments[2].hasPrefix("Next time: Number your reasons."))
        #expect(!feedback.body.contains("What worked"))
    }

    @Test func retrySummaryFallsBackToTheReportsOwnComparison() throws {
        var object = Fixture.fullReportObject()
        var coaching = object["coaching"] as! [String: Any]
        coaching["comparison"] = [
            "summary": "Clearer this time.", "focus_outcomes": [Any](),
        ]
        object["coaching"] = coaching
        let withComparison = try Fixture.decode(TakeReport.self, object: object)
        let feedback = DriveScript.feedback(for: try makeTake(attempt: 2), report: withComparison)
        #expect(feedback.segments.first == "Clearer this time.")
    }

    @Test func coachingWithoutAFetchedReportUsesTheTakeSummary() throws {
        let feedback = DriveScript.feedback(for: try makeTake(), report: nil)
        #expect(feedback.kind == .coached)
        #expect(
            feedback.segments == [
                "Much clearer: the decision comes first and the reasons are numbered. The ending still fades out.",
                "Next time: Close on purpose.",
            ])
    }

    @Test func coachingDoneWithNothingToSayIsLater() throws {
        let feedback = DriveScript.feedback(
            for: try makeTake(summary: .some(nil)), report: nil)
        #expect(feedback.kind == .later)
    }

    // MARK: - No coaching

    @Test(arguments: ["unavailable", "failed"])
    func withoutCoachingTheMetricsAreSpokenInPlainWords(status: String) throws {
        let feedback = DriveScript.feedback(
            for: try makeTake(coaching: status, summary: .some(summaryObject())), report: nil)
        #expect(feedback.kind == .metricsOnly)
        #expect(
            feedback.segments == [
                "No coaching right now.",
                "You used about 3 fillers per 100 words.",
                "You got stuck mid-phrase once and restarted twice.",
                "You spoke at about 170 words per minute.",
            ])
        #expect(feedback.options == "Say again, next, or stop.")
        // No offer of a better version: there is none.
        #expect(!feedback.spoken.contains("better version"))
    }

    @Test func metricsWordingCoversTheEdgeCases() throws {
        func spoken(_ summary: [String: Any]) throws -> [String] {
            let take = try makeTake(coaching: "unavailable", summary: .some(summary))
            return DriveScript.feedback(for: take, report: nil).segments
        }
        #expect(
            try spoken(summaryObject(fillers: 0.2, blocks: 0, restarts: 0, wpm: 150))
                == [
                    "No coaching right now.", "You used almost no filler words.",
                    "No long stalls or restarts.", "You spoke at about 150 words per minute.",
                ])
        #expect(
            try spoken(summaryObject(fillers: 1.2, blocks: 3, restarts: 0, wpm: nil))
                == [
                    "No coaching right now.", "You used about 1 filler per 100 words.",
                    "You got stuck mid-phrase 3 times.",
                ])
        #expect(
            try spoken(summaryObject(fillers: nil, blocks: 0, restarts: 1, wpm: nil))
                == ["No coaching right now.", "You restarted a sentence once."])
        #expect(
            try spoken(summaryObject(fillers: nil, blocks: nil, restarts: nil, wpm: nil))
                == ["No coaching right now.", "Your answer is saved for when you're home."])
    }

    @Test func unavailableCoachingWithNoSummaryStillSaysSo() throws {
        let take = try makeTake(coaching: "unavailable", summary: .some(nil))
        let feedback = DriveScript.feedback(for: take, report: nil)
        #expect(feedback.kind == .metricsOnly)
        #expect(feedback.body == "No coaching right now. Your answer is saved for when you're home.")
    }

    // MARK: - Failures and waiting

    @Test func noSpeechAsksForAnotherTry() throws {
        let error: [String: Any] = ["code": "no_speech", "message": "Fewer than 5 words."]
        let feedback = DriveScript.feedback(
            for: try makeTake(status: "failed", coaching: "pending", error: error), report: nil)
        #expect(feedback.kind == .noSpeech)
        #expect(feedback.spoken == "I didn't catch an answer. Say again, next, or stop.")
    }

    @Test func otherFailuresSayTheTakeIsSaved() throws {
        let error: [String: Any] = ["code": "stt_failed", "message": "engine failed"]
        let feedback = DriveScript.feedback(
            for: try makeTake(status: "failed", coaching: "pending", error: error), report: nil)
        #expect(feedback.kind == .failed)
        #expect(
            feedback.spoken
                == "That one didn't process. Your answer is saved for when you're home. Say again, next, or stop."
        )
    }

    @Test(arguments: ["uploaded", "transcribing", "analyzing", "coaching", "something_new"])
    func aTakeStillProcessingIsLater(status: String) throws {
        let feedback = DriveScript.feedback(
            for: try makeTake(status: status, coaching: "pending"), report: nil)
        #expect(feedback.kind == .later)
    }

    @Test func coachingStillPendingOnADoneTakeIsLater() throws {
        let feedback = DriveScript.feedback(for: try makeTake(coaching: "pending"), report: nil)
        #expect(feedback.kind == .later)
    }

    @Test func offlineSaysFeedbackComesLaterAndOffersTheNextPrompt() {
        let feedback = DriveScript.offline
        #expect(feedback.kind == .later)
        #expect(
            feedback.spoken
                == "I couldn't reach the server. Your answer is saved; feedback will come later. Say next, again, or stop."
        )
    }

    @Test func waitingLines() {
        #expect(DriveScript.stillWorking == "Still working.")
        #expect(
            DriveScript.waitTimedOut
                == "Feedback on that one will come later. Say next, again, or stop.")
    }

    // MARK: - Better version

    @Test func theBetterVersionIsReadByParagraph() throws {
        var object = Fixture.fullReportObject()
        var coaching = object["coaching"] as! [String: Any]
        coaching["reference_version"] = [
            "text": "We chose Postgres. Two reasons.\n\nFirst, joins.\n\nSecond, transactions.",
            "structure": "Decision, two reasons",
        ]
        object["coaching"] = coaching
        let report = try Fixture.decode(TakeReport.self, object: object)
        let reading = DriveScript.referenceVersion(report: report)
        #expect(
            reading.segments == [
                "Here is a better version.", "We chose Postgres. Two reasons.", "First, joins.",
                "Second, transactions.",
            ])
        #expect(reading.options == "Say again, next, or stop.")
    }

    @Test func theContractExampleReferenceVersionIsSpoken() throws {
        let reading = DriveScript.referenceVersion(report: try makeReport())
        #expect(reading.segments.first == "Here is a better version.")
        #expect(reading.segments.count > 1)
        #expect(!reading.body.contains("\n"))
    }

    @Test func noBetterVersionWithoutCoaching() throws {
        #expect(
            DriveScript.referenceVersion(report: nil).body
                == "There is no better version without coaching.")
    }

    // MARK: - Start, prompt and end

    @Test func openingGreetsAndAsksForNervousness() {
        #expect(DriveScript.opening == "SpeakUp drive. How nervous are you, one to five?")
        #expect(DriveScript.nervousnessReask == "Say a number from one to five, or say skip.")
        #expect(DriveScript.nervousnessAfterQuestion == "How nervous are you now, one to five?")
    }

    @Test func nervousnessIsConfirmedInWords() {
        #expect(DriveScript.nervousnessRecorded(3) == "Nervousness three.")
        #expect(DriveScript.nervousnessRecorded(1) == "Nervousness one.")
        #expect(DriveScript.nervousnessRecorded(nil) == "Skipped.")
        #expect(DriveScript.nervousnessRecorded(9) == "Skipped.")
    }

    @Test func promptReadOutEndsWithTheToneCue() {
        let question = "Why did we choose Postgres over DynamoDB for the billing service?"
        #expect(
            DriveScript.promptReadOut(question: question)
                == "\(question) Answer after the tone.")
        #expect(
            DriveScript.promptReadOut(question: question, isRetry: true)
                == "Same question. \(question) Answer after the tone.")
        #expect(
            DriveScript.promptReadOut(question: "Walk me through the launch")
                == "Walk me through the launch. Answer after the tone.")
    }

    @Test func fixedLines() {
        #expect(DriveScript.takeEnded == "Got it.")
        #expect(DriveScript.timeLimit == "That's the time limit.")
        #expect(DriveScript.cutOff == "Your answer was cut off and saved. Say again, next, or stop.")
        #expect(
            DriveScript.commandHelp
                == "You can say again, next, repeat that, better version, or stop.")
        #expect(DriveScript.driveEnded(takes: 0) == "Drive ended.")
        #expect(DriveScript.driveEnded(takes: 1) == "Drive ended. One answer saved.")
        #expect(DriveScript.driveEnded(takes: 4) == "Drive ended. 4 answers saved.")
    }

    // MARK: - Speakable text

    @Test func speakableStripsQuotesMarkdownAndEllipses() {
        #expect(DriveScript.speakable("Say \"two reasons\", then go.") == "Say two reasons, then go.")
        #expect(DriveScript.speakable("Use **bold** and `code`.") == "Use bold and code.")
        #expect(DriveScript.speakable("First, ... then") == "First, then")
        #expect(DriveScript.speakable("Second, ...") == "Second")
        #expect(DriveScript.speakable("Wait\u{2026} what.") == "Wait, what.")
        #expect(DriveScript.speakable("  too   many \n spaces ") == "too many spaces")
    }

    @Test func noSpokenLineContainsSymbolsATextToSpeechVoiceWouldReadOut() throws {
        let lines = [
            DriveScript.feedback(for: try makeTake(), report: try makeReport()).spoken,
            DriveScript.feedback(for: try makeTake(), report: try makeReport(), comparison: try makeComparison())
                .spoken,
            DriveScript.referenceVersion(report: try makeReport()).spoken,
            DriveScript.offline.spoken, DriveScript.waitTimedOut, DriveScript.commandHelp,
            DriveScript.cutOff, DriveScript.opening, DriveScript.commandsUnavailable,
        ]
        for line in lines {
            #expect(!line.contains("\u{2014}"), "\(line)")
            #expect(line.rangeOfCharacter(from: CharacterSet(charactersIn: "\"*`#_<>[]{}")) == nil, "\(line)")
            #expect(!line.contains("..."), "\(line)")
        }
    }
}
