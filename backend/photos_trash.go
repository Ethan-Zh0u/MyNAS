package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Photo deletion is intentionally separate from the generic filesystem trash.
// A PhotoKit item can represent a Live Photo, RAW + sidecars, or other complete
// source-resource group. Moving only one file through /operations would violate
// the backup-integrity contract, so this endpoint moves the entire asset group.
type photosTrashItemInput struct {
	AssetID                string `json:"assetID"`
	DeviceID               string `json:"deviceID"`
	LocalIdentifier        string `json:"localIdentifier"`
	SourceModificationDate string `json:"sourceModificationDate"`
}

type photosTrashAssetsInput struct {
	Items []photosTrashItemInput `json:"items"`
}

type photosTrashItemResponse struct {
	AssetID   string `json:"assetID"`
	TrashID   string `json:"trashID"`
	TrashedAt string `json:"trashedAt"`
}

type photosTrashAssetsResponse struct {
	Items []photosTrashItemResponse `json:"items"`
}

type photosRestoreAssetsInput struct {
	AssetIDs []string `json:"assetIDs"`
}

type photosRestoreItemResponse struct {
	AssetID    string `json:"assetID"`
	RestoredAt string `json:"restoredAt"`
}

type photosRestoreAssetsResponse struct {
	Items []photosRestoreItemResponse `json:"items"`
}

// photosTrashRejected is deliberately returned as HTTP 409: the caller made a
// well-formed request, but the current server truth says it would be unsafe to
// remove the MyNAS copy. The app must not try to work around this client-side.
type photosTrashRejected struct{ message string }

func (e *photosTrashRejected) Error() string { return e.message }

type photosTrashPlan struct {
	AssetID                string
	TrashID                string
	VolumeID               string
	VolumeMount            string
	ContentFingerprint     string
	OriginalStoragePath    string
	DerivativeStoragePath  string
	OriginalSource         string
	DerivativeSource       string
	HasDerivativeDirectory bool
	TrashedAt              string
	OriginalMoved          bool
	DerivativeMoved        bool
}

type photosRestorePlan struct {
	AssetID                string
	TrashID                string
	VolumeID               string
	VolumeMount            string
	ContentFingerprint     string
	OriginalStoragePath    string
	DerivativeStoragePath  string
	OriginalDestination    string
	DerivativeDestination  string
	HasDerivativeDirectory bool
	RestoredAt             string
	OriginalMoved          bool
	DerivativeMoved        bool
}

