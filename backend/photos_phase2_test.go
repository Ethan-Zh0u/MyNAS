package main

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	_ "modernc.org/sqlite"
)

func newPhotosPhase2TestApp(t *testing.T) *App {
	t.Helper()
	root := t.TempDir()
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "photos-phase2.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	configureDB(db)
	app := &App{
		c: Config{
			Root:        root,
			DataDir:     t.TempDir(),
			DevIdentity: false,
		},
		db:            db,
		hub:           &Hub{subs: map[chan []byte]bool{}},
		activeUploads: map[string]bool{},
		volumeReads:   map[string]uint64{},
		volumeWrites:  map[string]uint64{},
	}
	if err = app.migrate(); err != nil {
		t.Fatal(err)
	}
	if err = app.ensureServerID(); err != nil {
		t.Fatal(err)
	}
	if err = app.seedPrimaryVolume(); err != nil {
		t.Fatal(err)
	}
	return app
}

func tailscaleRequest(method, path string) *http.Request {
	request := httptest.NewRequest(method, path, nil)
	request.Header.Set("Tailscale-User-Login", "owner@example.com")
	request.Header.Set("Tailscale-User-Name", "Owner")
	request.Header.Set("Tailscale-User-Profile-Pic", "https://example.com/avatar.png")
	return request
}

func TestPhotosPhase2HandshakeUsesStableServerAndUserIDs(t *testing.T) {
	app := newPhotosPhase2TestApp(t)

	capabilitiesRecorder := httptest.NewRecorder()
	app.photosCapabilities(capabilitiesRecorder, tailscaleRequest(http.MethodGet, "/api/v1/photos/capabilities"))
	if capabilitiesRecorder.Code != http.StatusOK {
		t.Fatalf("capabilities status = %d, body = %s", capabilitiesRecorder.Code, capabilitiesRecorder.Body.String())
	}
	var capabilities photosCapabilitiesResponse
	if err := json.NewDecoder(capabilitiesRecorder.Body).Decode(&capabilities); err != nil {
		t.Fatal(err)
	}
	if capabilities.ServerID == "" || capabilities.ServerID != app.serverID {
		t.Fatalf("unexpected server id %q", capabilities.ServerID)
	}
	if !capabilities.Features.PhotoAssets || !capabilities.Features.LivePhotos {
		t.Fatal("manual source backup must advertise photo assets and multi-resource Live Photo support")
	}
	if capabilities.BackupStateModel != photosBackupStateModelVersion ||
		capabilities.DerivativePolicy != photosDerivativePolicyVersion {
		t.Fatalf("unexpected backup state contract: %#v", capabilities)
	}
	if len(capabilities.DerivativeRecipes) != 0 {
		t.Fatal("E1 must not advertise derivative recipes before the E2 worker is available")
	}

	firstRecorder := httptest.NewRecorder()
	app.photosMe(firstRecorder, tailscaleRequest(http.MethodGet, "/api/v1/photos/me"))
	if firstRecorder.Code != http.StatusOK {
		t.Fatalf("first me status = %d, body = %s", firstRecorder.Code, firstRecorder.Body.String())
	}
	var first photosMeResponse
	if err := json.NewDecoder(firstRecorder.Body).Decode(&first); err != nil {
		t.Fatal(err)
	}

	secondRecorder := httptest.NewRecorder()
	secondRequest := tailscaleRequest(http.MethodGet, "/api/v1/photos/me")
	secondRequest.Header.Set("Tailscale-User-Name", "Updated Owner")
	app.photosMe(secondRecorder, secondRequest)
	var second photosMeResponse
	if err := json.NewDecoder(secondRecorder.Body).Decode(&second); err != nil {
		t.Fatal(err)
	}
	if first.UserID == "" || first.UserID != second.UserID {
		t.Fatalf("user ID changed across requests: %q != %q", first.UserID, second.UserID)
	}
	if second.DisplayName != "Updated Owner" {
		t.Fatalf("display name was not refreshed: %q", second.DisplayName)
	}
}

func TestPhotosVolumesDoNotExposeFilesystemPaths(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	recorder := httptest.NewRecorder()
	app.photosVolumes(recorder, tailscaleRequest(http.MethodGet, "/api/v1/photos/volumes"))
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	body := recorder.Body.String()
	if strings.Contains(body, app.c.Root) || strings.Contains(body, `"mount"`) || strings.Contains(body, `"device"`) {
		t.Fatalf("photos volume response leaked a filesystem path or device: %s", body)
	}
	var response struct {
		Volumes []photosVolumeResponse `json:"volumes"`
	}
	if err := json.Unmarshal([]byte(body), &response); err != nil {
		t.Fatal(err)
	}
	if len(response.Volumes) != 1 || response.Volumes[0].ID != "primary" || !response.Volumes[0].IsDefault {
		t.Fatalf("unexpected volumes response: %#v", response.Volumes)
	}
}

func TestPhotosPairingUsesConfiguredPrivateTailscaleOrigin(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	app.c.PrivateOrigin = "https://RSP.tail681937.ts.net/"
	recorder := httptest.NewRecorder()
	app.photosPairing(recorder, tailscaleRequest(http.MethodGet, "/api/v1/photos/pairing"))
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	var response photosPairingResponse
	if err := json.NewDecoder(recorder.Body).Decode(&response); err != nil {
		t.Fatal(err)
	}
	if response.Format != "mynas-photos-pairing" || response.Version != 1 {
		t.Fatalf("unexpected pairing format: %#v", response)
	}
	if response.ServerURL != "https://rsp.tail681937.ts.net" || response.ServerID != app.serverID {
		t.Fatalf("unexpected pairing identity: %#v", response)
	}
}

func TestPhotosPairingRejectsUntrustedOrMissingOrigin(t *testing.T) {
	for _, origin := range []string{"", "http://rsp.tail681937.ts.net", "https://example.com", "https://rsp.tail681937.ts.net/path"} {
		app := newPhotosPhase2TestApp(t)
		app.c.PrivateOrigin = origin
		recorder := httptest.NewRecorder()
		app.photosPairing(recorder, tailscaleRequest(http.MethodGet, "/api/v1/photos/pairing"))
		if recorder.Code != http.StatusServiceUnavailable {
			t.Fatalf("origin %q returned %d, want %d", origin, recorder.Code, http.StatusServiceUnavailable)
		}
	}
}

func TestPhotosRoutesRejectMissingTailscaleIdentity(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	handler := app.middleware(http.HandlerFunc(app.photosMe))
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/api/v1/photos/me", nil))
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusUnauthorized)
	}
}

func TestTailscaleIdentityHeaderDecodesUnicodeDisplayName(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	request := httptest.NewRequest(http.MethodGet, "/api/v1/photos/me", nil)
	request.Header.Set("Tailscale-User-Login", "owner@example.com")
	request.Header.Set("Tailscale-User-Name", "=?utf-8?q?=E5=BC=A0=E4=B8=89?=")
	user, ok := app.user(request)
	if !ok {
		t.Fatal("expected a Tailscale user")
	}
	if user.Name != "张三" {
		t.Fatalf("decoded name = %q, want 张三", user.Name)
	}
}
