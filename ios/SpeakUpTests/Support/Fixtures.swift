import Foundation
@testable import SpeakUp

/// The contract's JSON examples from docs/architecture.md, copied verbatim into `Fixtures/`.
/// They are read from the test bundle, never from the repository by path.
enum Fixture {
    private final class BundleToken {}

    static func data(_ name: String) -> Data {
        guard let url = Bundle(for: BundleToken.self).url(forResource: name, withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { fatalError("Missing fixture \(name).json") }
        return data
    }

    static func object(_ name: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: data(name)) as! [String: Any]
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONCoding.decoder().decode(type, from: data(name))
    }

    static func decode<T: Decodable>(_ type: T.Type, object: Any) throws -> T {
        try JSONCoding.decoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }

    /// The full report response the contract describes: the abbreviated example with `take`,
    /// `prompt`, `analysis` and `coaching` replaced by the full resources, as its text says.
    static func fullReportObject() -> [String: Any] {
        var report = object("report_abbreviated")
        var take = object("take_done")
        take["id"] = "c41a7e02-5b9d-4c66-8e1f-0a7b3d92f5c4"
        take["attempt"] = 1
        take["previous_take_id"] = NSNull()
        report["take"] = take
        report["prompt"] = promptObject()
        report["analysis"] = object("analysis")
        report["coaching"] = object("coaching")
        return report
    }

    /// The Prompt resource from the session detail example, without `takes`.
    static func promptObject() -> [String: Any] {
        let detail = object("session_detail")
        var prompt = (detail["prompts"] as! [[String: Any]])[0]
        prompt.removeValue(forKey: "takes")
        return prompt
    }

    /// Compares two JSON documents by value, ignoring key order.
    static func sameJSON(_ lhs: Data, _ rhs: Data) -> Bool {
        guard let left = try? JSONSerialization.jsonObject(with: lhs),
            let right = try? JSONSerialization.jsonObject(with: rhs)
        else { return false }
        return (left as AnyObject).isEqual(right)
    }
}
