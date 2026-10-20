import CryptoKit
import Foundation

struct S3Error: LocalizedError {
    var status: Int
    var code: String
    var message: String
    var errorDescription: String? {
        switch status {
        case 403: return String(localized: "Access denied (\(code)): \(message)")
        case 404: return String(localized: "Not found (\(code)): \(message)")
        case 0 where code.isEmpty: return message
        default: return "\(code.isEmpty ? "HTTP \(status)" : code): \(message)"
        }
    }
}

struct AWSCredentials: Sendable {
    var accessKeyID: String
    var secretAccessKey: String
    var sessionToken: String?
    var expiration: Date?

    /// True if they expire within 5 minutes.
    var isExpiring: Bool { expiration.map { $0.timeIntervalSinceNow < 300 } ?? false }
}

/// Minimal S3 client with AWS Signature V4 signing (no external dependencies).
final class S3Client: @unchecked Sendable {
    let connection: Connection
    let credentials: AWSCredentials
    let session: URLSession

    private let lock = NSLock()
    private var bucketRegions: [String: String] = [:]

    static let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    static let unsignedPayload = "UNSIGNED-PAYLOAD"

    init(connection: Connection, credentials: AWSCredentials) {
        self.connection = connection
        self.credentials = credentials
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.httpMaximumConnectionsPerHost = 8
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Operations

    func listBuckets() async throws -> [String] {
        let (data, _) = try await send("GET", bucket: nil)
        return XMLNode.parse(data).all("Bucket").compactMap { $0.value("Name") }
    }

    /// One ListObjectsV2 page.
    struct ListPage {
        var items: [RemoteItem]
        var nextToken: String?
    }

    func listPage(bucket: String, prefix: String, delimiter: String?, token: String?) async throws -> ListPage {
        var query: [(String, String)] = [("list-type", "2"), ("prefix", prefix), ("max-keys", "1000")]
        if let delimiter { query.append(("delimiter", delimiter)) }
        if let token { query.append(("continuation-token", token)) }
        let (data, _) = try await send("GET", bucket: bucket, query: query)
        let root = XMLNode.parse(data)

        var items: [RemoteItem] = []
        for p in root.all("CommonPrefixes") {
            guard let full = p.value("Prefix") else { continue }
            let name = String(full.dropFirst(prefix.count).dropLast())
            items.append(RemoteItem(key: full, name: name, isFolder: true))
        }
        for c in root.all("Contents") {
            guard let key = c.value("Key"), key != prefix else { continue }
            let rel = String(key.dropFirst(prefix.count))
            let isMarker = key.hasSuffix("/")
            items.append(RemoteItem(
                key: key,
                name: isMarker ? String(rel.dropLast()) : rel,
                isFolder: isMarker,
                size: Int64(c.value("Size") ?? "0") ?? 0,
                modified: S3Date.parse(c.value("LastModified")),
                storageClass: c.value("StorageClass")))
        }
        let truncated = root.value("IsTruncated") == "true"
        return ListPage(items: items, nextToken: truncated ? root.value("NextContinuationToken") : nil)
    }

    /// Lists every object under a prefix, recursively.
    func listAll(bucket: String, prefix: String) async throws -> [RemoteItem] {
        var all: [RemoteItem] = []
        var token: String?
        repeat {
            try Task.checkCancellation()
            let page = try await listPage(bucket: bucket, prefix: prefix, delimiter: nil, token: token)
            all += page.items
            token = page.nextToken
        } while token != nil
        return all
    }

    /// CopyObject; above 5 GB uses UploadPartCopy.
    func copyObject(fromBucket: String, key: String, size: Int64, toBucket: String, toKey: String) async throws {
        let source = "/" + fromBucket + "/" + key.s3PathEncoded
        let maxSingle: Int64 = 5 * 1024 * 1024 * 1024
        if size <= maxSingle {
            let (data, _) = try await send("PUT", bucket: toBucket, key: toKey, body: Data(),
                                           headers: ["x-amz-copy-source": source])
            let root = XMLNode.parse(data)
            if root.name == "Error" {
                throw S3Error(status: 200, code: root.value("Code") ?? "", message: root.value("Message") ?? "")
            }
            return
        }
        let partSize: Int64 = 512 * 1024 * 1024
        let uploadID = try await createMultipartUpload(bucket: toBucket, key: toKey, contentType: "application/octet-stream")
        do {
            var etags: [String] = []
            var offset: Int64 = 0
            var part = 1
            while offset < size {
                try Task.checkCancellation()
                let end = min(offset + partSize, size) - 1
                let (data, _) = try await send("PUT", bucket: toBucket, key: toKey,
                                               query: [("partNumber", String(part)), ("uploadId", uploadID)], body: Data(),
                                               headers: ["x-amz-copy-source": source, "x-amz-copy-source-range": "bytes=\(offset)-\(end)"])
                guard let etag = XMLNode.parse(data).value("ETag") else {
                    throw S3Error(status: 0, code: "NoETag", message: String(localized: "Missing ETag for part \(part)"))
                }
                etags.append(etag)
                offset = end + 1
                part += 1
            }
            try await completeMultipartUpload(bucket: toBucket, key: toKey, uploadID: uploadID, etags: etags)
        } catch {
            await abortMultipartUpload(bucket: toBucket, key: toKey, uploadID: uploadID)
            throw error
        }
    }

    /// Presigned URL (SigV4 query string) to download an object without credentials.
    func presignedURL(bucket: String, key: String, expires: TimeInterval) -> URL {
        let req = makeRequest("GET", bucket: bucket, key: key, payloadHash: Self.unsignedPayload,
                              presignExpires: Int(min(expires, 604_800)))
        return req.url!
    }

    func createFolder(bucket: String, key: String) async throws {
        _ = try await send("PUT", bucket: bucket, key: key, body: Data())
    }

    func deleteObject(bucket: String, key: String) async throws {
        _ = try await send("DELETE", bucket: bucket, key: key)
    }

    /// DeleteObjects in batches of 1000.
    func deleteObjects(bucket: String, keys: [String]) async throws {
        for start in stride(from: 0, to: keys.count, by: 1000) {
            try Task.checkCancellation()
            let chunk = keys[start..<min(start + 1000, keys.count)]
            var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Delete><Quiet>true</Quiet>"
            for k in chunk { xml += "<Object><Key>\(k.xmlEscaped)</Key></Object>" }
            xml += "</Delete>"
            let body = Data(xml.utf8)
            let md5 = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
            let (data, _) = try await send("POST", bucket: bucket, query: [("delete", "")], body: body,
                                           headers: ["Content-MD5": md5, "Content-Type": "application/xml"])
            let errors = XMLNode.parse(data).all("Error")
            if let first = errors.first {
                throw S3Error(status: 200, code: first.value("Code") ?? "DeleteError",
                              message: String(localized: "\(errors.count) objects not deleted, e.g. \(first.value("Key") ?? "")"))
            }
        }
    }

    // MARK: - Signed requests for transfers (run by TransferManager)

    func downloadRequest(bucket: String, key: String) -> URLRequest {
        makeRequest("GET", bucket: bucket, key: key, payloadHash: Self.emptySHA256)
    }

    func uploadRequest(bucket: String, key: String, contentType: String) -> URLRequest {
        makeRequest("PUT", bucket: bucket, key: key, payloadHash: Self.unsignedPayload,
                    headers: ["Content-Type": contentType])
    }

    func createMultipartUpload(bucket: String, key: String, contentType: String) async throws -> String {
        let (data, _) = try await send("POST", bucket: bucket, key: key, query: [("uploads", "")],
                                       headers: ["Content-Type": contentType])
        guard let id = XMLNode.parse(data).value("UploadId") else {
            throw S3Error(status: 0, code: "NoUploadId", message: String(localized: "Missing UploadId in the response"))
        }
        return id
    }

    func uploadPartRequest(bucket: String, key: String, uploadID: String, partNumber: Int) -> URLRequest {
        makeRequest("PUT", bucket: bucket, key: key,
                    query: [("partNumber", String(partNumber)), ("uploadId", uploadID)],
                    payloadHash: Self.unsignedPayload)
    }

    func completeMultipartUpload(bucket: String, key: String, uploadID: String, etags: [String]) async throws {
        var xml = "<CompleteMultipartUpload>"
        for (i, tag) in etags.enumerated() {
            xml += "<Part><PartNumber>\(i + 1)</PartNumber><ETag>\(tag.xmlEscaped)</ETag></Part>"
        }
        xml += "</CompleteMultipartUpload>"
        let (data, _) = try await send("POST", bucket: bucket, key: key, query: [("uploadId", uploadID)],
                                       body: Data(xml.utf8), headers: ["Content-Type": "application/xml"])
        // S3 can answer 200 with an <Error> in the body.
        let root = XMLNode.parse(data)
        if root.name == "Error" {
            throw S3Error(status: 200, code: root.value("Code") ?? "", message: root.value("Message") ?? "")
        }
    }

    func abortMultipartUpload(bucket: String, key: String, uploadID: String) async {
        _ = try? await send("DELETE", bucket: bucket, key: key, query: [("uploadId", uploadID)])
    }

    /// Checks a transfer response and throws the S3 error if there is one.
    static func check(_ response: URLResponse, body: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else { throw error(status: http.statusCode, data: body ?? Data()) }
    }

    // MARK: - Transport

    private func region(for bucket: String?) -> String {
        guard let bucket else { return connection.region }
        return lock.withLock { bucketRegions[bucket] } ?? connection.region
    }

    private func send(_ method: String, bucket: String?, key: String? = nil, query: [(String, String)] = [],
                      body: Data? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        let hash = body.map { SHA256.hash(data: $0).hex } ?? Self.emptySHA256
        for attempt in 0..<2 {
            var req = makeRequest(method, bucket: bucket, key: key, query: query, payloadHash: hash, headers: headers)
            req.httpBody = body
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if (200..<300).contains(http.statusCode) { return (data, http) }
            // Bucket in another region: remember the right region and retry once.
            if attempt == 0, let bucket, let actual = http.value(forHTTPHeaderField: "x-amz-bucket-region"),
               actual != region(for: bucket) {
                lock.withLock { bucketRegions[bucket] = actual }
                continue
            }
            throw Self.error(status: http.statusCode, data: data)
        }
        throw URLError(.unknown)
    }

    private static func error(status: Int, data: Data) -> S3Error {
        let root = XMLNode.parse(data)
        let code = root.value("Code") ?? ""
        var msg = root.value("Message") ?? ""
        if msg.isEmpty { msg = HTTPURLResponse.localizedString(forStatusCode: status) }
        return S3Error(status: status, code: code, message: msg)
    }

    /// Builds and signs (SigV4) a request. `payloadHash` is the SHA-256 of the body or UNSIGNED-PAYLOAD.
    func makeRequest(_ method: String, bucket: String?, key: String? = nil, query: [(String, String)] = [],
                     payloadHash: String, headers: [String: String] = [:], presignExpires: Int? = nil) -> URLRequest {
        let region = region(for: bucket)
        var scheme = "https"
        var hostPort: String
        if connection.isAWS {
            hostPort = region == "us-east-1" ? "s3.amazonaws.com" : "s3.\(region).amazonaws.com"
        } else {
            var ep = connection.endpoint.trimmingCharacters(in: .whitespaces)
            if !ep.contains("://") { ep = "https://" + ep }
            let comps = URLComponents(string: ep)
            scheme = comps?.scheme ?? "https"
            hostPort = comps?.host ?? ep
            if let port = comps?.port { hostPort += ":\(port)" }
        }

        // Path-style if requested or if the bucket name is not DNS-compatible (e.g. contains dots over https).
        var path = "/"
        if let bucket {
            let pathStyle = connection.usePathStyle || bucket.contains(".") || bucket.lowercased() != bucket
            if pathStyle {
                path = "/" + bucket.s3PathEncoded + "/"
            } else {
                hostPort = bucket + "." + hostPort
            }
        }
        if let key { path += key.s3PathEncoded }

        let now = Date()
        let amzDate = S3Date.amz.string(from: now)
        let dateStamp = String(amzDate.prefix(8))
        let scope = "\(dateStamp)/\(region)/s3/aws4_request"

        var query = query
        if let presignExpires {
            // Query string signature: only the host header is signed.
            query += [("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
                      ("X-Amz-Credential", "\(credentials.accessKeyID)/\(scope)"),
                      ("X-Amz-Date", amzDate),
                      ("X-Amz-Expires", String(presignExpires)),
                      ("X-Amz-SignedHeaders", "host")]
            if let token = credentials.sessionToken { query.append(("X-Amz-Security-Token", token)) }
        }
        let encoded: [(k: String, v: String)] = query.map { (k: $0.0.s3QueryEncoded, v: $0.1.s3QueryEncoded) }
        let sorted = encoded.sorted { a, b in a.k == b.k ? a.v < b.v : a.k < b.k }
        let canonicalQuery = sorted.map { p in p.k + "=" + p.v }.joined(separator: "&")

        let querySuffix = canonicalQuery.isEmpty ? "" : "?" + canonicalQuery
        var url = URL(string: scheme + "://" + hostPort + path + querySuffix)!
        var req = URLRequest(url: url)
        req.httpMethod = method

        var signed: [String: String] = ["host": hostPort]
        if presignExpires == nil {
            signed["x-amz-content-sha256"] = payloadHash
            signed["x-amz-date"] = amzDate
            if let token = credentials.sessionToken { signed["x-amz-security-token"] = token }
            for (k, v) in headers { signed[k.lowercased()] = v.trimmingCharacters(in: .whitespaces) }
        }
        for (k, v) in signed where k != "host" { req.setValue(v, forHTTPHeaderField: k) }

        let sortedKeys = signed.keys.sorted()
        let canonicalHeaders = sortedKeys.map { "\($0):\(signed[$0]!)\n" }.joined()
        let signedHeaders = sortedKeys.joined(separator: ";")
        let canonicalRequest = [method, path, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash]
            .joined(separator: "\n")

        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, SHA256.hash(data: Data(canonicalRequest.utf8)).hex]
            .joined(separator: "\n")

        var k = hmac(Data("AWS4\(credentials.secretAccessKey)".utf8), dateStamp)
        k = hmac(k, region)
        k = hmac(k, "s3")
        k = hmac(k, "aws4_request")
        let signature = hmac(k, stringToSign).hex

        if presignExpires != nil {
            url = URL(string: url.absoluteString + "&X-Amz-Signature=" + signature)!
            req.url = url
            return req
        }
        req.setValue("AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                     forHTTPHeaderField: "Authorization")
        return req
    }

    private func hmac(_ key: Data, _ msg: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key)))
    }
}

// MARK: - Utilities

enum S3Date {
    static let amz: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }
}

extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

extension Digest {
    var hex: String { Array(self).hex }
}

extension String {
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    var s3QueryEncoded: String { addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? self }

    /// S3 path encoding: everything except unreserved characters and "/".
    var s3PathEncoded: String {
        addingPercentEncoding(withAllowedCharacters: Self.unreserved.union(CharacterSet(charactersIn: "/"))) ?? self
    }

    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// Minimal XML tree to read S3 responses.
final class XMLNode {
    let name: String
    var text = ""
    var children: [XMLNode] = []

    init(name: String) { self.name = name }

    func child(_ n: String) -> XMLNode? { children.first { $0.name == n } }
    func value(_ n: String) -> String? { child(n)?.text }

    /// Every descendant with that name.
    func all(_ n: String) -> [XMLNode] {
        children.flatMap { ($0.name == n ? [$0] : []) + $0.all(n) }
    }

    static func parse(_ data: Data) -> XMLNode {
        let delegate = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.root.children.first ?? delegate.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        let root = XMLNode(name: "#document")
        lazy var stack: [XMLNode] = [root]

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let node = XMLNode(name: elementName)
            stack.last?.children.append(node)
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            stack.removeLast()
        }
    }
}
