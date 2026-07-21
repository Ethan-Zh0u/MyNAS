package main

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"mime"
	_ "modernc.org/sqlite"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type Config struct {
	Root, DataDir, Listen, Origin, PrivateOrigin string
	DevIdentity                                  bool
}
type StorageHealth struct {
	Status     string `json:"status"`
	Mount      string `json:"mount"`
	Device     string `json:"device"`
	Filesystem string `json:"filesystem"`
	UUID       string `json:"uuid"`
	Message    string `json:"message"`
}
type App struct {
	c             Config
	db            *sql.DB
	hub           *Hub
	uploadMu      sync.Mutex
	activeUploads map[string]bool
	transferMu    sync.Mutex
	volumeReads   map[string]uint64
	volumeWrites  map[string]uint64
}
type Hub struct {
	mu   sync.Mutex
	subs map[chan []byte]bool
}
type User struct {
	Login  string `json:"login"`
	Name   string `json:"name"`
	Avatar string `json:"avatar"`
	Role   string `json:"role"`
}
type Entry struct {
	Name      string    `json:"name"`
	Path      string    `json:"path"`
	VolumeID  string    `json:"volumeId"`
	Type      string    `json:"type"`
	Size      int64     `json:"size"`
	Modified  time.Time `json:"modified"`
	Thumbnail bool      `json:"thumbnail"`
}
type upload struct {
	ID       string `json:"id"`
	VolumeID string `json:"volumeId"`
	Target   string `json:"target"`
	Stage    string `json:"stage"`
	Name     string `json:"name"`
	Status   string `json:"status"`
	Updated  string `json:"updated"`
	Size     int64  `json:"size"`
	Received int64  `json:"received"`
}

