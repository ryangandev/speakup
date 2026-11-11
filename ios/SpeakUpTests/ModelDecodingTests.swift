import Foundation
import Testing
@testable import SpeakUp

/// Every contract example decodes, and every request body the app sends encodes to the
/// contract's example.
struct ModelDecodingTests {
    @Test func health() throws {
        let health = try Fixture.decode(Health.self, "health")
        #expect(health.apiVersion == "v1")
        #expect(health.sttEngine == "crisperwhisper")
        #expect(health.coaching.available)
        #expect(health.coaching.model == "claude-opus-5-5")
        #expect(health.coaching.rubricVersion == "rubric/1")
        #expect(health.queueLength == 0)
    }

    @Test func session() throws {
        let session = try Fixture.decode(Session.self, "session")
        #expect(session.id == "0b6f3c1e-8f5a-4f3e-9a51-2d1c7e4b9a10")
        #expect(session.mode == .home)
        #expect(session.endedAt == nil)
        #expect(session.nervousnessBefore == 3)
        #expect(session.nervousnessAfter == nil)
        #expect(JSONCoding.formatDate(session.startedAt) == "2026-11-09T08:12:03.115Z")
    }

    @Test func sessionsList() throws {
        let list = try Fixture.decode(SessionList.self, "sessions_list")
        #expect(list.nextBefore == nil)
        let item = try #require(list.sessions.first)
        #expect(item.session.nervousnessAfter == 2)
        #expect(item.takeCount == 2)
        #expect(item.prompts.first?.kind == .impromptu)
        #expect(item.prompts.first?.takeCount == 2)
    }

    @Test func sessionDetail() throws {
        let detail = try Fixture.decode(SessionDetail.self, "session_detail")
        #expect(detail.session.endedAt != nil)
        let prompt = try #require(detail.prompts.first)
        #expect(prompt.prompt.category == .decision)
        #expect(prompt.prompt.questionSource == .claude)
        #expect(prompt.prompt.notes == nil)
        #expect(prompt.prompt.targetSeconds == 90)
        #expect(prompt.takes.isEmpty)
    }

    @Test func promptDetailWithTakes() throws {
        var object = Fixture.promptObject()
        object["takes"] = [Fixture.object("take_uploaded"), Fixture.object("take_done")]
        let detail = try Fixture.decode(PromptDetail.self, object: object)
        #expect(detail.prompt.id == "7d2e9a44-1c3b-4e8f-b6a2-93f0c5d1e7a8")
        #expect(detail.takes.map(\.status) == [.uploaded, .done])
    }

    @Test func questionsResponse() throws {
        let response = try Fixture.decode(QuestionsResponse.self, "questions_response")
        #expect(response.source == .claude)
        #expect(response.questions.map(\.category) == [.status, .decision, .pushback])
        #expect(response.questions.map(\.targetSeconds) == [90, 90, 60])
        #expect(response.questions.allSatisfy { $0.theme == nil })
    }

    @Test func interestQuestionsResponse() throws {
        let response = try Fixture.decode(QuestionsResponse.self, "questions_interests_response")
        #expect(response.questions.allSatisfy { $0.category == .interest })
        #expect(response.questions.map(\.theme) == ["Contentment", "Charisma", "Travel"])
        #expect(response.questions.map(\.targetSeconds) == [60, 90, 60])
    }

    @Test func interestQuestionsRequestMatchesContract() throws {
        let body = QuestionsRequest(
            count: 3, track: .interests, category: nil, theme: nil, exclude: [], language: .chinese)
        #expect(Fixture.sameJSON(try JSONCoding.encoder().encode(body), Fixture.data("questions_interests_request")))
    }

    @Test func workQuestionsRequestMatchesContract() throws {
        let body = QuestionsRequest(
            count: 3, category: .decision,
            exclude: ["Why did we choose Postgres over DynamoDB for the billing service?"])
        #expect(Fixture.sameJSON(try JSONCoding.encoder().encode(body), Fixture.data("questions_request")))
    }

    @Test func themes() throws {
        let list = try Fixture.decode(InterestThemeList.self, "themes_list")
        #expect(list.themes.map(\.name) == ["Happiness", "Courage", "Charisma"])
        #expect(list.themes.map(\.source) == [.learned, .added, .learned])
        #expect(list.themes.map(\.pinned) == [true, false, false])
        let theme = try Fixture.decode(InterestTheme.self, "theme")
        #expect(theme == list.themes[1])
    }

