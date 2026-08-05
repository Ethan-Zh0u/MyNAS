package main

import (
	"database/sql"
	"errors"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// A PhotoKit item can represent a Live Photo, RAW + sidecars, or another
// complete source-resource group. Deletion is therefore asset-based rather
// than a generic single-file operation. The endpoint first revalidates every
// requested asset, stages every directory on the same volume, atomically
// removes its metadata, and then destroys the staging directories. Staging is
// only a short-lived transaction guard, never a user-visible MyNAS recycle bin.
type photosDeleteItemInput struct {
	AssetID                string `json:"assetID"`
	DeviceID               string `json:"deviceID"`
	LocalIdentifier        string `json:"localIdentifier"`
	SourceModificationDate string `json:"sourceModificationDate"`
}

type photosDeleteAssetsInput struct {
	Items []photosDeleteItemInput `json:"items"`
}

type photosDeleteItemResponse struct {
	AssetID   string `json:"assetID"`
	DeletedAt string `json:"deletedAt"`
}

type photosDeleteAssetsResponse struct {
	Items []photosDeleteItemResponse `json:"items"`
}

// Direct deletion is intentionally distinct from H0's paired local deletion.
// It carries the version displayed by the owner-scoped gallery so a stale card
// cannot erase a resource group that changed after it was shown.
type photosRemoteDeleteInput struct {
	Version string `json:"version"`
}

// A 409 means the request is structurally valid but cannot safely remove the
// current MyNAS copy. The client must never weaken these checks on its own.
type photosDeleteRejected struct{ message string }

func (e *photosDeleteRejected) Error() string { return e.message }

type photosDeletePlan struct {
	AssetID                string
	ExpectedVersion        string
	DeleteID               string
	VolumeID               string
	VolumeMount            string
	OriginalSource         string
	DerivativeSource       string
	HasDerivativeDirectory bool
	DeletedAt              string
	OriginalStaged         bool
	DerivativeStaged       bool
}

type photosDeletionAssetState struct {
	AssetID          string
	VolumeID         string
	Fingerprint      string
	ModificationDate sql.NullString
	Version          string
}

func (a *App) photosDeleteAssets(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	owner, ok := a.photosRequestOwner(w, r)
	if !ok {
		return
	}
	var input photosDeleteAssetsInput
	if err := readJSON(r, &input); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if err := validatePhotosDeleteItems(input.Items); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	transaction, err := a.db.Begin()
	if err != nil {
		http.Error(w, "photo deletion unavailable", http.StatusInternalServerError)
		return
	}
	defer transaction.Rollback()

	plans := make([]photosDeletePlan, 0, len(input.Items))
	for _, item := range input.Items {
		plan, planErr := a.planPhotoDeletion(transaction, owner.UserID, item)
		if planErr != nil {
			writePhotoDeletionError(w, planErr)
			return
		}
		plans = append(plans, plan)
	}

	for index := range plans {
		if err = stagePhotoAssetDeletion(&plans[index]); err != nil {
			rollbackStagedPhotoDeletions(plans)
			http.Error(w, "cannot stage photo resources for deletion", http.StatusInternalServerError)
			return
		}
	}

	for _, plan := range plans {
		if err = deletePhotoAssetMetadata(transaction, owner.UserID, plan); err != nil {
			rollbackStagedPhotoDeletions(plans)
			writePhotoDeletionError(w, err)
			return
		}
	}
	if err = transaction.Commit(); err != nil {
		rollbackStagedPhotoDeletions(plans)
		http.Error(w, "cannot commit MyNAS photo deletion", http.StatusInternalServerError)
		return
	}

	for _, plan := range plans {
		if cleanupErr := os.RemoveAll(photoDeleteStagingRoot(plan.VolumeMount, plan.DeleteID)); cleanupErr != nil {
			// The logical delete has committed. Leaving an inaccessible staging
			// directory is safer than reporting failure and encouraging a retry.
			log.Printf("photo deletion staging cleanup asset=%s: %v", plan.AssetID, cleanupErr)
		}
	}
	response := photosDeleteAssetsResponse{Items: make([]photosDeleteItemResponse, 0, len(plans))}
	for _, plan := range plans {
		response.Items = append(response.Items, photosDeleteItemResponse{
			AssetID: plan.AssetID, DeletedAt: plan.DeletedAt,
		})
	}
	writeJSON(w, response)
}

// photosDeleteRemoteAsset permanently deletes one owner-scoped gallery item.
// Unlike H0, it never proves or modifies a current device's PhotoKit asset.
// A group with zero mappings may be deleted; a group shared by two or more
// mappings is refused because that would unexpectedly remove another device's
// verified backup.
func (a *App) photosDeleteRemoteAsset(w http.ResponseWriter, r *http.Request, assetID string) {
	if r.Method != http.MethodPost {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	owner, ok := a.photosRequestOwner(w, r)
	if !ok {
		return
	}
	assetID = strings.TrimSpace(assetID)
	if err := validatePhotoAssetID(assetID); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	var input photosRemoteDeleteInput
	if err := readJSON(r, &input); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	input.Version = strings.TrimSpace(input.Version)
	if input.Version == "" || len(input.Version) > 100 {
		http.Error(w, "invalid photo version", http.StatusBadRequest)
		return
	}

	transaction, err := a.db.Begin()
	if err != nil {
		http.Error(w, "photo deletion unavailable", http.StatusInternalServerError)
		return
	}
	defer transaction.Rollback()

	plan, err := a.planRemotePhotoDeletion(transaction, owner.UserID, assetID, input.Version)
	if err != nil {
		writePhotoDeletionError(w, err)
		return
	}
	if err = stagePhotoAssetDeletion(&plan); err != nil {
		rollbackStagedPhotoDeletions([]photosDeletePlan{plan})
		http.Error(w, "cannot stage photo resources for deletion", http.StatusInternalServerError)
		return
	}
	if err = deletePhotoAssetMetadata(transaction, owner.UserID, plan); err != nil {
		rollbackStagedPhotoDeletions([]photosDeletePlan{plan})
		writePhotoDeletionError(w, err)
		return
	}
	if err = transaction.Commit(); err != nil {
		rollbackStagedPhotoDeletions([]photosDeletePlan{plan})
		http.Error(w, "cannot commit MyNAS photo deletion", http.StatusInternalServerError)
		return
	}
	if cleanupErr := os.RemoveAll(photoDeleteStagingRoot(plan.VolumeMount, plan.DeleteID)); cleanupErr != nil {
		log.Printf("photo deletion staging cleanup asset=%s: %v", plan.AssetID, cleanupErr)
	}
	writeJSON(w, photosDeleteItemResponse{AssetID: plan.AssetID, DeletedAt: plan.DeletedAt})
}

func (a *App) planPhotoDeletion(
	transaction *sql.Tx, ownerUserID string, item photosDeleteItemInput,
) (photosDeletePlan, error) {
	asset, err := a.photoDeletionAssetState(transaction, ownerUserID, item.AssetID)
	if err != nil {
		return photosDeletePlan{}, err
	}
	if !asset.ModificationDate.Valid || asset.ModificationDate.String != item.SourceModificationDate {
		return photosDeletePlan{}, &photosDeleteRejected{message: "本机照片版本已经变化；请先完成当前版本备份"}
	}
	var matchingMappings int
	if err = transaction.QueryRow(
		`SELECT COUNT(1) FROM device_asset_mappings
		 WHERE owner_user_id=? AND device_id=? AND local_identifier=? AND asset_id=?`,
		ownerUserID, item.DeviceID, item.LocalIdentifier, item.AssetID,
	).Scan(&matchingMappings); err != nil {
		return photosDeletePlan{}, err
	}
	if matchingMappings != 1 {
		return photosDeletePlan{}, &photosDeleteRejected{message: "MyNAS 备份与当前 iPhone 照片的验证关系已变化"}
	}
	if err = a.verifyPhotoDeletionNotSharedOrProcessing(transaction, ownerUserID, item.AssetID, true); err != nil {
		return photosDeletePlan{}, err
	}
	return a.planPhotoDeletionStorage(transaction, ownerUserID, asset)
}

func (a *App) planRemotePhotoDeletion(
	transaction *sql.Tx, ownerUserID, assetID, version string,
) (photosDeletePlan, error) {
	asset, err := a.photoDeletionAssetState(transaction, ownerUserID, assetID)
	if err != nil {
		return photosDeletePlan{}, err
	}
	if asset.Version != version {
		return photosDeletePlan{}, &photosDeleteRejected{message: "MyNAS 项目已更新；请刷新图库后再次确认删除"}
	}
	if err = a.verifyPhotoDeletionNotSharedOrProcessing(transaction, ownerUserID, assetID, false); err != nil {
		return photosDeletePlan{}, err
	}
	return a.planPhotoDeletionStorage(transaction, ownerUserID, asset)
}

func (a *App) photoDeletionAssetState(
	transaction *sql.Tx, ownerUserID, assetID string,
) (photosDeletionAssetState, error) {
	var asset photosDeletionAssetState
	asset.AssetID = assetID
	err := transaction.QueryRow(
		`SELECT volume_id,content_fingerprint,modification_date,updated
		 FROM photo_assets
		 WHERE owner_user_id=? AND id=? AND source_state=?`,
		ownerUserID, assetID, photosSourceStateCommitted,
	).Scan(&asset.VolumeID, &asset.Fingerprint, &asset.ModificationDate, &asset.Version)
	if errors.Is(err, sql.ErrNoRows) {
		return photosDeletionAssetState{}, &photosDeleteRejected{message: "MyNAS 上没有可安全删除的当前备份"}
	}
	if err != nil {
		return photosDeletionAssetState{}, err
	}
	return asset, nil
}

func (a *App) verifyPhotoDeletionNotSharedOrProcessing(
	transaction *sql.Tx, ownerUserID, assetID string, requireExactlyOneMapping bool,
) error {
	var allMappings, processingJobs int
	err := transaction.QueryRow(
		`SELECT COUNT(1) FROM device_asset_mappings WHERE owner_user_id=? AND asset_id=?`,
		ownerUserID, assetID,
	).Scan(&allMappings)
	if err != nil {
		return err
	}
	if (requireExactlyOneMapping && allMappings != 1) || (!requireExactlyOneMapping && allMappings > 1) {
		return &photosDeleteRejected{message: "该 MyNAS 原件仍被其他备份记录使用，不能删除"}
	}
	err = transaction.QueryRow(
		`SELECT COUNT(1) FROM photo_derivative_jobs
		 WHERE owner_user_id=? AND asset_id=? AND status=?`,
		ownerUserID, assetID, photosDerivativeStateProcessing,
	).Scan(&processingJobs)
	if err != nil {
		return err
	}
	if processingJobs != 0 {
		return &photosDeleteRejected{message: "MyNAS 正在生成该照片的预览，请稍后再删除"}
	}
	return nil
}

func (a *App) planPhotoDeletionStorage(
	transaction *sql.Tx, ownerUserID string, asset photosDeletionAssetState,
) (photosDeletePlan, error) {
	if !isSHA256(asset.Fingerprint) {
		return photosDeletePlan{}, errors.New("photo asset fingerprint is invalid")
	}

	volume, err := a.volumeByIDInTransaction(transaction, asset.VolumeID)
	if err != nil || volume.Status != "online" {
		return photosDeletePlan{}, &photosDeleteRejected{message: "保存该备份的 MyNAS 磁盘当前不可用"}
	}
	originalStoragePath := filepath.ToSlash(filepath.Join(
		"users", photosOwnerPathComponent(ownerUserID), "photos", "originals", asset.Fingerprint[:2], asset.AssetID,
	))
	if err = verifyPhotoResourceGroupPath(transaction, ownerUserID, asset.AssetID, originalStoragePath); err != nil {
		return photosDeletePlan{}, err
	}
	originalSource, err := resolveWithin(volume.Mount, originalStoragePath, false)
	if err != nil {
		return photosDeletePlan{}, &photosDeleteRejected{message: "MyNAS 无法确认该备份的完整原始资源"}
	}

	derivativeStoragePath := filepath.ToSlash(filepath.Join(
		"users", photosOwnerPathComponent(ownerUserID), "photos", "derivatives", asset.Fingerprint[:2], asset.AssetID,
	))
	if err = verifyPhotoDerivativeGroupPath(transaction, ownerUserID, asset.AssetID, derivativeStoragePath); err != nil {
		return photosDeletePlan{}, err
	}
	derivativeSource := filepath.Join(volume.Mount, filepath.FromSlash(derivativeStoragePath))
	hasDerivativeDirectory := false
	if info, statErr := os.Stat(derivativeSource); statErr == nil {
		if !info.IsDir() {
			return photosDeletePlan{}, errors.New("photo derivative storage is not a directory")
		}
		derivativeSource, err = resolveWithin(volume.Mount, derivativeStoragePath, false)
		if err != nil {
			return photosDeletePlan{}, errors.New("photo derivative storage path is invalid")
		}
		hasDerivativeDirectory = true
	} else if !os.IsNotExist(statErr) {
		return photosDeletePlan{}, statErr
	}
	deleteID, err := newOpaqueID("pdel")
	if err != nil {
		return photosDeletePlan{}, err
	}
	return photosDeletePlan{
		AssetID: asset.AssetID, ExpectedVersion: asset.Version, DeleteID: deleteID,
		VolumeID: asset.VolumeID, VolumeMount: volume.Mount,
		OriginalSource: originalSource, DerivativeSource: derivativeSource,
		HasDerivativeDirectory: hasDerivativeDirectory,
		DeletedAt:              time.Now().UTC().Format(time.RFC3339Nano),
	}, nil
}

func deletePhotoAssetMetadata(transaction *sql.Tx, ownerUserID string, plan photosDeletePlan) error {
	// Check the optimistic gallery version before removing *any* dependent rows.
	// The final DELETE repeats it as the SQL mutation guard; this first query
	// prevents a stale plan from deleting fresh metadata before that guard runs.
	var currentCount int
	if err := transaction.QueryRow(
		`SELECT COUNT(1) FROM photo_assets
		 WHERE owner_user_id=? AND id=? AND source_state=? AND updated=?`,
		ownerUserID, plan.AssetID, photosSourceStateCommitted, plan.ExpectedVersion,
	).Scan(&currentCount); err != nil {
		return err
	}
	if currentCount != 1 {
		return &photosDeleteRejected{message: "MyNAS 项目已更新；未执行删除"}
	}

	for _, query := range []string{
		`DELETE FROM photo_upload_resources WHERE upload_session_id IN (
			SELECT id FROM photo_upload_sessions WHERE owner_user_id=? AND asset_id=?
		)`,
		`DELETE FROM photo_upload_sessions WHERE owner_user_id=? AND asset_id=?`,
		`DELETE FROM photo_derivative_jobs WHERE owner_user_id=? AND asset_id=?`,
		`DELETE FROM photo_derivatives WHERE owner_user_id=? AND asset_id=?`,
		`DELETE FROM photo_resources WHERE owner_user_id=? AND asset_id=?`,
		`DELETE FROM photo_asset_version_transitions
		 WHERE owner_user_id=? AND (from_asset_id=? OR to_asset_id=?)`,
		`DELETE FROM device_asset_mappings WHERE owner_user_id=? AND asset_id=?`,
	} {
		arguments := []any{ownerUserID, plan.AssetID}
		if strings.Contains(query, "from_asset_id") {
			arguments = []any{ownerUserID, plan.AssetID, plan.AssetID}
		}
		if _, err := transaction.Exec(query, arguments...); err != nil {
			return err
		}
	}
	result, err := transaction.Exec(
		`DELETE FROM photo_assets WHERE owner_user_id=? AND id=? AND source_state=? AND updated=?`,
		ownerUserID, plan.AssetID, photosSourceStateCommitted, plan.ExpectedVersion,
	)
	if err != nil {
		return err
	}
	if affected, err := result.RowsAffected(); err != nil || affected != 1 {
		if err != nil {
			return err
		}
		return &photosDeleteRejected{message: "MyNAS 项目已更新；未执行删除"}
	}
	_, err = transaction.Exec(
		`INSERT OR IGNORE INTO photo_changes(
			owner_user_id,asset_id,change_type,asset_updated,created
		 ) VALUES(?,?,'delete',?,?)`,
		ownerUserID, plan.AssetID, plan.DeletedAt, plan.DeletedAt,
	)
	return err
}

func verifyPhotoResourceGroupPath(
	transaction *sql.Tx, ownerUserID, assetID, expectedDirectory string,
) error {
	rows, err := transaction.Query(
		`SELECT storage_path FROM photo_resources WHERE owner_user_id=? AND asset_id=?`,
		ownerUserID, assetID,
	)
	if err != nil {
		return err
	}
	defer rows.Close()
	count := 0
	for rows.Next() {
		var storagePath string
		if err = rows.Scan(&storagePath); err != nil {
			return err
		}
		if filepath.ToSlash(filepath.Dir(storagePath)) != expectedDirectory {
			return errors.New("photo resource group storage path is invalid")
		}
		count++
	}
	if err = rows.Err(); err != nil {
		return err
	}
	if count == 0 {
		return errors.New("photo asset has no original resources")
	}
	return nil
}

func verifyPhotoDerivativeGroupPath(
	transaction *sql.Tx, ownerUserID, assetID, expectedDirectory string,
) error {
	rows, err := transaction.Query(
		`SELECT storage_path FROM photo_derivatives
		 WHERE owner_user_id=? AND asset_id=? AND storage_path IS NOT NULL`,
		ownerUserID, assetID,
	)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var storagePath string
		if err = rows.Scan(&storagePath); err != nil {
			return err
		}
		if !strings.HasPrefix(filepath.ToSlash(filepath.Clean(storagePath)), expectedDirectory+"/") {
			return errors.New("photo derivative storage path is invalid")
		}
	}
	return rows.Err()
}

func stagePhotoAssetDeletion(plan *photosDeletePlan) error {
	stagingRoot := photoDeleteStagingRoot(plan.VolumeMount, plan.DeleteID)
	if err := os.MkdirAll(stagingRoot, 0700); err != nil {
		return err
	}
	if err := movePath(plan.OriginalSource, filepath.Join(stagingRoot, "originals")); err != nil {
		_ = os.RemoveAll(stagingRoot)
		return err
	}
	plan.OriginalStaged = true
	if plan.HasDerivativeDirectory {
		if err := movePath(plan.DerivativeSource, filepath.Join(stagingRoot, "derivatives")); err != nil {
			_ = movePath(filepath.Join(stagingRoot, "originals"), plan.OriginalSource)
			plan.OriginalStaged = false
			_ = os.RemoveAll(stagingRoot)
			return err
		}
		plan.DerivativeStaged = true
	}
	return nil
}

func rollbackStagedPhotoDeletions(plans []photosDeletePlan) {
	for index := len(plans) - 1; index >= 0; index-- {
		plan := plans[index]
		stagingRoot := photoDeleteStagingRoot(plan.VolumeMount, plan.DeleteID)
		if plan.DerivativeStaged {
			_ = movePath(filepath.Join(stagingRoot, "derivatives"), plan.DerivativeSource)
		}
		if plan.OriginalStaged {
			_ = movePath(filepath.Join(stagingRoot, "originals"), plan.OriginalSource)
		}
		_ = os.RemoveAll(stagingRoot)
	}
}

func photoDeleteStagingRoot(volumeMount, deleteID string) string {
	return filepath.Join(volumeMount, ".mynas", "photos-delete-staging", deleteID)
}

func validatePhotosDeleteItems(items []photosDeleteItemInput) error {
	if len(items) == 0 || len(items) > photosMaximumPageSize {
		return errors.New("select between 1 and 200 photos")
	}
	seenAssets := make(map[string]bool, len(items))
	for index := range items {
		item := &items[index]
		item.AssetID = strings.TrimSpace(item.AssetID)
		item.DeviceID = strings.TrimSpace(item.DeviceID)
		item.LocalIdentifier = strings.TrimSpace(item.LocalIdentifier)
		item.SourceModificationDate = strings.TrimSpace(item.SourceModificationDate)
		if err := validatePhotoAssetID(item.AssetID); err != nil {
			return err
		}
		if item.DeviceID == "" || len(item.DeviceID) > 200 {
			return errors.New("invalid device ID")
		}
		if item.LocalIdentifier == "" || len(item.LocalIdentifier) > 1200 {
			return errors.New("invalid local identifier")
		}
		if item.SourceModificationDate == "" || len(item.SourceModificationDate) > 100 {
			return errors.New("invalid source modification date")
		}
		if seenAssets[item.AssetID] {
			return errors.New("duplicate photo asset")
		}
		seenAssets[item.AssetID] = true
	}
	return nil
}

func validatePhotoAssetID(assetID string) error {
	assetID = strings.TrimSpace(assetID)
	if assetID == "" || len(assetID) > 200 || strings.ContainsAny(assetID, "/\\\x00") {
		return errors.New("invalid photo asset ID")
	}
	return nil
}

func writePhotoDeletionError(w http.ResponseWriter, err error) {
	var rejected *photosDeleteRejected
	if errors.As(err, &rejected) {
		http.Error(w, rejected.message, http.StatusConflict)
		return
	}
	http.Error(w, "photo deletion unavailable", http.StatusInternalServerError)
}
