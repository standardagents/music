import Foundation
import ImageIO
import OSLog

let gptLog = Logger(subsystem: "com.standardmusic", category: "chatgpt")

public enum ChatGPTError: Error, LocalizedError, Sendable {
    case notSignedIn
    case missingAccount
    case noCodexLogin
    case stateMismatch
    case portInUse
    case sessionExpired
    case oauth(String)
    case http(Int, String)
    case rateLimited(retryAfter: TimeInterval?, message: String)
    case failed(String)
    case malformed(String)
    /// The Images endpoint's safety system rejected the request or the image it produced. Retrying
    /// the same prompt fails the same way.
    case moderationBlocked([String])

    /// Maps a non-200 response, recognizing the Images endpoint's `moderation_blocked` rejection.
    static func from(status: Int, body: Data) -> ChatGPTError {
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let error = json["error"] as? [String: Any], error["code"] as? String == "moderation_blocked"
        {
            let categories = (error["moderation_details"] as? [String: Any])?["categories"] as? [String] ?? []
            return .moderationBlocked(categories)
        }
        return .http(status, String(decoding: body, as: UTF8.self))
    }

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "You're not signed in to ChatGPT."
        case .missingAccount: "This account doesn't have a ChatGPT workspace attached."
        case .noCodexLogin: "No Codex sign-in was found on this Mac."
        case .stateMismatch: "The sign-in response didn't match this request. Please try again."
        case .portInUse: "Another app is using the sign-in port (1455). Quit any Codex login in progress and try again."
        case .sessionExpired: "Your ChatGPT session expired. Please sign in again."
        case .oauth(let m): m
        case .http(let code, let body): "ChatGPT returned an error (\(code)). \(body.prefix(240))"
        case .rateLimited(_, let message): message
        case .failed(let m): m
        case .malformed(let m): "Unexpected response: \(m)"
        case .moderationBlocked(let categories):
            "OpenAI's safety system blocked this image\(categories.isEmpty ? "" : " (\(categories.joined(separator: ", ")))")."
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .failed, .malformed: true
        case .http(let code, _): code >= 500 || code == 408
        default: false
        }
    }
}

/// Plan usage reported by the backend on every response.
public struct ChatGPTUsage: Sendable, Equatable {
    public var planType: String?
    public var primaryUsedPercent: Double?
    public var primaryResetsAt: Date?
    public var secondaryUsedPercent: Double?
    public var secondaryResetsAt: Date?

    public init() {}
}

public struct ChatGPTModel: Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var description: String
}