    @Test func themeRequestsMatchContract() throws {
        let encoder = JSONCoding.encoder()
        #expect(Fixture.sameJSON(try encoder.encode(ThemeCreateRequest(name: "Courage")), Fixture.data("theme_create_request")))
        #expect(Fixture.sameJSON(try encoder.encode(ThemePatchRequest(pinned: true)), Fixture.data("theme_patch_request")))
    }

    @Test func takeUploaded() throws {
        let take = try Fixture.decode(Take.self, "take_uploaded")
        #expect(take.status == .uploaded)
        #expect(take.coachingStatus == .pending)
        #expect(take.micRoute == .builtIn)
        #expect(take.previousTakeId == "c41a7e02-5b9d-4c66-8e1f-0a7b3d92f5c4")
        #expect(take.summary == nil)
        #expect(take.error == nil)
        #expect(take.durationS == 78.2)
    }

    @Test func takeDone() throws {
        let take = try Fixture.decode(Take.self, "take_done")
        #expect(take.status == .done)
        let summary = try #require(take.summary)
        #expect(summary.focusTitles == ["Close on purpose"])
        #expect(summary.fillersPer100Words == 2.9)
        #expect(summary.blocks == 1)
        #expect(summary.wpmVoiced == 171.4)
    }

    /// The contract describes a failed take in prose; this is that take.
    @Test func takeFailed() throws {
        var object = Fixture.object("take_uploaded")
        object["status"] = "failed"
        object["error"] = ["code": "no_speech", "message": "Fewer than 5 words were transcribed."]
        let take = try Fixture.decode(Take.self, object: object)
        #expect(take.status == .failed)
        #expect(take.error?.code == .noSpeech)
    }

    /// "summary.verdict and summary.focus_titles are null and empty without coaching."
    @Test func takeSummaryWithoutCoaching() throws {
        var object = Fixture.object("take_done")
        object["coaching_status"] = "unavailable"
        object["summary"] = [
            "verdict": NSNull(), "focus_titles": [String](), "fillers_per_100_words": 2.9, "blocks": 1,
            "restarts": 2, "wpm_voiced": 171.4,
        ]
        let take = try Fixture.decode(Take.self, object: object)
        #expect(take.coachingStatus == .unavailable)
        #expect(take.summary?.verdict == nil)
        #expect(take.summary?.focusTitles == [])
    }

    @Test func analysis() throws {
        let analysis = try Fixture.decode(Analysis.self, "analysis")
        #expect(analysis.schemaVersion == "analysis/1")
        #expect(analysis.coachingApplied)
        #expect(analysis.provenance?.stt.engine == "crisperwhisper")
        #expect(analysis.words.count == 18)
        #expect(analysis.words.enumerated().allSatisfy { $0.offset == $0.element.i })
        #expect(analysis.words[1].kind == .filledPause)
        #expect(analysis.words[3].cutoff)
        #expect(analysis.events.count == 8)
        let restart = try #require(analysis.events.first { $0.id == "e1" })
        #expect(restart.type == .restart)
        #expect(restart.reason == "cutoff")
        #expect(restart.repairWord == 4)
        let block = try #require(analysis.events.first { $0.id == "e3" })
        #expect(block.isPoint)
        #expect(block.isProblem)
        let boundary = try #require(analysis.events.first { $0.id == "e4" })
        #expect(!boundary.isProblem)
        let offTopic = try #require(analysis.events.first { $0.id == "c0" })
        #expect(offTopic.source == .coaching)
        #expect(offTopic.note != nil)

        let metrics = analysis.metrics
        #expect(metrics.wordCount == 214)
        #expect(metrics.fillers.per100Words == 3.74)
        #expect(metrics.blocks.longestS == 1.1)
        #expect(metrics.boundaryPauses.medianS == 0.55)
        #expect(metrics.pace.byQuarterWpm.count == 4)
        #expect(metrics.pitch?.variationSt == 2.3)
        #expect(metrics.volume?.variationDb == 4.1)
        #expect(analysis.nervousnessSigns.first?.type == .paceRise)
    }

    @Test func analysisWithoutPitchOrVolume() throws {
        var object = Fixture.object("analysis")
        var metrics = object["metrics"] as! [String: Any]
        metrics["pitch"] = NSNull()
        metrics["volume"] = NSNull()
        metrics["boundary_pauses"] = ["count": 0, "median_s": NSNull()]
        object["metrics"] = metrics
        let analysis = try Fixture.decode(Analysis.self, object: object)
        #expect(analysis.metrics.pitch == nil)
        #expect(analysis.metrics.volume == nil)
        #expect(analysis.metrics.boundaryPauses.medianS == nil)
    }

