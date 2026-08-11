package main

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestPhotosMultiResourceUploadResumesVerifiesAndDeduplicates(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	still := []byte("original-hdr-photo-bytes")
	motion := []byte("paired-live-photo-video-bytes")
	input := testPhotoUploadInput(still, motion)

	created := createTestPhotoUploadSession(t, app, input)
	if created.Status != "waiting" || len(created.Resources) != 2 {
		t.Fatalf("unexpected create response: %#v", created)
	}

	first := testUploadResource(t, created.Resources, "photo-0")
	putTestPhotoPart(t, app, created.ID, first, 0, still)

	resumed := createTestPhotoUploadSession(t, app, input)
	if resumed.ID != created.ID || resumed.ReceivedBytes != int64(len(still)) {
		t.Fatalf("session did not resume: %#v", resumed)
	}

	second := testUploadResource(t, created.Resources, "pairedVideo-1")
	putTestPhotoPart(t, app, created.ID, second, 0, motion)

	completeRequest := tailscaleRequest(
		http.MethodPost,
		"/api/v1/photos/upload-sessions/"+created.ID+"/complete",
	)
	completeRecorder := httptest.NewRecorder()
	app.photosUploadSessionByPath(completeRecorder, completeRequest)
	if completeRecorder.Code != http.StatusOK {
		t.Fatalf("complete status=%d body=%s", completeRecorder.Code, completeRecorder.Body.String())
	}
	var completed photosUploadSessionResponse
	if err := json.NewDecoder(completeRecorder.Body).Decode(&completed); err != nil {
		t.Fatal(err)
	}
	if completed.Status != "completed" || completed.AssetID == "" {
		t.Fatalf("unexpected complete response: %#v", completed)
	}
	if completed.SourceState != photosSourceStateCommitted ||
		completed.DerivativeState != photosDerivativeStatePending ||
		completed.BrowseReady {
		t.Fatalf("upload completion claimed the wrong backup state: %#v", completed)
	}

	var resourceCount int
	if err := app.db.QueryRow(
		"SELECT COUNT(*) FROM photo_resources WHERE asset_id=?",
		completed.AssetID,
	).Scan(&resourceCount); err != nil {
		t.Fatal(err)
	}
	if resourceCount != 2 {
		t.Fatalf("resource count=%d, want 2", resourceCount)
	}
	var derivativeJobCount int
	if err := app.db.QueryRow(
		`SELECT COUNT(*) FROM photo_derivative_jobs
		 WHERE asset_id=? AND recipe_version=? AND status=?`,
		completed.AssetID, photosDerivativePolicyVersion, photosDerivativeJobPending,
	).Scan(&derivativeJobCount); err != nil {
		t.Fatal(err)
	}
	if derivativeJobCount != 1 {
		t.Fatalf("derivative job count=%d, want 1", derivativeJobCount)
	}
	rows, err := app.db.Query(
		"SELECT storage_path,sha256 FROM photo_resources WHERE asset_id=? ORDER BY resource_role",
		completed.AssetID,
	)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var relativePath, expectedHash string
		if err = rows.Scan(&relativePath, &expectedHash); err != nil {
			t.Fatal(err)
		}
		actualHash, hashErr := sha256File(filepath.Join(app.c.Root, filepath.FromSlash(relativePath)))
		if hashErr != nil || actualHash != expectedHash {
			t.Fatalf("committed resource hash=%q err=%v, want %q", actualHash, hashErr, expectedHash)
		}
	}

	duplicateInput := input
	duplicateInput.LocalIdentifier = "different-local-id"
	duplicate := createTestPhotoUploadSession(t, app, duplicateInput)
	if duplicate.Status != "duplicate" || duplicate.AssetID != completed.AssetID || duplicate.ID != "" {
		t.Fatalf("content was not deduplicated: %#v", duplicate)
	}
	if duplicate.SourceState != photosSourceStateCommitted ||
		duplicate.DerivativeState != photosDerivativeStatePending ||
		duplicate.BrowseReady {
		t.Fatalf("duplicate response claimed the wrong backup state: %#v", duplicate)
	}
}

