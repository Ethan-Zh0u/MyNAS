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

func TestPhotosTrashMovesCompleteGroupHidesItAndRestoresIt(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	still := []byte("trash-live-photo-still")
	motion := []byte("trash-live-photo-motion")
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

	originalPath, originalHash := testCommittedPhotoSource(t, app, completed.AssetID)
	if _, err := os.Stat(originalPath); err != nil {
		t.Fatalf("original missing before trash: %v", err)
	}
	var derivativePath string
	if err := app.db.QueryRow(
		`SELECT storage_path FROM photo_derivatives WHERE asset_id=? AND kind='grid'`,
		completed.AssetID,
	).Scan(&derivativePath); err != nil {
		t.Fatal(err)
	}
	derivativePath = filepath.Join(app.c.Root, filepath.FromSlash(derivativePath))
	if _, err := os.Stat(derivativePath); err != nil {
		t.Fatalf("derivative missing before trash: %v", err)
	}

	trashInput := photosTrashAssetsInput{Items: []photosTrashItemInput{{
		AssetID: completed.AssetID, DeviceID: input.DeviceID,
		LocalIdentifier: input.LocalIdentifier, SourceModificationDate: modificationDate,
	}}}
	data, err := json.Marshal(trashInput)
	if err != nil {
		t.Fatal(err)
	}
	request := tailscaleRequest(http.MethodPost, "/api/v1/photos/assets")
	request.Header.Set("Content-Type", "application/json")
	request.Body = ioNopCloser(strings.NewReader(string(data)))
	request.ContentLength = int64(len(data))
	recorder := httptest.NewRecorder()
	app.photosAssets(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("trash status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var trashed photosTrashAssetsResponse
	if err = json.NewDecoder(recorder.Body).Decode(&trashed); err != nil {
		t.Fatal(err)
	}
	if len(trashed.Items) != 1 || trashed.Items[0].AssetID != completed.AssetID || trashed.Items[0].TrashID == "" {
		t.Fatalf("unexpected trash response=%#v", trashed)
	}
	trashRoot := photoTrashRoot(app.c.Root, trashed.Items[0].TrashID)
	if _, err = os.Stat(filepath.Join(trashRoot, "originals")); err != nil {
		t.Fatalf("trash lost original resource group: %v", err)
	}
	if _, err = os.Stat(filepath.Join(trashRoot, "derivatives")); err != nil {
		t.Fatalf("trash lost derivative resource group: %v", err)
	}
	if _, err = os.Stat(originalPath); !os.IsNotExist(err) {
		t.Fatalf("original remains at active location after trash: %v", err)
	}
	if _, err = os.Stat(derivativePath); !os.IsNotExist(err) {
		t.Fatalf("derivative remains at active location after trash: %v", err)
	}
	var sourceState, storedFingerprint string
	if err = app.db.QueryRow(
		"SELECT source_state,content_fingerprint FROM photo_assets WHERE id=?", completed.AssetID,
	).Scan(&sourceState, &storedFingerprint); err != nil {
		t.Fatal(err)
	}
	if sourceState != photosSourceStateTrashed || !strings.HasPrefix(storedFingerprint, "trashed:") {
		t.Fatalf("asset state after trash=(%q,%q)", sourceState, storedFingerprint)
	}

	browseRecorder := httptest.NewRecorder()
	app.photosAssets(browseRecorder, tailscaleRequest(http.MethodGet, "/api/v1/photos/assets"))
	var browse photosAssetPageResponse
	if err = json.NewDecoder(browseRecorder.Body).Decode(&browse); err != nil {
		t.Fatal(err)
	}
	if len(browse.Assets) != 0 {
		t.Fatalf("trashed asset remained browsable: %#v", browse.Assets)
	}
	derivativeRecorder := httptest.NewRecorder()
	app.photosAssetByPath(
		derivativeRecorder,
		tailscaleRequest(http.MethodGet, "/api/v1/photos/assets/"+completed.AssetID+"/grid"),
	)
	if derivativeRecorder.Code != http.StatusNotFound {
		t.Fatalf("trashed derivative status=%d body=%s", derivativeRecorder.Code, derivativeRecorder.Body.String())
	}

	restoreRecorder := httptest.NewRecorder()
	app.photosAssetByPath(
		restoreRecorder,
		tailscaleRequest(http.MethodPost, "/api/v1/photos/assets/"+completed.AssetID+"/restore"),
	)
	if restoreRecorder.Code != http.StatusOK {
		t.Fatalf("restore status=%d body=%s", restoreRecorder.Code, restoreRecorder.Body.String())
	}
	if hash, err := sha256File(originalPath); err != nil || hash != originalHash {
		t.Fatalf("restored original hash=%q err=%v want=%q", hash, err, originalHash)
	}
	if _, err = os.Stat(derivativePath); err != nil {
		t.Fatalf("restored derivative missing: %v", err)
	}
	if err = app.db.QueryRow(
		"SELECT source_state,content_fingerprint FROM photo_assets WHERE id=?", completed.AssetID,
	).Scan(&sourceState, &storedFingerprint); err != nil {
		t.Fatal(err)
	}
	if sourceState != photosSourceStateCommitted || storedFingerprint != input.Fingerprint {
		t.Fatalf("asset state after restore=(%q,%q)", sourceState, storedFingerprint)
	}
}

func TestPhotosTrashRejectsSharedOrStaleBackupsWithoutMovingAnything(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	shared := []byte("shared-photo-must-not-trash")
	modificationDate := "2026-07-27T08:30:45.123Z"
	firstInput := testPhotoUploadInput(shared, nil)
	firstInput.DeviceID = "ios-first"
	firstInput.LocalIdentifier = "first-local"
	firstInput.ModificationDate = &modificationDate
	first := completeTestPhotoUpload(t, app, firstInput, map[string][]byte{"photo-0": shared})
	secondInput := firstInput
	secondInput.DeviceID = "ios-second"
	secondInput.LocalIdentifier = "second-local"
	duplicate := createTestPhotoUploadSession(t, app, secondInput)
	if duplicate.Status != "duplicate" || duplicate.AssetID != first.AssetID {
		t.Fatalf("expected exact duplicate mapping: %#v", duplicate)
	}
	originalPath, _ := testCommittedPhotoSource(t, app, first.AssetID)

	for _, sourceDate := range []string{modificationDate, "2026-07-28T08:30:45.123Z"} {
		input := photosTrashAssetsInput{Items: []photosTrashItemInput{{
			AssetID: first.AssetID, DeviceID: firstInput.DeviceID,
			LocalIdentifier: firstInput.LocalIdentifier, SourceModificationDate: sourceDate,
		}}}
		body, err := json.Marshal(input)
		if err != nil {
			t.Fatal(err)
		}
		request := tailscaleRequest(http.MethodPost, "/api/v1/photos/assets")
		request.Header.Set("Content-Type", "application/json")
		request.Body = ioNopCloser(strings.NewReader(string(body)))
		request.ContentLength = int64(len(body))
		recorder := httptest.NewRecorder()
		app.photosAssets(recorder, request)
		if recorder.Code != http.StatusConflict {
			t.Fatalf("sourceDate=%s status=%d body=%s", sourceDate, recorder.Code, recorder.Body.String())
		}
		if _, err = os.Stat(originalPath); err != nil {
			t.Fatalf("rejected trash moved original: %v", err)
		}
		var state string
		if err = app.db.QueryRow("SELECT source_state FROM photo_assets WHERE id=?", first.AssetID).Scan(&state); err != nil {
			t.Fatal(err)
		}
		if state != photosSourceStateCommitted {
			t.Fatalf("rejected trash state=%q", state)
		}
	}
}

func TestPhotosTrashBatchRejectsBeforeMovingAnyAsset(t *testing.T) {
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

	input := photosTrashAssetsInput{Items: []photosTrashItemInput{
		{AssetID: first.AssetID, DeviceID: firstInput.DeviceID, LocalIdentifier: firstInput.LocalIdentifier, SourceModificationDate: modificationDate},
		{AssetID: shared.AssetID, DeviceID: sharedInput.DeviceID, LocalIdentifier: sharedInput.LocalIdentifier, SourceModificationDate: modificationDate},
	}}
	body, err := json.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}
	request := tailscaleRequest(http.MethodPost, "/api/v1/photos/assets")
	request.Header.Set("Content-Type", "application/json")
	request.Body = ioNopCloser(strings.NewReader(string(body)))
	request.ContentLength = int64(len(body))
	recorder := httptest.NewRecorder()
	app.photosAssets(recorder, request)
	if recorder.Code != http.StatusConflict {
		t.Fatalf("batch status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	if _, err = os.Stat(firstPath); err != nil {
		t.Fatalf("batch rejection moved the earlier safe item: %v", err)
	}
}
