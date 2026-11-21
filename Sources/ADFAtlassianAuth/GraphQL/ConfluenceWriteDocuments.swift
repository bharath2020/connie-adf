import Foundation

/// The GraphQL documents ADFReader sends to write to Confluence. All are
/// named and live under the `confluence` mutation namespace. The tenant
/// gateway (`https://<site>/gateway/api/graphql`) rejects the `cloudId`
/// argument the public `api.atlassian.com` schema shows on it ("Unknown
/// field argument 'cloudId'", live 2026-11-21); the IDs are ARIs, which
/// carry the cloud ID.
///
/// Field names, input types and scopes were read from the public gateway
/// schema by introspection (2026-11-20). Every write field there is a beta
/// field: requests must carry ``ConfluenceWriteDocuments/betaHeader``. The
/// schema marks each one callable with `API_TOKEN` and lists one granular
/// scope (see ``AtlassianTokenScopes/write``).
public enum ConfluenceWriteDocuments {
    /// `X-ExperimentalApi: confluence-agg-beta`. Without it the gateway
    /// rejects the request outright.
    public static let betaHeader = (name: "X-ExperimentalApi", value: "confluence-agg-beta")

    static let mutationErrors = "errors { message extensions { statusCode errorType } }"
    static let commentFields = "comment { id commentId links { base webUi } }"
    static let pageFields = "page { id pageId title latestVersion { number } links { base webUi } }"

    public static let createFooterCommentOperationName = "AdfCreateFooterComment"
    public static let createFooterComment = """
        mutation AdfCreateFooterComment($input: ConfluenceCreateFooterCommentOnPageInput!) {
          confluence {
            createFooterCommentOnPage(input: $input) { success \(mutationErrors) \(commentFields) }
          }
        }
        """

    public static let replyToCommentOperationName = "AdfReplyToComment"
    public static let replyToComment = """
        mutation AdfReplyToComment($input: ConfluenceReplyToCommentInput!) {
          confluence {
            replyToComment(input: $input) { success \(mutationErrors) \(commentFields) }
          }
        }
        """

    public static let updatePageOperationName = "AdfUpdatePage"
    public static let updatePage = """
        mutation AdfUpdatePage($input: ConfluenceUpdateCurrentPageInput!) {
          confluence {
            updateCurrentPage(input: $input) { success \(mutationErrors) \(pageFields) }
          }
        }
        """

    public static let createPageOperationName = "AdfCreatePage"
    public static let createPage = """
        mutation AdfCreatePage($input: ConfluenceCreatePageInput!) {
          confluence {
            createPage(input: $input) { success \(mutationErrors) \(pageFields) }
          }
        }
        """

    public static let createBlogPostOperationName = "AdfCreateBlogPost"
    public static let createBlogPost = """
        mutation AdfCreateBlogPost($input: ConfluenceCreateBlogPostInput!) {
          confluence {
            createBlogPost(input: $input) { success \(mutationErrors) blogPost { id blogPostId title latestVersion { number } links { base webUi } } }
          }
        }
        """

    public static let pageVersionOperationName = "AdfPageVersion"
    /// The current version of one page, read before an update to detect a
    /// stale version (`updateCurrentPage` takes no version number).
    public static let pageVersion = """
        query AdfPageVersion($id: ID!) {
          confluence {
            page(id: $id) { id pageId title status latestVersion { number } }
          }
        }
        """
}

extension GraphQLOperation {
    /// `{"representation": "ATLAS_DOC_FORMAT", "value": <ADF JSON string>}`.
    static func adfBody(_ adf: String) -> [String: Any] {
        ["representation": "ATLAS_DOC_FORMAT", "value": adf]
    }

    static func createFooterComment(cloudId: String, pageARI: String, adf: String) -> GraphQLOperation {
        GraphQLOperation(
            operationName: ConfluenceWriteDocuments.createFooterCommentOperationName,
            query: ConfluenceWriteDocuments.createFooterComment,
            jsonVariables: ["input": ["pageId": pageARI, "body": adfBody(adf)]],
            field: "confluence.createFooterCommentOnPage"
        )
    }

    static func replyToComment(cloudId: String, parentCommentARI: String, adf: String) -> GraphQLOperation {
        GraphQLOperation(
            operationName: ConfluenceWriteDocuments.replyToCommentOperationName,
            query: ConfluenceWriteDocuments.replyToComment,
            jsonVariables: ["input": ["parentCommentId": parentCommentARI, "body": adfBody(adf)]],
            field: "confluence.replyToComment"
        )
    }

    static func updatePage(cloudId: String, pageARI: String, title: String, adf: String) -> GraphQLOperation {
        GraphQLOperation(
            operationName: ConfluenceWriteDocuments.updatePageOperationName,
            query: ConfluenceWriteDocuments.updatePage,
            jsonVariables: ["input": ["id": pageARI, "title": title, "body": adfBody(adf)]],
            field: "confluence.updateCurrentPage"
        )
    }

    static func createPage(cloudId: String, spaceId: String, title: String, adf: String) -> GraphQLOperation {
        GraphQLOperation(
            operationName: ConfluenceWriteDocuments.createPageOperationName,
            query: ConfluenceWriteDocuments.createPage,
            jsonVariables: ["input": ["spaceId": spaceId, "title": title, "status": "CURRENT", "body": adfBody(adf)]],
            field: "confluence.createPage"
        )
    }

    static func createBlogPost(cloudId: String, spaceId: String, title: String, adf: String) -> GraphQLOperation {
        GraphQLOperation(
            operationName: ConfluenceWriteDocuments.createBlogPostOperationName,
            query: ConfluenceWriteDocuments.createBlogPost,
            jsonVariables: ["input": ["spaceId": spaceId, "title": title, "status": "CURRENT", "body": adfBody(adf)]],
            field: "confluence.createBlogPost"
        )
    }

    static func pageVersion(pageARI: String) -> GraphQLOperation {
        GraphQLOperation(
            operationName: ConfluenceWriteDocuments.pageVersionOperationName,
            query: ConfluenceWriteDocuments.pageVersion,
            jsonVariables: ["id": pageARI],
            field: "confluence.page"
        )
    }

    /// `ari:cloud:confluence:<cloudId>:<kind>/<id>`, or `id` unchanged when
    /// it already is an ARI.
    static func confluenceARI(cloudId: String, kind: String, id: String) -> String {
        id.hasPrefix("ari:") ? id : "ari:cloud:confluence:\(cloudId):\(kind)/\(id)"
    }
}
