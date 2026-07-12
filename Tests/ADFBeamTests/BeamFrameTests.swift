import Foundation
import Testing
@testable import ADFBeam

@Suite("BeamFrame parsing")
struct BeamFrameTests {
    @Test("valid payload parses all fields and decodes the chunk")
    func validPayload() throws {
        let chunk = Data("hello".utf8)
        let frame = try BeamFrame(payload: "ADF1|doc-42|2|5|\(chunk.base64EncodedString())")
        #expect(frame.docId == "doc-42")
        #expect(frame.index == 2)
        #expect(frame.total == 5)
        #expect(frame.chunk == chunk)
    }

    @Test("base64 padding characters survive the field split")
    func base64Padding() throws {
        let chunk = Data([0xDE, 0xAD, 0xBE, 0xEF]) // encodes with '=' padding
        let frame = try BeamFrame(payload: "ADF1|d|0|1|\(chunk.base64EncodedString())")
        #expect(frame.chunk == chunk)
    }

    @Test("malformed payloads are rejected with the right error", arguments: [
        ("QRX1|d|0|1|aGk=", BeamFrame.ParseError.badPrefix),
        ("ADF1|d|0|1", BeamFrame.ParseError.badFieldCount),
        ("plain text, no pipes", BeamFrame.ParseError.badFieldCount),
        ("ADF1||0|1|aGk=", BeamFrame.ParseError.emptyDocId),
        ("ADF1|d|x|1|aGk=", BeamFrame.ParseError.badIndex),
        ("ADF1|d|-1|1|aGk=", BeamFrame.ParseError.badIndex),
        ("ADF1|d|0|zero|aGk=", BeamFrame.ParseError.badTotal),
        ("ADF1|d|0|0|aGk=", BeamFrame.ParseError.badTotal),
        ("ADF1|d|3|3|aGk=", BeamFrame.ParseError.indexOutOfRange),
        ("ADF1|d|0|1|not base64!!", BeamFrame.ParseError.badBase64),
        ("ADF1|d|0|1|", BeamFrame.ParseError.badBase64),
    ])
    func malformedPayloads(payload: String, expected: BeamFrame.ParseError) {
        #expect(throws: expected) {
            try BeamFrame(payload: payload)
        }
    }
}
