package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
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

func TestPhotosBrowseRecipeV1HasRequiredKinds(t *testing.T) {
	got := strings.Join(requiredPhotosDerivativeKinds(), ",")
	if got != "tiny,grid,preview" {
		t.Fatalf("required derivative kinds=%q", got)
	}
	for _, recipe := range photosBrowseRecipesV1 {
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