func main() {
	c := Config{Root: env("MYNAS_ROOT", "/mnt/nas"), DataDir: env("MYNAS_DATA_DIR", filepath.Join(os.Getenv("HOME"), ".local/share/mynas")), Listen: env("MYNAS_LISTEN", "127.0.0.1:8080"), Origin: env("MYNAS_ALLOWED_ORIGIN", ""), PrivateOrigin: env("MYNAS_PRIVATE_ORIGIN", ""), DevIdentity: os.Getenv("MYNAS_ENV") == "development" && os.Getenv("MYNAS_DEV_IDENTITY") == "1"}
	if os.Getenv("MYNAS_ENV") == "production" {
		c.DevIdentity = false
	}
	if err := os.MkdirAll(c.DataDir, 0700); err != nil {
		log.Fatal(err)
	}
	if storageRootAvailable(c.Root) {
		for _, d := range []string{"staging", "thumbnails", "trash"} {
			if err := os.MkdirAll(filepath.Join(c.Root, ".mynas", d), 0700); err != nil {
				log.Fatal(err)
			}
		}
	} else {
		log.Printf("storage unavailable at %s; starting in safe read-only API mode", c.Root)
	}
	db, err := sql.Open("sqlite", filepath.Join(c.DataDir, "mynas.db"))
	if err != nil {
		log.Fatal(err)
	}
	configureDB(db)
	a := &App{c: c, db: db, hub: &Hub{subs: map[chan []byte]bool{}}, activeUploads: map[string]bool{}, volumeReads: map[string]uint64{}, volumeWrites: map[string]uint64{}}
	if err = a.migrate(); err != nil {
		log.Fatal(err)
	}
	if err = a.seedPrimaryVolume(); err != nil {
		log.Fatal(err)
	}
	if err = a.loadConfiguredVolumes(); err != nil {
		log.Fatal(err)
	}
	if err = a.ensureRegisteredVolumeDirs(); err != nil {
		log.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/health", a.health)
	mux.HandleFunc("/api/v1/events", a.events)
	mux.HandleFunc("/api/v1/files", a.files)
	mux.HandleFunc("/api/v1/files/", a.fileByPath)
	mux.HandleFunc("/api/v1/folders", a.folder)
	mux.HandleFunc("/api/v1/operations", a.operations)
	mux.HandleFunc("/api/v1/uploads", a.uploads)
	mux.HandleFunc("/api/v1/uploads/", a.uploadByID)
	mux.HandleFunc("/api/v1/trash", a.trash)
	mux.HandleFunc("/api/v1/disk", a.disk)
	mux.HandleFunc("/api/v1/volumes", a.volumes)
	mux.HandleFunc("/api/v1/volumes/candidates", a.volumeCandidates)
	if web := os.Getenv("MYNAS_WEB_DIR"); web != "" {
		mux.Handle("/", spa(web))
	}
	log.Printf("MyNAS listening at %s; root=%s", c.Listen, c.Root)
	log.Fatal(http.ListenAndServe(c.Listen, a.middleware(mux)))
}
func configureDB(db *sql.DB) {
	// SQLite 只有一个写入器。树莓派上传完成协程与新会话可能同时写库，
	// 用单连接队列避免把短暂锁竞争暴露成 SQLITE_BUSY 给浏览器。
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
}
func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
func (a *App) migrate() error {
	_, e := a.db.Exec(`CREATE TABLE IF NOT EXISTS uploads(id TEXT PRIMARY KEY,target TEXT,stage TEXT,name TEXT,status TEXT,size INTEGER,received INTEGER,updated TEXT);CREATE TABLE IF NOT EXISTS audit(id INTEGER PRIMARY KEY AUTOINCREMENT,at TEXT,user_login TEXT,action TEXT,path TEXT,detail TEXT);CREATE TABLE IF NOT EXISTS volumes(id TEXT PRIMARY KEY,name TEXT NOT NULL,uuid TEXT UNIQUE,device TEXT NOT NULL,filesystem TEXT NOT NULL,mount TEXT NOT NULL UNIQUE,enabled INTEGER NOT NULL DEFAULT 1,created TEXT NOT NULL);`)
	if e != nil {
		return e
	}
	if _, e = a.db.Exec("ALTER TABLE uploads ADD COLUMN volume_id TEXT NOT NULL DEFAULT 'primary'"); e != nil && !strings.Contains(strings.ToLower(e.Error()), "duplicate column") {
		return e
	}
	return nil
}
func (a *App) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin != "" {
			if !a.allowedOrigin(origin) {
				http.Error(w, "origin denied", 403)
				return
			}
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Vary", "Origin")
			w.Header().Set("Access-Control-Allow-Credentials", "true")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-MyNAS-Request, X-Upload-Offset, X-Chunk-Checksum")
			w.Header().Set("Access-Control-Allow-Methods", "GET,POST,PUT,PATCH,DELETE,OPTIONS")
			if strings.EqualFold(r.Header.Get("Access-Control-Request-Private-Network"), "true") {
				w.Header().Set("Access-Control-Allow-Private-Network", "true")
			}
		}
		if r.Method == "OPTIONS" {
			w.WriteHeader(204)
			return
		}
		u, ok := a.user(r)
		if !ok {
			http.Error(w, "Tailscale identity required", 401)
			return
		}
		r.Header.Set("X-MyNAS-User", u.Login)
		if r.Method != "GET" && r.Method != "HEAD" && r.Header.Get("X-MyNAS-Request") != "1" {
			http.Error(w, "missing CSRF request header", 403)
			return
		}
		next.ServeHTTP(w, r)
	})
}
func (a *App) allowedOrigin(o string) bool {
	if strings.HasPrefix(o, "http://localhost:") || strings.HasPrefix(o, "http://127.0.0.1:") {
		return true
	}
	return (a.c.Origin != "" && o == a.c.Origin) || (a.c.PrivateOrigin != "" && o == a.c.PrivateOrigin)
}
func (a *App) user(r *http.Request) (User, bool) {
	l := r.Header.Get("Tailscale-User-Login")
	if l != "" {
		return User{l, r.Header.Get("Tailscale-User-Name"), r.Header.Get("Tailscale-User-Profile-Pic"), "member"}, true
	}
	if a.c.DevIdentity {
		return User{"developer@example.test", "开发身份", "", "member"}, true
	}
	return User{}, false
}
func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(v)
}
func spa(dir string) http.Handler {
	files := http.FileServer(http.Dir(dir))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" && r.Method != "HEAD" {
			http.Error(w, "method", 405)
			return
		}
		rel := strings.TrimPrefix(filepath.ToSlash(filepath.Clean(r.URL.Path)), "/")
		candidate := filepath.Join(dir, filepath.FromSlash(rel))
		if info, e := os.Stat(candidate); e == nil && !info.IsDir() {
			files.ServeHTTP(w, r)
			return
		}
		http.ServeFile(w, r, filepath.Join(dir, "index.html"))
	})
}
func readJSON(r *http.Request, v any) error {
	if !strings.Contains(r.Header.Get("Content-Type"), "application/json") {
		return errors.New("JSON required")
	}
	return json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(v)
}
func cleanName(n string) (string, error) {
	if strings.ContainsAny(n, "/\\\x00\r\n\t") {
		return "", errors.New("invalid file name")
	}
	n = strings.TrimSpace(n)
	if n == "" || n == "." || n == ".." {
		return "", errors.New("invalid file name")
	}
	for _, x := range []string{"CON", "PRN", "AUX", "NUL", "COM1", "LPT1"} {
		if strings.EqualFold(n, x) {
			return "", errors.New("reserved name")
		}
	}
	return n, nil
}
func (a *App) path(rel string, write bool) (string, error) {
	if a.db == nil {
		return resolveWithin(a.c.Root, rel, write)
	}
	return a.pathFor("primary", rel, write)
}
func relative(root, p string) string { x, _ := filepath.Rel(root, p); return filepath.ToSlash(x) }
func (a *App) audit(r *http.Request, act, p, detail string) {
	_, _ = a.db.Exec("INSERT INTO audit(at,user_login,action,path,detail) VALUES(?,?,?,?,?)", time.Now().UTC().Format(time.RFC3339), r.Header.Get("X-MyNAS-User"), act, p, detail)
}
func (a *App) emit(v any) {
	b, _ := json.Marshal(v)
	a.hub.mu.Lock()
	defer a.hub.mu.Unlock()
	for c := range a.hub.subs {
		select {
		case c <- b:
		default:
		}
	}
}
func (a *App) health(w http.ResponseWriter, r *http.Request) {
	u, _ := a.user(r)
	writeJSON(w, map[string]any{"ok": true, "user": u, "protocol": "HTTPS over Tailscale Serve", "version": "0.3.2", "storage": a.storageHealth()})
}

