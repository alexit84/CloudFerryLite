import AppKit
import CryptoKit
import Foundation
import Observation

struct SSOError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Codice da mostrare all'utente durante il login SSO.
struct SSOLoginPrompt: Identifiable {
    let id = UUID()
    var startURL: String
    var userCode: String
    var verificationURL: URL
}

struct SSOAccount: Identifiable, Hashable {
    var accountId: String
    var accountName: String
    var id: String { accountId }
}

/// AWS IAM Identity Center: login con device authorization (come `aws sso login`) e credenziali temporanee del ruolo.
@Observable
@MainActor
final class SSOService {
    /// Login in attesa di conferma nel browser (mostrato come sheet).
    var prompt: SSOLoginPrompt?

    private var loginTasks: [String: Task<String, Error>] = [:]

    private struct CachedToken: Codable {
        var accessToken: String
        var expiresAt: Date
    }

    private struct ClientRegistration: Codable {
        var clientId: String
        var clientSecret: String
        var expiresAt: Date
    }

    // MARK: Token

    /// Access token valido per lo start URL: da cache (app o AWS CLI) o con un nuovo login interattivo.
    func accessToken(startURL: String, region: String, interactive: Bool = true) async throws -> String {
        if let t = cachedToken(startURL: startURL) { return t }
        guard interactive else { throw SSOError(message: String(localized: "SSO session expired: sign in again")) }
        // Più richieste contemporanee condividono lo stesso login.
        if let running = loginTasks[startURL] { return try await running.value }
        let task = Task { try await self.login(startURL: startURL, region: region) }
        loginTasks[startURL] = task
        defer { loginTasks[startURL] = nil }
        return try await task.value
    }

    func cancelLogin() {
        for t in loginTasks.values { t.cancel() }
        prompt = nil
    }

    func logout(startURL: String) {
        Keychain.delete(account: "sso-token:" + startURL)
    }

    private func cachedToken(startURL: String) -> String? {
        if let json = Keychain.get(account: "sso-token:" + startURL),
           let t = try? Self.decoder.decode(CachedToken.self, from: Data(json.utf8)),
           t.expiresAt.timeIntervalSinceNow > 300 {
            return t.accessToken
        }
        return awsCLICachedToken(startURL: startURL)
    }

