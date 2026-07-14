package main

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

type Volume struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	UUID       string `json:"uuid"`
	Device     string `json:"device"`
	Filesystem string `json:"filesystem"`
	Mount      string `json:"mount"`
	Status     string `json:"status"`
	Total      uint64 `json:"total"`
	Free       uint64 `json:"free"`
	Used       uint64 `json:"used"`
	ReadBytes  uint64 `json:"readBytes"`
	WriteBytes uint64 `json:"writeBytes"`
	Protocol   string `json:"protocol"`
	Smart      string `json:"smart"`
}

type VolumeCandidate struct {
	Device     string `json:"device"`
	UUID       string `json:"uuid"`
	Label      string `json:"label"`
	Model      string `json:"model"`
	Serial     string `json:"serial"`
	Filesystem string `json:"filesystem"`
	Mount      string `json:"mount"`
	Size       uint64 `json:"size"`
	Removable  bool   `json:"removable"`
	Supported  bool   `json:"supported"`
	Registered bool   `json:"registered"`
	Reason     string `json:"reason,omitempty"`
}

type volumeConfigFile struct {
	Volumes []struct {
		ID         string `json:"id"`
		Name       string `json:"name"`
		UUID       string `json:"uuid"`
		Device     string `json:"device"`
		Filesystem string `json:"filesystem"`
		Mount      string `json:"mount"`
	} `json:"volumes"`
}

func normalizeFilesystem(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "ntfs", "ntfs3":
		return "ntfs3"
	case "ext4":
		return "ext4"
	case "exfat":
		return "exfat"
	default:
		return strings.ToLower(strings.TrimSpace(value))
	}
}

func supportedFilesystem(value string) bool {
	switch normalizeFilesystem(value) {
	case "ntfs3", "ext4", "exfat":
		return true
	default:
		return false
	}
}

func stableVolumeID(uuid, device string) string {
	seed := strings.ToLower(strings.TrimSpace(uuid))
	if seed == "" {
		seed = strings.ToLower(strings.TrimSpace(device))
	}
	sum := sha256.Sum256([]byte(seed))
	return "vol-" + hex.EncodeToString(sum[:6])
}

func (a *App) seedPrimaryVolume() error {
	device, filesystem, uuid, label := mountedVolumeInfo(a.c.Root)
	if device == "" {
		device = a.c.Root
	}
	if filesystem == "" {
		if runtime.GOOS == "windows" {
			filesystem = "Windows 文件系统"
		} else {
			filesystem = "unknown"
		}
	}
	name := label
	if name == "" {
		name = "NAS 数据盘"
	}
	_, err := a.db.Exec(`INSERT INTO volumes(id,name,uuid,device,filesystem,mount,enabled,created)
		VALUES('primary',?,?,?,?,?,1,?)
		ON CONFLICT(id) DO UPDATE SET uuid=excluded.uuid,device=excluded.device,filesystem=excluded.filesystem,mount=excluded.mount`,
		name, uuid, device, normalizeFilesystem(filesystem), a.c.Root, time.Now().UTC().Format(time.RFC3339))
	return err
}

func (a *App) loadConfiguredVolumes() error {
	path := env("MYNAS_VOLUMES_FILE", "/etc/mynas/volumes.json")
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read volume configuration: %w", err)
	}
	var config volumeConfigFile
	if err = json.Unmarshal(data, &config); err != nil {
		return fmt.Errorf("parse volume configuration: %w", err)
	}
	for _, volume := range config.Volumes {
		volume.ID = strings.TrimSpace(volume.ID)
		volume.UUID = strings.TrimSpace(volume.UUID)
		volume.Mount = filepath.Clean(strings.TrimSpace(volume.Mount))
		if volume.ID == "" || volume.ID == "primary" || volume.UUID == "" || !filepath.IsAbs(volume.Mount) || !supportedFilesystem(volume.Filesystem) {
			return fmt.Errorf("invalid configured volume %q", volume.ID)
		}
		if runtime.GOOS != "windows" && volume.Mount != "/mnt/mynas" && !strings.HasPrefix(volume.Mount, "/mnt/mynas/") {
			return fmt.Errorf("configured volume %q is outside /mnt/mynas", volume.ID)
		}
		if volume.ID != stableVolumeID(volume.UUID, volume.Device) {
			return fmt.Errorf("configured volume %q has an invalid stable id", volume.ID)
		}
		name := strings.TrimSpace(volume.Name)
		if name == "" {
			name = "存储硬盘"
		}
		_, err = a.db.Exec(`INSERT INTO volumes(id,name,uuid,device,filesystem,mount,enabled,created) VALUES(?,?,?,?,?,?,1,?)
			ON CONFLICT(uuid) DO UPDATE SET device=excluded.device,filesystem=excluded.filesystem,mount=excluded.mount,enabled=1`,
			volume.ID, name, volume.UUID, volume.Device, normalizeFilesystem(volume.Filesystem), volume.Mount, time.Now().UTC().Format(time.RFC3339))
		if err != nil {
			return fmt.Errorf("register configured volume %q: %w", volume.ID, err)
		}
	}
	return nil
}