func (a *App) storageHealth() StorageHealth {
	storage := StorageHealth{Status: "offline", Mount: a.c.Root, Message: "NAS 数据盘未挂载，文件操作已暂停"}
	volume, err := a.volumeByID("primary")
	if err != nil {
		storage.Message = "NAS 数据盘状态暂时无法读取"
		return storage
	}
	storage.Status = volume.Status
	storage.Mount = volume.Mount
	storage.Device = volume.Device
	storage.Filesystem = volume.Filesystem
	storage.UUID = volume.UUID
	if volume.Status == "online" {
		storage.Message = "NAS 数据盘已挂载"
	} else if volume.Smart != "" {
		storage.Message = volume.Smart
	}
	return storage
}
func (a *App) events(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	f, ok := w.(http.Flusher)
	if !ok {
		return
	}
	ch := make(chan []byte, 16)
	a.hub.mu.Lock()
	a.hub.subs[ch] = true
	a.hub.mu.Unlock()
	defer func() { a.hub.mu.Lock(); delete(a.hub.subs, ch); a.hub.mu.Unlock() }()
	fmt.Fprint(w, "event: ready\ndata: {}\n\n")
	f.Flush()
	for {
		select {
		case b := <-ch:
			fmt.Fprintf(w, "event: update\ndata: %s\n\n", b)
			f.Flush()
		case <-r.Context().Done():
			return
		}
	}
}
func (a *App) files(w http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" {
		http.Error(w, "method", 405)
		return
	}
	rel := r.URL.Query().Get("path")
	volumeID := r.URL.Query().Get("volumeId")
	if volumeID == "" {
		volumeID = "primary"
	}
	p, e := a.pathFor(volumeID, rel, false)
	if e != nil {
		http.Error(w, e.Error(), 400)
		return
	}
	ds, e := os.ReadDir(p)
	if e != nil {
		http.Error(w, "not a readable directory", 404)
		return
	}
	out := make([]Entry, 0, len(ds))
	for _, d := range ds {
		if d.Name() == ".mynas" || d.Name() == "$RECYCLE.BIN" || d.Name() == "System Volume Information" {
			continue
		}
		i, e := d.Info()
		if e != nil {
			continue
		}
		typ := kind(d.Name(), d.IsDir())
		out = append(out, Entry{Name: d.Name(), Path: filepath.ToSlash(filepath.Join(rel, d.Name())), VolumeID: volumeID, Type: typ, Size: i.Size(), Modified: i.ModTime(), Thumbnail: a.thumbnailExists(volumeID, rel, d.Name(), typ)})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Type == "folder" && out[j].Type != "folder" {
			return true
		}
		if out[j].Type == "folder" && out[i].Type != "folder" {
			return false
		}
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	writeJSON(w, map[string]any{"volumeId": volumeID, "path": rel, "items": out})
}
func kind(n string, dir bool) string {
	if dir {
		return "folder"
	}
	x := strings.ToLower(filepath.Ext(n))
	for t, ss := range map[string][]string{"image": {".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic"}, "video": {".mp4", ".mkv", ".mov", ".avi", ".webm"}, "audio": {".mp3", ".flac", ".wav", ".m4a", ".ogg"}, "pdf": {".pdf"}, "office": {".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx"}, "text": {".txt", ".md", ".csv", ".log"}, "code": {".go", ".js", ".ts", ".tsx", ".py", ".c", ".h", ".cpp", ".json", ".yaml", ".yml"}, "archive": {".zip", ".rar", ".7z", ".tar", ".gz", ".bz2"}, "disk": {".iso", ".img"}, "font": {".ttf", ".otf", ".woff", ".woff2"}, "exec": {".exe", ".msi", ".sh", ".bat"}} {
		for _, e := range ss {
			if x == e {
				return t
			}
		}
	}
	return "unknown"
}
func (a *App) folder(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, "method", 405)
		return
	}
	var v struct{ Path, Name, VolumeID string }
	if e := readJSON(r, &v); e != nil {
		http.Error(w, e.Error(), 400)
		return
	}
	n, e := cleanName(v.Name)
	if e != nil {
		http.Error(w, e.Error(), 400)
		return
	}
	parent, e := a.pathFor(v.VolumeID, v.Path, false)
	if e != nil {
		http.Error(w, e.Error(), 400)
		return
	}
	if e = os.Mkdir(filepath.Join(parent, n), 0750); e != nil {
		http.Error(w, e.Error(), 409)
		return
	}
	a.audit(r, "mkdir", filepath.Join(v.Path, n), "volume="+defaultVolumeID(v.VolumeID))
	a.emit(map[string]string{"type": "files"})
	w.WriteHeader(201)
}
func (a *App) fileByPath(w http.ResponseWriter, r *http.Request) {
	rel := strings.TrimPrefix(r.URL.Path, "/api/v1/files/")
	volumeID := defaultVolumeID(r.URL.Query().Get("volumeId"))
	p, e := a.pathFor(volumeID, rel, false)
	if e != nil {
		http.Error(w, e.Error(), 400)
		return
	}
	if r.Method == "GET" {
		a.download(w, r, p, volumeID)
		return
	}
	http.Error(w, "method", 405)
}

