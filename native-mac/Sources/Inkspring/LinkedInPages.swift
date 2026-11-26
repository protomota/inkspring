import Foundation

struct LinkedInDestination: Codable, Identifiable, Equatable, Sendable {
    let kind: String
    let urn: String
    let memberId: String
    let name: String

    var id: String { urn }

    var fields: [String: String] { ["kind": kind, "urn": urn, "memberId": memberId, "name": name] }

    init(kind: String, urn: String, memberId: String, name: String) {
        self.kind = kind
        self.urn = urn
        self.memberId = memberId
        self.name = name
    }

    init?(fields: [String: Any]?) {
        guard let fields, let kind = fields["kind"] as? String, let urn = fields["urn"] as? String,
              let member = fields["memberId"] as? String, let name = fields["name"] as? String,
              !name.isEmpty, name.utf16.count <= 300,
              member.range(of: #"\A[A-Za-z0-9_-]{1,200}\z"#, options: .regularExpression) != nil else { return nil }
        if kind == "personal" {
            guard urn == "urn:li:person:" + member else { return nil }
        } else {
            guard kind == "organization", Self.validOrganization(urn) else { return nil }
        }
        self.init(kind: kind, urn: urn, memberId: member, name: name)
    }

    static func personal(_ account: ManagedSocialAccount) -> Self {
        Self(kind: "personal", urn: "urn:li:person:" + account.id, memberId: account.id, name: account.name)
    }

    static func validOrganization(_ urn: String) -> Bool {
        urn.range(of: #"\Aurn:li:organization:[0-9]{1,24}\z"#, options: .regularExpression) != nil
    }
}

enum LinkedInPages {
    static let headers = ["LinkedIn-Version": "202609", "X-Restli-Protocol-Version": "2.0.0"]
    private static let roles: Set<String> = ["ADMINISTRATOR", "CONTENT_ADMINISTRATOR", "CONTENT_ADMIN"]

    static func available(_ account: ManagedSocialAccount) -> Bool {
        let scopes = (account.session.scopes ?? "").split { $0.isWhitespace || $0 == "," }
        return scopes.contains("w_organization_social")
            && (scopes.contains("r_organization_admin") || scopes.contains("rw_organization_admin"))
    }

    static func schedulingDestination(for draft: WorkspaceRecord, account: ManagedSocialAccount,
                                      selected: LinkedInDestination? = nil) throws -> LinkedInDestination {
        let personal = LinkedInDestination.personal(account)
        let saved = LinkedInDestination(fields: draft.fields["linkedinDestination"] as? [String: Any])
        guard selected != nil || draft.fields["linkedinDestination"] == nil || saved != nil else {
            throw WorkspaceError("Choose a valid LinkedIn destination before scheduling.")
        }
        let requested = selected ?? saved ?? personal
        let destinations = [personal] + (available(account) ? account.linkedInPages ?? [] : [])
        guard requested.memberId == account.id,
              let destination = destinations.first(where: { $0.urn == requested.urn && $0.memberId == account.id }) else {
            throw WorkspaceError("Choose your current LinkedIn profile or refresh the company pages in Connections before scheduling.")
        }
        let scopes = (account.session.scopes ?? "").split { $0.isWhitespace || $0 == "," }
        guard destination.kind != "personal" || scopes.isEmpty || scopes.contains("w_member_social") else {
            throw WorkspaceError("Reconnect LinkedIn with permission to publish to your profile.")
        }
        return destination
    }

    @MainActor
    static func refresh(_ account: ManagedSocialAccount, transport: SocialTransport) async throws -> [LinkedInDestination] {
        guard available(account) else { throw WorkspaceError("Reconnect a LinkedIn developer app with company-page access.") }
        var organizations: Set<String> = []
        let acl = URL(string: "https://api.linkedin.com/rest/organizationAcls")!
        for start in stride(from: 0, to: 1000, by: 100) {
            let url = acl.appending(queryItems: [
                .init(name: "q", value: "roleAssignee"), .init(name: "state", value: "APPROVED"),
                .init(name: "start", value: String(start)), .init(name: "count", value: "100")
            ])
            let (result, _) = try await transport.request(url, token: account.session.accessToken, headers: headers)
            guard let entries = result["elements"] as? [[String: Any]], entries.count <= 100 else {
                throw WorkspaceError("LinkedIn returned an unreadable company-page list.")
            }
            for row in entries {
                if row["state"] as? String == "APPROVED", row["roleAssignee"] as? String == "urn:li:person:" + account.id,
                   let role = row["role"] as? String, roles.contains(role),
                   let urn = row["organization"] as? String, LinkedInDestination.validOrganization(urn) {
                    organizations.insert(urn)
                }
            }
            if entries.count < 100 { break }
            if start == 900 { throw WorkspaceError("LinkedIn returned too many company-page roles.") }
        }
        var pages: [LinkedInDestination] = []
        for urn in organizations.sorted() {
            let id = urn.split(separator: ":").last.map(String.init) ?? ""
            let url = URL(string: "https://api.linkedin.com/rest/organizations/")!.appending(path: id)
            let (value, _) = try await transport.request(url, token: account.session.accessToken, headers: headers)
            let returnedID = value["id"] as? String ?? (value["id"] as? NSNumber)?.stringValue
            guard returnedID == id, let name = value["localizedName"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkspaceError("LinkedIn didn’t identify the company page.")
            }
            pages.append(LinkedInDestination(kind: "organization", urn: urn, memberId: account.id, name: String(name.prefix(300))))
        }
        return pages
    }
}
