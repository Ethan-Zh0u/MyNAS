import Foundation

struct PhotoBackupUploadOutcome: Sendable {
    let assetID: String
    let wasDuplicate: Bool
    let sourceState: PhotoSourceState
    let derivativeState: PhotoDerivativeState
    let browseReady: Bool
}

enum PhotoBackupUploadError: LocalizedError {
    case accountNotConnected
    case volumeNotSelected
    case invalidResponse
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .accountNotConnected:
            "请先连接 MyNAS。"
        case .volumeNotSelected:
            "请先为当前 MyNAS 账号选择一块在线硬盘。"
        case .invalidResponse:
            "MyNAS 返回了无法识别的上传响应。"
        case .server(let status, let message):
            "MyNAS 上传失败（\(status)）：\(message)"
        }
    }
}

actor PhotoBackupUploader {
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 10 * 60
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.httpCookieStorage = nil
            // Upload only to the already-validated *.ts.net MyNAS origin.
            // Keep TLS validation intact, but do not send private tailnet traffic
            // through a system/PAC proxy such as Simulator's 127.0.0.1 proxy.
            configuration.connectionProxyDictionary = [:]
            self.session = URLSession(configuration: configuration)
        }
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    func upload(
        preparedAsset: PreparedPhotoAsset,
        account: AccountContext,
        deviceID: String,
        progress: @Sendable @escaping (_ uploadedBytes: Int64, _ totalBytes: Int64) -> Void
    ) async throws -> PhotoBackupUploadOutcome {
        guard let baseURL = account.serverURL else {
            throw PhotoBackupUploadError.accountNotConnected
        }
        guard let volumeID = account.selectedVolumeID else {
            throw PhotoBackupUploadError.volumeNotSelected
        }

        var uploadSession = try await createSession(
            preparedAsset: preparedAsset,
            baseURL: baseURL,
            volumeID: volumeID,
            deviceID: deviceID
        )
        if uploadSession.status == "duplicate" || uploadSession.status == "completed" {
            progress(uploadSession.totalBytes, uploadSession.totalBytes)
            return try Self.outcome(
                from: uploadSession,
                wasDuplicate: uploadSession.status == "duplicate"
            )
        }
        guard let uploadSessionID = uploadSession.id else {
            throw PhotoBackupUploadError.invalidResponse
        }

        var receivedByResource = Dictionary(
            uniqueKeysWithValues: uploadSession.resources.map {
                ($0.clientResourceID, $0.receivedBytes)
            }
        )
        progress(
            receivedByResource.values.reduce(0, +),
            uploadSession.totalBytes
        )

        for localResource in preparedAsset.resources {
            guard var remoteResource = uploadSession.resources.first(
                where: { $0.clientResourceID == localResource.clientResourceID }
            ) else {
                throw PhotoBackupUploadError.invalidResponse
            }
            guard remoteResource.byteSize == localResource.byteSize,
                  remoteResource.sha256 == localResource.sha256,
                  remoteResource.chunkSize > 0 else {
                throw PhotoBackupUploadError.invalidResponse
            }

            let file = try FileHandle(forReadingFrom: localResource.fileURL)
            defer { try? file.close() }
            try file.seek(toOffset: UInt64(remoteResource.receivedBytes))

            while remoteResource.receivedBytes < remoteResource.byteSize {
                try Task.checkCancellation()
                let remaining = remoteResource.byteSize - remoteResource.receivedBytes
                let length = Int(min(remoteResource.chunkSize, remaining))
                guard let chunk = try file.read(upToCount: length), chunk.count == length else {
                    throw PhotoBackupPreparationError.invalidResource
                }
                let partNumber = remoteResource.receivedBytes / remoteResource.chunkSize
                let response = try await sendPartWithRetry(
                    data: chunk,
                    baseURL: baseURL,
                    sessionID: uploadSessionID,
                    resourceID: remoteResource.id,
                    partNumber: partNumber,
                    offset: remoteResource.receivedBytes
                )
                guard response.receivedBytes >= remoteResource.receivedBytes,
                      response.receivedBytes <= remoteResource.byteSize else {
                    throw PhotoBackupUploadError.invalidResponse
                }
                remoteResource.receivedBytes = response.receivedBytes
                receivedByResource[localResource.clientResourceID] = response.receivedBytes
                progress(
                    receivedByResource.values.reduce(0, +),
                    uploadSession.totalBytes
                )
            }
        }

        uploadSession = try await completeSession(
            baseURL: baseURL,
            sessionID: uploadSessionID
        )
        guard uploadSession.status == "completed" else {
            throw PhotoBackupUploadError.invalidResponse
        }
        progress(uploadSession.totalBytes, uploadSession.totalBytes)
        return try Self.outcome(from: uploadSession, wasDuplicate: false)
    }

    private func createSession(
        preparedAsset: PreparedPhotoAsset,
        baseURL: URL,
        volumeID: String,
        deviceID: String
    ) async throws -> PhotoUploadSessionEnvelope {
        let requestBody = PhotoUploadSessionRequest(
            volumeID: volumeID,
            deviceID: deviceID,
            localIdentifier: preparedAsset.localAsset.localIdentifier,
            fingerprint: preparedAsset.fingerprint,
            mediaType: preparedAsset.localAsset.mediaKind.backupMediaType,
            captureDate: preparedAsset.localAsset.creationDate.map(Self.dateString),
            modificationDate: preparedAsset.localAsset.modificationDate.map(Self.dateString),
            pixelWidth: preparedAsset.localAsset.pixelWidth,
            pixelHeight: preparedAsset.localAsset.pixelHeight,
            duration: preparedAsset.localAsset.duration,
            favorite: preparedAsset.localAsset.isFavorite,
            resources: preparedAsset.resources.map {
                PhotoUploadResourceRequest(
                    clientResourceID: $0.clientResourceID,
                    resourceRole: $0.role,
                    originalFilename: $0.originalFilename,
                    contentType: $0.contentType,
                    byteSize: $0.byteSize,
                    sha256: $0.sha256
                )
            }
        )
        return try await jsonRequest(
            baseURL: baseURL,
            path: "api/v1/photos/upload-sessions",
            method: "POST",
            body: try encoder.encode(requestBody)
        )
    }

    private func completeSession(
        baseURL: URL,
        sessionID: String
    ) async throws -> PhotoUploadSessionEnvelope {
        try await jsonRequest(
            baseURL: baseURL,
            path: "api/v1/photos/upload-sessions/\(sessionID)/complete",
            method: "POST",
            body: Data()
        )
    }

    private func sendPartWithRetry(
        data: Data,
        baseURL: URL,
        sessionID: String,
        resourceID: String,
        partNumber: Int64,
        offset: Int64
    ) async throws -> PhotoUploadPartEnvelope {
        var lastError: Error?
        for attempt in 0..<5 {
            do {
                return try await sendPart(
                    data: data,
                    baseURL: baseURL,
                    sessionID: sessionID,
                    resourceID: resourceID,
                    partNumber: partNumber,
                    offset: offset
                )
            } catch let error as URLError where Self.isTransient(error) {
                lastError = error
                if attempt < 4 {
                    try await Task.sleep(for: .seconds(1 << attempt))
                }
            }
        }
        throw lastError ?? URLError(.networkConnectionLost)
    }

    private func sendPart(
        data: Data,
        baseURL: URL,
        sessionID: String,
        resourceID: String,
        partNumber: Int64,
        offset: Int64
    ) async throws -> PhotoUploadPartEnvelope {
        let path = "api/v1/photos/upload-sessions/\(sessionID)/resources/\(resourceID)/parts/\(partNumber)"
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-MyNAS-Request")
        request.setValue(String(offset), forHTTPHeaderField: "X-Upload-Offset")
        request.setValue(FileSHA256.digest(of: data), forHTTPHeaderField: "X-Chunk-SHA256")
        return try await perform(request)
    }

    private func jsonRequest<Response: Decodable>(
        baseURL: URL,
        path: String,
        method: String,
        body: Data
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-MyNAS-Request")
        return try await perform(request)
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            throw PhotoBackupUploadError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data.prefix(500), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知错误"
            throw PhotoBackupUploadError.server(status: http.statusCode, message: message)
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw PhotoBackupUploadError.invalidResponse
        }
    }

    private nonisolated static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            true
        default:
            false
        }
    }

    private nonisolated static func dateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private nonisolated static func outcome(
        from session: PhotoUploadSessionEnvelope,
        wasDuplicate: Bool
    ) throws -> PhotoBackupUploadOutcome {
        let sourceState: PhotoSourceState
        if let rawSourceState = session.sourceState {
            guard let decoded = PhotoSourceState(rawValue: rawSourceState) else {
                throw PhotoBackupUploadError.invalidResponse
            }
            sourceState = decoded
        } else {
            // Compatibility with MyNAS 0.5.0 responses from before the E1
            // state contract. A completed upload still proves only source commit.
            sourceState = .committed
        }

        let derivativeState: PhotoDerivativeState
        if let rawDerivativeState = session.derivativeState {
            guard let decoded = PhotoDerivativeState(rawValue: rawDerivativeState) else {
                throw PhotoBackupUploadError.invalidResponse
            }
            derivativeState = decoded
        } else {
            derivativeState = .pending
        }

        let browseReady = session.browseReady ?? (derivativeState == .ready)
        guard sourceState == .committed,
              browseReady == (derivativeState == .ready) else {
            throw PhotoBackupUploadError.invalidResponse
        }
        return PhotoBackupUploadOutcome(
            assetID: session.assetID,
            wasDuplicate: wasDuplicate,
            sourceState: sourceState,
            derivativeState: derivativeState,
            browseReady: browseReady
        )
    }
}