type countingReadSeeker struct {
	io.ReadSeeker
	onRead func(int)
}

func (reader *countingReadSeeker) Read(buffer []byte) (int, error) {
	n, err := reader.ReadSeeker.Read(buffer)
	if n > 0 && reader.onRead != nil {
		reader.onRead(n)
	}
	return n, err
}

func (a *App) download(w http.ResponseWriter, r *http.Request, p, volumeID string) {
	i, e := os.Stat(p)
	if e != nil || i.IsDir() {
		http.Error(w, "not found", 404)
		return
	}
	f, e := os.Open(p)
	if e != nil {
		http.Error(w, "not found", 404)
		return
	}
	defer f.Close()
	etag := fmt.Sprintf("\"%x-%x\"", i.Size(), i.ModTime().UnixNano())
	w.Header().Set("ETag", etag)
	w.Header().Set("Accept-Ranges", "bytes")
	w.Header().Set("Content-Type", mime.TypeByExtension(filepath.Ext(p)))
	reader := &countingReadSeeker{ReadSeeker: f, onRead: func(n int) { a.addVolumeIO(volumeID, uint64(n), 0) }}
	http.ServeContent(w, r, filepath.Base(p), i.ModTime(), reader)
}
func (a *App) operations(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, "method", 405)
		return
	}
	var v struct{ Action, From, To, Conflict, FromVolumeID, ToVolumeID string }
	if e := readJSON(r, &v); e != nil {
		http.Error(w, e.Error(), 400)
		return
	}
	fromVolumeID := defaultVolumeID(v.FromVolumeID)
	toVolumeID := defaultVolumeID(v.ToVolumeID)
	src, e := a.pathFor(fromVolumeID, v.From, false)
	if e != nil {
		http.Error(w, e.Error(), 400)
		return
	}
	var dst string
	if v.Action != "delete" {
		dst, e = a.pathFor(toVolumeID, v.To, true)
		if e != nil {
			http.Error(w, e.Error(), 400)
			return
		}
		if _, e = os.Stat(dst); e == nil {
			if v.Conflict == "skip" {
				writeJSON(w, map[string]string{"status": "skipped"})
				return
			}
			if v.Conflict == "rename" {
				dst = unique(dst)
			} else if v.Conflict != "overwrite" {
				http.Error(w, "conflict", 409)
				return
			} else {
				if e = os.RemoveAll(dst); e != nil {
					http.Error(w, e.Error(), 500)
					return
				}
			}
		}
	}
	switch v.Action {
	case "rename":
		e = os.Rename(src, dst)
	case "move":
		e = movePath(src, dst)
	case "copy":
		e = copyTree(src, dst)
	case "delete":
		e = a.toTrash(fromVolumeID, src, v.From)
	default:
		e = errors.New("unknown operation")
	}
	if e != nil {
		http.Error(w, e.Error(), 400)
		return
	}
	a.audit(r, v.Action, fromVolumeID+":"+v.From, toVolumeID+":"+v.To)
	a.emit(map[string]string{"type": "files"})
	writeJSON(w, map[string]string{"status": "ok"})
}
func unique(p string) string {
	d, e := filepath.Dir(p), filepath.Ext(p)
	b := strings.TrimSuffix(filepath.Base(p), e)
	for n := 1; ; n++ {
		x := filepath.Join(d, fmt.Sprintf("%s (%d)%s", b, n, e))
		if _, z := os.Lstat(x); os.IsNotExist(z) {
			return x
		}
	}
}
func copyTree(src, dst string) error {
	return filepath.WalkDir(src, func(p string, d fs.DirEntry, e error) error {
		if e != nil {
			return e
		}
		r, _ := filepath.Rel(src, p)
		q := filepath.Join(dst, r)
		if d.IsDir() {
			return os.MkdirAll(q, 0750)
		}
		in, e := os.Open(p)
		if e != nil {
			return e
		}
		defer in.Close()
		out, e := os.OpenFile(q, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0640)
		if e != nil {
			return e
		}
		_, e = io.Copy(out, in)
		ce := out.Close()
		if e != nil {
			return e
		}
		return ce
	})
}
func movePath(src, dst string) error {
	if e := os.Rename(src, dst); e == nil {
		return nil
	} else if !errors.Is(e, syscall.EXDEV) {
		return e
	}
	i, e := os.Stat(src)
	if e != nil {
		return e
	}
	if !i.IsDir() {
		return commitStage(src, dst)
	}
	if e = copyTree(src, dst); e != nil {
		return e
	}
	return os.RemoveAll(src)
}
func defaultVolumeID(value string) string {
	if value == "" {
		return "primary"
	}
	return value
}

