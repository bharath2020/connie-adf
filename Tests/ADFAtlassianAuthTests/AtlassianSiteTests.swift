import Foundation
import Testing
@testable import ADFAtlassianAuth

@Suite("Atlassian site normalizer")
struct AtlassianSiteTests {
    @Test("accepted forms normalize to the same host", arguments: [
        "acme",
        "acme.atlassian.net",
        "ACME",
        "Acme.Atlassian.NET",
        "  acme.atlassian.net \n",
        "acme.atlassian.net.",
        "acme.atlassian.net:443",
        "acme.atlassian.net/wiki",
        "acme.atlassian.net?x=1",
        "https://acme.atlassian.net",
        "https://acme.atlassian.net/",
        "http://acme.atlassian.net:8080/wiki",
        "https://acme.atlassian.net/wiki/spaces/X/pages/1/T",
        "HTTPS://ACME.ATLASSIAN.NET/wiki/spaces/X/pages/1/T?focusedCommentId=2#anchor",
    ])
    func accepted(input: String) throws {
        let site = try AtlassianSite(parsing: input)
        #expect(site.host == "acme.atlassian.net")
    }

    @Test("names with digits and inner hyphens are accepted", arguments: [
        ("my-team-42", "my-team-42.atlassian.net"),
        ("a", "a.atlassian.net"),
        ("0", "0.atlassian.net"),
        (String(repeating: "a", count: 63), String(repeating: "a", count: 63) + ".atlassian.net"),
    ])
    func acceptedNames(input: String, host: String) throws {
        #expect(try AtlassianSite(parsing: input).host == host)
    }

    @Test("empty input is rejected", arguments: ["", "   ", "\n\t"])
    func empty(input: String) {
        #expect(throws: AtlassianSite.ParseError.empty) { try AtlassianSite(parsing: input) }
    }

    @Test("other hosts are unsupported", arguments: [
        ("wiki.acme.com", "wiki.acme.com"),
        ("https://confluence.acme.com/display/X", "confluence.acme.com"),
        ("evil.atlassian.net.example.com", "evil.atlassian.net.example.com"),
        ("atlassian.net", "atlassian.net"),
        ("a.b.atlassian.net", "a.b.atlassian.net"),
        ("acme.jira.com", "acme.jira.com"),
    ])
    func unsupported(input: String, host: String) {
        #expect(throws: AtlassianSite.ParseError.unsupportedHost(host)) { try AtlassianSite(parsing: input) }
    }

    @Test("invalid names are rejected", arguments: [
        "acme_corp",
        "-acme",
        "acme-",
        "-acme-.atlassian.net",
        String(repeating: "a", count: 64),
        "ac me",
        "acmé",
        "acme!",
    ])
    func invalid(input: String) {
        #expect {
            try AtlassianSite(parsing: input)
        } throws: { error in
            guard let error = error as? AtlassianSite.ParseError, case .invalidName = error else { return false }
            return true
        }
    }

    @Test("unsupported hosts explain the atlassian.net rule")
    func unsupportedMessage() {
        #expect(AtlassianSite.ParseError.unsupportedHost("wiki.acme.com").message.contains("Only <name>.atlassian.net sites are supported for now"))
    }

    @Test("the GraphQL endpoint is the tenant gateway")
    func endpoint() throws {
        let site = try AtlassianSite(parsing: "acme")
        #expect(site.graphQLEndpoint.absoluteString == "https://acme.atlassian.net/gateway/api/graphql")
    }

    @Test("codes as a single JSON string and normalizes on decode")
    func codable() throws {
        let site = try AtlassianSite(parsing: "acme")
        let data = try JSONEncoder().encode([site])
        #expect(String(decoding: data, as: UTF8.self) == #"["acme.atlassian.net"]"#)
        let decoded = try JSONDecoder().decode([AtlassianSite].self, from: Data(#"["ACME.atlassian.net"]"#.utf8))
        #expect(decoded == [site])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([AtlassianSite].self, from: Data(#"["wiki.acme.com"]"#.utf8))
        }
    }
}
