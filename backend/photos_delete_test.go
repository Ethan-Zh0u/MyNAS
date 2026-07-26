package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPhotosDeletePermanentlyRemovesCompleteResourceGroup(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	still := []byte("delete-live-photo-still")
	motion := []byte("delete-live-photo-motion")
	modificationDate := "2026-07-27T08:30:45.123Z"
	input := testPhotoUploadInput(still, motion)
	input.ModificationDate = &modificationDate
	completed := completeTestPhotoUpload(t, app, input, map[string][]byte{
		"photo-0": still, "pairedVideo-1": motion,
	})
	app.derivativeProcessor = &fakePhotosDerivativeProcessor{}
	if processed, err := app.runNextPhotoDerivativeJob(context.Background()); err != nil || !processed {
		t.Fatalf("derivative processing processed=%v err=%v", processed, err)
	}

	originalPath, _ := testCommittedPhotoSource(t, app, completed.AssetID)
	var derivativePath string
	if err := app.db.QueryRow(
		`SELECT storage_path FROM photo_derivatives WHERE asset_id=? AND kind='grid'`, completed.AssetID,
	).Scan(&derivativePath); err != nil {
		t.Fatal(err)
	}
	derivativePath = filepath.Join(app.c.Root, filepath.FromSlash(derivativePath))

	recorder := postPhotosDelete(t, app, photosDeleteAssetsInput{Items: []photosDeleteItemInput{{
		AssetID: completed.AssetID, DeviceID: input.DeviceID,
		LocalIdentifier: input.LocalIdentifier, SourceModificationDate: modificationDate,
	}}})
	if recorder.Code != http.StatusOK {
		t.Fatalf("delete status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var deleted photosDeleteAssetsResponse
	if err := json.NewDecoder(recorder.Body).Decode(&deleted); err != nil {
		t.Fatal(err)
	}
	if len(deleted.Items) != 1 || deleted.Items[0].AssetID != completed.AssetID || deleted.Items[0].DeletedAt == "" {
		t.Fatalf("unexpected delete response=%#v", deleted)
	}
	if _, err := os.Stat(originalPath); !os.IsNotExist(err) {
		t.Fatalf("original remains after permanent deletion: %v", err)
	}
	if _, err := os.Stat(derivativePath); !os.IsNotExist(err) {
		t.Fatalf("derivative remains after permanent deletion: %v", err)
	}
	for _, query := range []string{
		"SELECT COUNT(1) FROM photo_assets WHERE id=?",
		"SELECT COUNT(1) FROM photo_resources WHERE asset_id=?",
		"SELECT COUNT(1) FROM photo_derivatives WHERE asset_id=?",
		"SELECT COUNT(1) FROM photo_derivative_jobs WHERE asset_id=?",
		"SELECT COUNT(1) FROM device_asset_mappings WHERE asset_id=?",
	} {
		var count int
		if err := app.db.QueryRow(query, completed.AssetID).Scan(&count); err != nil || count != 0 {
			t.Fatalf("metadata remains query=%q count=%d err=%v", query, count, err)
		}
	}
	browseRecorder := httptest.NewRecorder()
	app.photosAssets(browseRecorder, tailscaleRequest(http.MethodGet, "/api/v1/photos/assets"))
	var browse photosAssetPageResponse
	if err := json.NewDecoder(browseRecorder.Body).Decode(&browse); err != nil {
		t.Fatal(err)
	}
	if len(browse.Assets) != 0 {
		t.Fatalf("deleted asset remained browsable: %#v", browse.Assets)
	}
}

func TestPhotosDeleteRejectsSharedOrStaleBackupsWithoutDeletingAnything(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	shared := []byte("shared-photo-must-not-delete")
	modificationDate := "2026-07-27T08:30:45.123Z"
	firstInput := testPhotoUploadInput(shared, nil)
	firstInput.DeviceID = "ios-first"
	firstInput.LocalIdentifier = "first-local"
	firstInput.ModificationDate = &modificationDate
	first := completeTestPhotoUpload(t, app, firstInput, map[string][]byte{"photo-0": shared})
	secondInput := firstInput
	secondInput.DeviceID = "ios-second"
	secondInput.LocalIdentifier = "second-local"
	if duplicate := createTestPhotoUploadSession(t, app, secondInput); duplicate.Status != "duplicate" {
		t.Fatalf("expected shared duplicate: %#v", duplicate)
	}
	originalPath, _ := testCommittedPhotoSource(t, app, first.AssetID)

	for _, sourceDate := range []string{modificationDate, "2026-07-28T08:30:45.123Z"} {
		recorder := postPhotosDelete(t, app, photosDeleteAssetsInput{Items: []photosDeleteItemInput{{
			AssetID: first.AssetID, DeviceID: firstInput.DeviceID,
			LocalIdentifier: firstInput.LocalIdentifier, SourceModificationDate: sourceDate,
		}}})
		if recorder.Code != http.StatusConflict {
			t.Fatalf("sourceDate=%s status=%d body=%s", sourceDate, recorder.Code, recorder.Body.String())
		}
		if _, err := os.Stat(originalPath); err != nil {
			t.Fatalf("rejected deletion removed original: %v", err)
		}
		var count int
		if err := app.db.QueryRow("SELECT COUNT(1) FROM photo_assets WHERE id=?", first.AssetID).Scan(&count); err != nil || count != 1 {
			t.Fatalf("rejected deletion metadata count=%d err=%v", count, err)
		}
	}
}

func TestPhotosDeleteBatchRejectsBeforeStagingAnyAsset(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	modificationDate := "2026-07-27T08:30:45.123Z"
	firstInput := testPhotoUploadInput([]byte("single-safe-photo"), nil)
	firstInput.LocalIdentifier = "single-local"
	firstInput.ModificationDate = &modificationDate
	first := completeTestPhotoUpload(t, app, firstInput, map[string][]byte{"photo-0": []byte("single-safe-photo")})
	sharedInput := testPhotoUploadInput([]byte("shared-batch-photo"), nil)
	sharedInput.DeviceID = "shared-first-device"
	sharedInput.LocalIdentifier = "shared-local"
	sharedInput.ModificationDate = &modificationDate
	shared := completeTestPhotoUpload(t, app, sharedInput, map[string][]byte{"photo-0": []byte("shared-batch-photo")})
	secondShared := sharedInput
	secondShared.DeviceID = "shared-second-device"
	secondShared.LocalIdentifier = "shared-other-local"
	if duplicate := createTestPhotoUploadSession(t, app, secondShared); duplicate.Status != "duplicate" {
		t.Fatalf("expected shared duplicate: %#v", duplicate)
	}
	firstPath, _ := testCommittedPhotoSource(t, app, first.AssetID)

	recorder := postPhotosDelete(t, app, photosDeleteAssetsInput{Items: []photosDeleteItemInput{
		{AssetID: first.AssetID, DeviceID: firstInput.DeviceID, LocalIdentifier: firstInput.LocalIdentifier, SourceModificationDate: modificationDate},
		{AssetID: shared.AssetID, DeviceID: sharedInput.DeviceID, LocalIdentifier: sharedInput.LocalIdentifier, SourceModificationDate: modificationDate},
	}})
	if recorder.Code != http.StatusConflict {
		t.Fatalf("batch status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	if _, err := os.Stat(firstPath); err != nil {
		t.Fatalf("batch rejection staged earlier safe item: %v", err)
	}
}

func postPhotosDelete(t *testing.T, app *App, input photosDeleteAssetsInput) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}
	request := tailscaleRequest(http.MethodPost, "/api/v1/photos/assets/delete")
	request.Header.Set("Content-Type", "application/json")
	request.Body = ioNopCloser(strings.NewReader(string(body)))
	request.ContentLength = int64(len(body))
	recorder := httptest.NewRecorder()
	app.photosAssetByPath(recorder, request)
	return recorder
}