func (a *App) toTrash(volumeID, src, rel string) error {
	volume, err := a.volumeByID(volumeID)
	if err != nil {
		return err
	}
	id := time.Now().UTC().Format("20060102T150405.000000000")
	d := filepath.Join(volume.Mount, ".mynas", "trash", id)
	if e := os.MkdirAll(d, 0700); e != nil {
		return fmt.Errorf("create trash directory: %w", e)
	}
	if e := movePath(src, filepath.Join(d, filepath.Base(src))); e != nil {
		os.RemoveAll(d)
		return fmt.Errorf("move item to trash: %w", e)
	}
	m := map[string]string{"original": rel, "volumeId": volume.ID}
	b, _ := json.Marshal(m)
	if e := os.WriteFile(filepath.Join(d, "meta.json"), b, 0600); e != nil {
		return fmt.Errorf("write trash metadata: %w", e)
	}
	return nil
}
func (a *App) trash(w http.ResponseWriter, r *http.Request) {
	if r.Method == "GET" {
		o := make([]map[string]string, 0)
		volumes, _ := a.listVolumes()
		for _, volume := range volumes {
			if volume.Status != "online" {
				continue
			}
			base := filepath.Join(volume.Mount, ".mynas", "trash")
			ds, _ := os.ReadDir(base)
			for _, d := range ds {
				b, e := os.ReadFile(filepath.Join(base, d.Name(), "meta.json"))
				if e == nil {
					var m map[string]string
					json.Unmarshal(b, &m)
					m["id"] = d.Name()
					m["volumeId"] = volume.ID
					m["volumeName"] = volume.Name
					o = append(o, m)
				}
			}
		}
		writeJSON(w, o)
		return
	}
	if r.Method != "POST" {
		http.Error(w, "method", 405)
		return
	}
	var v struct{ ID, Action, To, VolumeID string }
	if e := readJSON(r, &v); e != nil {
		http.Error(w, e.Error(), 400)
		return
	}
	volume, e := a.volumeByID(v.VolumeID)
	if e != nil {
		http.Error(w, e.Error(), 400)
		return
	}
	base := filepath.Join(volume.Mount, ".mynas", "trash")
	d := filepath.Join(base, v.ID)
	if filepath.Base(d) != v.ID {
		http.Error(w, "invalid", 400)
		return
	}
	if v.Action == "purge" {
		e := os.RemoveAll(d)
		if e != nil {
			http.Error(w, e.Error(), 500)
			return
		}
	} else if v.Action == "restore" {
		b, e := os.ReadFile(filepath.Join(d, "meta.json"))
		if e != nil {
			http.Error(w, "not found", 404)
			return
		}
		var m map[string]string
		json.Unmarshal(b, &m)
		dst, e := a.pathFor(volume.ID, m["original"], true)
		if e != nil {
			http.Error(w, e.Error(), 400)
			return
		}
		ds, _ := os.ReadDir(d)
		var source string
		for _, x := range ds {
			if x.Name() != "meta.json" {
				source = filepath.Join(d, x.Name())
				break
			}
		}
		if source == "" {
			http.Error(w, "missing trashed file", 409)
			return
		}
		e = movePath(source, dst)
		if e == nil {
			e = os.RemoveAll(d)
		}
		if e != nil {
			http.Error(w, e.Error(), 409)
			return
		}
	} else {
		http.Error(w, "action", 400)
		return
	}
	a.emit(map[string]string{"type": "files"})
	w.WriteHeader(204)
}
func token() string { b := make([]byte, 16); rand.Read(b); return hex.EncodeToString(b) }
func (a *App) uploads(w http.ResponseWriter, r *http.Request) {
	if r.Method == "GET" {
		// A browser can disappear between chunks. Once no request is writing a
		// session, turn an old row into a resumable paused task instead of
		// leaving the transfer page stuck forever.
		cutoff := time.Now().UTC().Add(-30 * time.Second).Format(time.RFC3339)
		rows, e := a.db.Query("SELECT id FROM uploads WHERE status IN ('waiting','uploading') AND updated < ?", cutoff)
		if e == nil {
			var stale []string
			for rows.Next() {
				var id string
				if rows.Scan(&id) == nil && !a.uploadActive(id) {
					stale = append(stale, id)
				}
			}
			rows.Close()
			for _, id := range stale {
				a.db.Exec("UPDATE uploads SET status='paused',updated=? WHERE id=? AND status IN ('waiting','uploading')", time.Now().UTC().Format(time.RFC3339), id)
			}
		}
		rows, e = a.db.Query("SELECT id,target,stage,name,status,size,received,updated,volume_id FROM uploads ORDER BY updated DESC LIMIT 200")
		if e != nil {
			http.Error(w, "uploads unavailable", 500)
			return
		}
		defer rows.Close()
		out := make([]upload, 0)
		for rows.Next() {
			var u upload
			if e = rows.Scan(&u.ID, &u.Target, &u.Stage, &u.Name, &u.Status, &u.Size, &u.Received, &u.Updated, &u.VolumeID); e != nil {
				http.Error(w, "uploads unavailable", 500)
				return
			}
			out = append(out, u)
		}
		writeJSON(w, out)
		return
	}
	if r.Method != "POST" {
		http.Error(w, "method", 405)
		return
	}
	var v struct {
		Path, Name, VolumeID string
		Size                 int64
	}
	if e := readJSON(r, &v); e != nil {
		http.Error(w, e.Error(), 400)
		return
	}
	n, e := cleanName(v.Name)
	if e != nil || v.Size < 0 {
		http.Error(w, "invalid upload", 400)
		return
	}
	volumeID := defaultVolumeID(v.VolumeID)
	parent, e := a.pathFor(volumeID, v.Path, false)
	if e != nil {
		http.Error(w, e.Error(), 400)
		return
	}
	if _, free, e := diskSpace(parent); e == nil && uint64(v.Size) > free {
		http.Error(w, "insufficient space", 409)
		return
	}
	id := token()
	volume, e := a.volumeByID(volumeID)
	if e != nil {
		http.Error(w, e.Error(), 400)
		return
	}
	stage := filepath.Join(volume.Mount, ".mynas", "staging", id+".part")
	if e = os.WriteFile(stage, nil, 0600); e != nil {
		http.Error(w, e.Error(), 500)
		return
	}
	status := "waiting"
	if v.Size == 0 {
		status = "verifying"
	}
	_, e = a.db.Exec("INSERT INTO uploads(id,target,stage,name,status,size,received,updated,volume_id) VALUES(?,?,?,?,?,?,?,?,?)", id, v.Path, stage, n, status, v.Size, 0, time.Now().UTC().Format(time.RFC3339), volumeID)
	if e != nil {
		http.Error(w, e.Error(), 500)
		return
	}
	u := upload{ID: id, VolumeID: volumeID, Target: v.Path, Stage: stage, Name: n, Status: status, Size: v.Size}
	if v.Size == 0 {
		go a.finalize(u)
	}
	writeJSON(w, map[string]any{"id": id, "volumeId": volumeID, "chunkSize": 8 * 1024 * 1024, "status": status})
}
func (a *App) uploadByID(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/api/v1/uploads/")
	if filepath.Base(id) != id {
		http.Error(w, "invalid", 400)
		return
	}
	var u upload
	e := a.db.QueryRow("SELECT id,target,stage,name,status,size,received,updated,volume_id FROM uploads WHERE id=?", id).Scan(&u.ID, &u.Target, &u.Stage, &u.Name, &u.Status, &u.Size, &u.Received, &u.Updated, &u.VolumeID)
	if e != nil {
		log.Printf("upload lookup failed for %s: %v", id, e)
		http.Error(w, "not found", 404)
		return
	}
	if r.Method == "GET" {
		writeJSON(w, u)
		return
	}
	if r.Method == "DELETE" {
		if a.uploadActive(id) {
			http.Error(w, "upload chunk is still being written; pause first", 409)
			return
		}
		if e = os.Remove(u.Stage); e != nil && !os.IsNotExist(e) {
			http.Error(w, e.Error(), 500)
			return
		}
		if _, e = a.db.Exec("DELETE FROM uploads WHERE id=?", id); e != nil {
			http.Error(w, e.Error(), 500)
			return
		}
		a.emit(map[string]string{"type": "upload", "id": id, "status": "cancelled"})
		w.WriteHeader(204)
		return
	}
	if r.Method == "PUT" {
		var v struct {
			Status string `json:"status"`
		}
		if e = readJSON(r, &v); e != nil || (v.Status != "paused" && v.Status != "uploading") {
			http.Error(w, "status must be paused or uploading", 400)
			return
		}
		if u.Status == "completed" || u.Status == "verifying" || u.Status == "processing-cover" {
			http.Error(w, "upload can no longer be paused", 409)
			return
		}
		if _, e = a.db.Exec("UPDATE uploads SET status=?,updated=? WHERE id=?", v.Status, time.Now().UTC().Format(time.RFC3339), id); e != nil {
			http.Error(w, e.Error(), 500)
			return
		}
		a.emit(map[string]string{"type": "upload", "id": id, "status": v.Status})
		writeJSON(w, map[string]any{"id": id, "status": v.Status, "received": u.Received})
		return
	}
	if r.Method != "PATCH" {
		http.Error(w, "method", 405)
		return
	}
	a.setUploadActive(id, true)
	defer a.setUploadActive(id, false)
	off, e := strconv.ParseInt(r.Header.Get("X-Upload-Offset"), 10, 64)
	if e != nil || off != u.Received {
		http.Error(w, "offset conflict", 409)
		return
	}
	f, e := os.OpenFile(u.Stage, os.O_WRONLY, 0600)
	if e != nil {
		http.Error(w, e.Error(), 500)
		return
	}
	n, e := f.Seek(off, 0)
	var written int64
	if e == nil {
		written, e = io.CopyN(f, io.LimitReader(r.Body, 8*1024*1024+1), 8*1024*1024+1)
	}
	f.Close()
	if written > 0 {
		a.addVolumeIO(u.VolumeID, 0, uint64(written))
	}
	if e != nil && e != io.EOF {
		http.Error(w, e.Error(), 500)
		return
	}
	u.Received = n + int64(n)
	if info, z := os.Stat(u.Stage); z == nil {
		u.Received = info.Size()
	}
	status := "uploading"
	if u.Received >= u.Size {
		status = "verifying"
	}
	a.db.Exec("UPDATE uploads SET received=?,status=?,updated=? WHERE id=?", u.Received, status, time.Now().UTC().Format(time.RFC3339), id)
	if status == "verifying" {
		go a.finalize(u)
	}
	a.emit(map[string]any{"type": "upload", "id": id, "received": u.Received, "size": u.Size, "status": status})
	writeJSON(w, map[string]any{"received": u.Received, "status": status})
}

