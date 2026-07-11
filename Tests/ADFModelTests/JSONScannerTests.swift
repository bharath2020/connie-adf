import Foundation
import Testing
@testable import ADFModel

@Suite("JSONScanner")
struct JSONScannerTests {
    @Test("scanner output matches the JSONSerialization bridge on every fixture", arguments: [
        "kitchen-sink", "stress-5k", "giant-table", "media-gallery",
    ])
    func matchesBridgeOnFixtures(name: String) throws {
        let data = try fixtureData("\(name).json")
        let scanned = try JSONScanner.scan(data)
        let bridged = try JSONValue(jsonObject: JSONSerialization.jsonObject(with: data))
        #expect(scanned == bridged)
    }

    @Test("escapes, unicode, surrogate pairs, and numbers decode exactly")
    func escapesAndNumbers() throws {
        let json = #"""
        {
          "quote": "a\"b",
          "backslash": "a\\b",
          "slash": "a\/b",
          "controls": "a\b\f\n\r\tb",
          "unicode": "café — dash",
          "surrogate": "😀",
          "rawUTF8": "héllo — 😀",
          "int": 42,
          "negative": -7,
          "zero": 0,
          "fraction": 3.25,
          "exponent": 1.5e3,
          "negExponent": 2E-2,
          "big": 1720569600000
        }
        """#
        let data = try #require(json.data(using: .utf8))
        let scanned = try JSONScanner.scan(data)
        let bridged = try JSONValue(jsonObject: JSONSerialization.jsonObject(with: data))
        #expect(scanned == bridged)
        #expect(scanned["surrogate"]?.stringValue == "\u{1F600}")
        #expect(scanned["big"]?.doubleValue == 1_720_569_600_000)
        #expect(scanned["exponent"]?.doubleValue == 1_500)
    }

    @Test("nested containers, literals, and whitespace round-trip")
    func containersAndLiterals() throws {
        let json = "\n\t {\"a\": [true, false, null, {\"b\": []}, [1, 2]], \"empty\": {}} \r\n"
        let data = try #require(json.data(using: .utf8))
        let scanned = try JSONScanner.scan(data)
        let bridged = try JSONValue(jsonObject: JSONSerialization.jsonObject(with: data))
        #expect(scanned == bridged)
    }

    @Test("malformed JSON throws", arguments: [
        "{", "{\"a\":}", "[1,]", "{\"a\":1,}", "01", "1.", "1e", "\"unterminated",
        "\"bad\\q\"", "\"\\uD83D\"", "tru", "{\"a\":1} trailing", "",
        "{\"a\" 1}", "nul", "-", "\"\\uZZZZ\"",
    ])
    func malformedThrows(json: String) throws {
        let data = try #require(json.data(using: .utf8))
        #expect(throws: JSONScanner.SyntaxError.self) {
            try JSONScanner.scan(data)
        }
    }

    @Test("scalar roots scan (parser rejects them later)")
    func scalarRoots() throws {
        #expect(try JSONScanner.scan(Data("42".utf8)) == .number(42))
        #expect(try JSONScanner.scan(Data("\"s\"".utf8)) == .string("s"))
        #expect(try JSONScanner.scan(Data("null".utf8)) == .null)
    }
}
