package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestPhotosAssetsAreOwnerScopedPaginatedAndNeverLeakPaths(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	first := uploadBrowseTestPhoto(t, app, "first", "2026-07-24T12:00:00Z")
	second := uploadBrowseTestPhoto(t, app, "second", "2026-07-24T11:00:00Z")
	_ = uploadBrowseTestPhoto(t, app, "third", "2026-07-24T10:00:00Z")

	recorder := httptest.NewRecorder()
	app.photosAssets(recorder, tailscaleRequest(http.MethodGet, "/api/v1/photos/assets?limit=2"))
	if recorder.Code != http.StatusOK {
		t.Fatalf("assets status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	body := recorder.Body.String()
	if strings.Contains(body, app.c.Root) || strings.Contains(body, "storage_path") ||
		strings.Contains(body, "storagePath") {
		t.Fatalf("assets response leaked storage details: %s", body)
	}
	var page photosAssetPageResponse
	if err := json.Unmarshal([]byte(body), &page); err != nil {
		t.Fatal(err)
	}
	if len(page.Assets) != 2 || !page.HasMore || page.NextCursor == nil {
		t.Fatalf("unexpected first page: %#v", page)
	}
	if page.Assets[0].ID != first.AssetID || page.Assets[1].ID != second.AssetID {
		t.Fatalf("capture ordering=%q,%q", page.Assets[0].ID, page.Assets[1].ID)
	}
	if len(page.Assets[0].Resources) != 1 ||
		!strings.HasPrefix(page.Assets[0].Resources[0].DownloadURL, "/api/v1/photos/assets/") {
		t.Fatalf("resource links missing: %#v", page.Assets[0].Resources)
	}

	nextRecorder := httptest.NewRecorder()
	nextPath := "/api/v1/photos/assets?limit=2&cursor=" + url.QueryEscape(*page.NextCursor)
	app.photosAssets(nextRecorder, tailscaleRequest(http.MethodGet, nextPath))
	var next photosAssetPageResponse
	if err := json.NewDecoder(nextRecorder.Body).Decode(&next); err != nil {
		t.Fatal(err)
	}
	if len(next.Assets) != 1 || next.HasMore || next.NextCursor != nil {
		t.Fatalf("unexpected second page: %#v", next)
	}

	otherOwnerRequest := tailscaleRequest(http.MethodGet, "/api/v1/photos/assets")
	otherOwnerRequest.Header.Set("Tailscale-User-Login", "other@example.com")
	otherOwnerRecorder := httptest.NewRecorder()
	app.photosAssets(otherOwnerRecorder, otherOwnerRequest)
	var otherPage photosAssetPageResponse
	if err := json.NewDecoder(otherOwnerRecorder.Body).Decode(&otherPage); err != nil {
		t.Fatal(err)
	}
	if len(otherPage.Assets) != 0 {
		t.Fatalf("other owner received %d assets", len(otherPage.Assets))
	}
}

func TestPhotosBrowseSupportsETagRangeAndOwnerAuthorization(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	payload := []byte("0123456789-original-photo")
	completed := uploadBrowsePhotoBytes(t, app, "ready", "2026-07-24T13:00:00Z", payload)
	app.derivativeProcessor = &fakePhotosDerivativeProcessor{}
	processed, err := app.runNextPhotoDerivativeJob(context.Background())
	if err != nil || !processed {
		t.Fatalf("derivative processed=%v err=%v", processed, err)
	}

	detailRecorder := httptest.NewRecorder()
	detailPath := "/api/v1/photos/assets/" + completed.AssetID
	app.photosAssetByPath(detailRecorder, tailscaleRequest(http.MethodGet, detailPath))
	if detailRecorder.Code != http.StatusOK {
		t.Fatalf("detail status=%d body=%s", detailRecorder.Code, detailRecorder.Body.String())
	}
	etag := detailRecorder.Header().Get("ETag")
	if etag == "" {
		t.Fatal("detail response omitted ETag")
	}
	var detail photosAssetResponse
	if err = json.NewDecoder(detailRecorder.Body).Decode(&detail); err != nil {
		t.Fatal(err)
	}
	if !detail.BrowseReady || len(detail.Derivatives) != 3 {
		t.Fatalf("ready asset metadata=%#v", detail)
	}

	conditional := tailscaleRequest(http.MethodGet, detailPath)
	conditional.Header.Set("If-None-Match", etag)
	conditionalRecorder := httptest.NewRecorder()
	app.photosAssetByPath(conditionalRecorder, conditional)
	if conditionalRecorder.Code != http.StatusNotModified {
		t.Fatalf("conditional status=%d", conditionalRecorder.Code)
	}

	rangeRequest := tailscaleRequest(http.MethodGet, "/api/v1/photos/assets/"+completed.AssetID+"/original")
	rangeRequest.Header.Set("Range", "bytes=2-5")
	rangeRecorder := httptest.NewRecorder()
	app.photosAssetByPath(rangeRecorder, rangeRequest)
	if rangeRecorder.Code != http.StatusPartialContent || rangeRecorder.Body.String() != "2345" {
		t.Fatalf("range status=%d body=%q headers=%v", rangeRecorder.Code, rangeRecorder.Body.String(), rangeRecorder.Header())
	}
	if rangeRecorder.Header().Get("ETag") == "" ||
		rangeRecorder.Header().Get("Accept-Ranges") != "bytes" {
		t.Fatalf("range headers=%v", rangeRecorder.Header())
	}

	gridRecorder := httptest.NewRecorder()
	app.photosAssetByPath(
		gridRecorder,
		tailscaleRequest(http.MethodGet, "/api/v1/photos/assets/"+completed.AssetID+"/grid"),
	)
	if gridRecorder.Code != http.StatusOK ||
		gridRecorder.Header().Get("Content-Type") != "image/jpeg" {
		t.Fatalf("grid status=%d headers=%v", gridRecorder.Code, gridRecorder.Header())
	}

	otherOwnerRequest := tailscaleRequest(http.MethodGet, detailPath)
	otherOwnerRequest.Header.Set("Tailscale-User-Login", "other@example.com")
	otherOwnerRecorder := httptest.NewRecorder()
	app.photosAssetByPath(otherOwnerRecorder, otherOwnerRequest)
	if otherOwnerRecorder.Code != http.StatusNotFound {
		t.Fatalf("other owner detail status=%d", otherOwnerRecorder.Code)
	}
}

func TestPhotosChangesReportSourceAndDerivativeUpdates(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	completed := uploadBrowseTestPhoto(t, app, "changes", "2026-07-24T14:00:00Z")
	app.derivativeProcessor = &fakePhotosDerivativeProcessor{}
	if processed, err := app.runNextPhotoDerivativeJob(context.Background()); err != nil || !processed {
		t.Fatalf("derivative processed=%v err=%v", processed, err)
	}

	recorder := httptest.NewRecorder()
	app.photosChanges(
		recorder,
		tailscaleRequest(http.MethodGet, "/api/v1/photos/changes?cursor=0&limit=1"),
	)
	var first photosChangePageResponse
	if err := json.NewDecoder(recorder.Body).Decode(&first); err != nil {
		t.Fatal(err)
	}
	if len(first.Changes) != 1 || first.Changes[0].AssetID != completed.AssetID ||
		!first.HasMore || first.ResetRequired {
		t.Fatalf("first change page=%#v", first)
	}

	nextRecorder := httptest.NewRecorder()
	app.photosChanges(
		nextRecorder,
		tailscaleRequest(http.MethodGet, "/api/v1/photos/changes?cursor="+first.NextCursor+"&limit=10"),
	)
	var next photosChangePageResponse
	if err := json.NewDecoder(nextRecorder.Body).Decode(&next); err != nil {
		t.Fatal(err)
	}
	if len(next.Changes) < 1 || next.Changes[0].AssetID != completed.AssetID ||
		next.ResetRequired {
		t.Fatalf("next change page=%#v", next)
	}
}

func TestPhotosHTTPContentTypeMapsPhotoKitUTIsForStreaming(t *testing.T) {
	cases := map[string]string{
		"com.apple.quicktime-movie": "video/quicktime",
		"public.mpeg-4":              "video/mp4",
		"public.heic":                "image/heic",
		"image/jpeg":                 "image/jpeg",
		"unrecognized.type":          "application/octet-stream",
	}
	for input, want := range cases {
		if got := photosHTTPContentType(input); got != want {
			t.Errorf("photosHTTPContentType(%q)=%q want %q", input, got, want)
		}
	}
}

func TestPhotosCORSAllowsActualChunkChecksumHeader(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	request := httptest.NewRequest(
		http.MethodOptions,
		"/api/v1/photos/upload-sessions/example/resources/example/parts/0",
		nil,
	)
	request.Header.Set("Origin", "http://localhost:5173")
	request.Header.Set("Access-Control-Request-Headers", "X-Chunk-SHA256")
	recorder := httptest.NewRecorder()
	app.middleware(http.NotFoundHandler()).ServeHTTP(recorder, request)
	if recorder.Code != http.StatusNoContent {
		t.Fatalf("preflight status=%d", recorder.Code)
	}
	if !strings.Contains(
		recorder.Header().Get("Access-Control-Allow-Headers"),
		"X-Chunk-SHA256",
	) {
		t.Fatalf("allow headers=%q", recorder.Header().Get("Access-Control-Allow-Headers"))
	}
}

func uploadBrowseTestPhoto(
	t *testing.T,
	app *App,
	localIdentifier string,
	captureDate string,
) photosUploadSessionResponse {
	t.Helper()
	return uploadBrowsePhotoBytes(
		t, app, localIdentifier, captureDate, []byte("browse-source-"+localIdentifier),
	)
}

func uploadBrowsePhotoBytes(
	t *testing.T,
	app *App,
	localIdentifier string,
	captureDate string,
	payload []byte,
) photosUploadSessionResponse {
	t.Helper()
	input := testPhotoUploadInput(payload, nil)
	input.LocalIdentifier = localIdentifier
	input.CaptureDate = &captureDate
	created := createTestPhotoUploadSession(t, app, input)
	putTestPhotoPart(t, app, created.ID, created.Resources[0], 0, payload)
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
