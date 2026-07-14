package main

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSupportedVolumeFilesystems(t *testing.T) {
	for _, filesystem := range []string{"ext4", "ntfs", "ntfs3", "exfat"} {
		if !supportedFilesystem(filesystem) {
			t.Fatalf("expected %s to be supported", filesystem)
		}
	}
	if supportedFilesystem("btrfs") {
		t.Fatal("unexpected btrfs support")
	}
}

func TestStableVolumeIDUsesUUID(t *testing.T) {
	first := stableVolumeID("ABC-123", "/dev/sda1")
	second := stableVolumeID("abc-123", "/dev/sdb1")
	if first != second || !strings.HasPrefix(first, "vol-") {
		t.Fatalf("unstable ids: %q %q", first, second)
	}
}

func TestCrossVolumeMove(t *testing.T) {
	rootA, rootB := t.TempDir(), t.TempDir()
	if err := os.WriteFile(filepath.Join(rootA, "move.txt"), []byte("cross-volume"), 0640); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "volumes.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	a := &App{c: Config{Root: rootA}, db: db, hub: &Hub{subs: map[chan []byte]bool{}}}
	if err = a.migrate(); err != nil {
		t.Fatal(err)
	}
	for _, row := range []struct{ id, uuid, mount string }{{"vol-a", "uuid-a", rootA}, {"vol-b", "uuid-b", rootB}} {
		if _, err = db.Exec("INSERT INTO volumes(id,name,uuid,device,filesystem,mount,enabled,created) VALUES(?,?,?,?,?,?,1,'now')", row.id, row.id, row.uuid, row.mount, "ext4", row.mount); err != nil {
			t.Fatal(err)
		}
	}
	request := httptest.NewRequest(http.MethodPost, "/api/v1/operations", strings.NewReader(`{"action":"move","fromVolumeId":"vol-a","toVolumeId":"vol-b","from":"move.txt","to":"moved.txt","conflict":"rename"}`))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-MyNAS-User", "tester")
	response := httptest.NewRecorder()
	a.operations(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("move failed: %d %s", response.Code, response.Body.String())
	}
	data, err := os.ReadFile(filepath.Join(rootB, "moved.txt"))
	if err != nil || string(data) != "cross-volume" {
		t.Fatalf("destination=%q err=%v", data, err)
	}
	if _, err = os.Stat(filepath.Join(rootA, "move.txt")); !os.IsNotExist(err) {
		t.Fatal("source was not removed")
	}
}

func TestVolumePathCannotEscapeSelectedVolume(t *testing.T) {
	root := t.TempDir()
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "path.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	a := &App{c: Config{Root: root}, db: db}
	if err = a.migrate(); err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec("INSERT INTO volumes(id,name,uuid,device,filesystem,mount,enabled,created) VALUES('vol-a','A','uuid-a',?,'ext4',?,1,'now')", root, root); err != nil {
		t.Fatal(err)
	}
	if _, err = a.pathFor("vol-a", "../outside", false); err == nil {
		t.Fatal("accepted traversal")
	}
	if _, err = a.pathFor("missing", "file", false); err == nil {
		t.Fatal("accepted unknown volume")
	}
}

func TestLoadConfiguredVolume(t *testing.T) {
	root := t.TempDir()
	dataDir := t.TempDir()
	uuid := "configured-volume-uuid"
	id := stableVolumeID(uuid, root)
	config := volumeConfigFile{}
	config.Volumes = append(config.Volumes, struct {
		ID         string `json:"id"`
		Name       string `json:"name"`
		UUID       string `json:"uuid"`
		Device     string `json:"device"`
		Filesystem string `json:"filesystem"`
		Mount      string `json:"mount"`
	}{ID: id, Name: "Configured", UUID: uuid, Device: root, Filesystem: "exfat", Mount: root})
	data, _ := json.Marshal(config)
	configPath := filepath.Join(t.TempDir(), "volumes.json")
	if err := os.WriteFile(configPath, data, 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("MYNAS_VOLUMES_FILE", configPath)
	db, err := sql.Open("sqlite", filepath.Join(dataDir, "config.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	a := &App{c: Config{Root: t.TempDir(), DataDir: dataDir}, db: db}
	if err = a.migrate(); err != nil {
		t.Fatal(err)
	}
	if err = a.loadConfiguredVolumes(); err != nil {
		t.Fatal(err)
	}
	volume, err := a.volumeByID(id)
	if err != nil || volume.Name != "Configured" || volume.Filesystem != "exfat" {
		t.Fatalf("volume=%+v err=%v", volume, err)
	}
	if _, err = db.Exec("UPDATE volumes SET name='My custom name' WHERE id=?", id); err != nil {
		t.Fatal(err)
	}
	if err = a.loadConfiguredVolumes(); err != nil {
		t.Fatal(err)
	}
	volume, err = a.volumeByID(id)
	if err != nil || volume.Name != "My custom name" {
		t.Fatalf("custom volume name was overwritten: volume=%+v err=%v", volume, err)
	}
}

func TestRenameVolume(t *testing.T) {
	root := t.TempDir()
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "rename.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	a := &App{c: Config{Root: root}, db: db, hub: &Hub{subs: map[chan []byte]bool{}}}
	if err = a.migrate(); err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec("INSERT INTO volumes(id,name,uuid,device,filesystem,mount,enabled,created) VALUES('vol-a','Old name','uuid-a',?,'ext4',?,1,'now')", root, root); err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPut, "/api/v1/volumes", strings.NewReader(`{"id":"vol-a","name":"Family Backup"}`))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-MyNAS-User", "tester")
	response := httptest.NewRecorder()
	a.volumes(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("rename failed: %d %s", response.Code, response.Body.String())
	}
	volume, err := a.volumeByID("vol-a")
	if err != nil || volume.Name != "Family Backup" {
		t.Fatalf("volume=%+v err=%v", volume, err)
	}

	invalid := httptest.NewRequest(http.MethodPut, "/api/v1/volumes", strings.NewReader(`{"id":"vol-a","name":"bad/name"}`))
	invalid.Header.Set("Content-Type", "application/json")
	invalidResponse := httptest.NewRecorder()
	a.volumes(invalidResponse, invalid)
	if invalidResponse.Code != http.StatusBadRequest {
		t.Fatalf("invalid name accepted: %d %s", invalidResponse.Code, invalidResponse.Body.String())
	}
}
