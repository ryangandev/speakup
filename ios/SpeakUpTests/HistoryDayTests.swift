import Foundation
import Testing
@testable import SpeakUp

struct HistoryDayTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }

    private func session(_ id: String, _ startedAt: String, prompts: [String]) throws -> SessionListItem {
        try Fixture.decode(SessionListItem.self, object: [
            "id": id, "mode": "home", "started_at": startedAt, "ended_at": NSNull(),
            "nervousness_before": NSNull(), "nervousness_after": NSNull(),
            "created_at": startedAt, "updated_at": startedAt,
            "prompts": prompts.map {
                ["id": "\(id)-\($0)", "kind": "own", "language": "en", "text": $0, "take_count": 1]
            },
            "take_count": prompts.count,
        ])
    }

    @Test func groupsTopicsByTheDayTheirSessionStarted() throws {
        let days = HistoryDay.group([
            try session("evening", "2026-11-10T19:00:00Z", prompts: ["Standup", "Demo"]),
            try session("morning", "2026-11-10T08:00:00Z", prompts: ["Review"]),
            try session("before", "2026-11-09T21:30:00Z", prompts: ["Retro"]),
        ], calendar: calendar)

        #expect(days.count == 2)
        // Newest first: the evening session's last topic leads the day.
        #expect(days[0].topics.map(\.prompt.text) == ["Demo", "Standup", "Review"])
        #expect(days[0].topics.first?.sessionID == "evening")
        #expect(days[1].topics.map(\.prompt.text) == ["Retro"])
    }

    @Test func aSessionWithNoTopicsLeavesNoEmptyDay() throws {
        let days = HistoryDay.group([try session("empty", "2026-11-08T10:00:00Z", prompts: [])], calendar: calendar)
        #expect(days.isEmpty)
    }

    @Test func dayHeadingsNameTodayAndYesterday() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-10T12:00:00Z"))
        let earlier = try #require(ISO8601DateFormatter().date(from: "2026-11-10T07:00:00Z"))
        let yesterday = try #require(ISO8601DateFormatter().date(from: "2026-11-09T23:00:00Z"))
        let lastWeek = try #require(ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z"))
        let lastYear = try #require(ISO8601DateFormatter().date(from: "2025-11-03T12:00:00Z"))
        #expect(Format.day(earlier, now: now, calendar: calendar) == "Today")
        #expect(Format.day(yesterday, now: now, calendar: calendar) == "Yesterday")
        #expect(Format.day(lastWeek, now: now, calendar: calendar).contains("3"))
        #expect(!Format.day(lastWeek, now: now, calendar: calendar).contains("2026"))
        #expect(Format.day(lastYear, now: now, calendar: calendar).contains("2025"))
    }
}
