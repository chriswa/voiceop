import XCTest
@testable import VoiceOperator

final class NameVoiceTableTests: XCTestCase {
    /// Names whose conventional gender is independent of the table, so a table
    /// regeneration that pairs e.g. "Emma" with a masculine voice fails here.
    /// Any name not in this set is treated as masculine.
    private static let feminineNames: Set<String> = [
        "Bella", "Beth", "Chloe", "Claire", "Dana", "Daphne", "Diana", "Emma",
        "Fiona", "Gemma", "Grace", "Hazel", "Heidi", "Iris", "Ivy", "Jane",
        "Julia", "Kate", "Laura", "Lily", "Lucy", "Maya", "Mia", "Molly",
        "Naomi", "Nina", "Nora", "Olivia", "Penny", "Piper", "Rachel", "Rita",
        "Rose", "Ruth", "Sadie", "Stella", "Tessa", "Vivian", "Wendy",
        "Zoe",
    ]

    func testEveryNameMatchesItsVoiceGender() {
        for pair in NameVoiceTable.all {
            let expected: VoiceGender =
                Self.feminineNames.contains(pair.name) ? .feminine : .masculine
            XCTAssertEqual(pair.gender, expected,
                           "'\(pair.name)' is paired with a \(pair.gender.rawValue) voice")
        }
    }

    func testGenderClassificationCoversTable() {
        // If the roster gains a name this test has never heard of, force a
        // conscious decision about its gender rather than defaulting silently.
        let known = Self.feminineNames.union([
            "Oliver", "Jack", "Henry", "Leo", "Max", "Noah", "Ethan", "Lucas",
            "Mason", "Logan", "Nathan", "Caleb", "Isaac", "Blake", "Dean",
            "Evan", "Grant", "Jake", "Kyle", "Luke", "Mark", "Miles", "Ross",
            "Scott", "Wade", "Wyatt", "Bruno", "Harvey", "Leon", "Marcus",
            "Oscar", "Simon", "Victor", "George", "Jonah", "Roland", "Vincent",
            "Nolan", "Wesley", "Felix", "Jasper",
        ])
        for pair in NameVoiceTable.all {
            XCTAssertTrue(known.contains(pair.name),
                          "'\(pair.name)' is not in the test's gender lists — add it")
        }
    }
}
