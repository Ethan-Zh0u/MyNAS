package main

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	photosUploadChunkSize = int64(4 * 1024 * 1024)
	photosMaxResourceSize = int64(1 << 40)
)

type photosUploadResourceInput struct {
	ClientResourceID string `json:"clientResourceID"`
	ResourceRole     string `json:"resourceRole"`
	OriginalFilename string `json:"originalFilename"`
	ContentType      string `json:"contentType"`
	ByteSize         int64  `json:"byteSize"`
	SHA256           string `json:"sha256"`
}

type photosUploadSessionInput struct {
	VolumeID         string                      `json:"volumeID"`
	DeviceID         string                      `json:"deviceID"`
	LocalIdentifier  string                      `json:"localIdentifier"`
	Fingerprint      string                      `json:"fingerprint"`
	MediaType        string                      `json:"mediaType"`
	CaptureDate      *string                     `json:"captureDate"`
	ModificationDate *string                     `json:"modificationDate"`
	PixelWidth       int                         `json:"pixelWidth"`
	PixelHeight      int                         `json:"pixelHeight"`
	Duration         float64                     `json:"duration"`
	Favorite         bool                        `json:"favorite"`
	Resources        []photosUploadResourceInput `json:"resources"`
}

type photosUploadResourceResponse struct {
	ID               string `json:"id"`
	ClientResourceID string `json:"clientResourceID"`
	ResourceRole     string `json:"resourceRole"`
	OriginalFilename string `json:"originalFilename"`
	ContentType      string `json:"contentType"`
	ByteSize         int64  `json:"byteSize"`
	SHA256           string `json:"sha256"`
	ReceivedBytes    int64  `json:"receivedBytes"`
	ChunkSize        int64  `json:"chunkSize"`
	Status           string `json:"status"`
}

type photosUploadSessionResponse struct {
	ID              string                         `json:"id,omitempty"`
	AssetID         string                         `json:"assetID"`
	Status          string                         `json:"status"`
	SourceState     string                         `json:"sourceState,omitempty"`
	DerivativeState string                         `json:"derivativeState,omitempty"`
	BrowseReady     bool                           `json:"browseReady"`
	Fingerprint     string                         `json:"fingerprint"`
	TotalBytes      int64                          `json:"totalBytes"`
	ReceivedBytes   int64                          `json:"receivedBytes"`
	Resources       []photosUploadResourceResponse `json:"resources"`
}

type photosUploadSessionRow struct {
	ID               string
	OwnerUserID      string
	VolumeID         string
	DeviceID         string
	LocalIdentifier  string
	Fingerprint      string
	AssetID          string
	MediaType        string
	Status           string
	CaptureDate      sql.NullString
	ModificationDate sql.NullString
	PixelWidth       int
	PixelHeight      int
	Duration         float64
	Favorite         bool
	StageDir         string
	Created          string
	Updated          string
}

type photosUploadResourceRow struct {
	ID               string
	UploadSessionID  string
	ClientResourceID string
	ResourceRole     string
	OriginalFilename string
	ContentType      string
	ByteSize         int64
	SHA256           string
	StageName        string
	Received         int64
	ChunkSize        int64
	Status           string
}