    /// Riusa il token salvato da `aws sso login` in ~/.aws/sso/cache, se valido.
    private func awsCLICachedToken(startURL: String) -> String? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws/sso/cache")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["startUrl"] as? String)?.trimmingSlash == startURL.trimmingSlash,
                  let token = obj["accessToken"] as? String,
                  let exp = (obj["expiresAt"] as? String).flatMap(S3Date.parse),
                  exp.timeIntervalSinceNow > 300 else { continue }
            return token
        }
        return nil
    }

    private func login(startURL: String, region: String) async throws -> String {
        let oidc = "https://oidc.\(region).amazonaws.com"
        let reg = try await registration(region: region)
        let auth = try await postJSON(oidc + "/device_authorization",
                                      ["clientId": reg.clientId, "clientSecret": reg.clientSecret, "startUrl": startURL])
        guard let deviceCode = auth["deviceCode"] as? String,
              let userCode = auth["userCode"] as? String,
              let uri = (auth["verificationUriComplete"] as? String) ?? (auth["verificationUri"] as? String),
              let url = URL(string: uri) else {
            throw SSOError(message: String(localized: "Invalid device_authorization response"))
        }
        var interval = (auth["interval"] as? Double) ?? 5
        let deadline = Date().addingTimeInterval((auth["expiresIn"] as? Double) ?? 600)

        prompt = SSOLoginPrompt(startURL: startURL, userCode: userCode, verificationURL: url)
        defer { prompt = nil }
        NSWorkspace.shared.open(url)

        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            let (status, body) = try await post(oidc + "/token", [
                "clientId": reg.clientId, "clientSecret": reg.clientSecret,
                "grantType": "urn:ietf:params:oauth:grant-type:device_code", "deviceCode": deviceCode,
            ])
            if status == 200, let token = body["accessToken"] as? String {
                let expires = Date().addingTimeInterval((body["expiresIn"] as? Double) ?? 3600)
                let cached = CachedToken(accessToken: token, expiresAt: expires)
                if let data = try? Self.encoder.encode(cached) {
                    Keychain.set(String(decoding: data, as: UTF8.self), account: "sso-token:" + startURL)
                }
                return token
            }
            switch body["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "expired_token": throw SSOError(message: String(localized: "SSO code expired: try again"))
            case "access_denied": throw SSOError(message: String(localized: "SSO access denied"))
            default:
                let detail = "\(body["error_description"] ?? body["error"] ?? "HTTP \(status)")"
                throw SSOError(message: String(localized: "SSO sign-in failed: \(detail)"))
            }
        }
        throw SSOError(message: String(localized: "SSO sign-in timed out"))
    }

    /// Registrazione del client OIDC pubblico (valida ~90 giorni, salvata nel Keychain).
    private func registration(region: String) async throws -> ClientRegistration {
        let account = "sso-client:" + region
        if let json = Keychain.get(account: account),
           let r = try? Self.decoder.decode(ClientRegistration.self, from: Data(json.utf8)),
           r.expiresAt.timeIntervalSinceNow > 3600 {
            return r
        }
        let body = try await postJSON("https://oidc.\(region).amazonaws.com/client/register",
                                      ["clientName": "CloudFerryLite", "clientType": "public", "scopes": ["sso:account:access"]])
        guard let id = body["clientId"] as? String, let secret = body["clientSecret"] as? String else {
            throw SSOError(message: String(localized: "Invalid SSO client registration"))
        }
        let exp = Date(timeIntervalSince1970: (body["clientSecretExpiresAt"] as? Double) ?? Date().addingTimeInterval(86400 * 30).timeIntervalSince1970)
        let r = ClientRegistration(clientId: id, clientSecret: secret, expiresAt: exp)
        if let data = try? Self.encoder.encode(r) { Keychain.set(String(decoding: data, as: UTF8.self), account: account) }
        return r
    }

    // MARK: Portale (account, ruoli, credenziali)

    func roleCredentials(_ conn: Connection) async throws -> AWSCredentials {
        let token = try await accessToken(startURL: conn.ssoStartURL, region: conn.ssoRegion)
        let body = try await portalGET(conn.ssoRegion, "/federation/credentials",
                                       [("account_id", conn.ssoAccountID), ("role_name", conn.ssoRoleName)], token: token,
                                       startURL: conn.ssoStartURL)
        guard let rc = body["roleCredentials"] as? [String: Any],
              let ak = rc["accessKeyId"] as? String, let sk = rc["secretAccessKey"] as? String else {
            throw SSOError(message: String(localized: "Invalid role credentials"))
        }
        let exp = (rc["expiration"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return AWSCredentials(accessKeyID: ak, secretAccessKey: sk, sessionToken: rc["sessionToken"] as? String, expiration: exp)
    }

    func accounts(startURL: String, region: String) async throws -> [SSOAccount] {
        let token = try await accessToken(startURL: startURL, region: region)
        var out: [SSOAccount] = []
        var next: String?
        repeat {
            var q = [("max_result", "100")]
            if let next { q.append(("next_token", next)) }
            let body = try await portalGET(region, "/assignment/accounts", q, token: token, startURL: startURL)
            for a in body["accountList"] as? [[String: Any]] ?? [] {
                guard let id = a["accountId"] as? String else { continue }
                out.append(SSOAccount(accountId: id, accountName: a["accountName"] as? String ?? id))
            }
            next = body["nextToken"] as? String
        } while next != nil
        return out.sorted { $0.accountName.localizedStandardCompare($1.accountName) == .orderedAscending }
    }

    func roles(startURL: String, region: String, accountID: String) async throws -> [String] {
        let token = try await accessToken(startURL: startURL, region: region)
        let body = try await portalGET(region, "/assignment/roles", [("account_id", accountID), ("max_result", "100")],
                                       token: token, startURL: startURL)
        return (body["roleList"] as? [[String: Any]] ?? []).compactMap { $0["roleName"] as? String }.sorted()
    }

    private func portalGET(_ region: String, _ path: String, _ query: [(String, String)], token: String,
                           startURL: String) async throws -> [String: Any] {
        var comps = URLComponents(string: "https://portal.sso.\(region).amazonaws.com" + path)!
        comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        var req = URLRequest(url: comps.url!)
        req.setValue(token, forHTTPHeaderField: "x-amz-sso_bearer_token")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if status == 401 {
            // Token revocato o scaduto lato server: dimenticalo così il prossimo tentativo rifà il login.
            logout(startURL: startURL)
            throw SSOError(message: String(localized: "SSO session no longer valid: try again to sign in"))
        }
        guard status == 200 else {
            let detail = "\(body["message"] ?? "HTTP \(status)")"
            throw SSOError(message: String(localized: "SSO portal: \(detail)"))
        }
        return body
    }

    // MARK: HTTP

    private func postJSON(_ url: String, _ payload: [String: Any]) async throws -> [String: Any] {
        let (status, body) = try await post(url, payload)
        guard status == 200 else {
            throw SSOError(message: "SSO: \(body["error_description"] ?? body["message"] ?? body["error"] ?? "HTTP \(status)")")
        }
        return body
    }

    private func post(_ url: String, _ payload: [String: Any]) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, body)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}

private extension String {
    var trimmingSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}