/// Responses API client for the ChatGPT (Codex) backend, authenticated with the user's subscription.
public actor ChatGPTClient {
    static let base = URL(string: "https://chatgpt.com/backend-api/codex")!
    public static let defaultWritingModel = "gpt-6.1-terra"
    public static let defaultFastModel = "gpt-6-luna"

    private let auth: ChatGPTAuth
    private let session: URLSession
    private let sessionID = UUID().uuidString.lowercased()
    public private(set) var usage = ChatGPTUsage()
    public var writingModel = ChatGPTClient.defaultWritingModel
    public var fastModel = ChatGPTClient.defaultFastModel
    private var usageObservers: [UUID: @Sendable (ChatGPTUsage) -> Void] = [:]

    public init(auth: ChatGPTAuth) {
        self.auth = auth
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config)
    }

    public func setModels(writing: String, fast: String) {
        writingModel = writing
        fastModel = fast
    }

    public func observeUsage(_ handler: @escaping @Sendable (ChatGPTUsage) -> Void) {
        usageObservers[UUID()] = handler
    }

    // MARK: Public API

    public enum Quality: Sendable { case writing, fast }

    public struct ImageInput: Sendable {
        public var data: Data
        public var mimeType: String
        public init(data: Data, mimeType: String = "image/jpeg") {
            self.data = data
            self.mimeType = mimeType
        }
    }

    /// Structured output decoded into `T` using a strict JSON schema.
    public func json<T: Decodable & Sendable>(
        _ type: T.Type, schemaName: String, schema: JSON, instructions: String, prompt: String,
        quality: Quality = .writing, effort: String = "low", retries: Int = 3
    ) async throws -> T {
        let format: JSON = ["type": "json_schema", "name": .string(schemaName), "schema": schema, "strict": true]
        var attempt = 0
        while true {
            do {
                let result = try await respond(
                    model: quality == .writing ? writingModel : fastModel, instructions: instructions, prompt: prompt,
                    format: format, effort: effort, tools: [])
                guard let data = result.text.data(using: .utf8) else { throw ChatGPTError.malformed("empty") }
                do {
                    return try JSONDecoder().decode(T.self, from: data)
                } catch {
                    throw ChatGPTError.malformed("\(schemaName): \(error)")
                }
            } catch let error as ChatGPTError where error.isRetryable && attempt < retries {
                attempt += 1
                try await Task.sleep(for: .seconds(backoff(for: error, attempt: attempt)))
            }
        }
    }

    /// Plain text completion.
    public func text(instructions: String, prompt: String, quality: Quality = .writing, effort: String = "low")
        async throws -> String
    {
        try await respond(
            model: quality == .writing ? writingModel : fastModel, instructions: instructions, prompt: prompt,
            format: nil, effort: effort, tools: []
        ).text
    }

    /// The image model behind ChatGPT's Images endpoint (what Codex uses).
    public static let imageModel = "gpt-image-2"

    /// Generates an image with ChatGPT's Images endpoint and returns JPEG data.
    public func image(prompt: String, size: String = "1024x1024", quality: String = "medium", retries: Int = 3)
        async throws -> Data
    {
        let body: JSON = [
            "prompt": .string(prompt), "model": .string(Self.imageModel), "quality": .string(quality),
            "size": .string(size), "background": "opaque",
        ]
        let payload = try JSONEncoder().encode(body)
        var attempt = 0
        var refreshed = false
        while true {
            do {
                let creds = try await auth.validCredentials(forceRefresh: refreshed)
                var request = URLRequest(url: Self.base.appending(path: "images/generations"))
                request.httpMethod = "POST"
                request.httpBody = payload
                request.timeoutInterval = 300
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                authorize(&request, creds)
                request.setValue(UUID().uuidString, forHTTPHeaderField: "x-codex-image-turn-id")
                let (data, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse
                if let http { recordUsage(http) }
                let status = http?.statusCode ?? 0
                if status == 401, !refreshed {
                    refreshed = true
                    continue
                }
                if status == 429 {
                    let retry = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
                    let resets = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                        .flatMap { ($0["error"] as? [String: Any])?["resets_in_seconds"] as? Double }
                    throw ChatGPTError.rateLimited(
                        retryAfter: retry ?? resets,
                        message: "You've hit your ChatGPT usage limit for now. Generation will resume automatically.")
                }
                guard status == 200 else { throw ChatGPTError.from(status: status, body: data) }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let first = (json["data"] as? [[String: Any]])?.first,
                    let b64 = first["b64_json"] as? String, let raw = Data(base64Encoded: b64)
                else { throw ChatGPTError.failed("No image was returned.") }
                return Self.jpeg(raw, square: size.split(separator: "x").count == 2 && Set(size.split(separator: "x")).count == 1) ?? raw
            } catch let error as ChatGPTError where error.isRetryable && attempt < retries {
                attempt += 1
                try await Task.sleep(for: .seconds(backoff(for: error, attempt: attempt)))
            }
        }
    }

    /// Re-encodes PNG (or anything ImageIO reads) as JPEG, center-cropped to a square if asked: the
    /// endpoint sizes images from the prompt and may ignore `size`.
    static func jpeg(_ data: Data, quality: Double = 0.9, square: Bool = false) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            var image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        if square, image.width != image.height {
            let side = min(image.width, image.height)
            let rect = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
            if let cropped = image.cropping(to: rect) { image = cropped }
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Models the subscription can use.
    public func availableModels() async throws -> [ChatGPTModel] {
        let creds = try await auth.validCredentials()
        var components = URLComponents(url: Self.base.appending(path: "models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "client_version", value: "0.165.0")]
        var request = URLRequest(url: components.url!)
        authorize(&request, creds)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ChatGPTError.http((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
        }
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models = body?["models"] as? [[String: Any]] ?? []
        return models.compactMap { m in
            guard let slug = m["slug"] as? String, (m["visibility"] as? String) != "hide" else { return nil }
            return ChatGPTModel(
                id: slug, displayName: m["display_name"] as? String ?? slug,
                description: m["description"] as? String ?? "")
        }
    }

    // MARK: Core request

    struct Result {
        var text: String
        var images: [Data]
    }

    private func authorize(_ request: inout URLRequest, _ creds: ChatGPTCredentials) {
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(creds.accountID, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue(sessionID, forHTTPHeaderField: "session_id")
    }

    private func respond(
        model: String, instructions: String, prompt: String, format: JSON?, effort: String, tools: [JSON],
        toolChoice: String? = nil
    ) async throws -> Result {
        var body: [String: JSON] = [
            "model": .string(model),
            "instructions": .string(instructions),
            "input": [["type": "message", "role": "user", "content": [["type": "input_text", "text": .string(prompt)]]]],
            "stream": true,
            "store": false,
            "tools": .array(tools),
            "reasoning": ["effort": .string(effort)],
        ]
        if let format { body["text"] = ["format": format] }
        if let toolChoice { body["tool_choice"] = .string(toolChoice) }
        let payload = try JSONEncoder().encode(JSON.object(body))

        var refreshed = false
        while true {
            let creds = try await auth.validCredentials(forceRefresh: refreshed)
            var request = URLRequest(url: Self.base.appending(path: "responses"))
            request.httpMethod = "POST"
            request.httpBody = payload
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            authorize(&request, creds)
            let (bytes, response) = try await session.bytes(for: request)
            let http = response as? HTTPURLResponse
            if let http { recordUsage(http) }
            let status = http?.statusCode ?? 0
            if status == 401, !refreshed {
                refreshed = true
                continue
            }
            if status != 200 {
                var raw = Data()
                for try await byte in bytes { raw.append(byte) }
                let text = String(decoding: raw, as: UTF8.self)
                if status == 429 {
                    let retry = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
                    let resets = (try? JSONSerialization.jsonObject(with: raw) as? [String: Any])
                        .flatMap { ($0["error"] as? [String: Any])?["resets_in_seconds"] as? Double }
                    throw ChatGPTError.rateLimited(
                        retryAfter: retry ?? resets,
                        message: "You've hit your ChatGPT usage limit for now. Generation will resume automatically.")
                }
                throw ChatGPTError.http(status, text)
            }
            return try await parse(bytes)
        }
    }

    private func parse(_ bytes: URLSession.AsyncBytes) async throws -> Result {
        var text = ""
        var images: [Data] = []
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = event["type"] as? String
            else { continue }
            switch type {
            case "response.output_text.delta":
                text += event["delta"] as? String ?? ""
            case "response.output_item.done":
                if let item = event["item"] as? [String: Any], item["type"] as? String == "image_generation_call",
                    let b64 = item["result"] as? String, let image = Data(base64Encoded: b64)
                {
                    images.append(image)
                }
            case "response.failed", "error":
                let response = event["response"] as? [String: Any]
                let error = (response?["error"] ?? event["error"]) as? [String: Any]
                let message = error?["message"] as? String ?? "The request failed."
                if (error?["code"] as? String) == "rate_limit_exceeded" {
                    throw ChatGPTError.rateLimited(retryAfter: nil, message: message)
                }
                throw ChatGPTError.failed(message)
            default:
                break
            }
        }
        return Result(text: text, images: images)
    }

    private func recordUsage(_ response: HTTPURLResponse) {
        func header(_ name: String) -> String? { response.value(forHTTPHeaderField: name) }
        var usage = self.usage
        if let plan = header("x-codex-plan-type") { usage.planType = plan }
        if let p = header("x-codex-primary-used-percent").flatMap(Double.init) { usage.primaryUsedPercent = p }
        if let p = header("x-codex-secondary-used-percent").flatMap(Double.init) { usage.secondaryUsedPercent = p }
        if let r = header("x-codex-primary-reset-at").flatMap(Double.init) {
            usage.primaryResetsAt = Date(timeIntervalSince1970: r)
        }
        if let r = header("x-codex-secondary-reset-at").flatMap(Double.init) {
            usage.secondaryResetsAt = Date(timeIntervalSince1970: r)
        }
        guard usage != self.usage else { return }
        self.usage = usage
        for observer in usageObservers.values { observer(usage) }
    }

    private func backoff(for error: ChatGPTError, attempt: Int) -> Double {
        if case .rateLimited(let after?, _) = error { return min(after, 600) }
        if case .rateLimited = error { return 30 * Double(attempt) }
        return pow(2, Double(attempt)) + Double.random(in: 0 ... 1)
    }
}
