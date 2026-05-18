import Foundation
import os

enum TypefluxOfficialASRRouteDecision: Equatable, Sendable {
    case webSocket
    case aliyun(token: String, model: String, expiresAt: Int64?, usageReportID: String)

    var usageReportID: String? {
        switch self {
        case .webSocket:
            nil
        case let .aliyun(_, _, _, usageReportID):
            usageReportID
        }
    }
}

protocol TypefluxOfficialASRRoutingClient: Sendable {
    func fetchRoute(
        accessToken: String,
        scenario: TypefluxCloudScenario
    ) async throws -> TypefluxOfficialASRRouteDecision

    func reportAliyunUsage(
        accessToken: String,
        usageReportID: String,
        audioDurationMs: Int64,
        outputChars: Int,
        scenario: TypefluxCloudScenario
    ) async throws
}

enum TypefluxOfficialASRRoutingError: LocalizedError, Equatable {
    case invalidResponse
    case unauthorized
    case serverError(code: String, message: String?)
    case unknownRouteType(String)
    case missingAliyunToken
    case missingUsageReportID

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Received an invalid Typeflux Cloud ASR routing response."
        case .unauthorized:
            "Please sign in to use Typeflux Cloud speech recognition."
        case let .serverError(code, message):
            TypefluxCloudServerErrorMessage.userMessage(
                code: code,
                message: message,
                fallback: "Typeflux Cloud ASR routing request failed."
            )
        case let .unknownRouteType(type):
            "Unknown Typeflux Cloud ASR route type: \(type)"
        case .missingAliyunToken:
            "Typeflux Cloud did not return an Aliyun temporary token."
        case .missingUsageReportID:
            "Typeflux Cloud did not return an Aliyun usage report id."
        }
    }
}

struct TypefluxOfficialASRRoutingHTTPClient: TypefluxOfficialASRRoutingClient {
    private let executor: CloudRequestExecutor
    private let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "TypefluxOfficialASRRoutingHTTPClient")

    init(executor: CloudRequestExecutor = CloudRequestExecutor()) {
        self.executor = executor
    }

    func fetchRoute(
        accessToken: String,
        scenario: TypefluxCloudScenario
    ) async throws -> TypefluxOfficialASRRouteDecision {
        let (data, response) = try await executor.execute(apiPath: "/api/v1/asr/aliyun/token") { baseURL in
            var request = URLRequest(url: AuthEndpointResolver.resolve(
                baseURL: baseURL,
                path: "/api/v1/asr/aliyun/token"
            ))
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            TypefluxCloudRequestHeaders.applyScenario(scenario, to: &request)
            request.httpBody = Data("{}".utf8)
            return request
        }

        let envelope = try decodeEnvelope(AliyunTokenResponse.self, from: data)
        if response.statusCode == 401 {
            throw TypefluxOfficialASRRoutingError.unauthorized
        }
        guard (200 ..< 300).contains(response.statusCode), envelope.code == "OK", let payload = envelope.data else {
            throw TypefluxOfficialASRRoutingError.serverError(code: envelope.code, message: envelope.message)
        }

        switch payload.type.lowercased() {
        case "websocket":
            return .webSocket
        case "aliyun":
            guard let token = payload.token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
                throw TypefluxOfficialASRRoutingError.missingAliyunToken
            }
            guard let usageReportID = payload.usageReportID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !usageReportID.isEmpty
            else {
                throw TypefluxOfficialASRRoutingError.missingUsageReportID
            }
            let trimmedModel = payload.model?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedModel = if let trimmedModel, !trimmedModel.isEmpty {
                trimmedModel
            } else {
                AliCloudASRDefaults.model
            }
            return .aliyun(
                token: token,
                model: resolvedModel,
                expiresAt: payload.expiresAt,
                usageReportID: usageReportID
            )
        default:
            throw TypefluxOfficialASRRoutingError.unknownRouteType(payload.type)
        }
    }

    func reportAliyunUsage(
        accessToken: String,
        usageReportID: String,
        audioDurationMs: Int64,
        outputChars: Int,
        scenario: TypefluxCloudScenario
    ) async throws {
        let body = AliyunUsageReportRequest(
            usageReportID: usageReportID,
            audioDurationMs: audioDurationMs,
            outputChars: outputChars
        )
        let payload = try JSONEncoder().encode(body)
        let (data, response) = try await executor.execute(apiPath: "/api/v1/asr/aliyun/usage") { baseURL in
            var request = URLRequest(url: AuthEndpointResolver.resolve(
                baseURL: baseURL,
                path: "/api/v1/asr/aliyun/usage"
            ))
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            TypefluxCloudRequestHeaders.applyScenario(scenario, to: &request)
            request.httpBody = payload
            return request
        }

        let envelope = try decodeEnvelope(AliyunUsageReportResponse.self, from: data)
        if response.statusCode == 401 {
            throw TypefluxOfficialASRRoutingError.unauthorized
        }
        guard (200 ..< 300).contains(response.statusCode), envelope.code == "OK" else {
            logger
                .error(
                    "Aliyun usage report failed with status \(response.statusCode): \(String(data: data, encoding: .utf8) ?? "<non-utf8>")"
                )
            throw TypefluxOfficialASRRoutingError.serverError(code: envelope.code, message: envelope.message)
        }
    }

    private func decodeEnvelope<T: Decodable>(_: T.Type, from data: Data) throws -> APIResponse<T> {
        do {
            return try JSONDecoder().decode(APIResponse<T>.self, from: data)
        } catch {
            throw TypefluxOfficialASRRoutingError.invalidResponse
        }
    }
}

enum TypefluxOfficialASRUsageMeter {
    static func audioDurationMilliseconds(
        pcm16ByteCount: Int,
        sampleRate: Double = CloudASRAudioConverter.targetSampleRate
    ) -> Int64 {
        guard pcm16ByteCount > 0, sampleRate > 0 else { return 0 }
        let bytesPerFrame = 2.0
        return Int64((Double(pcm16ByteCount) / bytesPerFrame / sampleRate * 1000.0).rounded())
    }
}

private struct AliyunTokenResponse: Decodable {
    let type: String
    let token: String?
    let model: String?
    let expiresAt: Int64?
    let usageReportID: String?

    enum CodingKeys: String, CodingKey {
        case type
        case token
        case model
        case expiresAt = "expires_at"
        case usageReportID = "usage_report_id"
    }
}

private struct AliyunUsageReportRequest: Encodable {
    let usageReportID: String
    let audioDurationMs: Int64
    let outputChars: Int

    enum CodingKeys: String, CodingKey {
        case usageReportID = "usage_report_id"
        case audioDurationMs = "audio_duration_ms"
        case outputChars = "output_chars"
    }
}

private struct AliyunUsageReportResponse: Decodable {
    let updated: Bool?
}
