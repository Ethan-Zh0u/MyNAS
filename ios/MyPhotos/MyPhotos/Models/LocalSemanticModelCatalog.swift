import Foundation

/// The one model family I4 may activate. Model bytes are downloaded separately
/// from the application, but the exact package contract lives in source so a
/// downloaded directory is never trusted merely because its filenames match.
nonisolated enum LocalSemanticModelCatalog {
    static let qwen3VLEmbedding2BInt8Profile: LocalEmbeddingModelProfile = {
        // This literal is programmer-controlled and validated once at startup.
        try! LocalEmbeddingModelProfile(
            modelIdentifier: "Qwen3-VL-Embedding-2B",
            modelRevision: "mnn-75e53afe-int8-2026-08-13",
            dimension: 2_048,
            quantization: "int8"
        )
    }()

    /// File digests for the MNN export exercised on iPhone 16 Pro. A trusted
    /// downloader must construct this manifest rather than accepting a remote
    /// manifest as authority. The model is Apache-2.0, but remains an optional
    /// user download and is never bundled in the App Store binary.
    static let qwen3VLEmbedding2BInt8Manifest: LocalSemanticModelPackageManifest = {
        let files: [(path: String, byteCount: Int64, digest: String)] = [
            ("config.json", 691, "bf93391763c39cbd58242c4a3bd82603f87de5101d6d7add2cc9e735545096d1"),
            ("embedding.mnn", 1_629_472, "fa4daabc7898d8712b7758eaae2964246e3d98978dd11fa101adacacc85a2561"),
            ("embedding.mnn.json", 3_887_177, "ad701a1337151475006f296bf745e666cc5888f2052f57c564f91fc4aa644a00"),
            ("embedding.mnn.weight", 793_661_656, "b73a5f0a52b1949e6de8848f34fa6824b9279f59b21d0a1ac273680a5f4358c6"),
            ("embeddings_int8.bin", 350_060_544, "4fb8fb0d5caa80362cd45e7a1f0d4608048bc2c94a8861179b4aa06ce21d9857"),
            ("llm_config.json", 900, "04545bfe6d531d51e12a04426505b60dbb10e2bf4ab50815fc7313373963a168"),
            ("tokenizer.mtok", 4_107_257, "8a3c850cf8a04542812c857f83a7cc008de873b7bf66e065f96a0b822a911224"),
            ("visual.mnn", 501_536, "e30ea1d3fe4959681f0d06467f392883b37863c588e996ef8b317f0a772a6a1e"),
            ("visual.mnn.weight", 238_304_582, "f817346c4085c0b57d6df535e2ebc10e38b2f32656714a1da804ff106ab0f72e"),
        ]
        return try! LocalSemanticModelPackageManifest(
            runtime: .mnnQwen3VLEmbedding,
            profile: qwen3VLEmbedding2BInt8Profile,
            files: files.map {
                try! LocalSemanticModelPackageFile(
                    relativePath: $0.path,
                    byteCount: $0.byteCount,
                    sha256: $0.digest
                )
            }
        )
    }()
}