func (a *App) photosTrashAssets(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	owner, ok := a.photosRequestOwner(w, r)
	if !ok {
		return
	}
	var input photosTrashAssetsInput
	if err := readJSON(r, &input); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if err := validatePhotosTrashItems(input.Items); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	transaction, err := a.db.Begin()
	if err != nil {
		http.Error(w, "photo trash unavailable", http.StatusInternalServerError)
		return
	}
	defer transaction.Rollback()

	plans := make([]photosTrashPlan, 0, len(input.Items))
	for _, item := range input.Items {
		plan, planErr := a.planPhotoTrash(transaction, owner.UserID, item)
		if planErr != nil {
			writePhotosTrashError(w, planErr)
			return
		}
		plans = append(plans, plan)
	}

	for index := range plans {
		if err = movePhotoAssetToTrash(&plans[index]); err != nil {
			rollbackMovedPhotoTrash(plans)
			http.Error(w, "cannot move photo resources to MyNAS trash", http.StatusInternalServerError)
			return
		}
	}

	for _, plan := range plans {
		if _, err = transaction.Exec(
			`UPDATE photo_assets
			 SET source_state=?,content_fingerprint=?,updated=?
			 WHERE owner_user_id=? AND id=? AND source_state=?`,
			photosSourceStateTrashed, "trashed:"+plan.TrashID, plan.TrashedAt,
			owner.UserID, plan.AssetID, photosSourceStateCommitted,
		); err != nil {
			rollbackMovedPhotoTrash(plans)
			http.Error(w, "cannot update MyNAS photo trash", http.StatusInternalServerError)
			return
		}
		if _, err = transaction.Exec(
			`INSERT INTO photo_trash_entries(
				id,owner_user_id,asset_id,volume_id,original_content_fingerprint,
				original_storage_path,derivative_storage_path,trashed_at,restored_at
			 ) VALUES(?,?,?,?,?,?,?,?,NULL)`,
			plan.TrashID, owner.UserID, plan.AssetID, plan.VolumeID, plan.ContentFingerprint,
			plan.OriginalStoragePath, nullableStringValue(plan.DerivativeStoragePath), plan.TrashedAt,
		); err != nil {
			rollbackMovedPhotoTrash(plans)
			http.Error(w, "cannot record MyNAS photo trash", http.StatusInternalServerError)
			return
		}
		if _, err = transaction.Exec(
			`INSERT OR IGNORE INTO photo_changes(
				owner_user_id,asset_id,change_type,asset_updated,created
			 ) VALUES(?,?,'delete',?,?)`,
			owner.UserID, plan.AssetID, plan.TrashedAt, plan.TrashedAt,
		); err != nil {
			rollbackMovedPhotoTrash(plans)
			http.Error(w, "cannot update MyNAS photo changes", http.StatusInternalServerError)
			return
		}
	}
	if err = transaction.Commit(); err != nil {
		rollbackMovedPhotoTrash(plans)
		http.Error(w, "cannot commit MyNAS photo trash", http.StatusInternalServerError)
		return
	}

	response := photosTrashAssetsResponse{Items: make([]photosTrashItemResponse, 0, len(plans))}
	for _, plan := range plans {
		response.Items = append(response.Items, photosTrashItemResponse{
			AssetID: plan.AssetID, TrashID: plan.TrashID, TrashedAt: plan.TrashedAt,
		})
	}
	writeJSON(w, response)
}

func (a *App) photosRestoreAssetsFromRequest(w http.ResponseWriter, r *http.Request) {
	var input photosRestoreAssetsInput
	if err := readJSON(r, &input); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	a.photosRestoreAssets(w, r, input.AssetIDs)
}