    @Test func coaching() throws {
        let coaching = try Fixture.decode(CoachingReport.self, "coaching")
        #expect(coaching.model == "claude-opus-5-5")
        #expect(coaching.strength.dimension == .answerFirst)
        #expect(coaching.strength.anchor.start == 2.45)
        #expect(coaching.focus.count == 2)
        #expect(coaching.focus[0].evidence.first?.wordStart == 9)
        #expect(coaching.dimensions.layering.level == .needsWork)
        #expect(coaching.dimensions.rows.map(\.dimension) == Dimension.all)
        #expect(coaching.outline.mainPointFirst)
        #expect(coaching.outline.points.map(\.role) == [.main, .support, .support, .aside, .close])
        #expect(coaching.referenceVersion.text.contains("\n\n"))
        #expect(coaching.fillerRulings == [FillerRuling(eventId: "e2", isFiller: true)])
        #expect(coaching.annotations.first?.type == .offTopic)
        #expect(coaching.comparison == nil)
    }

    @Test func coachingComparison() throws {
        let comparison = try Fixture.decode(CoachingComparison.self, "coaching_comparison")
        #expect(comparison.focusOutcomes.map(\.outcome) == [.improved, .partlyImproved])
        #expect(comparison.focusOutcomes[0].anchor?.quote == "Two reasons. First,")
        #expect(comparison.focusOutcomes[1].anchor == nil)
    }

