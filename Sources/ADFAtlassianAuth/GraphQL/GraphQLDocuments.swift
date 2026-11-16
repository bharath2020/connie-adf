import Foundation

/// Every GraphQL document ADFReader sends. All operations are named.
///
/// Verified against the public gateway schema by introspection; how the
/// gateway treats a scoped API token at runtime is unverified.
public enum GraphQLDocuments {
    public static let authCheckOperationName = "AdfAuthCheck"

    /// The single harmless call used to check a token. `tenantContexts` has
    /// no `@scopes` / `@scopedApiTokenUnavailable` directive.
    public static let authCheck = """
        query AdfAuthCheck($hostNames: [String!]!) {
          tenantContexts(hostNames: $hostNames) { cloudId hostName }
        }
        """

    public static let probePagesOperationName = "AdfProbePages"

    /// Page titles, spaces and title emoji. `metadata` needs
    /// `read:content.metadata:confluence` (one of the requested scopes); a
    /// token created without it gets `metadata` back as null with an error
    /// (partial success).
    public static let probePages = """
        query AdfProbePages($ids: [ID!]!) {
          confluence {
            pages(ids: $ids) {
              id pageId title
              links { base webUi }
              space { id key name icon { path } }
              metadata { titleEmojiPublished { id key value } }
            }
          }
        }
        """
}

/// A named GraphQL operation with its JSON request body.
public struct GraphQLOperation: Sendable, Equatable {
    public let operationName: String
    public let query: String
    /// The POST body: `{"operationName","query","variables"}`, sorted keys.
    public let body: Data
    /// The GraphQL field the operation reads, used in error messages.
    public let field: String

    init(operationName: String, query: String, variables: [String: [String]], field: String) {
        self.operationName = operationName
        self.query = query
        self.field = field
        let object: [String: Any] = ["operationName": operationName, "query": query, "variables": variables]
        // A dictionary of strings always serializes.
        self.body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// `AdfAuthCheck` with `{"hostNames": [<host>]}`.
    public static func authCheck(site: AtlassianSite) -> GraphQLOperation {
        GraphQLOperation(
            operationName: GraphQLDocuments.authCheckOperationName,
            query: GraphQLDocuments.authCheck,
            variables: ["hostNames": [site.host]],
            field: "tenantContexts"
        )
    }

    /// `AdfProbePages` with `{"ids": [<page ARIs>]}`.
    public static func probePages(pageIds: [String], cloudId: String) -> GraphQLOperation {
        GraphQLOperation(
            operationName: GraphQLDocuments.probePagesOperationName,
            query: GraphQLDocuments.probePages,
            variables: ["ids": pageIds.map { pageARI(cloudId: cloudId, pageId: $0) }],
            field: "confluence.pages"
        )
    }

    /// `ari:cloud:confluence:<cloudId>:page/<pageId>`.
    public static func pageARI(cloudId: String, pageId: String) -> String {
        "ari:cloud:confluence:\(cloudId):page/\(pageId)"
    }

    /// The body as pretty-printed JSON, for dry runs.
    public var prettyBody: String {
        guard let object = try? JSONSerialization.jsonObject(with: body),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return String(decoding: body, as: UTF8.self) }
        return String(decoding: data, as: UTF8.self)
    }
}