func (a *App) photosRestoreAssets(w http.ResponseWriter, r *http.Request, assetIDs []string) {
	if r.Method != http.MethodPost {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	owner, ok := a.photosRequestOwner(w, r)
	if !ok {
		return
	}
	if err := validatePhotoAssetIDs(assetIDs); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	transaction, err := a.db.Begin()
	if err != nil {
		http.Error(w, "photo restore unavailable", http.StatusInternalServerError)
		return
	}
	defer transaction.Rollback()
	plans := make([]photosRestorePlan, 0, len(assetIDs))
	for _, assetID := range assetIDs {
		plan, planErr := a.planPhotoRestore(transaction, owner.UserID, assetID)
		if planErr != nil {
			writePhotosTrashError(w, planErr)
			return
		}
		plans = append(plans, plan)
	}
	for index := range plans {
		if err = restorePhotoAssetFromTrash(&plans[index]); err != nil {
			rollbackRestoredPhotoTrash(plans)
			http.Error(w, "cannot restore MyNAS photo resources", http.StatusInternalServerError)
			return
		}
	}
	for _, plan := range plans {
		if _, err = transaction.Exec(
			`UPDATE photo_assets
			 SET source_state=?,content_fingerprint=?,updated=?
			 WHERE owner_user_id=? AND id=? AND source_state=?`,
			photosSourceStateCommitted, plan.ContentFingerprint, plan.RestoredAt,
			owner.UserID, plan.AssetID, photosSourceStateTrashed,
		); err != nil {
			rollbackRestoredPhotoTrash(plans)
			http.Error(w, "cannot update restored MyNAS photo", http.StatusInternalServerError)
			return
		}
		if _, err = transaction.Exec(
			`UPDATE photo_trash_entries SET restored_at=?
			 WHERE id=? AND owner_user_id=? AND restored_at IS NULL`,
			plan.RestoredAt, plan.TrashID, owner.UserID,
		); err != nil {
			rollbackRestoredPhotoTrash(plans)
			http.Error(w, "cannot record restored MyNAS photo", http.StatusInternalServerError)
			return
		}
		if _, err = transaction.Exec(
			`INSERT OR IGNORE INTO photo_changes(
				owner_user_id,asset_id,change_type,asset_updated,created
			 ) VALUES(?,?,'upsert',?,?)`,
			owner.UserID, plan.AssetID, plan.RestoredAt, plan.RestoredAt,
		); err != nil {
			rollbackRestoredPhotoTrash(plans)
			http.Error(w, "cannot update restored MyNAS photo changes", http.StatusInternalServerError)
			return
		}
	}
	if err = transaction.Commit(); err != nil {
		rollbackRestoredPhotoTrash(plans)
		http.Error(w, "cannot commit restored MyNAS photo", http.StatusInternalServerError)
		return
	}
	a.wakePhotoDerivativeWorker()
	response := photosRestoreAssetsResponse{Items: make([]photosRestoreItemResponse, 0, len(plans))}
	for _, plan := range plans {
		response.Items = append(response.Items, photosRestoreItemResponse{
			AssetID: plan.AssetID, RestoredAt: plan.RestoredAt,
		})
	}
	writeJSON(w, response)
}

func (a *App) planPhotoTrash(
	transaction *sql.Tx, ownerUserID string, item photosTrashItemInput,
) (photosTrashPlan, error) {
	var volumeID, fingerprint string
	var modificationDate sql.NullString
	err := transaction.QueryRow(
		`SELECT volume_id,content_fingerprint,modification_date
		 FROM photo_assets
		 WHERE owner_user_id=? AND id=? AND source_state=?`,
		ownerUserID, item.AssetID, photosSourceStateCommitted,
	).Scan(&volumeID, &fingerprint, &modificationDate)
	if errors.Is(err, sql.ErrNoRows) {
		return photosTrashPlan{}, &photosTrashRejected{message: "MyNAS 上没有可安全删除的当前备份"}
	}
	if err != nil {
		return photosTrashPlan{}, err
	}
	if !modificationDate.Valid || modificationDate.String != item.SourceModificationDate {
		return photosTrashPlan{}, &photosTrashRejected{message: "本机照片版本已经变化；请先完成当前版本备份"}
	}
	var matchingMappings, allMappings, processingJobs int
	if err = transaction.QueryRow(
		`SELECT COUNT(1) FROM device_asset_mappings
		 WHERE owner_user_id=? AND device_id=? AND local_identifier=? AND asset_id=?`,
		ownerUserID, item.DeviceID, item.LocalIdentifier, item.AssetID,
	).Scan(&matchingMappings); err != nil {
		return photosTrashPlan{}, err
	}
	if matchingMappings != 1 {
		return photosTrashPlan{}, &photosTrashRejected{message: "MyNAS 备份与当前 iPhone 照片的验证关系已变化"}
	}
	if err = transaction.QueryRow(
		`SELECT COUNT(1) FROM device_asset_mappings WHERE owner_user_id=? AND asset_id=?`,
		ownerUserID, item.AssetID,
	).Scan(&allMappings); err != nil {
		return photosTrashPlan{}, err
	}
	if allMappings != 1 {
		return photosTrashPlan{}, &photosTrashRejected{message: "该 MyNAS 原件仍被其他备份记录使用，不能随本机照片一同删除"}
	}
	if err = transaction.QueryRow(
		`SELECT COUNT(1) FROM photo_derivative_jobs
		 WHERE owner_user_id=? AND asset_id=? AND status=?`,
		ownerUserID, item.AssetID, photosDerivativeStateProcessing,
	).Scan(&processingJobs); err != nil {
		return photosTrashPlan{}, err
	}
	if processingJobs != 0 {
		return photosTrashPlan{}, &photosTrashRejected{message: "MyNAS 正在生成该照片的预览，请稍后再删除"}
	}
	if !isSHA256(fingerprint) {
		return photosTrashPlan{}, errors.New("photo asset fingerprint is invalid")
	}

	volume, err := a.volumeByID(volumeID)
	if err != nil || volume.Status != "online" {
		return photosTrashPlan{}, &photosTrashRejected{message: "保存该备份的 MyNAS 磁盘当前不可用"}
	}
	originalStoragePath := filepath.ToSlash(filepath.Join(
		"users", photosOwnerPathComponent(ownerUserID), "photos", "originals", fingerprint[:2], item.AssetID,
	))
	if err = verifyPhotoResourceGroupPath(transaction, ownerUserID, item.AssetID, originalStoragePath); err != nil {
		return photosTrashPlan{}, err
	}
	originalSource, err := a.pathFor(volumeID, originalStoragePath, false)
	if err != nil {
		return photosTrashPlan{}, &photosTrashRejected{message: "MyNAS 无法确认该备份的完整原始资源"}
	}
	derivativeStoragePath := filepath.ToSlash(filepath.Join(
		"users", photosOwnerPathComponent(ownerUserID), "photos", "derivatives", fingerprint[:2], item.AssetID,
	))
	if err = verifyPhotoDerivativeGroupPath(transaction, ownerUserID, item.AssetID, derivativeStoragePath); err != nil {
		return photosTrashPlan{}, err
	}
	derivativeSource := filepath.Join(volume.Mount, filepath.FromSlash(derivativeStoragePath))
	hasDerivativeDirectory := false
	if info, statErr := os.Stat(derivativeSource); statErr == nil {
		if !info.IsDir() {
			return photosTrashPlan{}, errors.New("photo derivative storage is not a directory")
		}
		derivativeSource, err = a.pathFor(volumeID, derivativeStoragePath, false)
		if err != nil {
			return photosTrashPlan{}, errors.New("photo derivative storage path is invalid")
		}
		hasDerivativeDirectory = true
	} else if !os.IsNotExist(statErr) {
		return photosTrashPlan{}, statErr
	}
	trashID, err := newOpaqueID("ptr")
	if err != nil {
		return photosTrashPlan{}, err
	}
	return photosTrashPlan{
		AssetID: item.AssetID, TrashID: trashID, VolumeID: volumeID, VolumeMount: volume.Mount,
		ContentFingerprint: fingerprint, OriginalStoragePath: originalStoragePath,
		DerivativeStoragePath: derivativeStoragePath, OriginalSource: originalSource,
		DerivativeSource: derivativeSource, HasDerivativeDirectory: hasDerivativeDirectory,
		TrashedAt: time.Now().UTC().Format(time.RFC3339Nano),
	}, nil
}

func (a *App) planPhotoRestore(
	transaction *sql.Tx, ownerUserID, assetID string,
) (photosRestorePlan, error) {
	var plan photosRestorePlan
	var derivativeStoragePath sql.NullString
	err := transaction.QueryRow(
		`SELECT t.id,t.volume_id,t.original_content_fingerprint,t.original_storage_path,
		        t.derivative_storage_path
		 FROM photo_trash_entries t
		 JOIN photo_assets a ON a.id=t.asset_id AND a.owner_user_id=t.owner_user_id
		 WHERE t.owner_user_id=? AND t.asset_id=? AND t.restored_at IS NULL
		   AND a.source_state=?`,
		ownerUserID, assetID, photosSourceStateTrashed,
	).Scan(
		&plan.TrashID, &plan.VolumeID, &plan.ContentFingerprint, &plan.OriginalStoragePath,
		&derivativeStoragePath,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return photosRestorePlan{}, &photosTrashRejected{message: "找不到可恢复的 MyNAS 照片回收站项目"}
	}
	if err != nil {
		return photosRestorePlan{}, err
	}
	if !isSHA256(plan.ContentFingerprint) {
		return photosRestorePlan{}, errors.New("trashed photo fingerprint is invalid")
	}
	plan.AssetID = assetID
	plan.DerivativeStoragePath = derivativeStoragePath.String
	expectedOriginalPath := filepath.ToSlash(filepath.Join(
		"users", photosOwnerPathComponent(ownerUserID), "photos", "originals",
		plan.ContentFingerprint[:2], assetID,
	))
	if plan.OriginalStoragePath != expectedOriginalPath {
		return photosRestorePlan{}, errors.New("trashed photo original path is invalid")
	}
	expectedDerivativePath := filepath.ToSlash(filepath.Join(
		"users", photosOwnerPathComponent(ownerUserID), "photos", "derivatives",
		plan.ContentFingerprint[:2], assetID,
	))
	if plan.DerivativeStoragePath != "" && plan.DerivativeStoragePath != expectedDerivativePath {
		return photosRestorePlan{}, errors.New("trashed photo derivative path is invalid")
	}
	var duplicateCount int
	if err = transaction.QueryRow(
		`SELECT COUNT(1) FROM photo_assets
		 WHERE owner_user_id=? AND volume_id=? AND content_fingerprint=?
		   AND source_state=? AND id<>?`,
		ownerUserID, plan.VolumeID, plan.ContentFingerprint, photosSourceStateCommitted, assetID,
	).Scan(&duplicateCount); err != nil {
		return photosRestorePlan{}, err
	}
	if duplicateCount != 0 {
		return photosRestorePlan{}, &photosTrashRejected{message: "MyNAS 已有相同内容的新备份，不能覆盖恢复"}
	}
	volume, err := a.volumeByID(plan.VolumeID)
	if err != nil || volume.Status != "online" {
		return photosRestorePlan{}, &photosTrashRejected{message: "保存该回收站项目的 MyNAS 磁盘当前不可用"}
	}
	plan.VolumeMount = volume.Mount
	plan.OriginalDestination, err = a.pathFor(plan.VolumeID, plan.OriginalStoragePath, true)
	if err != nil {
		return photosRestorePlan{}, &photosTrashRejected{message: "MyNAS 无法准备原始资源的恢复位置"}
	}
	plan.DerivativeDestination = filepath.Join(volume.Mount, filepath.FromSlash(expectedDerivativePath))
	plan.HasDerivativeDirectory = plan.DerivativeStoragePath != ""
	plan.RestoredAt = time.Now().UTC().Format(time.RFC3339Nano)
	return plan, nil
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

func movePhotoAssetToTrash(plan *photosTrashPlan) error {
	trashRoot := photoTrashRoot(plan.VolumeMount, plan.TrashID)
	if err := os.MkdirAll(trashRoot, 0700); err != nil {
		return err
	}
	originalDestination := filepath.Join(trashRoot, "originals")
	if err := movePath(plan.OriginalSource, originalDestination); err != nil {
		_ = os.RemoveAll(trashRoot)
		return err
	}
	plan.OriginalMoved = true
	if plan.HasDerivativeDirectory {
		derivativeDestination := filepath.Join(trashRoot, "derivatives")
		if err := movePath(plan.DerivativeSource, derivativeDestination); err != nil {
			_ = movePath(originalDestination, plan.OriginalSource)
			plan.OriginalMoved = false
			_ = os.RemoveAll(trashRoot)
			return err
		}
		plan.DerivativeMoved = true
	}
	metadata, _ := json.Marshal(map[string]string{
		"format": "mynas-photos-trash-v1", "assetID": plan.AssetID, "trashedAt": plan.TrashedAt,
	})
	if err := os.WriteFile(filepath.Join(trashRoot, "meta.json"), metadata, 0600); err != nil {
		rollbackOneMovedPhotoTrash(*plan)
		return err
	}
	return nil
}

func restorePhotoAssetFromTrash(plan *photosRestorePlan) error {
	trashRoot := photoTrashRoot(plan.VolumeMount, plan.TrashID)
	originalSource := filepath.Join(trashRoot, "originals")
	if _, err := os.Stat(originalSource); err != nil {
		return err
	}
	if _, err := os.Stat(plan.OriginalDestination); err == nil {
		return fmt.Errorf("photo restore destination already exists")
	} else if !os.IsNotExist(err) {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(plan.OriginalDestination), 0700); err != nil {
		return err
	}
	if err := movePath(originalSource, plan.OriginalDestination); err != nil {
		return err
	}
	plan.OriginalMoved = true
	if plan.HasDerivativeDirectory {
		derivativeSource := filepath.Join(trashRoot, "derivatives")
		if _, err := os.Stat(derivativeSource); err == nil {
			if _, destinationErr := os.Stat(plan.DerivativeDestination); destinationErr == nil {
				rollbackOneRestoredPhotoTrash(*plan)
				return fmt.Errorf("photo derivative restore destination already exists")
			} else if !os.IsNotExist(destinationErr) {
				rollbackOneRestoredPhotoTrash(*plan)
				return destinationErr
			}
			if err = os.MkdirAll(filepath.Dir(plan.DerivativeDestination), 0700); err != nil {
				rollbackOneRestoredPhotoTrash(*plan)
				return err
			}
			if err = movePath(derivativeSource, plan.DerivativeDestination); err != nil {
				rollbackOneRestoredPhotoTrash(*plan)
				return err
			}
			plan.DerivativeMoved = true
		} else if !os.IsNotExist(err) {
			rollbackOneRestoredPhotoTrash(*plan)
			return err
		}
	}
	return nil
}

func rollbackMovedPhotoTrash(plans []photosTrashPlan) {
	for index := len(plans) - 1; index >= 0; index-- {
		rollbackOneMovedPhotoTrash(plans[index])
	}
}

func rollbackOneMovedPhotoTrash(plan photosTrashPlan) {
	trashRoot := photoTrashRoot(plan.VolumeMount, plan.TrashID)
	if plan.DerivativeMoved {
		_ = movePath(filepath.Join(trashRoot, "derivatives"), plan.DerivativeSource)
	}
	if plan.OriginalMoved {
		_ = movePath(filepath.Join(trashRoot, "originals"), plan.OriginalSource)
	}
	_ = os.RemoveAll(trashRoot)
}

func rollbackRestoredPhotoTrash(plans []photosRestorePlan) {
	for index := len(plans) - 1; index >= 0; index-- {
		rollbackOneRestoredPhotoTrash(plans[index])
	}
}

func rollbackOneRestoredPhotoTrash(plan photosRestorePlan) {
	trashRoot := photoTrashRoot(plan.VolumeMount, plan.TrashID)
	_ = os.MkdirAll(trashRoot, 0700)
	if plan.DerivativeMoved {
		_ = movePath(plan.DerivativeDestination, filepath.Join(trashRoot, "derivatives"))
	}
	if plan.OriginalMoved {
		_ = movePath(plan.OriginalDestination, filepath.Join(trashRoot, "originals"))
	}
}

func photoTrashRoot(volumeMount, trashID string) string {
	return filepath.Join(volumeMount, ".mynas", "photos-trash", trashID)
}

func validatePhotosTrashItems(items []photosTrashItemInput) error {
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

func validatePhotoAssetIDs(assetIDs []string) error {
	if len(assetIDs) == 0 || len(assetIDs) > photosMaximumPageSize {
		return errors.New("select between 1 and 200 photos")
	}
	seen := make(map[string]bool, len(assetIDs))
	for _, assetID := range assetIDs {
		if err := validatePhotoAssetID(assetID); err != nil {
			return err
		}
		if seen[assetID] {
			return errors.New("duplicate photo asset")
		}
		seen[assetID] = true
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

func writePhotosTrashError(w http.ResponseWriter, err error) {
	var rejected *photosTrashRejected
	if errors.As(err, &rejected) {
		http.Error(w, rejected.message, http.StatusConflict)
		return
	}
	http.Error(w, "photo trash unavailable", http.StatusInternalServerError)
}

func nullableStringValue(value string) any {
	if value == "" {
		return nil
	}
	return value
}
