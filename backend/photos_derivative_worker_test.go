package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"image"
	"image/color"
	"image/jpeg"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

type fakePhotosDerivativeProcessor struct {
	calls    int
	failure  error
	omitKind string
}

func (processor *fakePhotosDerivativeProcessor) Process(
	_ context.Context,
	request photosDerivativeRequest,
) (photosDerivativeResult, error) {
	processor.calls++
	if processor.failure != nil {
		return photosDerivativeResult{}, processor.failure
	}
	if err := os.MkdirAll(request.FinalDirectory, 0700); err != nil {
		return photosDerivativeResult{}, err
	}
	outputs := make([]photosGeneratedDerivative, 0, len(request.Recipes))
	for _, recipe := range request.Recipes {
		if recipe.Kind == processor.omitKind {
			continue
		}
		path := filepath.Join(request.FinalDirectory, recipe.Kind+".jpg")
		file, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
		if err != nil {
			return photosDerivativeResult{}, err
		}
		width, height := 32, 24
		if recipe.ResizeMode == "centerCrop" {
			width = recipe.MaxPixelDimension
			height = recipe.MaxPixelDimension
		}
		picture := image.NewRGBA(image.Rect(0, 0, width, height))
		for y := 0; y < height; y++ {
			for x := 0; x < width; x++ {
				picture.Set(x, y, color.RGBA{R: uint8(x * 4), G: uint8(y * 7), B: 90, A: 255})
			}
		}
		encodeErr := jpeg.Encode(file, picture, &jpeg.Options{Quality: 80})
		closeErr := file.Close()
		if encodeErr != nil {
			return photosDerivativeResult{}, encodeErr
		}
		if closeErr != nil {
			return photosDerivativeResult{}, closeErr
		}
		generated, err := inspectPhotosDerivativeDirectory(
			request.FinalDirectory,
			[]photosDerivativeRecipe{recipe},
		)
		if err != nil {
			return photosDerivativeResult{}, err
		}
		outputs = append(outputs, generated[0])
	}
	return photosDerivativeResult{
		SourcePath: request.Sources[0].Path,
		Outputs:    outputs,
	}, nil
}

func TestPhotosDerivativeWorkerCompletesRequiredOutputsWithoutChangingSource(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	completed := uploadTestPhotoForDerivatives(t, app)
	sourcePath, sourceHash := testCommittedPhotoSource(t, app, completed.AssetID)
	before, err := sha256File(sourcePath)
	if err != nil || before != sourceHash {
		t.Fatalf("source hash before worker=%q err=%v, want %q", before, err, sourceHash)
	}

	processor := &fakePhotosDerivativeProcessor{}
	app.derivativeProcessor = processor
	processed, err := app.runNextPhotoDerivativeJob(context.Background())
	if err != nil || !processed {
		t.Fatalf("processed=%v err=%v", processed, err)
	}
	processed, err = app.runNextPhotoDerivativeJob(context.Background())
	if err != nil || processed {
		t.Fatalf("completed job ran twice: processed=%v err=%v", processed, err)
	}
	if processor.calls != 1 {
		t.Fatalf("processor calls=%d, want 1", processor.calls)
	}

	var derivativeState, derivativeError string
	if err = app.db.QueryRow(
		`SELECT derivative_state,COALESCE(derivative_error,'')
		 FROM photo_assets WHERE id=?`,
		completed.AssetID,
	).Scan(&derivativeState, &derivativeError); err != nil {
		t.Fatal(err)
	}
	if derivativeState != photosDerivativeStateReady || derivativeError != "" {
		t.Fatalf("asset derivative state=(%q,%q)", derivativeState, derivativeError)
	}
	var jobStatus string
	if err = app.db.QueryRow(
		"SELECT status FROM photo_derivative_jobs WHERE asset_id=?",
		completed.AssetID,
	).Scan(&jobStatus); err != nil {
		t.Fatal(err)
	}
	if jobStatus != photosDerivativeJobCompleted {
		t.Fatalf("job status=%q", jobStatus)
	}
	var derivativeCount int
	if err = app.db.QueryRow(
		`SELECT COUNT(*) FROM photo_derivatives
		 WHERE asset_id=? AND status=?`,
		completed.AssetID,
		photosDerivativeStateReady,
	).Scan(&derivativeCount); err != nil {
		t.Fatal(err)
	}
	if derivativeCount != len(requiredPhotosDerivativeKinds()) {
		t.Fatalf("derivative count=%d", derivativeCount)
	}
	after, err := sha256File(sourcePath)
	if err != nil || after != before {
		t.Fatalf("source changed after worker: before=%q after=%q err=%v", before, after, err)
	}

	duplicateInput := testPhotoUploadInput([]byte("immutable-photo-source"), nil)
	duplicateInput.LocalIdentifier = "duplicate-after-derivatives"
	duplicate := createTestPhotoUploadSession(t, app, duplicateInput)
	if duplicate.Status != "duplicate" ||
		duplicate.SourceState != photosSourceStateCommitted ||
		duplicate.DerivativeState != photosDerivativeStateReady ||
		!duplicate.BrowseReady {
		t.Fatalf("ready duplicate response=%#v", duplicate)
	}
}