func (a *App) volumeByID(id string) (Volume, error) {
	if id == "" {
		id = "primary"
	}
	if a.db == nil {
		if id != "primary" {
			return Volume{}, errors.New("unknown volume")
		}
		return a.measureVolume(Volume{ID: "primary", Name: "NAS 数据盘", Device: a.c.Root, Filesystem: "unknown", Mount: a.c.Root}), nil
	}
	var v Volume
	err := a.db.QueryRow("SELECT id,name,uuid,device,filesystem,mount FROM volumes WHERE id=? AND enabled=1", id).
		Scan(&v.ID, &v.Name, &v.UUID, &v.Device, &v.Filesystem, &v.Mount)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			if id == "primary" && a.c.Root != "" {
				return a.measureVolume(Volume{ID: "primary", Name: "NAS 数据盘", Device: a.c.Root, Filesystem: "unknown", Mount: a.c.Root}), nil
			}
			return Volume{}, errors.New("unknown volume")
		}
		return Volume{}, err
	}
	return a.measureVolume(v), nil
}

func (a *App) measureVolume(v Volume) Volume {
	v.Status = "offline"
	v.Protocol = "HTTPS over Tailscale Serve"
	v.Smart = "当前设备不支持或未授予最小权限"
	if info, err := os.Stat(v.Mount); err != nil || !info.IsDir() {
		return v
	}
	total, free, err := diskSpace(v.Mount)
	if err != nil {
		return v
	}
	v.Total, v.Free, v.Used, v.Status = total, free, total-free, "online"
	// Report bytes transferred through MyNAS itself. Linux block-device counters
	// are delayed by the page cache and commonly stay at zero during uploads.
	v.ReadBytes, v.WriteBytes = a.volumeIO(v.ID)
	return v
}

func (a *App) listVolumes() ([]Volume, error) {
	if a.db == nil {
		volume, err := a.volumeByID("primary")
		if err != nil {
			return nil, err
		}
		return []Volume{volume}, nil
	}
	rows, err := a.db.Query("SELECT id,name,uuid,device,filesystem,mount FROM volumes WHERE enabled=1 ORDER BY CASE WHEN id='primary' THEN 0 ELSE 1 END,name")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]Volume, 0)
	for rows.Next() {
		var v Volume
		if err = rows.Scan(&v.ID, &v.Name, &v.UUID, &v.Device, &v.Filesystem, &v.Mount); err != nil {
			return nil, err
		}
		result = append(result, a.measureVolume(v))
	}
	return result, rows.Err()
}

func (a *App) ensureRegisteredVolumeDirs() error {
	volumes, err := a.listVolumes()
	if err != nil {
		return err
	}
	for _, volume := range volumes {
		if volume.Status != "online" {
			continue
		}
		for _, name := range []string{"staging", "trash"} {
			if err = os.MkdirAll(filepath.Join(volume.Mount, ".mynas", name), 0700); err != nil {
				return fmt.Errorf("prepare volume %s: %w", volume.ID, err)
			}
		}
	}
	return nil
}

func resolveWithin(root, rel string, write bool) (string, error) {
	rel = strings.TrimPrefix(filepath.ToSlash(rel), "/")
	if rel == "" {
		return root, nil
	}
	for _, part := range strings.Split(rel, "/") {
		if part == ".." {
			return "", errors.New("path traversal")
		}
		if part == ".mynas" || part == "$RECYCLE.BIN" || part == "System Volume Information" {
			return "", errors.New("protected path")
		}
	}
	p := filepath.Join(root, filepath.FromSlash(rel))
	realRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", err
	}
	base := p
	if write {
		base, err = filepath.EvalSymlinks(filepath.Dir(p))
	} else {
		base, err = filepath.EvalSymlinks(p)
	}
	if err != nil {
		return "", err
	}
	if base != realRoot && !strings.HasPrefix(base, realRoot+string(os.PathSeparator)) {
		return "", errors.New("symlink escape")
	}
	return p, nil
}

func (a *App) pathFor(volumeID, rel string, write bool) (string, error) {
	volume, err := a.volumeByID(volumeID)
	if err != nil {
		return "", fmt.Errorf("volume lookup: %w", err)
	}
	if volume.Status != "online" {
		return "", errors.New("volume offline")
	}
	path, err := resolveWithin(volume.Mount, rel, write)
	if err != nil {
		return "", fmt.Errorf("resolve volume path in %q: %w", volume.Mount, err)
	}
	return path, nil
}

func (a *App) volumes(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPut {
		var input struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		}
		if err := readJSON(r, &input); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		input.ID = strings.TrimSpace(input.ID)
		name, err := cleanName(input.Name)
		if input.ID == "" || err != nil || len([]rune(name)) > 40 {
			http.Error(w, "invalid volume name", http.StatusBadRequest)
			return
		}
		if a.db == nil {
			http.Error(w, "volume database unavailable", http.StatusServiceUnavailable)
			return
		}
		result, err := a.db.Exec("UPDATE volumes SET name=? WHERE id=? AND enabled=1", name, input.ID)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		changed, err := result.RowsAffected()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		if changed == 0 {
			http.Error(w, "unknown volume", http.StatusNotFound)
			return
		}
		a.audit(r, "rename-volume", input.ID, "name="+name)
		volume, err := a.volumeByID(input.ID)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		writeJSON(w, volume)
		return
	}
	if r.Method != http.MethodGet {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	volumes, err := a.listVolumes()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, volumes)
}

func (a *App) volumeCandidates(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	registered := map[string]bool{}
	volumes, err := a.listVolumes()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	for _, volume := range volumes {
		if volume.UUID != "" {
			registered[strings.ToLower(volume.UUID)] = true
		}
	}
	candidates, err := discoverVolumeCandidates(registered)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, candidates)
}