func (a *App) photosUploadSessions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	owner, ok := a.photosRequestOwner(w, r)
	if !ok {
		return
	}

	var input photosUploadSessionInput
	if err := readJSON(r, &input); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if err := validatePhotosUploadInput(&input); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if expected := photoManifestFingerprint(input.Resources); input.Fingerprint != expected {
		http.Error(w, "fingerprint does not match resource manifest", http.StatusBadRequest)
		return
	}

	volume, err := a.volumeByID(input.VolumeID)
	if err != nil || volume.Status != "online" {
		http.Error(w, "selected volume is offline or unavailable", http.StatusConflict)
		return
	}
	var totalBytes int64
	for _, resource := range input.Resources {
		totalBytes += resource.ByteSize
	}
	if uint64(totalBytes) > volume.Free {
		http.Error(w, "insufficient space", http.StatusConflict)
		return
	}

	if assetID, found, lookupErr := a.findBackedUpPhotoAsset(owner.UserID, input.VolumeID, input.DeviceID, input.LocalIdentifier, input.Fingerprint); lookupErr != nil {
		http.Error(w, "photo deduplication unavailable", http.StatusInternalServerError)
		return
	} else if found {
		_ = a.upsertDeviceAssetMapping(owner.UserID, input.DeviceID, input.LocalIdentifier, input.Fingerprint, assetID)
		sourceState, derivativeState, stateErr := a.photoAssetStates(assetID, owner.UserID)
		if stateErr != nil {
			http.Error(w, "photo state unavailable", http.StatusInternalServerError)
			return
		}
		writeJSON(w, photosUploadSessionResponse{
			AssetID: assetID, Status: "duplicate", Fingerprint: input.Fingerprint,
			SourceState: sourceState, DerivativeState: derivativeState,
			BrowseReady: derivativeState == photosDerivativeStateReady,
			TotalBytes:  totalBytes, ReceivedBytes: totalBytes, Resources: []photosUploadResourceResponse{},
		})
		return
	}

	var existingID string
	err = a.db.QueryRow(
		`SELECT id FROM photo_upload_sessions
		 WHERE owner_user_id=? AND device_id=? AND local_identifier=? AND fingerprint=?`,
		owner.UserID, input.DeviceID, input.LocalIdentifier, input.Fingerprint,
	).Scan(&existingID)
	if err == nil {
		response, responseErr := a.photoUploadSessionResponse(existingID, owner.UserID)
		if responseErr != nil {
			http.Error(w, "upload session unavailable", http.StatusInternalServerError)
			return
		}
		writeJSON(w, response)
		return
	}
	if !errors.Is(err, sql.ErrNoRows) {
		http.Error(w, "upload session unavailable", http.StatusInternalServerError)
		return
	}

	sessionID, err := newOpaqueID("pus")
	if err != nil {
		http.Error(w, "cannot create upload session", http.StatusInternalServerError)
		return
	}
	assetID, err := newOpaqueID("ast")
	if err != nil {
		http.Error(w, "cannot create asset identity", http.StatusInternalServerError)
		return
	}
	stageDir := filepath.Join(volume.Mount, ".mynas", "photos-staging", sessionID)
	if err = os.MkdirAll(stageDir, 0700); err != nil {
		http.Error(w, "cannot prepare upload staging", http.StatusInternalServerError)
		return
	}

	now := time.Now().UTC().Format(time.RFC3339Nano)
	transaction, err := a.db.Begin()
	if err != nil {
		_ = os.RemoveAll(stageDir)
		http.Error(w, "cannot begin upload session", http.StatusInternalServerError)
		return
	}
	defer transaction.Rollback()
	_, err = transaction.Exec(
		`INSERT INTO photo_upload_sessions(
			id,owner_user_id,volume_id,device_id,local_identifier,fingerprint,asset_id,media_type,status,
			capture_date,modification_date,pixel_width,pixel_height,duration,favorite,stage_dir,created,updated
		) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		sessionID, owner.UserID, input.VolumeID, input.DeviceID, input.LocalIdentifier, input.Fingerprint,
		assetID, input.MediaType, "waiting", nullableString(input.CaptureDate), nullableString(input.ModificationDate),
		input.PixelWidth, input.PixelHeight, input.Duration, input.Favorite, stageDir, now, now,
	)
	if err != nil {
		_ = os.RemoveAll(stageDir)
		http.Error(w, "cannot save upload session", http.StatusInternalServerError)
		return
	}
	for index, resource := range input.Resources {
		resourceID, idErr := newOpaqueID("pur")
		if idErr != nil {
			_ = os.RemoveAll(stageDir)
			http.Error(w, "cannot create resource identity", http.StatusInternalServerError)
			return
		}
		stageName := fmt.Sprintf("%03d-%s", index, resource.OriginalFilename)
		stagePath := filepath.Join(stageDir, stageName)
		file, createErr := os.OpenFile(stagePath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if createErr == nil {
			createErr = file.Close()
		}
		if createErr != nil {
			_ = os.RemoveAll(stageDir)
			http.Error(w, "cannot prepare resource staging", http.StatusInternalServerError)
			return
		}
		status := "waiting"
		if resource.ByteSize == 0 {
			status = "uploaded"
		}
		_, err = transaction.Exec(
			`INSERT INTO photo_upload_resources(
				id,upload_session_id,client_resource_id,resource_role,original_filename,content_type,
				byte_size,sha256,stage_name,received,chunk_size,status,created,updated
			) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
			resourceID, sessionID, resource.ClientResourceID, resource.ResourceRole,
			resource.OriginalFilename, resource.ContentType, resource.ByteSize, resource.SHA256,
			stageName, 0, photosUploadChunkSize, status, now, now,
		)
		if err != nil {
			_ = os.RemoveAll(stageDir)
			http.Error(w, "cannot save upload resources", http.StatusInternalServerError)
			return
		}
	}
	if err = transaction.Commit(); err != nil {
		_ = os.RemoveAll(stageDir)
		http.Error(w, "cannot commit upload session", http.StatusInternalServerError)
		return
	}
	response, err := a.photoUploadSessionResponse(sessionID, owner.UserID)
	if err != nil {
		http.Error(w, "upload session unavailable", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(response)
}

func (a *App) photosUploadSessionByPath(w http.ResponseWriter, r *http.Request) {
	owner, ok := a.photosRequestOwner(w, r)
	if !ok {
		return
	}
	path := strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/v1/photos/upload-sessions/"), "/")
	parts := strings.Split(path, "/")
	if len(parts) == 1 && r.Method == http.MethodGet {
		response, err := a.photoUploadSessionResponse(parts[0], owner.UserID)
		if errors.Is(err, sql.ErrNoRows) {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		if err != nil {
			http.Error(w, "upload session unavailable", http.StatusInternalServerError)
			return
		}
		writeJSON(w, response)
		return
	}
	if len(parts) == 2 && parts[1] == "complete" && r.Method == http.MethodPost {
		a.completePhotoUploadSession(w, owner.UserID, parts[0])
		return
	}
	if len(parts) == 5 && parts[1] == "resources" && parts[3] == "parts" && r.Method == http.MethodPut {
		partNumber, err := strconv.ParseInt(parts[4], 10, 64)
		if err != nil || partNumber < 0 {
			http.Error(w, "invalid part number", http.StatusBadRequest)
			return
		}
		a.putPhotoUploadPart(w, r, owner.UserID, parts[0], parts[2], partNumber)
		return
	}
	http.Error(w, "method or path", http.StatusMethodNotAllowed)
}

func (a *App) putPhotoUploadPart(
	w http.ResponseWriter,
	r *http.Request,
	ownerUserID string,
	sessionID string,
	resourceID string,
	partNumber int64,
) {
	session, resource, err := a.photoUploadResource(sessionID, resourceID, ownerUserID)
	if errors.Is(err, sql.ErrNoRows) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if err != nil {
		http.Error(w, "upload resource unavailable", http.StatusInternalServerError)
		return
	}
	if session.Status == "completed" {
		response, _ := a.photoUploadSessionResponse(sessionID, ownerUserID)
		writeJSON(w, response)
		return
	}
	if session.Status == "failed" {
		http.Error(w, "upload session failed", http.StatusConflict)
		return
	}

	offset, err := strconv.ParseInt(r.Header.Get("X-Upload-Offset"), 10, 64)
	expectedOffset := partNumber * resource.ChunkSize
	if err != nil || offset != expectedOffset {
		http.Error(w, "invalid upload offset", http.StatusBadRequest)
		return
	}
	if offset < resource.Received {
		writeJSON(w, map[string]any{
			"resourceID": resource.ID, "receivedBytes": resource.Received, "status": resource.Status,
		})
		return
	}
	if offset != resource.Received {
		w.WriteHeader(http.StatusConflict)
		writeJSON(w, map[string]any{
			"error": "offset conflict", "receivedBytes": resource.Received,
		})
		return
	}
	remaining := resource.ByteSize - resource.Received
	expectedLength := min(resource.ChunkSize, remaining)
	if expectedLength <= 0 {
		writeJSON(w, map[string]any{
			"resourceID": resource.ID, "receivedBytes": resource.Received, "status": "uploaded",
		})
		return
	}
	data, err := io.ReadAll(io.LimitReader(r.Body, resource.ChunkSize+1))
	if err != nil || int64(len(data)) != expectedLength {
		http.Error(w, "invalid chunk length", http.StatusBadRequest)
		return
	}
	chunkHash := sha256.Sum256(data)
	providedHash := strings.ToLower(strings.TrimSpace(r.Header.Get("X-Chunk-SHA256")))
	if providedHash == "" || providedHash != hex.EncodeToString(chunkHash[:]) {
		http.Error(w, "chunk checksum mismatch", http.StatusUnprocessableEntity)
		return
	}
	stagePath := filepath.Join(session.StageDir, resource.StageName)
	file, err := os.OpenFile(stagePath, os.O_WRONLY, 0600)
	if err != nil {
		http.Error(w, "cannot open staging resource", http.StatusInternalServerError)
		return
	}
	_, seekErr := file.Seek(offset, io.SeekStart)
	written, writeErr := file.Write(data)
	syncErr := file.Sync()
	closeErr := file.Close()
	if seekErr != nil || writeErr != nil || syncErr != nil || closeErr != nil || written != len(data) {
		http.Error(w, "cannot persist upload chunk", http.StatusInternalServerError)
		return
	}
	received := resource.Received + int64(written)
	status := "uploading"
	if received == resource.ByteSize {
		status = "uploaded"
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err = a.db.Exec(
		"UPDATE photo_upload_resources SET received=?,status=?,updated=? WHERE id=? AND upload_session_id=?",
		received, status, now, resource.ID, session.ID,
	); err != nil {
		http.Error(w, "cannot save upload progress", http.StatusInternalServerError)
		return
	}
	_, _ = a.db.Exec(
		"UPDATE photo_upload_sessions SET status='uploading',updated=? WHERE id=?",
		now, session.ID,
	)
	a.addVolumeIO(session.VolumeID, 0, uint64(written))
	writeJSON(w, map[string]any{
		"resourceID": resource.ID, "receivedBytes": received, "status": status,
	})
}

func (a *App) completePhotoUploadSession(w http.ResponseWriter, ownerUserID string, sessionID string) {
	session, resources, err := a.photoUploadSessionRows(sessionID, ownerUserID)
	if errors.Is(err, sql.ErrNoRows) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if err != nil {
		http.Error(w, "upload session unavailable", http.StatusInternalServerError)
		return
	}
	if session.Status == "completed" {
		response, _ := a.photoUploadSessionResponse(sessionID, ownerUserID)
		writeJSON(w, response)
		return
	}
	for _, resource := range resources {
		if resource.Received != resource.ByteSize {
			http.Error(w, "not all resources are uploaded", http.StatusConflict)
			return
		}
		stagePath := filepath.Join(session.StageDir, resource.StageName)
		info, statErr := os.Stat(stagePath)
		if statErr != nil || info.Size() != resource.ByteSize {
			a.failPhotoUploadSession(sessionID)
			http.Error(w, "staged resource size mismatch", http.StatusUnprocessableEntity)
			return
		}
		hash, hashErr := sha256File(stagePath)
		if hashErr != nil || hash != resource.SHA256 {
			a.failPhotoUploadSession(sessionID)
			http.Error(w, "resource checksum mismatch", http.StatusUnprocessableEntity)
			return
		}
	}

	volume, err := a.volumeByID(session.VolumeID)
	if err != nil || volume.Status != "online" {
		http.Error(w, "selected volume is offline", http.StatusConflict)
		return
	}
	ownerPath := photosOwnerPathComponent(ownerUserID)
	finalParent := filepath.Join(
		volume.Mount, "users", ownerPath, "photos", "originals", session.Fingerprint[:2],
	)
	if err = os.MkdirAll(finalParent, 0700); err != nil {
		http.Error(w, "cannot prepare photo library", http.StatusInternalServerError)
		return
	}
	finalDir := filepath.Join(finalParent, session.AssetID)
	if _, err = os.Stat(finalDir); err == nil {
		http.Error(w, "asset destination already exists", http.StatusConflict)
		return
	} else if !os.IsNotExist(err) {
		http.Error(w, "cannot inspect asset destination", http.StatusInternalServerError)
		return
	}
	if err = os.Rename(session.StageDir, finalDir); err != nil {
		http.Error(w, "cannot atomically commit photo resources", http.StatusInternalServerError)
		return
	}

	now := time.Now().UTC().Format(time.RFC3339Nano)
	transaction, err := a.db.Begin()
	if err != nil {
		_ = os.Rename(finalDir, session.StageDir)
		http.Error(w, "cannot commit photo metadata", http.StatusInternalServerError)
		return
	}
	defer transaction.Rollback()
	_, err = transaction.Exec(
		`INSERT INTO photo_assets(
			id,owner_user_id,volume_id,content_fingerprint,media_type,capture_date,modification_date,
			pixel_width,pixel_height,duration,favorite,backup_state,source_state,derivative_state,
			derivative_recipe_version,derivative_error,derivative_updated,created,updated
		) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		session.AssetID, ownerUserID, session.VolumeID, session.Fingerprint, session.MediaType,
		nullStringValue(session.CaptureDate), nullStringValue(session.ModificationDate),
		session.PixelWidth, session.PixelHeight, session.Duration, session.Favorite, "backedUp",
		photosSourceStateCommitted, photosDerivativeStatePending, photosDerivativePolicyVersion,
		nil, now, now, now,
	)
	if err == nil {
		for _, resource := range resources {
			storagePath, relativeErr := filepath.Rel(volume.Mount, filepath.Join(finalDir, resource.StageName))
			if relativeErr != nil {
				err = relativeErr
				break
			}
			_, err = transaction.Exec(
				`INSERT INTO photo_resources(
					id,asset_id,owner_user_id,volume_id,resource_role,original_filename,content_type,
					byte_size,sha256,storage_path,created
				) VALUES(?,?,?,?,?,?,?,?,?,?,?)`,
				resource.ID, session.AssetID, ownerUserID, session.VolumeID, resource.ResourceRole,
				resource.OriginalFilename, resource.ContentType, resource.ByteSize, resource.SHA256,
				filepath.ToSlash(storagePath), now,
			)
			if err != nil {
				break
			}
		}
	}
	if err == nil {
		_, err = transaction.Exec(
			`INSERT INTO photo_derivative_jobs(
				id,asset_id,owner_user_id,volume_id,recipe_version,status,
				attempt_count,last_error,next_attempt_at,created,updated
			 ) VALUES(?,?,?,?,?,?,0,NULL,NULL,?,?)`,
			"pdj_"+session.AssetID+"_"+photosDerivativePolicyVersion,
			session.AssetID, ownerUserID, session.VolumeID,
			photosDerivativePolicyVersion, photosDerivativeJobPending, now, now,
		)
	}
	if err == nil {
		_, err = transaction.Exec(
			`INSERT INTO device_asset_mappings(owner_user_id,device_id,local_identifier,fingerprint,asset_id,updated)
			 VALUES(?,?,?,?,?,?)
			 ON CONFLICT(owner_user_id,device_id,local_identifier)
			 DO UPDATE SET fingerprint=excluded.fingerprint,asset_id=excluded.asset_id,updated=excluded.updated`,
			ownerUserID, session.DeviceID, session.LocalIdentifier, session.Fingerprint, session.AssetID, now,
		)
	}
	if err == nil {
		_, err = transaction.Exec(
			"UPDATE photo_upload_sessions SET status='completed',stage_dir='',updated=? WHERE id=?",
			now, session.ID,
		)
	}
	if err == nil {
		err = transaction.Commit()
	}
	if err != nil {
		_ = os.Rename(finalDir, session.StageDir)
		http.Error(w, "cannot commit photo metadata", http.StatusInternalServerError)
		return
	}
	a.wakePhotoDerivativeWorker()
	response, err := a.photoUploadSessionResponse(sessionID, ownerUserID)
	if err != nil {
		http.Error(w, "photo committed but response unavailable", http.StatusInternalServerError)
		return
	}
	writeJSON(w, response)
}

func (a *App) photosRequestOwner(w http.ResponseWriter, r *http.Request) (photosMeResponse, bool) {
	tailscaleUser, ok := a.user(r)
	if !ok {
		http.Error(w, "Tailscale identity required", http.StatusUnauthorized)
		return photosMeResponse{}, false
	}
	owner, err := a.ensurePhotoUser(tailscaleUser)
	if err != nil {
		http.Error(w, "photo user unavailable", http.StatusInternalServerError)
		return photosMeResponse{}, false
	}
	return owner, true
}

func (a *App) findBackedUpPhotoAsset(
	ownerUserID, volumeID, deviceID, localIdentifier, fingerprint string,
) (string, bool, error) {
	var assetID string
	err := a.db.QueryRow(
		`SELECT a.id
		 FROM device_asset_mappings m
		 JOIN photo_assets a ON a.id=m.asset_id AND a.owner_user_id=m.owner_user_id
		 WHERE m.owner_user_id=? AND m.device_id=? AND m.local_identifier=? AND m.fingerprint=?
		   AND a.volume_id=? AND a.source_state=?`,
		ownerUserID, deviceID, localIdentifier, fingerprint, volumeID, photosSourceStateCommitted,
	).Scan(&assetID)
	if err == nil {
		return assetID, true, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return "", false, err
	}
	err = a.db.QueryRow(
		`SELECT id FROM photo_assets
		 WHERE owner_user_id=? AND volume_id=? AND content_fingerprint=? AND source_state=?`,
		ownerUserID, volumeID, fingerprint, photosSourceStateCommitted,
	).Scan(&assetID)
	if err == nil {
		return assetID, true, nil
	}
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	return "", false, err
}

func (a *App) upsertDeviceAssetMapping(
	ownerUserID, deviceID, localIdentifier, fingerprint, assetID string,
) error {
	_, err := a.db.Exec(
		`INSERT INTO device_asset_mappings(owner_user_id,device_id,local_identifier,fingerprint,asset_id,updated)
		 VALUES(?,?,?,?,?,?)
		 ON CONFLICT(owner_user_id,device_id,local_identifier)
		 DO UPDATE SET fingerprint=excluded.fingerprint,asset_id=excluded.asset_id,updated=excluded.updated`,
		ownerUserID, deviceID, localIdentifier, fingerprint, assetID,
		time.Now().UTC().Format(time.RFC3339Nano),
	)
	return err
}

func (a *App) photoUploadSessionResponse(sessionID, ownerUserID string) (photosUploadSessionResponse, error) {
	session, resources, err := a.photoUploadSessionRows(sessionID, ownerUserID)
	if err != nil {
		return photosUploadSessionResponse{}, err
	}
	response := photosUploadSessionResponse{
		ID: session.ID, AssetID: session.AssetID, Status: session.Status,
		Fingerprint: session.Fingerprint, Resources: make([]photosUploadResourceResponse, 0, len(resources)),
	}
	if session.Status == "completed" {
		response.SourceState, response.DerivativeState, err = a.photoAssetStates(session.AssetID, ownerUserID)
		if err != nil {
			return photosUploadSessionResponse{}, err
		}
		response.BrowseReady = response.DerivativeState == photosDerivativeStateReady
	}
	for _, resource := range resources {
		response.TotalBytes += resource.ByteSize
		response.ReceivedBytes += resource.Received
		response.Resources = append(response.Resources, photosUploadResourceResponse{
			ID: resource.ID, ClientResourceID: resource.ClientResourceID,
			ResourceRole: resource.ResourceRole, OriginalFilename: resource.OriginalFilename,
			ContentType: resource.ContentType, ByteSize: resource.ByteSize, SHA256: resource.SHA256,
			ReceivedBytes: resource.Received, ChunkSize: resource.ChunkSize, Status: resource.Status,
		})
	}
	return response, nil
}

func (a *App) photoAssetStates(assetID, ownerUserID string) (string, string, error) {
	var sourceState, derivativeState string
	err := a.db.QueryRow(
		`SELECT source_state,derivative_state
		 FROM photo_assets WHERE id=? AND owner_user_id=?`,
		assetID, ownerUserID,
	).Scan(&sourceState, &derivativeState)
	return sourceState, derivativeState, err
}

func (a *App) photoUploadSessionRows(
	sessionID, ownerUserID string,
) (photosUploadSessionRow, []photosUploadResourceRow, error) {
	var session photosUploadSessionRow
	err := a.db.QueryRow(
		`SELECT id,owner_user_id,volume_id,device_id,local_identifier,fingerprint,asset_id,media_type,status,
		        capture_date,modification_date,pixel_width,pixel_height,duration,favorite,stage_dir,created,updated
		 FROM photo_upload_sessions WHERE id=? AND owner_user_id=?`,
		sessionID, ownerUserID,
	).Scan(
		&session.ID, &session.OwnerUserID, &session.VolumeID, &session.DeviceID,
		&session.LocalIdentifier, &session.Fingerprint, &session.AssetID, &session.MediaType,
		&session.Status, &session.CaptureDate, &session.ModificationDate,
		&session.PixelWidth, &session.PixelHeight, &session.Duration, &session.Favorite,
		&session.StageDir, &session.Created, &session.Updated,
	)
	if err != nil {
		return photosUploadSessionRow{}, nil, err
	}
	rows, err := a.db.Query(
		`SELECT id,upload_session_id,client_resource_id,resource_role,original_filename,content_type,
		        byte_size,sha256,stage_name,received,chunk_size,status
		 FROM photo_upload_resources WHERE upload_session_id=? ORDER BY client_resource_id`,
		sessionID,
	)
	if err != nil {
		return photosUploadSessionRow{}, nil, err
	}
	defer rows.Close()
	resources := make([]photosUploadResourceRow, 0)
	for rows.Next() {
		var resource photosUploadResourceRow
		if err = rows.Scan(
			&resource.ID, &resource.UploadSessionID, &resource.ClientResourceID,
			&resource.ResourceRole, &resource.OriginalFilename, &resource.ContentType,
			&resource.ByteSize, &resource.SHA256, &resource.StageName, &resource.Received,
			&resource.ChunkSize, &resource.Status,
		); err != nil {
			return photosUploadSessionRow{}, nil, err
		}
		resources = append(resources, resource)
	}
	return session, resources, rows.Err()
}

func (a *App) photoUploadResource(
	sessionID, resourceID, ownerUserID string,
) (photosUploadSessionRow, photosUploadResourceRow, error) {
	session, resources, err := a.photoUploadSessionRows(sessionID, ownerUserID)
	if err != nil {
		return photosUploadSessionRow{}, photosUploadResourceRow{}, err
	}
	for _, resource := range resources {
		if resource.ID == resourceID {
			return session, resource, nil
		}
	}
	return photosUploadSessionRow{}, photosUploadResourceRow{}, sql.ErrNoRows
}

func (a *App) failPhotoUploadSession(sessionID string) {
	_, _ = a.db.Exec(
		"UPDATE photo_upload_sessions SET status='failed',updated=? WHERE id=?",
		time.Now().UTC().Format(time.RFC3339Nano), sessionID,
	)
}

func validatePhotosUploadInput(input *photosUploadSessionInput) error {
	input.VolumeID = strings.TrimSpace(input.VolumeID)
	input.DeviceID = strings.TrimSpace(input.DeviceID)
	input.LocalIdentifier = strings.TrimSpace(input.LocalIdentifier)
	input.Fingerprint = strings.ToLower(strings.TrimSpace(input.Fingerprint))
	input.MediaType = strings.TrimSpace(input.MediaType)
	if input.VolumeID == "" || len(input.VolumeID) > 200 {
		return errors.New("invalid volume ID")
	}
	if input.DeviceID == "" || len(input.DeviceID) > 200 {
		return errors.New("invalid device ID")
	}
	if input.LocalIdentifier == "" || len(input.LocalIdentifier) > 1200 {
		return errors.New("invalid local identifier")
	}
	if !isSHA256(input.Fingerprint) {
		return errors.New("invalid fingerprint")
	}
	switch input.MediaType {
	case "photo", "video", "livePhoto":
	default:
		return errors.New("invalid media type")
	}
	if input.PixelWidth < 0 || input.PixelHeight < 0 || input.Duration < 0 {
		return errors.New("invalid asset dimensions or duration")
	}
	if err := validateOptionalPhotoDate(input.CaptureDate); err != nil {
		return err
	}
	if err := validateOptionalPhotoDate(input.ModificationDate); err != nil {
		return err
	}
	if len(input.Resources) == 0 || len(input.Resources) > 32 {
		return errors.New("asset must contain 1 to 32 resources")
	}
	seenIDs := map[string]bool{}
	var total int64
	for index := range input.Resources {
		resource := &input.Resources[index]
		resource.ClientResourceID = strings.TrimSpace(resource.ClientResourceID)
		resource.ResourceRole = strings.TrimSpace(resource.ResourceRole)
		resource.ContentType = strings.TrimSpace(resource.ContentType)
		resource.SHA256 = strings.ToLower(strings.TrimSpace(resource.SHA256))
		filename, err := cleanName(resource.OriginalFilename)
		if err != nil || len([]rune(filename)) > 240 {
			return errors.New("invalid original filename")
		}
		resource.OriginalFilename = filename
		if !isSafePhotoToken(resource.ClientResourceID, 100) || seenIDs[resource.ClientResourceID] {
			return errors.New("invalid or duplicate client resource ID")
		}
		seenIDs[resource.ClientResourceID] = true
		if !isSafePhotoToken(resource.ResourceRole, 80) {
			return errors.New("invalid resource role")
		}
		if resource.ContentType == "" || len(resource.ContentType) > 200 || strings.ContainsAny(resource.ContentType, "\r\n\x00") {
			return errors.New("invalid content type")
		}
		if resource.ByteSize < 0 || resource.ByteSize > photosMaxResourceSize {
			return errors.New("invalid resource size")
		}
		if !isSHA256(resource.SHA256) {
			return errors.New("invalid resource checksum")
		}
		if total > photosMaxResourceSize-resource.ByteSize {
			return errors.New("asset resources are too large")
		}
		total += resource.ByteSize
	}
	return nil
}

func photoManifestFingerprint(resources []photosUploadResourceInput) string {
	sorted := append([]photosUploadResourceInput(nil), resources...)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i].ClientResourceID < sorted[j].ClientResourceID
	})
	hash := sha256.New()
	for _, resource := range sorted {
		fmt.Fprintf(
			hash, "%s\x00%s\x00%s\x00%d\n",
			resource.ClientResourceID, resource.ResourceRole, resource.SHA256, resource.ByteSize,
		)
	}
	return hex.EncodeToString(hash.Sum(nil))
}

func sha256File(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err = io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func photosOwnerPathComponent(ownerUserID string) string {
	hash := sha256.Sum256([]byte(ownerUserID))
	return "user-" + hex.EncodeToString(hash[:12])
}

func nullableString(value *string) any {
	if value == nil {
		return nil
	}
	trimmed := strings.TrimSpace(*value)
	if trimmed == "" {
		return nil
	}
	return trimmed
}

func nullStringValue(value sql.NullString) any {
	if value.Valid {
		return value.String
	}
	return nil
}

func validateOptionalPhotoDate(value *string) error {
	if value == nil || strings.TrimSpace(*value) == "" {
		return nil
	}
	if _, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(*value)); err != nil {
		return errors.New("invalid photo date")
	}
	return nil
}

func isSHA256(value string) bool {
	if len(value) != sha256.Size*2 {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}

func isSafePhotoToken(value string, maximumLength int) bool {
	if value == "" || len(value) > maximumLength {
		return false
	}
	for _, character := range value {
		if (character >= 'a' && character <= 'z') ||
			(character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') ||
			character == '-' || character == '_' || character == '.' {
			continue
		}
		return false
	}
	return true
}