    @Test func comparison() throws {
        let comparison = try Fixture.decode(Comparison.self, "comparison")
        #expect(comparison.attempt == 2)
        #expect(comparison.previousAttempt == 1)
        #expect(comparison.focusOutcomes.count == 2)
        #expect(comparison.dimensionChanges.map(\.dimension) == Dimension.all)
        #expect(comparison.dimensionChanges[1].change == .better)
        #expect(comparison.metricChanges.map(\.metric) == [
            "fillers_per_100_words", "blocks", "restarts", "repetitions", "wpm_voiced", "duration_s",
            "pitch_variation_st", "volume_variation_db",
        ])
        #expect(comparison.metricChanges[1].before == 4)
        #expect(comparison.metricChanges[3].change == .worse)
        #expect(comparison.metricChanges[4].change == .info)
    }

    @Test func fullReport() throws {
        let report = try Fixture.decode(TakeReport.self, object: Fixture.fullReportObject())
        #expect(report.take.attempt == 1)
        #expect(report.prompt.kind == .impromptu)
        #expect(report.analysis.words.count == 18)
        #expect(report.coaching?.verdict.isEmpty == false)
        #expect(!report.hasComparison)
    }

    @Test func reportWithoutCoaching() throws {
        var object = Fixture.fullReportObject()
        object["coaching"] = NSNull()
        let report = try Fixture.decode(TakeReport.self, object: object)
        #expect(report.coaching == nil)
    }

    @Test func errorBody() throws {
        let body = try Fixture.decode(APIErrorBody.self, "error")
        #expect(body.error.code == "not_found")
        #expect(body.error.details == nil)
    }

    // MARK: Forward compatibility

    /// Unknown keys are ignored and unknown enum values are kept, never a decoding failure.
    @Test func unknownKeysAndEnumValues() throws {
        var object = Fixture.object("take_done")
        object["status"] = "archived"
        object["coaching_status"] = "queued"
        object["mic_route"] = "airplay"
        object["brand_new_key"] = ["nested": true]
        let take = try Fixture.decode(Take.self, object: object)
        #expect(take.status.rawValue == "archived")
        #expect(!take.status.isFinal)
        #expect(take.status.label == "Archived")
        #expect(take.coachingStatus.rawValue == "queued")
        #expect(take.micRoute.rawValue == "airplay")
    }

    @Test func unknownEventTypeIsPlainText() throws {
        var object = Fixture.object("analysis")
        var events = object["events"] as! [[String: Any]]
        events[0]["type"] = "mumble"
        object["events"] = events
        let analysis = try Fixture.decode(Analysis.self, object: object)
        #expect(analysis.events[0].type.rawValue == "mumble")
        #expect(TranscriptMarkKind(event: analysis.events[0]) == nil)
        #expect(!analysis.events[0].isProblem)
    }

    @Test func timestampsWithAndWithoutMilliseconds() {
        #expect(JSONCoding.parseDate("2026-11-09T08:15:30.123Z") != nil)
        #expect(JSONCoding.parseDate("2026-11-09T08:15:30Z") != nil)
        #expect(JSONCoding.parseDate("yesterday") == nil)
        let date = Date(timeIntervalSince1970: 1_793_268_930.123)
        #expect(JSONCoding.formatDate(date).hasSuffix(".123Z"))
    }

    @Test func idsAreLowercaseUUIDs() {
        let id = IDs.make()
        #expect(id == id.lowercased())
        #expect(UUID(uuidString: id) != nil)
    }

    // MARK: Requests

    @Test func sessionCreateRequestMatchesContract() throws {
        let body = SessionCreateRequest(
            mode: .home, startedAt: try #require(JSONCoding.parseDate("2026-11-09T08:12:03.115Z")),
            nervousnessBefore: 3)
        #expect(Fixture.sameJSON(try JSONCoding.encoder().encode(body), Fixture.data("session_create_request")))
    }

    @Test func skippedRatingIsSentAsNull() throws {
        let body = SessionCreateRequest(mode: .home, startedAt: Date(), nervousnessBefore: nil)
        let object = try JSONSerialization.jsonObject(with: JSONCoding.encoder().encode(body)) as? [String: Any]
        #expect(object?["nervousness_before"] is NSNull)
    }

    @Test func sessionEndRequestMatchesContract() throws {
        let body = SessionEndRequest(
            endedAt: try #require(JSONCoding.parseDate("2026-11-09T08:41:50.020Z")), nervousnessAfter: 2)
        #expect(Fixture.sameJSON(try JSONCoding.encoder().encode(body), Fixture.data("session_end_request")))
    }

    @Test func promptCreateRequestMatchesContract() throws {
        let body = PromptCreateRequest(
            sessionId: "0b6f3c1e-8f5a-4f3e-9a51-2d1c7e4b9a10", kind: .impromptu,
            text: "Why did we choose Postgres over DynamoDB for the billing service?", notes: nil,
            category: .decision, targetSeconds: 90, questionSource: .claude, language: .english)
        #expect(Fixture.sameJSON(try JSONCoding.encoder().encode(body), Fixture.data("prompt_create_request")))
    }

    @Test func anInterestPromptCarriesItsTheme() throws {
        var object = Fixture.promptObject()
        #expect(try Fixture.decode(Prompt.self, object: object).theme == nil)
        object["category"] = "interest"
        object["theme"] = "Travel"
        let prompt = try Fixture.decode(Prompt.self, object: object)
        #expect(prompt.category == .interest)
        #expect(prompt.theme == "Travel")
        object.removeValue(forKey: "theme")
        #expect(try Fixture.decode(Prompt.self, object: object).theme == nil, "A server from before themes sends none")
    }

    @Test func aPromptWithoutALanguageIsEnglish() throws {
        var object = Fixture.promptObject()
        object.removeValue(forKey: "language")
        #expect(try Fixture.decode(Prompt.self, object: object).language == .english)
        object["language"] = "zh"
        #expect(try Fixture.decode(Prompt.self, object: object).language == .chinese)
    }

    @Test func takeMetadataMatchesContract() throws {
        let body = TakeUploadMetadata(
            promptId: "7d2e9a44-1c3b-4e8f-b6a2-93f0c5d1e7a8", attempt: 2,
            recordedAt: try #require(JSONCoding.parseDate("2026-11-09T08:19:47.530Z")), durationS: 78.2,
            audioSha256: "9f2c4e0b7a1d3c5e8f6a2b4d0c9e7f1a3b5d7c9e1f2a4b6c8d0e2f4a6b8c0d2e", micRoute: .builtIn)
        #expect(Fixture.sameJSON(try JSONCoding.encoder().encode(body), Fixture.data("take_upload_metadata")))
    }

    @Test func questionsRequestMatchesContract() throws {
        let body = QuestionsRequest(
            count: 3, category: .decision,
            exclude: ["Why did we choose Postgres over DynamoDB for the billing service?"])
        #expect(Fixture.sameJSON(try JSONCoding.encoder().encode(body), Fixture.data("questions_request")))
    }

    @Test func anyCategoryIsSentAsNull() throws {
        let body = QuestionsRequest(count: 3, category: nil, exclude: [])
        let object = try JSONSerialization.jsonObject(with: JSONCoding.encoder().encode(body)) as? [String: Any]
        #expect(object?["category"] is NSNull)
    }

    @Test func reprocessRequestMatchesContract() throws {
        let body = ReprocessRequest(fromStage: .coaching)
        #expect(Fixture.sameJSON(try JSONCoding.encoder().encode(body), Fixture.data("reprocess_request")))
    }
}
