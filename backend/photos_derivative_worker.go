package main

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"image/jpeg"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const (
	photosDerivativeJobProcessing = "processing"
	photosDerivativeJobCompleted  = "completed"
	photosDerivativeJobFailed     = "failed"
	photosDerivativeMaxAttempts   = 5
)

type photosDerivativeProcessor interface {
	Process(context.Context, photosDerivativeRequest) (photosDerivativeResult, error)
}

type photosDerivativeRequest struct {
	AssetID        string
	MediaType      string
	Duration       float64
	FinalDirectory string
	Sources        []photosDerivativeSource
	Recipes        []photosDerivativeRecipe
}

type photosDerivativeSource struct {
	Path         string
	StoragePath  string
	ResourceRole string
	ContentType  string
	SHA256       string
}

type photosGeneratedDerivative struct {
	Kind        string
	RecipeID    string
	Path        string
	ContentType string
	PixelWidth  int
	PixelHeight int
	ByteSize    int64
	SHA256      string
}

type photosDerivativeResult struct {
	SourcePath string
	Outputs    []photosGeneratedDerivative
}

type photosDerivativeJobRow struct {
	ID            string
	AssetID       string
	OwnerUserID   string
	VolumeID      string
	RecipeVersion string
	AttemptCount  int
	MediaType     string
	Fingerprint   string
	Duration      float64
}

type ffmpegPhotosDerivativeProcessor struct {
	executable string
}

type cappedPhotosDiagnosticWriter struct {
	buffer    *bytes.Buffer
	remaining int
}

func (writer *cappedPhotosDiagnosticWriter) Write(data []byte) (int, error) {
	originalLength := len(data)
	if writer.remaining <= 0 {
		return originalLength, nil
	}
	if len(data) > writer.remaining {
		data = data[:writer.remaining]
	}
	_, _ = writer.buffer.Write(data)
	writer.remaining -= len(data)
	return originalLength, nil
}

func (a *App) startPhotoDerivativeWorker() error {
	if a.db == nil {
		return nil
	}
	if err := a.recoverInterruptedPhotoDerivativeJobs(); err != nil {
		return err
	}
	executable, err := exec.LookPath("ffmpeg")
	if err != nil {
		log.Printf("photos derivative worker paused: ffmpeg is unavailable")
		return nil
	}
	a.derivativeProcessor = &ffmpegPhotosDerivativeProcessor{executable: executable}
	a.derivativeWake = make(chan struct{}, 1)
	go a.runPhotoDerivativeWorker()
	a.wakePhotoDerivativeWorker()
	return nil
}

func (a *App) wakePhotoDerivativeWorker() {
	if a.derivativeWake == nil {
		return
	}
	select {
	case a.derivativeWake <- struct{}{}:
	default:
	}
}

func (a *App) runPhotoDerivativeWorker() {
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()
	for {
		processed, err := a.runNextPhotoDerivativeJob(context.Background())
		if err != nil {
			log.Printf("photos derivative worker: %v", err)
		}
		if processed {
			continue
		}
		select {
		case <-a.derivativeWake:
		case <-ticker.C:
		}
	}
}

func (a *App) runNextPhotoDerivativeJob(ctx context.Context) (bool, error) {
	if a.derivativeProcessor == nil {
		return false, nil
	}
	job, found, err := a.claimPhotoDerivativeJob()
	if err != nil || !found {
		return found, err
	}
	if err = a.processPhotoDerivativeJob(ctx, job); err != nil {
		if failErr := a.failPhotoDerivativeJob(job, err); failErr != nil {
			return true, fmt.Errorf("process job %s: %v; persist failure: %w", job.ID, err, failErr)
		}
		return true, nil
	}
	return true, nil
}

