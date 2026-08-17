package main

import (
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// This is a deliberately fixed, optional package distribution endpoint. It
// does not expose MyNAS files or folders: only the exact Qwen/MNN release the
// iOS app pins by identifier, revision, byte count and SHA-256 is reachable.
const photosSemanticModelID = "qwen3-vl-embedding-2b"

type photosSemanticModelFile struct {
	RelativePath string `json:"relativePath"`
	ByteCount    int64  `json:"byteCount"`
	SHA256       string `json:"sha256"`
}

type photosSemanticModelProfile struct {
	ModelIdentifier string `json:"modelIdentifier"`
	ModelRevision   string `json:"modelRevision"`
	Dimension       int    `json:"dimension"`
	Quantization    string `json:"quantization"`
}

type photosSemanticModelManifest struct {
	SchemaVersion int                        `json:"schemaVersion"`
	Runtime       string                     `json:"runtime"`
	Profile       photosSemanticModelProfile `json:"profile"`
	Files         []photosSemanticModelFile  `json:"files"`
}

type photosSemanticModelManifestResponse struct {
	ServerID string                      `json:"serverID"`
	ModelID  string                      `json:"modelID"`
	Manifest photosSemanticModelManifest `json:"manifest"`
}

var pinnedQwen3VLEmbedding2BInt8Manifest = photosSemanticModelManifest{
	SchemaVersion: 1,
	Runtime:       "mnnQwen3VLEmbedding",
	Profile: photosSemanticModelProfile{
		ModelIdentifier: "Qwen3-VL-Embedding-2B",
		ModelRevision:   "mnn-75e53afe-int8-2026-08-13",
		Dimension:       2048,
		Quantization:    "int8",
	},
	Files: []photosSemanticModelFile{
		{RelativePath: "config.json", ByteCount: 691, SHA256: "bf93391763c39cbd58242c4a3bd82603f87de5101d6d7add2cc9e735545096d1"},
		{RelativePath: "embedding.mnn", ByteCount: 1629472, SHA256: "fa4daabc7898d8712b7758eaae2964246e3d98978dd11fa101adacacc85a2561"},
		{RelativePath: "embedding.mnn.json", ByteCount: 3887177, SHA256: "ad701a1337151475006f296bf745e666cc5888f2052f57c564f91fc4aa644a00"},
		{RelativePath: "embedding.mnn.weight", ByteCount: 793661656, SHA256: "b73a5f0a52b1949e6de8848f34fa6824b9279f59b21d0a1ac273680a5f4358c6"},
		{RelativePath: "embeddings_int8.bin", ByteCount: 350060544, SHA256: "4fb8fb0d5caa80362cd45e7a1f0d4608048bc2c94a8861179b4aa06ce21d9857"},
		{RelativePath: "llm_config.json", ByteCount: 900, SHA256: "04545bfe6d531d51e12a04426505b60dbb10e2bf4ab50815fc7313373963a168"},
		{RelativePath: "tokenizer.mtok", ByteCount: 4107257, SHA256: "8a3c850cf8a04542812c857f83a7cc008de873b7bf66e065f96a0b822a911224"},
		{RelativePath: "visual.mnn", ByteCount: 501536, SHA256: "e30ea1d3fe4959681f0d06467f392883b37863c588e996ef8b317f0a772a6a1e"},
		{RelativePath: "visual.mnn.weight", ByteCount: 238304582, SHA256: "f817346c4085c0b57d6df535e2ebc10e38b2f32656714a1da804ff106ab0f72e"},
	},
}

func (a *App) photosSemanticModelManifest(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	if _, ok := a.photosRequestOwner(w, r); !ok {
		return
	}
	if !a.hasPinnedSemanticModelPackage() {
		http.NotFound(w, r)
		return
	}
	writeJSON(w, photosSemanticModelManifestResponse{
		ServerID: a.serverID,
		ModelID:  photosSemanticModelID,
		Manifest: pinnedQwen3VLEmbedding2BInt8Manifest,
	})
}

func (a *App) photosSemanticModelFile(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	if _, ok := a.photosRequestOwner(w, r); !ok {
		return
	}
	name := strings.TrimPrefix(r.URL.Path, "/api/v1/photos/models/qwen3-vl-embedding-2b/files/")
	entry, ok := pinnedSemanticModelFile(name)
	if !ok {
		http.NotFound(w, r)
		return
	}
	path := filepath.Join(a.semanticModelDirectory(), entry.RelativePath)
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() != entry.ByteCount {
		http.NotFound(w, r)
		return
	}
	file, err := os.Open(path)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer file.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", "attachment; filename=\""+entry.RelativePath+"\"")
	http.ServeContent(w, r, entry.RelativePath, info.ModTime(), file)
}

func (a *App) semanticModelDirectory() string {
	return filepath.Join(a.c.Root, ".mynas", "models", photosSemanticModelID)
}

func (a *App) hasPinnedSemanticModelPackage() bool {
	for _, entry := range pinnedQwen3VLEmbedding2BInt8Manifest.Files {
		info, err := os.Lstat(filepath.Join(a.semanticModelDirectory(), entry.RelativePath))
		if err != nil || !info.Mode().IsRegular() || info.Size() != entry.ByteCount {
			return false
		}
	}
	return true
}

func pinnedSemanticModelFile(name string) (photosSemanticModelFile, bool) {
	for _, entry := range pinnedQwen3VLEmbedding2BInt8Manifest.Files {
		if entry.RelativePath == name {
			return entry, true
		}
	}
	return photosSemanticModelFile{}, false
}
