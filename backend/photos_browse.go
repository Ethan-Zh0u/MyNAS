package main

import (
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	photosDefaultPageSize = 50
	photosMaximumPageSize = 200
)

type photosAssetResourceResponse struct {
	ID               string `json:"id"`
	ResourceRole     string `json:"resourceRole"`
	OriginalFilename string `json:"originalFilename"`
	ContentType      string `json:"contentType"`
	ByteSize         int64  `json:"byteSize"`
	SHA256           string `json:"sha256"`
	DownloadURL      string `json:"downloadURL"`
}

type photosAssetDerivativeResponse struct {
	Kind          string `json:"kind"`
	RecipeID      string `json:"recipeID"`
	RecipeVersion string `json:"recipeVersion"`
	ContentType   string `json:"contentType"`
	PixelWidth    int    `json:"pixelWidth"`
	PixelHeight   int    `json:"pixelHeight"`
	ByteSize      int64  `json:"byteSize"`
	SHA256        string `json:"sha256"`
	DownloadURL   string `json:"downloadURL"`
}

type photosAssetResponse struct {
	ID                      string                          `json:"id"`
	VolumeID                string                          `json:"volumeID"`
	MediaType               string                          `json:"mediaType"`
	CaptureDate             *string                         `json:"captureDate"`
	ModificationDate        *string                         `json:"modificationDate"`
	PixelWidth              int                             `json:"pixelWidth"`
	PixelHeight             int                             `json:"pixelHeight"`
	Duration                float64                         `json:"duration"`
	Favorite                bool                            `json:"favorite"`
	SourceState             string                          `json:"sourceState"`
	DerivativeState         string                          `json:"derivativeState"`
	DerivativeRecipeVersion string                          `json:"derivativeRecipeVersion"`
	DerivativeError         *string                         `json:"derivativeError,omitempty"`
	BrowseReady             bool                            `json:"browseReady"`
	Version                 string                          `json:"version"`
	Resources               []photosAssetResourceResponse   `json:"resources"`
	Derivatives             []photosAssetDerivativeResponse `json:"derivatives"`
}

type photosAssetPageResponse struct {
	Assets     []photosAssetResponse `json:"assets"`
	NextCursor *string               `json:"nextCursor"`
	HasMore    bool                  `json:"hasMore"`
}

// A device mapping is intentionally narrower than an asset list. It is only
// used to restore this device's verified PhotoKit localIdentifier ↔ MyNAS asset
// relationship after the app's local job store is lost. The fingerprint never
// leaves the server, and mappings are owner- and device-scoped.
type photosDeviceAssetMappingResponse struct {
	LocalIdentifier        string  `json:"localIdentifier"`
	AssetID                string  `json:"assetID"`
	SourceModificationDate *string `json:"sourceModificationDate"`
	SourceState            string  `json:"sourceState"`
	DerivativeState        string  `json:"derivativeState"`
	ResourceCount          int     `json:"resourceCount"`
	SourceBytes            int64   `json:"sourceBytes"`
	UpdatedAt              string  `json:"updatedAt"`
}

type photosDeviceAssetMappingPageResponse struct {
	Mappings   []photosDeviceAssetMappingResponse `json:"mappings"`
	NextCursor *string                            `json:"nextCursor"`
	HasMore    bool                               `json:"hasMore"`
}

type photosChangeResponse struct {
	Sequence  int64  `json:"sequence"`
	Type      string `json:"type"`
	AssetID   string `json:"assetID"`
	UpdatedAt string `json:"updatedAt"`
}

type photosChangePageResponse struct {
	Changes       []photosChangeResponse `json:"changes"`
	NextCursor    string                 `json:"nextCursor"`
	HasMore       bool                   `json:"hasMore"`
	ResetRequired bool                   `json:"resetRequired"`
}

type photosBrowseCursor struct {
	SortTime string `json:"sortTime"`
	AssetID  string `json:"assetID"`
}

type photosDeviceAssetMappingCursor struct {
	UpdatedAt       string `json:"updatedAt"`
	LocalIdentifier string `json:"localIdentifier"`
}

type photosStoredFile struct {
	VolumeID    string
	StoragePath string
	ContentType string
	ByteSize    int64
	SHA256      string
	Updated     string
}