func TestPhotosExpectedAssetUsesCompleteResourceProofAcrossTransportMetadata(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	originalBytes := []byte("same-png-original")
	originalInput := testPhotoUploadInput(originalBytes, nil)
	originalInput.Resources[0].ClientResourceID = "fixture-resource"
	originalInput.Resources[0].ContentType = "image/png"
	originalInput.Fingerprint = photoManifestFingerprint(originalInput.Resources)
	original := commitTestPhotoUpload(t, app, originalInput, [][]byte{originalBytes})

	importedInput := originalInput
	importedInput.DeviceID = "current-iphone"
	importedInput.LocalIdentifier = "photo-kit-import-placeholder"
	importedInput.ExpectedAssetID = original.AssetID
	importedModificationDate := "2026-08-11T01:12:55.138Z"
	importedInput.ModificationDate = &importedModificationDate
	importedInput.Resources[0].ClientResourceID = "resource-000"
	importedInput.Resources[0].ContentType = "public.png"
	importedInput.Fingerprint = photoManifestFingerprint(importedInput.Resources)

	associated := createTestPhotoUploadSession(t, app, importedInput)
	if associated.Status != "duplicate" || associated.AssetID != original.AssetID || associated.ID != "" {
		t.Fatalf("verified association response=%#v, want target %q", associated, original.AssetID)
	}
	var committedAssets int
	if err := app.db.QueryRow(
		"SELECT COUNT(*) FROM photo_assets WHERE source_state=?",
		photosSourceStateCommitted,
	).Scan(&committedAssets); err != nil {
		t.Fatal(err)
	}
	if committedAssets != 1 {
		t.Fatalf("committed assets=%d, expected association created a duplicate", committedAssets)
	}
	var mappedAssetID, mappedSourceModificationDate string
	if err := app.db.QueryRow(
		`SELECT asset_id,source_modification_date FROM device_asset_mappings
		 WHERE device_id=? AND local_identifier=?`,
		importedInput.DeviceID, importedInput.LocalIdentifier,
	).Scan(&mappedAssetID, &mappedSourceModificationDate); err != nil {
		t.Fatal(err)
	}
	if mappedAssetID != original.AssetID {
		t.Fatalf("mapping asset=%q, want %q", mappedAssetID, original.AssetID)
	}
	if mappedSourceModificationDate != importedModificationDate {
		t.Fatalf(
			"mapping source version=%q, want local version %q",
			mappedSourceModificationDate,
			importedModificationDate,
		)
	}
	mappingRequest := tailscaleRequest(
		http.MethodGet,
		"/api/v1/photos/device-asset-mappings?deviceID=current-iphone&limit=10",
	)
	mappingRecorder := httptest.NewRecorder()
	app.photosDeviceAssetMappings(mappingRecorder, mappingRequest)
	if mappingRecorder.Code != http.StatusOK {
		t.Fatalf("mapping status=%d body=%s", mappingRecorder.Code, mappingRecorder.Body.String())
	}
	var mappingPage photosDeviceAssetMappingPageResponse
	if err := json.NewDecoder(mappingRecorder.Body).Decode(&mappingPage); err != nil {
		t.Fatal(err)
	}
	if len(mappingPage.Mappings) != 1 ||
		mappingPage.Mappings[0].SourceModificationDate == nil ||
		*mappingPage.Mappings[0].SourceModificationDate != importedModificationDate {
		t.Fatalf("mapping recovery lost the local source version: %#v", mappingPage.Mappings)
	}
}

