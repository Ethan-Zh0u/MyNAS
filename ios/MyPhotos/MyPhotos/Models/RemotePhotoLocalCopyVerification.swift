import Foundation

/// Proves that a current Photos asset has the same complete original resource
/// group as a MyNAS item. Candidate metadata only reduces PhotoKit work; the
/// final decision always requires every resource role, byte count, and SHA-256
/// value to match.
nonisolated enum RemotePhotoLocalCopyVerification {
    static func candidates(
        for remoteAsset: ServerPhotoAsset,
        in localAssets: [LocalPhotoAsset]
    ) -> [LocalPhotoAsset] {
        localAssets.filter { isCandidate($0, for: remoteAsset) }
    }

    static func isCandidate(
        _ localAsset: LocalPhotoAsset,
        for remoteAsset: ServerPhotoAsset
    ) -> Bool {
        let hasCompatibleKind: Bool
        switch remoteAsset.mediaType {
        case .unknown:
            hasCompatibleKind = localAsset.mediaKind == .photo
        default:
            hasCompatibleKind = localAsset.mediaKind.rawValue == remoteAsset.mediaType.rawValue
        }
        guard hasCompatibleKind else { return false }

        let hasKnownPixelSize = remoteAsset.pixelWidth > 0 && remoteAsset.pixelHeight > 0
        guard !hasKnownPixelSize else {
            return localAsset.pixelWidth == remoteAsset.pixelWidth
                && localAsset.pixelHeight == remoteAsset.pixelHeight
        }
        return true
    }

    static func hasSameCompleteResourceGroup(
        localResources: [PreparedPhotoResource],
        remoteResources: [ServerPhotoResource]
    ) -> Bool {
        guard !localResources.isEmpty,
              localResources.count == remoteResources.count else {
            return false
        }

        let localProofs = localResources.compactMap(ResourceProof.init)
        let remoteProofs = remoteResources.compactMap(ResourceProof.init)
        guard localProofs.count == localResources.count,
              remoteProofs.count == remoteResources.count else {
            return false
        }
        return localProofs.sorted() == remoteProofs.sorted()
    }

    /// Returns an identity only when the complete resource proof selects one
    /// and only one MyNAS item. Equal resource groups under several remote IDs
    /// are a server-side ambiguity and must not be resolved by client order.
    static func uniqueCompleteResourceGroupMatch(
        localResources: [PreparedPhotoResource],
        among remoteAssets: [ServerPhotoAsset]
    ) -> ServerPhotoAsset? {
        var match: ServerPhotoAsset?
        for remoteAsset in remoteAssets where hasSameCompleteResourceGroup(
            localResources: localResources,
            remoteResources: remoteAsset.resources
        ) {
            guard match == nil else { return nil }
            match = remoteAsset
        }
        return match
    }

    private struct ResourceProof: Comparable {
        private static let hexadecimalCharacters = CharacterSet(
            charactersIn: "0123456789abcdefABCDEF"
        )
        let role: String
        let byteSize: Int64
        let sha256: String

        init?(_ resource: PreparedPhotoResource) {
            self.init(role: resource.role, byteSize: resource.byteSize, sha256: resource.sha256)
        }

        init?(_ resource: ServerPhotoResource) {
            self.init(role: resource.resourceRole, byteSize: resource.byteSize, sha256: resource.sha256)
        }

        private init?(role: String, byteSize: Int64, sha256: String) {
            let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedHash = sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedRole.isEmpty,
                  byteSize >= 0,
                  normalizedHash.count == 64,
                  normalizedHash.unicodeScalars.allSatisfy({
                      Self.hexadecimalCharacters.contains($0)
                  }) else {
                return nil
            }
            self.role = normalizedRole
            self.byteSize = byteSize
            self.sha256 = normalizedHash
        }

        static func < (lhs: ResourceProof, rhs: ResourceProof) -> Bool {
            if lhs.role != rhs.role { return lhs.role < rhs.role }
            if lhs.byteSize != rhs.byteSize { return lhs.byteSize < rhs.byteSize }
            return lhs.sha256 < rhs.sha256
        }
    }
}
