import Foundation

/// Identifies the exact local model output that produced an embedding. Vectors
/// from different profiles must never be compared or mixed in one index.
nonisolated struct LocalEmbeddingModelProfile: Codable, Equatable, Sendable {
    let modelIdentifier: String
    let modelRevision: String
    let dimension: Int
    let quantization: String

    init(
        modelIdentifier: String,
        modelRevision: String,
        dimension: Int,
        quantization: String
    ) throws {
        let canonicalIdentifier = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalRevision = modelRevision.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalQuantization = quantization.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonicalIdentifier.isEmpty,
              canonicalIdentifier.count <= 200,
              !canonicalRevision.isEmpty,
              canonicalRevision.count <= 200,
              (1...LocalEmbeddingVector.maximumDimension).contains(dimension),
              !canonicalQuantization.isEmpty,
              canonicalQuantization.count <= 50 else {
            throw LocalSemanticIndexError.invalidModelProfile
        }
        self.modelIdentifier = canonicalIdentifier
        self.modelRevision = canonicalRevision
        self.dimension = dimension
        self.quantization = canonicalQuantization
    }

    private enum CodingKeys: String, CodingKey {
        case modelIdentifier
        case modelRevision
        case dimension
        case quantization
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            modelIdentifier: container.decode(String.self, forKey: .modelIdentifier),
            modelRevision: container.decode(String.self, forKey: .modelRevision),
            dimension: container.decode(Int.self, forKey: .dimension),
            quantization: container.decode(String.self, forKey: .quantization)
        )
    }
}

/// A validated, unit-length embedding suitable for cosine-similarity search.
/// Decoding runs the same validation as model output so malformed local index
/// bytes fail closed instead of reaching vector arithmetic.
nonisolated struct LocalEmbeddingVector: Codable, Equatable, Sendable {
    static let maximumDimension = 4_096

    let values: [Float]

    var dimension: Int { values.count }

    init(normalizing values: [Float]) throws {
        guard !values.isEmpty, values.count <= Self.maximumDimension else {
            throw LocalSemanticIndexError.invalidEmbedding
        }
        guard values.allSatisfy(\.isFinite) else {
            throw LocalSemanticIndexError.invalidEmbedding
        }

        let squaredMagnitude = values.reduce(Float.zero) { partial, value in
            partial + value * value
        }
        guard squaredMagnitude.isFinite, squaredMagnitude > Float.ulpOfOne else {
            throw LocalSemanticIndexError.invalidEmbedding
        }

        let magnitude = squaredMagnitude.squareRoot()
        self.values = values.map { $0 / magnitude }
    }

    func cosineSimilarity(to other: LocalEmbeddingVector) throws -> Float {
        guard dimension == other.dimension else {
            throw LocalSemanticIndexError.embeddingDimensionMismatch(
                expected: dimension,
                actual: other.dimension
            )
        }
        return zip(values, other.values).reduce(Float.zero) { partial, pair in
            partial + pair.0 * pair.1
        }
    }

    /// Produces one normalized representative for a user-confirmed local
    /// collection. Callers must keep model-profile compatibility separate;
    /// averaging vectors from different spaces is never meaningful.
    static func centroid(of vectors: [LocalEmbeddingVector]) throws -> LocalEmbeddingVector {
        guard let first = vectors.first else {
            throw LocalSemanticIndexError.invalidEmbedding
        }
        guard vectors.allSatisfy({ $0.dimension == first.dimension }) else {
            throw LocalSemanticIndexError.embeddingDimensionMismatch(
                expected: first.dimension,
                actual: vectors.first(where: { $0.dimension != first.dimension })?.dimension ?? 0
            )
        }
        let sum = vectors.reduce(Array(repeating: Float.zero, count: first.dimension)) { partial, vector in
            zip(partial, vector.values).map(+)
        }
        return try LocalEmbeddingVector(normalizing: sum)
    }

    /// Produces a normalized representative while preserving how many source
    /// samples each input represents. This is used only for a user's already
    /// confirmed local identity reference; it is not a classifier update.
    static func weightedCentroid(
        of vectors: [(vector: LocalEmbeddingVector, weight: Int)]
    ) throws -> LocalEmbeddingVector {
        guard let first = vectors.first,
              first.weight > 0,
              vectors.allSatisfy({ $0.weight > 0 }) else {
            throw LocalSemanticIndexError.invalidEmbedding
        }
        guard vectors.allSatisfy({ $0.vector.dimension == first.vector.dimension }) else {
            throw LocalSemanticIndexError.embeddingDimensionMismatch(
                expected: first.vector.dimension,
                actual: vectors.first(where: { $0.vector.dimension != first.vector.dimension })?.vector.dimension ?? 0
            )
        }
        let sum = vectors.reduce(Array(repeating: Float.zero, count: first.vector.dimension)) { partial, entry in
            zip(partial, entry.vector.values).map { $0 + $1 * Float(entry.weight) }
        }
        return try LocalEmbeddingVector(normalizing: sum)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(normalizing: container.decode([Float].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

/// A whole-photo vector retained only in the current account's protected,
/// deletable local analysis namespace. It contains no image or thumbnail.
nonisolated struct LocalPhotoEmbeddingRecord: Identifiable, Codable, Equatable, Sendable {
    let assetID: String
    let sourceVersion: String
    let modelProfile: LocalEmbeddingModelProfile
    let embedding: LocalEmbeddingVector
    let indexedAt: Date

    var id: String { assetID }
}

nonisolated struct LocalSemanticSearchHit: Identifiable, Equatable, Sendable {
    let assetID: String
    let score: Float

    var id: String { assetID }
}

nonisolated enum LocalSemanticSearchRanker {
    static func rank(
        query: LocalEmbeddingVector,
        records: [LocalPhotoEmbeddingRecord],
        profile: LocalEmbeddingModelProfile,
        limit: Int,
        minimumScore: Float = -1
    ) throws -> [LocalSemanticSearchHit] {
        guard limit > 0 else { return [] }
        guard query.dimension == profile.dimension else {
            throw LocalSemanticIndexError.embeddingDimensionMismatch(
                expected: profile.dimension,
                actual: query.dimension
            )
        }

        var seenAssetIDs = Set<String>()
        let hits = try records.map { record -> LocalSemanticSearchHit in
            guard seenAssetIDs.insert(record.assetID).inserted,
                  !record.assetID.isEmpty,
                  record.modelProfile == profile else {
                throw LocalSemanticIndexError.incompatibleIndex
            }
            let score = try query.cosineSimilarity(to: record.embedding)
            return LocalSemanticSearchHit(assetID: record.assetID, score: score)
        }

        return hits
            .filter { $0.score >= minimumScore }
            .sorted { left, right in
                if left.score != right.score { return left.score > right.score }
                return left.assetID < right.assetID
            }
            .prefix(limit)
            .map { $0 }
    }
}

nonisolated enum LocalSemanticIndexError: LocalizedError, Equatable, Sendable {
    case invalidModelProfile
    case invalidEmbedding
    case embeddingDimensionMismatch(expected: Int, actual: Int)
    case incompatibleIndex

    var errorDescription: String? {
        switch self {
        case .invalidModelProfile:
            "本地模型标识、版本或向量维度无效。"
        case .invalidEmbedding:
            "模型返回了无效的本地特征向量。"
        case .embeddingDimensionMismatch:
            "本地特征向量维度不一致，必须重建索引。"
        case .incompatibleIndex:
            "本地语义索引与当前模型不兼容，必须重建。"
        }
    }
}