func (a *App) claimPhotoDerivativeJob() (photosDerivativeJobRow, bool, error) {
	now := time.Now().UTC().Format(time.RFC3339Nano)
	transaction, err := a.db.Begin()
	if err != nil {
		return photosDerivativeJobRow{}, false, err
	}
	defer transaction.Rollback()

	var job photosDerivativeJobRow
	err = transaction.QueryRow(
		`SELECT j.id,j.asset_id,j.owner_user_id,j.volume_id,j.recipe_version,j.attempt_count,
		        a.media_type,a.content_fingerprint,a.duration
		 FROM photo_derivative_jobs j
		 JOIN photo_assets a ON a.id=j.asset_id AND a.owner_user_id=j.owner_user_id
		 WHERE j.recipe_version=?
		   AND j.attempt_count<?
		   AND j.status IN (?,?)
		   AND (j.next_attempt_at IS NULL OR j.next_attempt_at<=?)
		   AND a.source_state=?
		   AND a.derivative_state<>?
		 ORDER BY COALESCE(j.next_attempt_at,j.created),j.created,j.id
		 LIMIT 1`,
		photosDerivativePolicyVersion,
		photosDerivativeMaxAttempts,
		photosDerivativeJobPending,
		photosDerivativeJobFailed,
		now,
		photosSourceStateCommitted,
		photosDerivativeStateReady,
	).Scan(
		&job.ID,
		&job.AssetID,
		&job.OwnerUserID,
		&job.VolumeID,
		&job.RecipeVersion,
		&job.AttemptCount,
		&job.MediaType,
		&job.Fingerprint,
		&job.Duration,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return photosDerivativeJobRow{}, false, nil
	}
	if err != nil {
		return photosDerivativeJobRow{}, false, err
	}
	result, err := transaction.Exec(
		`UPDATE photo_derivative_jobs
		 SET status=?,last_error=NULL,next_attempt_at=NULL,updated=?
		 WHERE id=? AND status IN (?,?)`,
		photosDerivativeJobProcessing,
		now,
		job.ID,
		photosDerivativeJobPending,
		photosDerivativeJobFailed,
	)
	if err != nil {
		return photosDerivativeJobRow{}, false, err
	}
	changed, err := result.RowsAffected()
	if err != nil || changed != 1 {
		if err == nil {
			err = errors.New("derivative job was claimed concurrently")
		}
		return photosDerivativeJobRow{}, false, err
	}
	if _, err = transaction.Exec(
		`UPDATE photo_assets
		 SET derivative_state=?,derivative_error=NULL,derivative_updated=?,updated=?
		 WHERE id=? AND owner_user_id=?`,
		photosDerivativeStateProcessing,
		now,
		now,
		job.AssetID,
		job.OwnerUserID,
	); err != nil {
		return photosDerivativeJobRow{}, false, err
	}
	if err = transaction.Commit(); err != nil {
		return photosDerivativeJobRow{}, false, err
	}
	return job, true, nil
}

func (a *App) processPhotoDerivativeJob(ctx context.Context, job photosDerivativeJobRow) error {
	volume, err := a.volumeByID(job.VolumeID)
	if err != nil || volume.Status != "online" {
		return errors.New("selected volume is offline")
	}
	sources, err := a.photoDerivativeSources(job, volume)
	if err != nil {
		return err
	}
	if len(sources) == 0 {
		return fmt.Errorf("no decodable source resource for %s", job.MediaType)
	}
	for _, source := range sources {
		hash, hashErr := sha256File(source.Path)
		if hashErr != nil {
			return fmt.Errorf("verify source %s: %w", source.ResourceRole, hashErr)
		}
		if hash != source.SHA256 {
			return fmt.Errorf("source checksum mismatch for %s", source.ResourceRole)
		}
	}

	finalDirectory := filepath.Join(
		volume.Mount,
		"users",
		photosOwnerPathComponent(job.OwnerUserID),
		"photos",
		"derivatives",
		job.Fingerprint[:2],
		job.AssetID,
		job.RecipeVersion,
	)
	result, err := a.derivativeProcessor.Process(ctx, photosDerivativeRequest{
		AssetID:        job.AssetID,
		MediaType:      job.MediaType,
		Duration:       job.Duration,
		FinalDirectory: finalDirectory,
		Sources:        sources,
		Recipes:        photosBrowseRecipesV1,
	})
	if err != nil {
		return err
	}
	selectedSource, found := derivativeSourceByPath(sources, result.SourcePath)
	if !found {
		return errors.New("processor returned an unknown source")
	}
	hash, err := sha256File(selectedSource.Path)
	if err != nil || hash != selectedSource.SHA256 {
		return errors.New("source changed while generating derivatives")
	}
	outputs, err := validatePhotosDerivativeOutputs(result.Outputs, finalDirectory, job.RecipeVersion)
	if err != nil {
		return err
	}
	return a.completePhotoDerivativeJob(job, volume, outputs)
}