func TestPhotosDerivativeWorkerRecoversInterruptedJob(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	completed := uploadTestPhotoForDerivatives(t, app)
	if _, err := app.db.Exec(
		"UPDATE photo_derivative_jobs SET status=? WHERE asset_id=?",
		photosDerivativeJobProcessing,
		completed.AssetID,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := app.db.Exec(
		"UPDATE photo_assets SET derivative_state=? WHERE id=?",
		photosDerivativeStateProcessing,
		completed.AssetID,
	); err != nil {
		t.Fatal(err)
	}
	if err := app.recoverInterruptedPhotoDerivativeJobs(); err != nil {
		t.Fatal(err)
	}

	var jobStatus, assetState string
	if err := app.db.QueryRow(
		`SELECT j.status,a.derivative_state
		 FROM photo_derivative_jobs j JOIN photo_assets a ON a.id=j.asset_id
		 WHERE j.asset_id=?`,
		completed.AssetID,
	).Scan(&jobStatus, &assetState); err != nil {
		t.Fatal(err)
	}
	if jobStatus != photosDerivativeJobPending || assetState != photosDerivativeStatePending {
		t.Fatalf("recovered state=(%q,%q)", jobStatus, assetState)
	}

	app.derivativeProcessor = &fakePhotosDerivativeProcessor{}
	processed, err := app.runNextPhotoDerivativeJob(context.Background())
	if err != nil || !processed {
		t.Fatalf("recovered job processed=%v err=%v", processed, err)
	}
}

func TestPhotosDerivativeWorkerKeepsAssetUnreadyOnMissingOutput(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	completed := uploadTestPhotoForDerivatives(t, app)
	app.derivativeProcessor = &fakePhotosDerivativeProcessor{omitKind: "preview"}

	processed, err := app.runNextPhotoDerivativeJob(context.Background())
	if err != nil || !processed {
		t.Fatalf("processed=%v err=%v", processed, err)
	}
	var assetState, jobStatus string
	var attempts int
	var nextAttempt sql.NullString
	if err = app.db.QueryRow(
		`SELECT a.derivative_state,j.status,j.attempt_count,j.next_attempt_at
		 FROM photo_assets a JOIN photo_derivative_jobs j ON j.asset_id=a.id
		 WHERE a.id=?`,
		completed.AssetID,
	).Scan(&assetState, &jobStatus, &attempts, &nextAttempt); err != nil {
		t.Fatal(err)
	}
	if assetState != photosDerivativeStateFailed ||
		jobStatus != photosDerivativeJobFailed ||
		attempts != 1 ||
		!nextAttempt.Valid {
		t.Fatalf(
			"missing output state=(%q,%q,%d,%v)",
			assetState,
			jobStatus,
			attempts,
			nextAttempt,
		)
	}
	var derivatives int
	if err = app.db.QueryRow(
		"SELECT COUNT(*) FROM photo_derivatives WHERE asset_id=?",
		completed.AssetID,
	).Scan(&derivatives); err != nil {
		t.Fatal(err)
	}
	if derivatives != 0 {
		t.Fatalf("missing required output committed %d derivatives", derivatives)
	}
}

func TestPhotosCapabilitiesAdvertiseRecipesOnlyWithProcessor(t *testing.T) {
	app := newPhotosPhase2TestApp(t)
	app.derivativeProcessor = &fakePhotosDerivativeProcessor{failure: errors.New("unused")}
	recorder := httptest.NewRecorder()
	app.photosCapabilities(
		recorder,
		tailscaleRequest(http.MethodGet, "/api/v1/photos/capabilities"),
	)
	var capabilities photosCapabilitiesResponse
	if err := json.NewDecoder(recorder.Body).Decode(&capabilities); err != nil {
		t.Fatal(err)
	}
	if len(capabilities.DerivativeRecipes) != len(photosBrowseRecipesV1) {
		t.Fatalf("advertised recipes=%v", capabilities.DerivativeRecipes)
	}
}

func uploadTestPhotoForDerivatives(
	t *testing.T,
	app *App,
) photosUploadSessionResponse {
	t.Helper()
	payload := []byte("immutable-photo-source")
	input := testPhotoUploadInput(payload, nil)
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

func testCommittedPhotoSource(t *testing.T, app *App, assetID string) (string, string) {
	t.Helper()
	var storagePath, hash string
	if err := app.db.QueryRow(
		`SELECT storage_path,sha256 FROM photo_resources
		 WHERE asset_id=? ORDER BY resource_role LIMIT 1`,
		assetID,
	).Scan(&storagePath, &hash); err != nil {
		t.Fatal(err)
	}
	return filepath.Join(app.c.Root, filepath.FromSlash(storagePath)), hash
}