func TestMigrateBackfillsOnlyProvenDeviceMappingSourceVersions(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	payload := []byte("mapping-source-version-migration")
	input := testPhotoUploadInput(payload, nil)
	input.DeviceID = "migration-device"
	input.LocalIdentifier = "completed-session-local"
	provenModificationDate := "2026-08-06T09:13:35.577Z"
	input.ModificationDate = &provenModificationDate
	completed := completeTestPhotoUpload(t, app, input, map[string][]byte{"photo-0": payload})
	ownerUserID := testPhotoOwnerID(t, app, completed.AssetID)

	if _, err := app.db.Exec(
		`UPDATE device_asset_mappings SET source_modification_date=''
		 WHERE owner_user_id=? AND device_id=? AND local_identifier=?`,
		ownerUserID, input.DeviceID, input.LocalIdentifier,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := app.db.Exec(
		`INSERT INTO device_asset_mappings(
		 owner_user_id,device_id,local_identifier,fingerprint,source_modification_date,asset_id,updated
		 ) VALUES(?,?,?,?,?,?,?)`,
		ownerUserID, input.DeviceID, "mapping-without-session", input.Fingerprint, "",
		completed.AssetID, "2026-08-11T04:00:00Z",
	); err != nil {
		t.Fatal(err)
	}

	if err := app.migrate(); err != nil {
		t.Fatal(err)
	}
	var restoredSourceVersion, unprovenSourceVersion string
	if err := app.db.QueryRow(
		`SELECT source_modification_date FROM device_asset_mappings
		 WHERE owner_user_id=? AND device_id=? AND local_identifier=?`,
		ownerUserID, input.DeviceID, input.LocalIdentifier,
	).Scan(&restoredSourceVersion); err != nil {
		t.Fatal(err)
	}
	if restoredSourceVersion != provenModificationDate {
		t.Fatalf("restored source version=%q, want %q", restoredSourceVersion, provenModificationDate)
	}
	if err := app.db.QueryRow(
		`SELECT source_modification_date FROM device_asset_mappings
		 WHERE owner_user_id=? AND device_id=? AND local_identifier='mapping-without-session'`,
		ownerUserID, input.DeviceID,
	).Scan(&unprovenSourceVersion); err != nil {
		t.Fatal(err)
	}
	if unprovenSourceVersion != "" {
		t.Fatalf("unproven mapping inherited an asset-wide source version=%q", unprovenSourceVersion)
	}

	request := tailscaleRequest(
		http.MethodGet,
		"/api/v1/photos/device-asset-mappings?deviceID=migration-device&limit=10",
	)
	recorder := httptest.NewRecorder()
	app.photosDeviceAssetMappings(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("mapping status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var page photosDeviceAssetMappingPageResponse
	if err := json.NewDecoder(recorder.Body).Decode(&page); err != nil {
		t.Fatal(err)
	}
	versionsByLocalIdentifier := make(map[string]*string, len(page.Mappings))
	for _, mapping := range page.Mappings {
		versionsByLocalIdentifier[mapping.LocalIdentifier] = mapping.SourceModificationDate
	}
	if version := versionsByLocalIdentifier[input.LocalIdentifier]; version == nil || *version != provenModificationDate {
		t.Fatalf("endpoint lost proven source version: %#v", versionsByLocalIdentifier)
	}
	if version := versionsByLocalIdentifier["mapping-without-session"]; version != nil {
		t.Fatalf("endpoint exposed unproven source version=%q", *version)
	}
}

func TestPhotosExpectedAssetRejectsDifferentCompleteResourceGroup(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	targetBytes := []byte("target-original")
	target := commitTestPhotoUpload(
		t, app, testPhotoUploadInput(targetBytes, nil), [][]byte{targetBytes},
	)

	differentInput := testPhotoUploadInput([]byte("different-original"), nil)
	differentInput.DeviceID = "current-iphone"
	differentInput.LocalIdentifier = "different-photo-kit-item"
	differentInput.ExpectedAssetID = target.AssetID
	data, err := json.Marshal(differentInput)
	if err != nil {
		t.Fatal(err)
	}
	request := tailscaleRequest(http.MethodPost, "/api/v1/photos/upload-sessions")
	request.Body = ioNopCloser(strings.NewReader(string(data)))
	request.ContentLength = int64(len(data))
	request.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()
	app.photosUploadSessions(recorder, request)
	if recorder.Code != http.StatusUnprocessableEntity ||
		!strings.Contains(recorder.Body.String(), "does not match complete resource group") {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var unexpectedMappings int
	if err = app.db.QueryRow(
		`SELECT COUNT(*) FROM device_asset_mappings
		 WHERE device_id=? AND local_identifier=?`,
		differentInput.DeviceID, differentInput.LocalIdentifier,
	).Scan(&unexpectedMappings); err != nil {
		t.Fatal(err)
	}
	if unexpectedMappings != 0 {
		t.Fatalf("different resource group created %d mappings", unexpectedMappings)
	}
}

func TestPhotosExpectedAssetConsolidatesProvenLegacyDuplicateWithoutDeletingFiles(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	originalBytes := []byte("legacy-duplicate-original")
	originalInput := testPhotoUploadInput(originalBytes, nil)
	original := commitTestPhotoUpload(t, app, originalInput, [][]byte{originalBytes})

	const duplicateAssetID = "ast-legacy-transport-duplicate"
	const duplicateResourceID = "res-legacy-transport-duplicate"
	if _, err := app.db.Exec(
		`INSERT INTO photo_assets(
		 id,owner_user_id,volume_id,content_fingerprint,media_type,capture_date,modification_date,
		 pixel_width,pixel_height,duration,favorite,backup_state,source_state,derivative_state,
		 derivative_recipe_version,derivative_error,derivative_updated,created,updated
		 ) SELECT ?,owner_user_id,volume_id,?,media_type,capture_date,modification_date,
		 pixel_width,pixel_height,duration,favorite,backup_state,source_state,derivative_state,
		 derivative_recipe_version,derivative_error,derivative_updated,created,updated
		 FROM photo_assets WHERE id=?`,
		duplicateAssetID, strings.Repeat("b", 64), original.AssetID,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := app.db.Exec(
		`INSERT INTO photo_resources(
		 id,asset_id,owner_user_id,volume_id,resource_role,original_filename,content_type,
		 byte_size,sha256,storage_path,created
		 ) SELECT ?,?,owner_user_id,volume_id,resource_role,original_filename,'public.png',
		 byte_size,sha256,storage_path,created
		 FROM photo_resources WHERE asset_id=?`,
		duplicateResourceID, duplicateAssetID, original.AssetID,
	); err != nil {
		t.Fatal(err)
	}
	ownerUserID := testPhotoOwnerID(t, app, original.AssetID)
	if _, err := app.db.Exec(
		`INSERT INTO device_asset_mappings(
		 owner_user_id,device_id,local_identifier,fingerprint,source_modification_date,asset_id,updated
		 ) VALUES(?,?,?,?,?,?,'now')`,
		ownerUserID, "legacy-device", "legacy-local", strings.Repeat("b", 64),
		"2026-08-05T01:02:03.456Z", duplicateAssetID,
	); err != nil {
		t.Fatal(err)
	}

	associationInput := originalInput
	associationInput.DeviceID = "current-iphone"
	associationInput.LocalIdentifier = "downloaded-local-copy"
	associationInput.ExpectedAssetID = original.AssetID
	associationInput.Resources[0].ClientResourceID = "resource-000"
	associationInput.Resources[0].ContentType = "public.png"
	associationInput.Fingerprint = photoManifestFingerprint(associationInput.Resources)
	associated := createTestPhotoUploadSession(t, app, associationInput)
	if associated.AssetID != original.AssetID || associated.Status != "duplicate" {
		t.Fatalf("association response=%#v", associated)
	}

	var duplicateState string
	if err := app.db.QueryRow(
		"SELECT source_state FROM photo_assets WHERE id=?", duplicateAssetID,
	).Scan(&duplicateState); err != nil {
		t.Fatal(err)
	}
	if duplicateState != photosSourceStateSuperseded {
		t.Fatalf("duplicate state=%q, want %q", duplicateState, photosSourceStateSuperseded)
	}
	var preservedResources int
	if err := app.db.QueryRow(
		"SELECT COUNT(*) FROM photo_resources WHERE asset_id=?", duplicateAssetID,
	).Scan(&preservedResources); err != nil {
		t.Fatal(err)
	}
	if preservedResources != 1 {
		t.Fatalf("superseded duplicate resources=%d, want preserved resource", preservedResources)
	}
	var legacyMappingAssetID, legacyMappingSourceModificationDate string
	if err := app.db.QueryRow(
		`SELECT asset_id,source_modification_date FROM device_asset_mappings
		 WHERE owner_user_id=? AND device_id='legacy-device' AND local_identifier='legacy-local'`,
		ownerUserID,
	).Scan(&legacyMappingAssetID, &legacyMappingSourceModificationDate); err != nil {
		t.Fatal(err)
	}
	if legacyMappingAssetID != original.AssetID {
		t.Fatalf("legacy mapping asset=%q, want %q", legacyMappingAssetID, original.AssetID)
	}
	if legacyMappingSourceModificationDate != "2026-08-05T01:02:03.456Z" {
		t.Fatalf("legacy mapping source version changed=%q", legacyMappingSourceModificationDate)
	}
}

func TestPhotosDeduplicationIgnoresTransportClientIDAndMIMEUTISpelling(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	originalBytes := []byte("transport-independent-content")
	originalInput := testPhotoUploadInput(originalBytes, nil)
	originalInput.Resources[0].ClientResourceID = "fixture-resource"
	originalInput.Resources[0].ContentType = "image/png"
	originalInput.Fingerprint = photoManifestFingerprint(originalInput.Resources)
	original := commitTestPhotoUpload(t, app, originalInput, [][]byte{originalBytes})

	secondInput := originalInput
	secondInput.DeviceID = "another-device"
	secondInput.LocalIdentifier = "another-local-id"
	secondInput.Resources[0].ClientResourceID = "resource-000"
	secondInput.Resources[0].ContentType = "public.png"
	secondInput.Fingerprint = photoManifestFingerprint(secondInput.Resources)
	duplicate := createTestPhotoUploadSession(t, app, secondInput)
	if duplicate.Status != "duplicate" || duplicate.AssetID != original.AssetID || duplicate.ID != "" {
		t.Fatalf("transport metadata split exact content: %#v", duplicate)
	}
}

func TestPhotosUploadSessionResumptionIsScopedToTheSelectedVolume(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	input := testPhotoUploadInput([]byte("same-resource-on-two-volumes"), nil)
	primary := createTestPhotoUploadSession(t, app, input)

	secondaryMount := t.TempDir()
	if _, err := app.db.Exec(
		`INSERT INTO volumes(id,name,uuid,device,filesystem,mount,enabled,created)
		 VALUES(?,?,?,?,?,?,1,?)`,
		"secondary", "Secondary", "test-secondary-uuid", secondaryMount, "ext4", secondaryMount, "now",
	); err != nil {
		t.Fatal(err)
	}
	secondaryInput := input
	secondaryInput.VolumeID = "secondary"
	secondary := createTestPhotoUploadSession(t, app, secondaryInput)
	if secondary.ID == primary.ID || secondary.ID == "" {
		t.Fatalf("volume switch reused the primary session: primary=%#v secondary=%#v", primary, secondary)
	}

	resumedPrimary := createTestPhotoUploadSession(t, app, input)
	if resumedPrimary.ID != primary.ID {
		t.Fatalf("primary volume did not resume its own session: got=%q want=%q", resumedPrimary.ID, primary.ID)
	}
}

func TestPhotoUploadSessionMigrationScopesLegacyUniquenessByVolume(t *testing.T) {
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "legacy-photos.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	configureDB(db)
	app := &App{db: db}
	if _, err = db.Exec(`CREATE TABLE photo_upload_sessions(
		id TEXT PRIMARY KEY,
		owner_user_id TEXT NOT NULL,
		volume_id TEXT NOT NULL,
		device_id TEXT NOT NULL,
		local_identifier TEXT NOT NULL,
		fingerprint TEXT NOT NULL,
		asset_id TEXT NOT NULL,
		media_type TEXT NOT NULL,
		status TEXT NOT NULL,
		capture_date TEXT,
		modification_date TEXT,
		pixel_width INTEGER NOT NULL DEFAULT 0,
		pixel_height INTEGER NOT NULL DEFAULT 0,
		duration REAL NOT NULL DEFAULT 0,
		favorite INTEGER NOT NULL DEFAULT 0,
		stage_dir TEXT NOT NULL,
		created TEXT NOT NULL,
		updated TEXT NOT NULL,
		UNIQUE(owner_user_id,device_id,local_identifier,fingerprint)
	)`); err != nil {
		t.Fatal(err)
	}
	if err = app.migratePhotoUploadSessionsVolumeScope(); err != nil {
		t.Fatal(err)
	}
	for _, row := range []struct {
		id, volume string
	}{
		{id: "primary-session", volume: "primary"},
		{id: "secondary-session", volume: "secondary"},
	} {
		if _, err = db.Exec(`INSERT INTO photo_upload_sessions(
			id,owner_user_id,volume_id,device_id,local_identifier,fingerprint,asset_id,media_type,status,
			stage_dir,created,updated
		) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)`,
			row.id, "owner", row.volume, "device", "local", "fingerprint", row.id+"-asset", "photo", "waiting",
			"stage", "now", "now",
		); err != nil {
			t.Fatalf("insert for %s: %v", row.volume, err)
		}
	}
	if _, err = db.Exec(`INSERT INTO photo_upload_sessions(
		id,owner_user_id,volume_id,device_id,local_identifier,fingerprint,asset_id,media_type,status,
		stage_dir,created,updated
	) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)`,
		"duplicate-primary", "owner", "primary", "device", "local", "fingerprint", "asset", "photo", "waiting",
		"stage", "now", "now",
	); err == nil {
		t.Fatal("legacy migration still allowed duplicate session identity within one volume")
	}
}

func TestExpiredPhotoUploadSessionCleanupOnlyRemovesVerifiedExpiredStaging(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	expiredInput := testPhotoUploadInput([]byte("expired-session"), nil)
	expired := createTestPhotoUploadSession(t, app, expiredInput)
	var expiredStageDir string
	if err := app.db.QueryRow("SELECT stage_dir FROM photo_upload_sessions WHERE id=?", expired.ID).Scan(&expiredStageDir); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(expiredStageDir, "expired-sentinel"), []byte("temporary"), 0600); err != nil {
		t.Fatal(err)
	}

	now := time.Date(2026, time.August, 3, 12, 0, 0, 0, time.UTC)
	expiredAt := now.Add(-photosUploadSessionMaxAge - time.Second).Format(time.RFC3339Nano)
	if _, err := app.db.Exec("UPDATE photo_upload_sessions SET updated=? WHERE id=?", expiredAt, expired.ID); err != nil {
		t.Fatal(err)
	}

	freshInput := testPhotoUploadInput([]byte("fresh-session"), nil)
	freshInput.LocalIdentifier = "fresh-local-id"
	fresh := createTestPhotoUploadSession(t, app, freshInput)
	var freshStageDir string
	if err := app.db.QueryRow("SELECT stage_dir FROM photo_upload_sessions WHERE id=?", fresh.ID).Scan(&freshStageDir); err != nil {
		t.Fatal(err)
	}

	foreignStageDir := filepath.Join(t.TempDir(), "not-a-mynas-stage")
	if err := os.MkdirAll(foreignStageDir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(foreignStageDir, "foreign-sentinel"), []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := app.db.Exec(`INSERT INTO photo_upload_sessions(
		id,owner_user_id,volume_id,device_id,local_identifier,fingerprint,asset_id,media_type,status,
		stage_dir,created,updated
	) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)`,
		"unexpected-stage", "owner", "primary", "device", "unexpected-local", "unexpected-fingerprint", "unexpected-asset", "photo", "waiting",
		foreignStageDir, expiredAt, expiredAt,
	); err != nil {
		t.Fatal(err)
	}

	if err := app.cleanupExpiredPhotoUploadSessions(now); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(expiredStageDir); !os.IsNotExist(err) {
		t.Fatalf("expired staging still exists or cannot be checked: %v", err)
	}
	var expiredSessionCount, expiredResourceCount int
	if err := app.db.QueryRow("SELECT COUNT(*) FROM photo_upload_sessions WHERE id=?", expired.ID).Scan(&expiredSessionCount); err != nil {
		t.Fatal(err)
	}
	if err := app.db.QueryRow("SELECT COUNT(*) FROM photo_upload_resources WHERE upload_session_id=?", expired.ID).Scan(&expiredResourceCount); err != nil {
		t.Fatal(err)
	}
	if expiredSessionCount != 0 || expiredResourceCount != 0 {
		t.Fatalf("expired metadata remained: sessions=%d resources=%d", expiredSessionCount, expiredResourceCount)
	}
	if _, err := os.Stat(freshStageDir); err != nil {
		t.Fatalf("fresh staging was removed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(foreignStageDir, "foreign-sentinel")); err != nil {
		t.Fatalf("unverified foreign path was removed: %v", err)
	}
	var foreignSessionCount int
	if err := app.db.QueryRow("SELECT COUNT(*) FROM photo_upload_sessions WHERE id='unexpected-stage'").Scan(&foreignSessionCount); err != nil {
		t.Fatal(err)
	}
	if foreignSessionCount != 1 {
		t.Fatalf("unverified foreign session was removed: %d", foreignSessionCount)
	}
}

func TestPhotosBrowseRecipeV2HasRequiredKinds(t *testing.T) {
	got := strings.Join(requiredPhotosDerivativeKinds(), ",")
	if got != "tiny,grid,preview" {
		t.Fatalf("required derivative kinds=%q", got)
	}
	for _, recipe := range photosBrowseRecipesV2 {
		if recipe.ID == "" || recipe.MaxPixelDimension <= 0 || recipe.ResizeMode == "" {
			t.Fatalf("incomplete derivative recipe: %#v", recipe)
		}
	}
}

func TestPhotosUploadRejectsBadChunkChecksum(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	payload := []byte("one-photo")
	input := testPhotoUploadInput(payload, nil)
	created := createTestPhotoUploadSession(t, app, input)
	resource := created.Resources[0]

	request := tailscaleRequest(
		http.MethodPut,
		"/api/v1/photos/upload-sessions/"+created.ID+"/resources/"+resource.ID+"/parts/0",
	)
	request.Body = ioNopCloser(strings.NewReader(string(payload)))
	request.ContentLength = int64(len(payload))
	request.Header.Set("X-Upload-Offset", "0")
	request.Header.Set("X-Chunk-SHA256", strings.Repeat("0", 64))
	recorder := httptest.NewRecorder()
	app.photosUploadSessionByPath(recorder, request)
	if recorder.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}

	var received int64
	if err := app.db.QueryRow(
		"SELECT received FROM photo_upload_resources WHERE id=?",
		resource.ID,
	).Scan(&received); err != nil {
		t.Fatal(err)
	}
	if received != 0 {
		t.Fatalf("bad chunk advanced received bytes to %d", received)
	}
}

func TestPhotosUploadRejectsIncompleteLivePhoto(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	still := []byte("still")
	motion := []byte("motion")
	input := testPhotoUploadInput(still, motion)
	created := createTestPhotoUploadSession(t, app, input)
	putTestPhotoPart(t, app, created.ID, testUploadResource(t, created.Resources, "photo-0"), 0, still)

	request := tailscaleRequest(
		http.MethodPost,
		"/api/v1/photos/upload-sessions/"+created.ID+"/complete",
	)
	recorder := httptest.NewRecorder()
	app.photosUploadSessionByPath(recorder, request)
	if recorder.Code != http.StatusConflict {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	if _, err := os.Stat(filepath.Join(app.c.Root, "users")); !os.IsNotExist(err) {
		t.Fatalf("incomplete Live Photo created a final users directory: %v", err)
	}
}

func createTestPhotoUploadSession(
	t *testing.T,
	app *App,
	input photosUploadSessionInput,
) photosUploadSessionResponse {
	t.Helper()
	data, err := json.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}
	request := tailscaleRequest(http.MethodPost, "/api/v1/photos/upload-sessions")
	request.Body = ioNopCloser(strings.NewReader(string(data)))
	request.ContentLength = int64(len(data))
	request.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()
	app.photosUploadSessions(recorder, request)
	if recorder.Code != http.StatusCreated && recorder.Code != http.StatusOK {
		t.Fatalf("create status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response photosUploadSessionResponse
	if err = json.NewDecoder(recorder.Body).Decode(&response); err != nil {
		t.Fatal(err)
	}
	return response
}

func commitTestPhotoUpload(
	t *testing.T,
	app *App,
	input photosUploadSessionInput,
	resourceBytes [][]byte,
) photosUploadSessionResponse {
	t.Helper()
	created := createTestPhotoUploadSession(t, app, input)
	if created.Status != "waiting" || len(created.Resources) != len(resourceBytes) {
		t.Fatalf("unexpected create response: %#v", created)
	}
	for index, resourceData := range resourceBytes {
		remote := testUploadResource(t, created.Resources, input.Resources[index].ClientResourceID)
		putTestPhotoPart(t, app, created.ID, remote, 0, resourceData)
	}
	request := tailscaleRequest(
		http.MethodPost,
		"/api/v1/photos/upload-sessions/"+created.ID+"/complete",
	)
	recorder := httptest.NewRecorder()
	app.photosUploadSessionByPath(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("complete status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var completed photosUploadSessionResponse
	if err := json.NewDecoder(recorder.Body).Decode(&completed); err != nil {
		t.Fatal(err)
	}
	return completed
}

func putTestPhotoPart(
	t *testing.T,
	app *App,
	sessionID string,
	resource photosUploadResourceResponse,
	partNumber int64,
	data []byte,
) {
	t.Helper()
	request := tailscaleRequest(
		http.MethodPut,
		"/api/v1/photos/upload-sessions/"+sessionID+"/resources/"+resource.ID+
			"/parts/"+strconv.FormatInt(partNumber, 10),
	)
	request.Body = ioNopCloser(strings.NewReader(string(data)))
	request.ContentLength = int64(len(data))
	request.Header.Set("X-Upload-Offset", strconv.FormatInt(partNumber*resource.ChunkSize, 10))
	sum := sha256.Sum256(data)
	request.Header.Set("X-Chunk-SHA256", hex.EncodeToString(sum[:]))
	recorder := httptest.NewRecorder()
	app.photosUploadSessionByPath(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("part status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}

func testPhotoUploadInput(still, motion []byte) photosUploadSessionInput {
	resources := []photosUploadResourceInput{
		testPhotoResource("photo-0", "photo", "IMG_0001.HEIC", "image/heic", still),
	}
	mediaType := "photo"
	if motion != nil {
		resources = append(resources,
			testPhotoResource("pairedVideo-1", "pairedVideo", "IMG_0001.MOV", "video/quicktime", motion),
		)
		mediaType = "livePhoto"
	}
	return photosUploadSessionInput{
		VolumeID: "primary", DeviceID: "test-ios-device", LocalIdentifier: "photo-kit-id",
		Fingerprint: photoManifestFingerprint(resources), MediaType: mediaType,
		PixelWidth: 4032, PixelHeight: 3024, Duration: 1.5, Favorite: true,
		Resources: resources,
	}
}

func testPhotoResource(
	clientID, role, filename, contentType string,
	data []byte,
) photosUploadResourceInput {
	sum := sha256.Sum256(data)
	return photosUploadResourceInput{
		ClientResourceID: clientID, ResourceRole: role, OriginalFilename: filename,
		ContentType: contentType, ByteSize: int64(len(data)), SHA256: hex.EncodeToString(sum[:]),
	}
}

func testUploadResource(
	t *testing.T,
	resources []photosUploadResourceResponse,
	clientResourceID string,
) photosUploadResourceResponse {
	t.Helper()
	for _, resource := range resources {
		if resource.ClientResourceID == clientResourceID {
			return resource
		}
	}
	t.Fatalf("missing resource %q in %#v", clientResourceID, resources)
	return photosUploadResourceResponse{}
}

type stringReadCloser struct {
	*strings.Reader
}

func (stringReadCloser) Close() error { return nil }

func ioNopCloser(reader *strings.Reader) stringReadCloser {
	return stringReadCloser{Reader: reader}
}