func (a *App) uploadActive(id string) bool {
	a.uploadMu.Lock()
	defer a.uploadMu.Unlock()
	return a.activeUploads != nil && a.activeUploads[id]
}

func (a *App) setUploadActive(id string, active bool) {
	a.uploadMu.Lock()
	defer a.uploadMu.Unlock()
	if a.activeUploads == nil {
		a.activeUploads = map[string]bool{}
	}
	if active {
		a.activeUploads[id] = true
	} else {
		delete(a.activeUploads, id)
	}
}

func (a *App) addVolumeIO(volumeID string, readBytes, writeBytes uint64) {
	volumeID = defaultVolumeID(volumeID)
	a.transferMu.Lock()
	defer a.transferMu.Unlock()
	if a.volumeReads == nil {
		a.volumeReads = map[string]uint64{}
	}
	if a.volumeWrites == nil {
		a.volumeWrites = map[string]uint64{}
	}
	a.volumeReads[volumeID] += readBytes
	a.volumeWrites[volumeID] += writeBytes
}

func (a *App) volumeIO(volumeID string) (uint64, uint64) {
	volumeID = defaultVolumeID(volumeID)
	a.transferMu.Lock()
	defer a.transferMu.Unlock()
	return a.volumeReads[volumeID], a.volumeWrites[volumeID]
}
func (a *App) finalize(u upload) {
	info, e := os.Stat(u.Stage)
	if e != nil || info.Size() != u.Size {
		log.Printf("upload finalize failed for %s: invalid staging file", u.ID)
		a.db.Exec("UPDATE uploads SET status='failed' WHERE id=?", u.ID)
		return
	}
	typ := kind(u.Name, false)
	if typ == "video" {
		a.db.Exec("UPDATE uploads SET status='processing-cover' WHERE id=?", u.ID)
		a.emit(map[string]string{"type": "upload", "id": u.ID, "status": "processing-cover"})
		thumbDir := filepath.Join(a.c.DataDir, "thumbnails")
		_ = os.MkdirAll(thumbDir, 0700)
		hash := fmt.Sprintf("%x", u.VolumeID+":"+u.Target+"/"+u.Name)
		thumb := filepath.Join(thumbDir, hash+".jpg")
		cmd := exec.Command("ffmpeg", "-y", "-ss", "00:00:01", "-i", u.Stage, "-frames:v", "1", "-vf", "scale=480:-2", thumb)
		if o, e := cmd.CombinedOutput(); e != nil {
			log.Printf("video thumbnail failed: %v (%d bytes)", e, len(o))
		}
	}
	dst, e := a.pathFor(u.VolumeID, filepath.ToSlash(filepath.Join(u.Target, u.Name)), true)
	if e == nil {
		if _, z := os.Stat(dst); z == nil {
			dst = unique(dst)
		}
		e = commitStage(u.Stage, dst)
	}
	if e != nil {
		log.Printf("upload finalize failed for %s: %v", u.ID, e)
		a.db.Exec("UPDATE uploads SET status='failed' WHERE id=?", u.ID)
	} else {
		a.db.Exec("UPDATE uploads SET status='completed' WHERE id=?", u.ID)
		a.emit(map[string]string{"type": "files"})
	}
	status := "completed"
	if e != nil {
		status = "failed"
	}
	a.emit(map[string]string{"type": "upload", "id": u.ID, "status": status})
}
func commitStage(stage, dst string) error {
	if e := os.Rename(stage, dst); e == nil {
		return nil
	} else if !errors.Is(e, syscall.EXDEV) {
		return e
	}
	in, e := os.Open(stage)
	if e != nil {
		return e
	}
	defer in.Close()
	tmp := filepath.Join(filepath.Dir(dst), "."+filepath.Base(dst)+"."+token()+".part")
	out, e := os.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0640)
	if e != nil {
		return e
	}
	_, copyErr := io.Copy(out, in)
	syncErr := out.Sync()
	closeErr := out.Close()
	if copyErr != nil || syncErr != nil || closeErr != nil {
		os.Remove(tmp)
		if copyErr != nil {
			return copyErr
		}
		if syncErr != nil {
			return syncErr
		}
		return closeErr
	}
	if e = os.Rename(tmp, dst); e != nil {
		os.Remove(tmp)
		return e
	}
	return os.Remove(stage)
}
func (a *App) thumbnailExists(volumeID, rel, name, typ string) bool {
	if typ != "image" && typ != "video" {
		return false
	}
	h := fmt.Sprintf("%x", volumeID+":"+rel+"/"+name)
	_, e := os.Stat(filepath.Join(a.c.DataDir, "thumbnails", h+".jpg"))
	return e == nil
}
func (a *App) disk(w http.ResponseWriter, r *http.Request) {
	volume, e := a.volumeByID("primary")
	if e != nil {
		http.Error(w, e.Error(), 500)
		return
	}
	writeJSON(w, volume)
}