func (a *App) photoDerivativeSources(
	job photosDerivativeJobRow,
	volume Volume,
) ([]photosDerivativeSource, error) {
	rows, err := a.db.Query(
		`SELECT resource_role,content_type,sha256,storage_path
		 FROM photo_resources
		 WHERE asset_id=? AND owner_user_id=? AND volume_id=?`,
		job.AssetID,
		job.OwnerUserID,
		job.VolumeID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	sources := make([]photosDerivativeSource, 0)
	for rows.Next() {
		var source photosDerivativeSource
		if err = rows.Scan(
			&source.ResourceRole,
			&source.ContentType,
			&source.SHA256,
			&source.StoragePath,
		); err != nil {
			return nil, err
		}
		if !photoResourceCanRender(job.MediaType, source.ResourceRole, source.ContentType, source.StoragePath) {
			continue
		}
		source.Path, err = resolveWithin(volume.Mount, source.StoragePath, false)
		if err != nil {
			return nil, fmt.Errorf("resolve derivative source: %w", err)
		}
		sources = append(sources, source)
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	sort.SliceStable(sources, func(i, j int) bool {
		return photoDerivativeSourcePriority(job.MediaType, sources[i].ResourceRole) <
			photoDerivativeSourcePriority(job.MediaType, sources[j].ResourceRole)
	})
	return sources, nil
}

func photoResourceCanRender(mediaType, role, contentType, storagePath string) bool {
	role = strings.ToLower(role)
	contentType = strings.ToLower(contentType)
	extension := strings.ToLower(filepath.Ext(storagePath))
	if mediaType == "video" {
		if strings.Contains(role, "paired") {
			return false
		}
		return strings.Contains(role, "video") ||
			strings.Contains(contentType, "video") ||
			extension == ".mov" || extension == ".mp4" || extension == ".m4v"
	}
	if strings.Contains(role, "paired") || strings.Contains(role, "video") ||
		role == "adjustmentdata" || role == "audio" {
		return false
	}
	return strings.Contains(role, "photo") ||
		strings.Contains(contentType, "image") ||
		strings.Contains(contentType, "heic") ||
		strings.Contains(contentType, "raw") ||
		extension == ".heic" || extension == ".heif" || extension == ".jpg" ||
		extension == ".jpeg" || extension == ".png" || extension == ".dng"
}

func photoDerivativeSourcePriority(mediaType, role string) int {
	role = strings.ToLower(role)
	priorities := map[string]int{
		"fullsizephoto":       0,
		"photo":               1,
		"alternatephoto":      2,
		"adjustmentbasephoto": 3,
		"photoproxy":          4,
	}
	if mediaType == "video" {
		priorities = map[string]int{
			"fullsizevideo":       0,
			"video":               1,
			"adjustmentbasevideo": 2,
		}
	}
	if priority, ok := priorities[role]; ok {
		return priority
	}
	return 100
}

func derivativeSourceByPath(
	sources []photosDerivativeSource,
	path string,
) (photosDerivativeSource, bool) {
	cleaned := filepath.Clean(path)
	for _, source := range sources {
		if filepath.Clean(source.Path) == cleaned {
			return source, true
		}
	}
	return photosDerivativeSource{}, false
}

func validatePhotosDerivativeOutputs(
	outputs []photosGeneratedDerivative,
	finalDirectory string,
	recipeVersion string,
) ([]photosGeneratedDerivative, error) {
	required := map[string]photosDerivativeRecipe{}
	for _, recipe := range photosBrowseRecipesV1 {
		if recipe.RequiredForBrowse {
			required[recipe.Kind] = recipe
		}
	}
	validated := make([]photosGeneratedDerivative, 0, len(outputs))
	seen := map[string]bool{}
	for _, output := range outputs {
		recipe, ok := required[output.Kind]
		if !ok || seen[output.Kind] || output.RecipeID != recipe.ID {
			return nil, fmt.Errorf("unexpected derivative output %q", output.Kind)
		}
		seen[output.Kind] = true
		if !pathIsWithin(finalDirectory, output.Path) {
			return nil, fmt.Errorf("derivative output escaped its asset directory")
		}
		file, err := os.Open(output.Path)
		if err != nil {
			return nil, err
		}
		config, decodeErr := jpeg.DecodeConfig(file)
		closeErr := file.Close()
		if decodeErr != nil || closeErr != nil {
			return nil, fmt.Errorf("invalid JPEG derivative %q", output.Kind)
		}
		info, err := os.Stat(output.Path)
		if err != nil || info.Size() <= 0 {
			return nil, fmt.Errorf("empty derivative %q", output.Kind)
		}
		hash, err := sha256File(output.Path)
		if err != nil || hash != output.SHA256 {
			return nil, fmt.Errorf("derivative checksum mismatch for %q", output.Kind)
		}
		if output.ContentType != "image/jpeg" ||
			output.ByteSize != info.Size() ||
			output.PixelWidth != config.Width ||
			output.PixelHeight != config.Height {
			return nil, fmt.Errorf("derivative metadata mismatch for %q", output.Kind)
		}
		if recipe.ResizeMode == "centerCrop" &&
			(config.Width != recipe.MaxPixelDimension || config.Height != recipe.MaxPixelDimension) {
			return nil, fmt.Errorf("derivative dimensions do not match recipe for %q", output.Kind)
		}
		if recipe.ResizeMode == "aspectFit" &&
			(config.Width > recipe.MaxPixelDimension || config.Height > recipe.MaxPixelDimension) {
			return nil, fmt.Errorf("derivative exceeds recipe bounds for %q", output.Kind)
		}
		validated = append(validated, output)
	}
	if len(seen) != len(required) {
		return nil, errors.New("required derivative output is missing")
	}
	sort.Slice(validated, func(i, j int) bool { return validated[i].Kind < validated[j].Kind })
	return validated, nil
}

func pathIsWithin(root, path string) bool {
	relative, err := filepath.Rel(filepath.Clean(root), filepath.Clean(path))
	return err == nil && relative != "." && relative != ".." &&
		!strings.HasPrefix(relative, ".."+string(os.PathSeparator))
}

func (a *App) completePhotoDerivativeJob(
	job photosDerivativeJobRow,
	volume Volume,
	outputs []photosGeneratedDerivative,
) error {
	now := time.Now().UTC().Format(time.RFC3339Nano)
	transaction, err := a.db.Begin()
	if err != nil {
		return err
	}
	defer transaction.Rollback()
	for _, output := range outputs {
		storagePath, pathErr := filepath.Rel(volume.Mount, output.Path)
		if pathErr != nil || strings.HasPrefix(storagePath, "..") {
			if pathErr == nil {
				pathErr = errors.New("derivative path is outside its volume")
			}
			return pathErr
		}
		derivativeID := "pdr_" + job.AssetID + "_" + output.Kind + "_" + job.RecipeVersion
		if _, err = transaction.Exec(
			`INSERT INTO photo_derivatives(
				id,asset_id,owner_user_id,volume_id,kind,recipe_id,recipe_version,status,
				content_type,pixel_width,pixel_height,byte_size,sha256,storage_path,error,created,updated
			 ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL,?,?)
			 ON CONFLICT(asset_id,kind,recipe_version)
			 DO UPDATE SET recipe_id=excluded.recipe_id,status=excluded.status,
			   content_type=excluded.content_type,pixel_width=excluded.pixel_width,
			   pixel_height=excluded.pixel_height,byte_size=excluded.byte_size,
			   sha256=excluded.sha256,storage_path=excluded.storage_path,error=NULL,
			   updated=excluded.updated`,
			derivativeID,
			job.AssetID,
			job.OwnerUserID,
			job.VolumeID,
			output.Kind,
			output.RecipeID,
			job.RecipeVersion,
			photosDerivativeStateReady,
			output.ContentType,
			output.PixelWidth,
			output.PixelHeight,
			output.ByteSize,
			output.SHA256,
			filepath.ToSlash(storagePath),
			now,
			now,
		); err != nil {
			return err
		}
	}
	if _, err = transaction.Exec(
		`UPDATE photo_derivative_jobs
		 SET status=?,last_error=NULL,next_attempt_at=NULL,updated=?
		 WHERE id=?`,
		photosDerivativeJobCompleted,
		now,
		job.ID,
	); err != nil {
		return err
	}
	if _, err = transaction.Exec(
		`UPDATE photo_assets
		 SET derivative_state=?,derivative_error=NULL,derivative_updated=?,updated=?
		 WHERE id=? AND owner_user_id=?`,
		photosDerivativeStateReady,
		now,
		now,
		job.AssetID,
		job.OwnerUserID,
	); err != nil {
		return err
	}
	return transaction.Commit()
}

func (a *App) failPhotoDerivativeJob(job photosDerivativeJobRow, failure error) error {
	attempts := job.AttemptCount + 1
	var nextAttempt any
	if attempts < photosDerivativeMaxAttempts {
		nextAttempt = time.Now().UTC().
			Add(photoDerivativeRetryDelay(attempts)).
			Format(time.RFC3339Nano)
	}
	message := strings.TrimSpace(failure.Error())
	if len(message) > 1000 {
		message = message[:1000]
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	transaction, err := a.db.Begin()
	if err != nil {
		return err
	}
	defer transaction.Rollback()
	if _, err = transaction.Exec(
		`UPDATE photo_derivative_jobs
		 SET status=?,attempt_count=?,last_error=?,next_attempt_at=?,updated=?
		 WHERE id=?`,
		photosDerivativeJobFailed,
		attempts,
		message,
		nextAttempt,
		now,
		job.ID,
	); err != nil {
		return err
	}
	if _, err = transaction.Exec(
		`UPDATE photo_assets
		 SET derivative_state=?,derivative_error=?,derivative_updated=?,updated=?
		 WHERE id=? AND owner_user_id=?`,
		photosDerivativeStateFailed,
		message,
		now,
		now,
		job.AssetID,
		job.OwnerUserID,
	); err != nil {
		return err
	}
	return transaction.Commit()
}

func photoDerivativeRetryDelay(attempt int) time.Duration {
	delays := []time.Duration{
		15 * time.Second,
		time.Minute,
		5 * time.Minute,
		30 * time.Minute,
	}
	if attempt <= 0 {
		return delays[0]
	}
	if attempt > len(delays) {
		return delays[len(delays)-1]
	}
	return delays[attempt-1]
}

func (a *App) recoverInterruptedPhotoDerivativeJobs() error {
	now := time.Now().UTC().Format(time.RFC3339Nano)
	transaction, err := a.db.Begin()
	if err != nil {
		return err
	}
	defer transaction.Rollback()
	if _, err = transaction.Exec(
		`UPDATE photo_derivative_jobs
		 SET status=?,last_error='server restarted during derivative generation',
		     next_attempt_at=NULL,updated=?
		 WHERE status=?`,
		photosDerivativeJobPending,
		now,
		photosDerivativeJobProcessing,
	); err != nil {
		return err
	}
	if _, err = transaction.Exec(
		`UPDATE photo_assets
		 SET derivative_state=?,derivative_error=NULL,derivative_updated=?,updated=?
		 WHERE derivative_state=?
		   AND EXISTS(
		     SELECT 1 FROM photo_derivative_jobs j
		     WHERE j.asset_id=photo_assets.id AND j.status=?
		   )`,
		photosDerivativeStatePending,
		now,
		now,
		photosDerivativeStateProcessing,
		photosDerivativeJobPending,
	); err != nil {
		return err
	}
	return transaction.Commit()
}

func (p *ffmpegPhotosDerivativeProcessor) Process(
	ctx context.Context,
	request photosDerivativeRequest,
) (photosDerivativeResult, error) {
	if len(request.Sources) == 0 {
		return photosDerivativeResult{}, errors.New("no derivative source")
	}
	if outputs, err := inspectPhotosDerivativeDirectory(request.FinalDirectory, request.Recipes); err == nil {
		return photosDerivativeResult{SourcePath: request.Sources[0].Path, Outputs: outputs}, nil
	}
	parent := filepath.Dir(request.FinalDirectory)
	if err := os.MkdirAll(parent, 0700); err != nil {
		return photosDerivativeResult{}, err
	}
	var failures []string
	for _, source := range request.Sources {
		workDirectory, err := os.MkdirTemp(parent, ".derivative-"+request.AssetID+"-")
		if err != nil {
			return photosDerivativeResult{}, err
		}
		generateErr := p.generateAll(ctx, request, source, workDirectory)
		if generateErr != nil {
			_ = os.RemoveAll(workDirectory)
			failures = append(failures, source.ResourceRole+": "+generateErr.Error())
			continue
		}
		staleDirectory := request.FinalDirectory + ".stale"
		_ = os.RemoveAll(staleDirectory)
		if _, statErr := os.Stat(request.FinalDirectory); statErr == nil {
			if err = os.Rename(request.FinalDirectory, staleDirectory); err != nil {
				_ = os.RemoveAll(workDirectory)
				return photosDerivativeResult{}, err
			}
		} else if !os.IsNotExist(statErr) {
			_ = os.RemoveAll(workDirectory)
			return photosDerivativeResult{}, statErr
		}
		if err = os.Rename(workDirectory, request.FinalDirectory); err != nil {
			_ = os.Rename(staleDirectory, request.FinalDirectory)
			_ = os.RemoveAll(workDirectory)
			return photosDerivativeResult{}, err
		}
		_ = os.RemoveAll(staleDirectory)
		outputs, err := inspectPhotosDerivativeDirectory(request.FinalDirectory, request.Recipes)
		if err != nil {
			return photosDerivativeResult{}, err
		}
		return photosDerivativeResult{SourcePath: source.Path, Outputs: outputs}, nil
	}
	return photosDerivativeResult{}, fmt.Errorf(
		"ffmpeg could not decode any candidate: %s",
		strings.Join(failures, "; "),
	)
}

func (p *ffmpegPhotosDerivativeProcessor) generateAll(
	ctx context.Context,
	request photosDerivativeRequest,
	source photosDerivativeSource,
	workDirectory string,
) error {
	for _, recipe := range request.Recipes {
		output := filepath.Join(workDirectory, recipe.Kind+".jpg")
		commandContext, cancel := context.WithTimeout(ctx, 5*time.Minute)
		args := []string{"-nostdin", "-hide_banner", "-loglevel", "error", "-y"}
		if request.MediaType == "video" && request.Duration >= 2 {
			args = append(args, "-ss", "1")
		}
		args = append(
			args,
			"-i", source.Path,
			"-frames:v", "1",
			"-an",
			"-sn",
			"-map_metadata", "-1",
			"-threads", "1",
			"-vf", photosDerivativeFilter(recipe),
			"-q:v", "3",
			"-f", "image2",
			output,
		)
		command := exec.CommandContext(commandContext, p.executable, args...)
		var diagnostics bytes.Buffer
		diagnosticWriter := &cappedPhotosDiagnosticWriter{
			buffer:    &diagnostics,
			remaining: 16 * 1024,
		}
		command.Stdout = diagnosticWriter
		command.Stderr = diagnosticWriter
		err := command.Run()
		cancel()
		if err != nil {
			return fmt.Errorf("%s: %w: %s", recipe.Kind, err, strings.TrimSpace(diagnostics.String()))
		}
		if info, statErr := os.Stat(output); statErr != nil || info.Size() <= 0 {
			return fmt.Errorf("%s: ffmpeg produced no output", recipe.Kind)
		}
	}
	return nil
}

func photosDerivativeFilter(recipe photosDerivativeRecipe) string {
	switch recipe.ResizeMode {
	case "centerCrop":
		return fmt.Sprintf(
			"scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d,setsar=1",
			recipe.MaxPixelDimension,
			recipe.MaxPixelDimension,
			recipe.MaxPixelDimension,
			recipe.MaxPixelDimension,
		)
	default:
		return fmt.Sprintf(
			"scale='min(%d,iw)':'min(%d,ih)':force_original_aspect_ratio=decrease,setsar=1",
			recipe.MaxPixelDimension,
			recipe.MaxPixelDimension,
		)
	}
}

func inspectPhotosDerivativeDirectory(
	directory string,
	recipes []photosDerivativeRecipe,
) ([]photosGeneratedDerivative, error) {
	outputs := make([]photosGeneratedDerivative, 0, len(recipes))
	for _, recipe := range recipes {
		path := filepath.Join(directory, recipe.Kind+".jpg")
		file, err := os.Open(path)
		if err != nil {
			return nil, err
		}
		config, decodeErr := jpeg.DecodeConfig(file)
		closeErr := file.Close()
		if decodeErr != nil || closeErr != nil {
			return nil, fmt.Errorf("inspect %s derivative: invalid JPEG", recipe.Kind)
		}
		info, err := os.Stat(path)
		if err != nil || info.Size() <= 0 {
			return nil, fmt.Errorf("inspect %s derivative: empty output", recipe.Kind)
		}
		hash, err := sha256File(path)
		if err != nil {
			return nil, err
		}
		outputs = append(outputs, photosGeneratedDerivative{
			Kind:        recipe.Kind,
			RecipeID:    recipe.ID,
			Path:        path,
			ContentType: "image/jpeg",
			PixelWidth:  config.Width,
			PixelHeight: config.Height,
			ByteSize:    info.Size(),
			SHA256:      hash,
		})
	}
	return outputs, nil
}
