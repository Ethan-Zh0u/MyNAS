package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCleanName(t *testing.T) {
	for _, n := range []string{"..", "a/b", "NUL", "a\n"} {
		if _, e := cleanName(n); e == nil {
			t.Fatalf("accepted %q", n)
		}
	}
	if n, e := cleanName("中文 文件.txt"); e != nil || n == "" {
		t.Fatal("valid Chinese name rejected")
	}
}
func TestConfigureDBSerializesSQLiteAccess(t *testing.T) {
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "pool.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	configureDB(db)
	if got := db.Stats().MaxOpenConnections; got != 1 {
		t.Fatalf("max open connections=%d", got)
	}
}
func TestPathProtectionAndSymlinkEscape(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	if e := os.Symlink(outside, filepath.Join(root, "escape")); e != nil {
		t.Skip(e)
	}
	a := &App{c: Config{Root: root}}
	for _, p := range []string{"../x", ".mynas/a", "$RECYCLE.BIN/a", "escape/a"} {
		if _, e := a.path(p, false); e == nil {
			t.Fatalf("accepted %q", p)
		}
	}
}
func TestProdAuthentication(t *testing.T) {
	a := &App{c: Config{Origin: "https://mynas.pages.dev"}}
	h := a.middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	r := httptest.NewRequest("GET", "/api/v1/health", nil)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 401 {
		t.Fatalf("got %d", w.Code)
	}
}
func TestPrivateNetworkPreflight(t *testing.T) {
	a := &App{c: Config{Origin: "https://mynas.pages.dev"}}
	h := a.middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	r := httptest.NewRequest("OPTIONS", "/api/v1/health", nil)
	r.Header.Set("Origin", "https://mynas.pages.dev")
	r.Header.Set("Access-Control-Request-Private-Network", "true")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 204 {
		t.Fatalf("got %d", w.Code)
	}
	if got := w.Header().Get("Access-Control-Allow-Private-Network"); got != "true" {
		t.Fatalf("private network header=%q", got)
	}
}
func TestPrivateOriginIsAllowed(t *testing.T) {
	a := &App{c: Config{Origin: "https://mynas.pages.dev", PrivateOrigin: "https://rsp.tail681937.ts.net"}}
	if !a.allowedOrigin("https://rsp.tail681937.ts.net") {
		t.Fatal("private origin rejected")
	}
	if a.allowedOrigin("https://untrusted.example") {
		t.Fatal("untrusted origin accepted")
	}
}
func TestDeleteMovesItemToTrash(t *testing.T) {
	root := t.TempDir()
	if e := os.Mkdir(filepath.Join(root, "item"), 0750); e != nil {
		t.Fatal(e)
	}
	db, e := sql.Open("sqlite", filepath.Join(t.TempDir(), "test.db"))
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	a := &App{c: Config{Root: root}, db: db, hub: &Hub{subs: map[chan []byte]bool{}}}
	if e = a.migrate(); e != nil {
		t.Fatal(e)
	}
	r := httptest.NewRequest("POST", "/api/v1/operations", strings.NewReader(`{"action":"delete","from":"item"}`))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("X-MyNAS-User", "tester")
	w := httptest.NewRecorder()
	a.operations(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	if _, e = os.Stat(filepath.Join(root, "item")); !os.IsNotExist(e) {
		t.Fatal("item was not moved")
	}
	entries, e := os.ReadDir(filepath.Join(root, ".mynas", "trash"))
	if e != nil || len(entries) != 1 {
		t.Fatalf("trash entries=%d err=%v", len(entries), e)
	}
}
func TestEmptyTrashIsJSONArray(t *testing.T) {
	root := t.TempDir()
	if e := os.MkdirAll(filepath.Join(root, ".mynas", "trash"), 0700); e != nil {
		t.Fatal(e)
	}
	a := &App{c: Config{Root: root}}
	r := httptest.NewRequest("GET", "/api/v1/trash", nil)
	w := httptest.NewRecorder()
	a.trash(w, r)
	if got := strings.TrimSpace(w.Body.String()); got != "[]" {
		t.Fatalf("got %q", got)
	}
}
func TestFilesUseClientJSONFieldNames(t *testing.T) {
	root := t.TempDir()
	if e := os.WriteFile(filepath.Join(root, "sample.txt"), []byte("x"), 0640); e != nil {
		t.Fatal(e)
	}
	a := &App{c: Config{Root: root}}
	r := httptest.NewRequest("GET", "/api/v1/files", nil)
	w := httptest.NewRecorder()
	a.files(w, r)
	body := w.Body.String()
	if !strings.Contains(body, `"name":"sample.txt"`) {
		t.Fatalf("missing lower-case name: %s", body)
	}
	if strings.Contains(body, `"Name"`) {
		t.Fatalf("unexpected Go field name: %s", body)
	}
}
func TestDownloadClosesFile(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "download.txt")
	if err := os.WriteFile(source, []byte("stream me"), 0640); err != nil {
		t.Fatal(err)
	}
	a := &App{c: Config{Root: root}}
	r := httptest.NewRequest("GET", "/api/v1/files/download.txt", nil)
	w := httptest.NewRecorder()
	a.download(w, r, source, "primary")
	if w.Code != http.StatusOK || w.Body.String() != "stream me" {
		t.Fatalf("download: %d %q", w.Code, w.Body.String())
	}
	if readBytes, _ := a.volumeIO("primary"); readBytes != uint64(len("stream me")) {
		t.Fatalf("tracked read bytes=%d", readBytes)
	}
	if err := os.Rename(source, filepath.Join(root, "renamed.txt")); err != nil {
		t.Fatalf("file remained locked after download: %v", err)
	}
}
func TestRangeDownload(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "range.bin")
	if err := os.WriteFile(source, []byte("0123456789abcdef"), 0640); err != nil {
		t.Fatal(err)
	}
	a := &App{c: Config{Root: root}}
	r := httptest.NewRequest("GET", "/api/v1/files/range.bin", nil)
	r.Header.Set("Range", "bytes=4-7")
	w := httptest.NewRecorder()
	a.download(w, r, source, "primary")
	if w.Code != http.StatusPartialContent || w.Body.String() != "4567" {
		t.Fatalf("range: %d %q", w.Code, w.Body.String())
	}
	if got := w.Header().Get("Content-Range"); got != "bytes 4-7/16" {
		t.Fatalf("content-range=%q", got)
	}
	if w.Header().Get("ETag") == "" || w.Header().Get("Accept-Ranges") != "bytes" {
		t.Fatal("range metadata missing")
	}
}
func TestUploadSessionReceivesAndFinalizesChunk(t *testing.T) {
	root := t.TempDir()
	for _, d := range []string{"staging", "thumbnails", "trash"} {
		if e := os.MkdirAll(filepath.Join(root, ".mynas", d), 0700); e != nil {
			t.Fatal(e)
		}
	}
	db, e := sql.Open("sqlite", filepath.Join(t.TempDir(), "test.db"))
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	a := &App{c: Config{Root: root}, db: db, hub: &Hub{subs: map[chan []byte]bool{}}}
	if e = a.migrate(); e != nil {
		t.Fatal(e)
	}
	r := httptest.NewRequest("POST", "/api/v1/uploads", strings.NewReader(`{"path":"","name":"sample.txt","size":5}`))
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	a.uploads(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("create: %d %s", w.Code, w.Body.String())
	}
	var created map[string]any
	if e = json.Unmarshal(w.Body.Bytes(), &created); e != nil {
		t.Fatal(e)
	}
	id := created["id"].(string)
	get := httptest.NewRequest("GET", "/api/v1/uploads/"+id, nil)
	gw := httptest.NewRecorder()
	a.uploadByID(gw, get)
	if gw.Code != http.StatusOK {
		t.Fatalf("get: %d %s", gw.Code, gw.Body.String())
	}
	patch := httptest.NewRequest("PATCH", "/api/v1/uploads/"+id, strings.NewReader("hello"))
	patch.Header.Set("X-Upload-Offset", "0")
	pw := httptest.NewRecorder()
	a.uploadByID(pw, patch)
	if pw.Code != http.StatusOK {
		t.Fatalf("patch: %d %s", pw.Code, pw.Body.String())
	}
	for i := 0; i < 50; i++ {
		if b, e := os.ReadFile(filepath.Join(root, "sample.txt")); e == nil && string(b) == "hello" {
			if _, writeBytes := a.volumeIO("primary"); writeBytes != uint64(len("hello")) {
				t.Fatalf("tracked write bytes=%d", writeBytes)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("upload was not finalized")
}

func TestUploadSessionCanPauseAndCancel(t *testing.T) {
	root := t.TempDir()
	for _, d := range []string{"staging", "thumbnails", "trash"} {
		if e := os.MkdirAll(filepath.Join(root, ".mynas", d), 0700); e != nil {
			t.Fatal(e)
		}
	}
	db, e := sql.Open("sqlite", filepath.Join(t.TempDir(), "test.db"))
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	a := &App{c: Config{Root: root}, db: db, hub: &Hub{subs: map[chan []byte]bool{}}, activeUploads: map[string]bool{}}
	if e = a.migrate(); e != nil {
		t.Fatal(e)
	}
	create := httptest.NewRequest("POST", "/api/v1/uploads", strings.NewReader(`{"path":"","name":"paused.txt","size":10}`))
	create.Header.Set("Content-Type", "application/json")
	cw := httptest.NewRecorder()
	a.uploads(cw, create)
	if cw.Code != http.StatusOK {
		t.Fatalf("create: %d %s", cw.Code, cw.Body.String())
	}
	var created map[string]any
	if e = json.Unmarshal(cw.Body.Bytes(), &created); e != nil {
		t.Fatal(e)
	}
	id := created["id"].(string)
	pause := httptest.NewRequest("PUT", "/api/v1/uploads/"+id, strings.NewReader(`{"status":"paused"}`))
	pause.Header.Set("Content-Type", "application/json")
	pw := httptest.NewRecorder()
	a.uploadByID(pw, pause)
	if pw.Code != http.StatusOK {
		t.Fatalf("pause: %d %s", pw.Code, pw.Body.String())
	}
	var status string
	if e = db.QueryRow("SELECT status FROM uploads WHERE id=?", id).Scan(&status); e != nil || status != "paused" {
		t.Fatalf("status=%q err=%v", status, e)
	}
	cancel := httptest.NewRequest("DELETE", "/api/v1/uploads/"+id, nil)
	dw := httptest.NewRecorder()
	a.uploadByID(dw, cancel)
	if dw.Code != http.StatusNoContent {
		t.Fatalf("cancel: %d %s", dw.Code, dw.Body.String())
	}
	if e = db.QueryRow("SELECT status FROM uploads WHERE id=?", id).Scan(&status); !errors.Is(e, sql.ErrNoRows) {
		t.Fatalf("upload row still exists: %v", e)
	}
}
func TestCommitStage(t *testing.T) {
	root := t.TempDir()
	stage := filepath.Join(root, "stage.part")
	dst := filepath.Join(root, "done.txt")
	if e := os.WriteFile(stage, []byte("streamed"), 0600); e != nil {
		t.Fatal(e)
	}
	if e := commitStage(stage, dst); e != nil {
		t.Fatal(e)
	}
	if b, e := os.ReadFile(dst); e != nil || string(b) != "streamed" {
		t.Fatalf("dst=%q err=%v", b, e)
	}
	if _, e := os.Stat(stage); !os.IsNotExist(e) {
		t.Fatal("stage still exists")
	}
}