private nonisolated struct PhotoUploadSessionRequest: Encodable {
    let volumeID: String
    let deviceID: String
    let localIdentifier: String
    let fingerprint: String
    let mediaType: String
    let captureDate: String?
    let modificationDate: String?
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval
    let favorite: Bool
    let resources: [PhotoUploadResourceRequest]
}

private nonisolated struct PhotoUploadResourceRequest: Encodable {
    let clientResourceID: String
    let resourceRole: String
    let originalFilename: String
    let contentType: String
    let byteSize: Int64
    let sha256: String
}

private nonisolated struct PhotoUploadSessionEnvelope: Decodable {
    let id: String?
    let assetID: String
    let status: String
    let sourceState: String?
    let derivativeState: String?
    let browseReady: Bool?
    let fingerprint: String
    let totalBytes: Int64
    let receivedBytes: Int64
    var resources: [PhotoUploadResourceEnvelope]
}

private nonisolated struct PhotoUploadResourceEnvelope: Decodable {
    let id: String
    let clientResourceID: String
    let resourceRole: String
    let originalFilename: String
    let contentType: String
    let byteSize: Int64
    let sha256: String
    var receivedBytes: Int64
    let chunkSize: Int64
    let status: String
}

private nonisolated struct PhotoUploadPartEnvelope: Decodable {
    let resourceID: String
    let receivedBytes: Int64
    let status: String
}