func (a *App) photosAssets(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	owner, ok := a.photosRequestOwner(w, r)
	if !ok {
		return
	}
	limit, err := photosPageLimit(r.URL.Query().Get("limit"), photosDefaultPageSize)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	cursor, err := decodePhotosBrowseCursor(r.URL.Query().Get("cursor"))
	if err != nil {
		http.Error(w, "invalid cursor", http.StatusBadRequest)
		return
	}

	query := `SELECT id,volume_id,media_type,capture_date,modification_date,
		pixel_width,pixel_height,duration,favorite,source_state,derivative_state,
		derivative_recipe_version,derivative_error,updated,
		COALESCE(capture_date,created) AS sort_time
		FROM photo_assets
		WHERE owner_user_id=? AND source_state=?`
	arguments := []any{owner.UserID, photosSourceStateCommitted}
	if cursor != nil {
		query += ` AND (COALESCE(capture_date,created) < ?
			OR (COALESCE(capture_date,created)=? AND id < ?))`
		arguments = append(arguments, cursor.SortTime, cursor.SortTime, cursor.AssetID)
	}
	query += ` ORDER BY sort_time DESC,id DESC LIMIT ?`
	arguments = append(arguments, limit+1)

	rows, err := a.db.Query(query, arguments...)
	if err != nil {
		http.Error(w, "photo library unavailable", http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	baseAssets := make([]photosAssetResponse, 0, limit+1)
	baseCursors := make([]photosBrowseCursor, 0, limit+1)
	for rows.Next() {
		asset, sortTime, scanErr := scanPhotosAsset(rows)
		if scanErr != nil {
			http.Error(w, "photo metadata unavailable", http.StatusInternalServerError)
			return
		}
		baseAssets = append(baseAssets, asset)
		baseCursors = append(
			baseCursors,
			photosBrowseCursor{SortTime: sortTime, AssetID: asset.ID},
		)
	}
	if err = rows.Err(); err != nil {
		http.Error(w, "photo library unavailable", http.StatusInternalServerError)
		return
	}
	rows.Close()

	hasMore := len(baseAssets) > limit
	if hasMore {
		baseAssets = baseAssets[:limit]
		baseCursors = baseCursors[:limit]
	}
	for index := range baseAssets {
		if loadErr := a.loadPhotosAssetFiles(owner.UserID, &baseAssets[index]); loadErr != nil {
			http.Error(w, "photo resources unavailable", http.StatusInternalServerError)
			return
		}
	}
	var nextCursor *string
	if hasMore && len(baseCursors) > 0 {
		encoded := encodePhotosBrowseCursor(baseCursors[len(baseCursors)-1])
		nextCursor = &encoded
	}
	response := photosAssetPageResponse{
		Assets: baseAssets, NextCursor: nextCursor, HasMore: hasMore,
	}
	writePhotosJSONWithETag(
		w, r, response, photosMetadataETag(owner.UserID, baseAssets, nextCursor),
	)
}

func (a *App) photosDeviceAssetMappings(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	owner, ok := a.photosRequestOwner(w, r)
	if !ok {
		return
	}
	deviceID := strings.TrimSpace(r.URL.Query().Get("deviceID"))
	if deviceID == "" || len(deviceID) > 200 {
		http.Error(w, "invalid device ID", http.StatusBadRequest)
		return
	}
	limit, err := photosPageLimit(r.URL.Query().Get("limit"), photosDefaultPageSize)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	cursor, err := decodePhotosDeviceAssetMappingCursor(r.URL.Query().Get("cursor"))
	if err != nil {
		http.Error(w, "invalid cursor", http.StatusBadRequest)
		return
	}

	query := `SELECT m.local_identifier,m.asset_id,a.modification_date,a.source_state,a.derivative_state,
		COALESCE((SELECT COUNT(1) FROM photo_resources r
			WHERE r.owner_user_id=m.owner_user_id AND r.asset_id=m.asset_id),0),
		COALESCE((SELECT SUM(r.byte_size) FROM photo_resources r
			WHERE r.owner_user_id=m.owner_user_id AND r.asset_id=m.asset_id),0),
		m.updated
		FROM device_asset_mappings m
		JOIN photo_assets a ON a.id=m.asset_id AND a.owner_user_id=m.owner_user_id
		WHERE m.owner_user_id=? AND m.device_id=? AND a.source_state=?`
	arguments := []any{owner.UserID, deviceID, photosSourceStateCommitted}
	if cursor != nil {
		query += ` AND (m.updated < ? OR (m.updated=? AND m.local_identifier < ?))`
		arguments = append(arguments, cursor.UpdatedAt, cursor.UpdatedAt, cursor.LocalIdentifier)
	}
	query += ` ORDER BY m.updated DESC,m.local_identifier DESC LIMIT ?`
	arguments = append(arguments, limit+1)

	rows, err := a.db.Query(query, arguments...)
	if err != nil {
		http.Error(w, "photo mapping unavailable", http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	mappings := make([]photosDeviceAssetMappingResponse, 0, limit+1)
	cursors := make([]photosDeviceAssetMappingCursor, 0, limit+1)
	for rows.Next() {
		var mapping photosDeviceAssetMappingResponse
		var modificationDate sql.NullString
		if err = rows.Scan(
			&mapping.LocalIdentifier, &mapping.AssetID, &modificationDate,
			&mapping.SourceState, &mapping.DerivativeState, &mapping.ResourceCount,
			&mapping.SourceBytes, &mapping.UpdatedAt,
		); err != nil {
			http.Error(w, "photo mapping unavailable", http.StatusInternalServerError)
			return
		}
		mapping.SourceModificationDate = nullablePhotosString(modificationDate)
		mappings = append(mappings, mapping)
		cursors = append(cursors, photosDeviceAssetMappingCursor{
			UpdatedAt: mapping.UpdatedAt, LocalIdentifier: mapping.LocalIdentifier,
		})
	}
	if err = rows.Err(); err != nil {
		http.Error(w, "photo mapping unavailable", http.StatusInternalServerError)
		return
	}

	hasMore := len(mappings) > limit
	if hasMore {
		mappings = mappings[:limit]
		cursors = cursors[:limit]
	}
	var nextCursor *string
	if hasMore && len(cursors) > 0 {
		encoded := encodePhotosDeviceAssetMappingCursor(cursors[len(cursors)-1])
		nextCursor = &encoded
	}
	response := photosDeviceAssetMappingPageResponse{
		Mappings: mappings, NextCursor: nextCursor, HasMore: hasMore,
	}
	writePhotosJSONWithETag(
		w, r, response, photosDeviceAssetMappingETag(owner.UserID, deviceID, mappings, nextCursor),
	)
}

func (a *App) photosAssetByPath(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	owner, ok := a.photosRequestOwner(w, r)
	if !ok {
		return
	}
	path := strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/v1/photos/assets/"), "/")
	parts := strings.Split(path, "/")
	if path == "" || len(parts) > 2 || parts[0] == "" {
		http.NotFound(w, r)
		return
	}
	assetID := parts[0]
	if len(parts) == 1 {
		asset, err := a.photoAsset(owner.UserID, assetID)
		if errors.Is(err, sql.ErrNoRows) {
			http.NotFound(w, r)
			return
		}
		if err != nil {
			http.Error(w, "photo metadata unavailable", http.StatusInternalServerError)
			return
		}
		writePhotosJSONWithETag(
			w, r, asset, photosMetadataETag(owner.UserID, []photosAssetResponse{asset}, nil),
		)
		return
	}

	kind := parts[1]
	var stored photosStoredFile
	var err error
	switch kind {
	case "tiny", "grid", "preview":
		stored, err = a.photoDerivativeFile(owner.UserID, assetID, kind)
	case "original":
		stored, err = a.photoOriginalFile(
			owner.UserID,
			assetID,
			strings.TrimSpace(r.URL.Query().Get("resourceID")),
		)
	default:
		http.NotFound(w, r)
		return
	}
	if errors.Is(err, sql.ErrNoRows) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		http.Error(w, "photo resource unavailable", http.StatusInternalServerError)
		return
	}
	a.servePhotoFile(w, r, stored)
}

func (a *App) photosChanges(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	owner, ok := a.photosRequestOwner(w, r)
	if !ok {
		return
	}
	limit, err := photosPageLimit(r.URL.Query().Get("limit"), photosMaximumPageSize)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	cursor := int64(0)
	if raw := strings.TrimSpace(r.URL.Query().Get("cursor")); raw != "" {
		cursor, err = strconv.ParseInt(raw, 10, 64)
		if err != nil || cursor < 0 {
			http.Error(w, "invalid cursor", http.StatusBadRequest)
			return
		}
	}
	rows, err := a.db.Query(
		`SELECT sequence,change_type,asset_id,asset_updated
		 FROM photo_changes
		 WHERE owner_user_id=? AND sequence>?
		 ORDER BY sequence ASC LIMIT ?`,
		owner.UserID, cursor, limit+1,
	)
	if err != nil {
		http.Error(w, "photo changes unavailable", http.StatusInternalServerError)
		return
	}
	defer rows.Close()
	changes := make([]photosChangeResponse, 0, limit)
	next := cursor
	hasMore := false
	for rows.Next() {
		var change photosChangeResponse
		if err = rows.Scan(&change.Sequence, &change.Type, &change.AssetID, &change.UpdatedAt); err != nil {
			http.Error(w, "photo changes unavailable", http.StatusInternalServerError)
			return
		}
		if len(changes) == limit {
			hasMore = true
			break
		}
		changes = append(changes, change)
		next = change.Sequence
	}
	response := photosChangePageResponse{
		Changes: changes, NextCursor: strconv.FormatInt(next, 10),
		HasMore: hasMore, ResetRequired: false,
	}
	etag := quotedPhotosETag(owner.UserID + ":changes:" + response.NextCursor)
	writePhotosJSONWithETag(w, r, response, etag)
}

func scanPhotosAsset(scanner interface{ Scan(...any) error }) (photosAssetResponse, string, error) {
	var asset photosAssetResponse
	var captureDate, modificationDate, derivativeError sql.NullString
	var favorite int
	var sortTime string
	err := scanner.Scan(
		&asset.ID, &asset.VolumeID, &asset.MediaType, &captureDate, &modificationDate,
		&asset.PixelWidth, &asset.PixelHeight, &asset.Duration, &favorite,
		&asset.SourceState, &asset.DerivativeState, &asset.DerivativeRecipeVersion,
		&derivativeError, &asset.Version, &sortTime,
	)
	if err != nil {
		return photosAssetResponse{}, "", err
	}
	asset.CaptureDate = nullablePhotosString(captureDate)
	asset.ModificationDate = nullablePhotosString(modificationDate)
	asset.DerivativeError = nullablePhotosString(derivativeError)
	asset.Favorite = favorite != 0
	asset.BrowseReady = asset.SourceState == photosSourceStateCommitted &&
		asset.DerivativeState == photosDerivativeStateReady
	asset.Resources = []photosAssetResourceResponse{}
	asset.Derivatives = []photosAssetDerivativeResponse{}
	return asset, sortTime, nil
}

func (a *App) photoAsset(ownerUserID, assetID string) (photosAssetResponse, error) {
	row := a.db.QueryRow(
		`SELECT id,volume_id,media_type,capture_date,modification_date,
		 pixel_width,pixel_height,duration,favorite,source_state,derivative_state,
		 derivative_recipe_version,derivative_error,updated,
		 COALESCE(capture_date,created)
		 FROM photo_assets WHERE owner_user_id=? AND id=? AND source_state=?`,
		ownerUserID, assetID, photosSourceStateCommitted,
	)
	asset, _, err := scanPhotosAsset(row)
	if err != nil {
		return photosAssetResponse{}, err
	}
	if err = a.loadPhotosAssetFiles(ownerUserID, &asset); err != nil {
		return photosAssetResponse{}, err
	}
	return asset, nil
}

func (a *App) loadPhotosAssetFiles(ownerUserID string, asset *photosAssetResponse) error {
	resourceRows, err := a.db.Query(
		`SELECT id,resource_role,original_filename,content_type,byte_size,sha256
		 FROM photo_resources
		 WHERE owner_user_id=? AND asset_id=?
		 ORDER BY resource_role,id`,
		ownerUserID, asset.ID,
	)
	if err != nil {
		return err
	}
	for resourceRows.Next() {
		var resource photosAssetResourceResponse
		if err = resourceRows.Scan(
			&resource.ID, &resource.ResourceRole, &resource.OriginalFilename,
			&resource.ContentType, &resource.ByteSize, &resource.SHA256,
		); err != nil {
			resourceRows.Close()
			return err
		}
		resource.DownloadURL = "/api/v1/photos/assets/" + asset.ID +
			"/original?resourceID=" + resource.ID
		asset.Resources = append(asset.Resources, resource)
	}
	if err = resourceRows.Err(); err != nil {
		resourceRows.Close()
		return err
	}
	resourceRows.Close()

	derivativeRows, err := a.db.Query(
		`SELECT kind,recipe_id,recipe_version,content_type,pixel_width,pixel_height,
		 byte_size,sha256
		 FROM photo_derivatives
		 WHERE owner_user_id=? AND asset_id=? AND status=? AND recipe_version=?
		 ORDER BY kind`,
		ownerUserID, asset.ID, photosDerivativeStateReady, asset.DerivativeRecipeVersion,
	)
	if err != nil {
		return err
	}
	defer derivativeRows.Close()
	for derivativeRows.Next() {
		var derivative photosAssetDerivativeResponse
		if err = derivativeRows.Scan(
			&derivative.Kind, &derivative.RecipeID, &derivative.RecipeVersion,
			&derivative.ContentType, &derivative.PixelWidth, &derivative.PixelHeight,
			&derivative.ByteSize, &derivative.SHA256,
		); err != nil {
			return err
		}
		derivative.DownloadURL = "/api/v1/photos/assets/" + asset.ID + "/" + derivative.Kind
		asset.Derivatives = append(asset.Derivatives, derivative)
	}
	return derivativeRows.Err()
}

func (a *App) photoDerivativeFile(
	ownerUserID, assetID, kind string,
) (photosStoredFile, error) {
	var stored photosStoredFile
	err := a.db.QueryRow(
		`SELECT d.volume_id,d.storage_path,d.content_type,d.byte_size,d.sha256,d.updated
		 FROM photo_derivatives d
		 JOIN photo_assets a ON a.id=d.asset_id AND a.owner_user_id=d.owner_user_id
		 WHERE d.owner_user_id=? AND d.asset_id=? AND d.kind=? AND d.status=?
		   AND d.recipe_version=a.derivative_recipe_version`,
		ownerUserID, assetID, kind, photosDerivativeStateReady,
	).Scan(
		&stored.VolumeID, &stored.StoragePath, &stored.ContentType,
		&stored.ByteSize, &stored.SHA256, &stored.Updated,
	)
	return stored, err
}

func (a *App) photoOriginalFile(
	ownerUserID, assetID, resourceID string,
) (photosStoredFile, error) {
	var stored photosStoredFile
	query := `SELECT r.volume_id,r.storage_path,r.content_type,r.byte_size,r.sha256,r.created
		FROM photo_resources r
		JOIN photo_assets a ON a.id=r.asset_id AND a.owner_user_id=r.owner_user_id
		WHERE r.owner_user_id=? AND r.asset_id=? AND a.source_state=?`
	arguments := []any{ownerUserID, assetID, photosSourceStateCommitted}
	if resourceID != "" {
		query += " AND r.id=?"
		arguments = append(arguments, resourceID)
	}
	query += ` ORDER BY CASE r.resource_role
		WHEN 'photo' THEN 0 WHEN 'fullSizePhoto' THEN 1
		WHEN 'video' THEN 2 WHEN 'fullSizeVideo' THEN 3 ELSE 4 END,r.id LIMIT 1`
	err := a.db.QueryRow(query, arguments...).Scan(
		&stored.VolumeID, &stored.StoragePath, &stored.ContentType,
		&stored.ByteSize, &stored.SHA256, &stored.Updated,
	)
	return stored, err
}

func (a *App) servePhotoFile(w http.ResponseWriter, r *http.Request, stored photosStoredFile) {
	path, err := a.pathFor(stored.VolumeID, stored.StoragePath, false)
	if err != nil {
		http.Error(w, "photo storage unavailable", http.StatusServiceUnavailable)
		return
	}
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		http.Error(w, "photo storage unavailable", http.StatusInternalServerError)
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() != stored.ByteSize {
		http.Error(w, "photo resource failed integrity metadata check", http.StatusConflict)
		return
	}
	modified, _ := time.Parse(time.RFC3339Nano, stored.Updated)
	w.Header().Set("Content-Type", photosHTTPContentType(stored.ContentType))
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	w.Header().Set("ETag", `"`+stored.SHA256+`"`)
	w.Header().Set("Accept-Ranges", "bytes")
	http.ServeContent(w, r, filepath.Base(path), modified, file)
}

// PhotoKit commonly reports Uniform Type Identifier values (for example
// com.apple.quicktime-movie) for original resources. They are useful metadata,
// but are not valid HTTP media types and AVPlayer may refuse to stream them.
// Preserve a supplied MIME type, otherwise translate the UTI values MyNAS
// stores for media that the iOS client can display or play.
func photosHTTPContentType(contentType string) string {
	value := strings.ToLower(strings.TrimSpace(contentType))
	if strings.Contains(value, "/") {
		return contentType
	}
	switch value {
	case "com.apple.quicktime-movie":
		return "video/quicktime"
	case "public.mpeg-4", "public.mpeg4", "public.mp4":
		return "video/mp4"
	case "public.heic", "public.heif":
		return "image/heic"
	case "public.jpeg", "public.jpg":
		return "image/jpeg"
	case "public.png":
		return "image/png"
	default:
		return "application/octet-stream"
	}
}

func photosPageLimit(raw string, defaultValue int) (int, error) {
	if strings.TrimSpace(raw) == "" {
		return defaultValue, nil
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value < 1 || value > photosMaximumPageSize {
		return 0, fmt.Errorf("limit must be between 1 and %d", photosMaximumPageSize)
	}
	return value, nil
}

func encodePhotosBrowseCursor(cursor photosBrowseCursor) string {
	data, _ := json.Marshal(cursor)
	return base64.RawURLEncoding.EncodeToString(data)
}

func decodePhotosBrowseCursor(raw string) (*photosBrowseCursor, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, nil
	}
	data, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return nil, err
	}
	var cursor photosBrowseCursor
	if err = json.Unmarshal(data, &cursor); err != nil ||
		cursor.SortTime == "" || cursor.AssetID == "" {
		return nil, errors.New("invalid cursor")
	}
	return &cursor, nil
}

func encodePhotosDeviceAssetMappingCursor(cursor photosDeviceAssetMappingCursor) string {
	data, _ := json.Marshal(cursor)
	return base64.RawURLEncoding.EncodeToString(data)
}

func decodePhotosDeviceAssetMappingCursor(raw string) (*photosDeviceAssetMappingCursor, error) {
	if raw == "" {
		return nil, nil
	}
	data, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return nil, err
	}
	var cursor photosDeviceAssetMappingCursor
	if err = json.Unmarshal(data, &cursor); err != nil ||
		cursor.UpdatedAt == "" || cursor.LocalIdentifier == "" {
		return nil, errors.New("invalid cursor")
	}
	return &cursor, nil
}

func nullablePhotosString(value sql.NullString) *string {
	if !value.Valid {
		return nil
	}
	result := value.String
	return &result
}

func photosMetadataETag(
	ownerUserID string,
	assets []photosAssetResponse,
	nextCursor *string,
) string {
	seed := ownerUserID
	for _, asset := range assets {
		seed += ":" + asset.ID + ":" + asset.Version
	}
	if nextCursor != nil {
		seed += ":" + *nextCursor
	}
	return quotedPhotosETag(seed)
}

func photosDeviceAssetMappingETag(
	ownerUserID, deviceID string,
	mappings []photosDeviceAssetMappingResponse,
	nextCursor *string,
) string {
	seed := ownerUserID + ":device-mappings:" + deviceID
	for _, mapping := range mappings {
		modificationDate := ""
		if mapping.SourceModificationDate != nil {
			modificationDate = *mapping.SourceModificationDate
		}
		seed += ":" + mapping.LocalIdentifier + ":" + mapping.AssetID + ":" +
			modificationDate + ":" + mapping.SourceState + ":" + mapping.DerivativeState +
			":" + strconv.Itoa(mapping.ResourceCount) + ":" + strconv.FormatInt(mapping.SourceBytes, 10) +
			":" + mapping.UpdatedAt
	}
	if nextCursor != nil {
		seed += ":" + *nextCursor
	}
	return quotedPhotosETag(seed)
}

func quotedPhotosETag(seed string) string {
	sum := sha256.Sum256([]byte(seed))
	return `"` + hex.EncodeToString(sum[:]) + `"`
}

func writePhotosJSONWithETag(w http.ResponseWriter, r *http.Request, value any, etag string) {
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "private, no-cache")
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}
	writeJSON(w, value)
}
