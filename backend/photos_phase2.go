package main

import (
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

const (
	photosAPIVersion       = "v1"
	photosServerVersion    = "0.7.0"
	photosMinimumApp       = "1.0"
	photosServerSettingKey = "photos.server_id"
)

type photosCapabilitiesResponse struct {
	ServerID             string                `json:"serverID"`
	APIVersion           string                `json:"apiVersion"`
	ServerVersion        string                `json:"serverVersion"`
	MinimumClientVersion string                `json:"minimumClientVersion"`
	BackupStateModel     int                   `json:"backupStateModelVersion"`
	DerivativePolicy     string                `json:"derivativePolicyVersion"`
	Features             photosFeatureResponse `json:"features"`
	DerivativeRecipes    []string              `json:"derivativeRecipes"`
	SupportsVolumes      bool                  `json:"supportsVolumes"`
}

type photosFeatureResponse struct {
	PhotoAssets         bool `json:"photoAssets"`
	BackgroundTransfers bool `json:"backgroundTransfers"`
	LivePhotos          bool `json:"livePhotos"`
}

type photosPairingResponse struct {
	Format    string `json:"format"`
	Version   int    `json:"version"`
	ServerURL string `json:"serverURL"`
	ServerID  string `json:"serverID"`
}

type photosMeResponse struct {
	ServerID               string  `json:"serverID"`
	UserID                 string  `json:"userID"`
	AuthenticationIdentity string  `json:"authenticationIdentity"`
	DisplayName            string  `json:"displayName"`
	AvatarVersion          *string `json:"avatarVersion"`
}

type photosVolumeResponse struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	Status         string `json:"status"`
	TotalBytes     uint64 `json:"totalBytes"`
	AvailableBytes uint64 `json:"availableBytes"`
	IsDefault      bool   `json:"isDefault"`
}

func (a *App) ensureServerID() error {
	if configured := strings.TrimSpace(os.Getenv("MYNAS_SERVER_ID")); configured != "" {
		a.serverID = configured
		return nil
	}
	if a.db == nil {
		return errors.New("database unavailable while creating server identity")
	}
	var serverID string
	err := a.db.QueryRow("SELECT value FROM app_settings WHERE key=?", photosServerSettingKey).Scan(&serverID)
	if err == nil {
		a.serverID = serverID
		return nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	serverID, err = newOpaqueID("srv")
	if err != nil {
		return err
	}
	if _, err = a.db.Exec(
		"INSERT OR IGNORE INTO app_settings(key,value) VALUES(?,?)",
		photosServerSettingKey,
		serverID,
	); err != nil {
		return err
	}
	if err = a.db.QueryRow("SELECT value FROM app_settings WHERE key=?", photosServerSettingKey).Scan(&serverID); err != nil {
		return err
	}
	a.serverID = serverID
	return nil
}

func (a *App) photosCapabilities(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	derivativeRecipes := []string{}
	if a.derivativeProcessor != nil {
		for _, recipe := range photosBrowseRecipesV1 {
			derivativeRecipes = append(derivativeRecipes, recipe.ID)
		}
	}
	writeJSON(w, photosCapabilitiesResponse{
		ServerID:             a.serverID,
		APIVersion:           photosAPIVersion,
		ServerVersion:        photosServerVersion,
		MinimumClientVersion: photosMinimumApp,
		BackupStateModel:     photosBackupStateModelVersion,
		DerivativePolicy:     photosDerivativePolicyVersion,
		Features: photosFeatureResponse{
			PhotoAssets:         true,
			BackgroundTransfers: false,
			LivePhotos:          true,
		},
		// Recipes are advertised only when a real processor is available.
		DerivativeRecipes: derivativeRecipes,
		SupportsVolumes:   true,
	})
}

func (a *App) photosPairing(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	serverURL, err := normalizedPhotosPairingURL(a.c.PrivateOrigin)
	if err != nil {
		http.Error(w, "MyNAS private Tailscale URL is not configured", http.StatusServiceUnavailable)
		return
	}
	writeJSON(w, photosPairingResponse{
		Format:    "mynas-photos-pairing",
		Version:   1,
		ServerURL: serverURL,
		ServerID:  a.serverID,
	})
}

func normalizedPhotosPairingURL(rawValue string) (string, error) {
	parsed, err := url.Parse(strings.TrimSpace(rawValue))
	if err != nil || parsed.Scheme != "https" || parsed.User != nil {
		return "", errors.New("invalid private origin")
	}
	host := strings.ToLower(parsed.Hostname())
	if host == "ts.net" || !strings.HasSuffix(host, ".ts.net") || parsed.Port() != "" {
		return "", errors.New("private origin must be a standard Tailscale HTTPS URL")
	}
	if parsed.RawQuery != "" || parsed.Fragment != "" || (parsed.Path != "" && parsed.Path != "/") {
		return "", errors.New("private origin must be a root URL")
	}
	return "https://" + host, nil
}

func (a *App) photosMe(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	tailscaleUser, ok := a.user(r)
	if !ok {
		http.Error(w, "Tailscale identity required", http.StatusUnauthorized)
		return
	}
	response, err := a.ensurePhotoUser(tailscaleUser)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, response)
}

func (a *App) photosVolumes(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	volumes, err := a.listVolumes()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	response := struct {
		Volumes []photosVolumeResponse `json:"volumes"`
	}{
		Volumes: make([]photosVolumeResponse, 0, len(volumes)),
	}
	for _, volume := range volumes {
		response.Volumes = append(response.Volumes, photosVolumeResponse{
			ID:             volume.ID,
			Name:           volume.Name,
			Status:         volume.Status,
			TotalBytes:     volume.Total,
			AvailableBytes: volume.Free,
			IsDefault:      volume.ID == "primary",
		})
	}
	writeJSON(w, response)
}

func (a *App) ensurePhotoUser(user User) (photosMeResponse, error) {
	if a.db == nil {
		return photosMeResponse{}, errors.New("database unavailable")
	}
	identity := strings.ToLower(strings.TrimSpace(user.Login))
	if identity == "" {
		return photosMeResponse{}, errors.New("empty Tailscale identity")
	}
	displayName := strings.TrimSpace(user.Name)
	if displayName == "" {
		displayName = strings.TrimSpace(user.Login)
	}
	var avatarVersion *string
	if user.Avatar != "" {
		hash := sha256.Sum256([]byte(user.Avatar))
		value := hex.EncodeToString(hash[:8])
		avatarVersion = &value
	}

	now := time.Now().UTC().Format(time.RFC3339)
	var userID string
	err := a.db.QueryRow(
		"SELECT id FROM photo_users WHERE authentication_identity=?",
		identity,
	).Scan(&userID)
	if errors.Is(err, sql.ErrNoRows) {
		candidateID, idErr := newOpaqueID("usr")
		if idErr != nil {
			return photosMeResponse{}, idErr
		}
		_, err = a.db.Exec(
			`INSERT OR IGNORE INTO photo_users(id,authentication_identity,display_name,avatar_version,created,updated)
			 VALUES(?,?,?,?,?,?)`,
			candidateID,
			identity,
			displayName,
			avatarVersion,
			now,
			now,
		)
		if err != nil {
			return photosMeResponse{}, err
		}
		err = a.db.QueryRow(
			"SELECT id FROM photo_users WHERE authentication_identity=?",
			identity,
		).Scan(&userID)
	}
	if err == nil {
		_, err = a.db.Exec(
			"UPDATE photo_users SET display_name=?,avatar_version=?,updated=? WHERE id=?",
			displayName,
			avatarVersion,
			now,
			userID,
		)
	}
	if err != nil {
		return photosMeResponse{}, err
	}
	return photosMeResponse{
		ServerID:               a.serverID,
		UserID:                 userID,
		AuthenticationIdentity: user.Login,
		DisplayName:            displayName,
		AvatarVersion:          avatarVersion,
	}, nil
}

func newOpaqueID(prefix string) (string, error) {
	buffer := make([]byte, 16)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	return prefix + "-" + hex.EncodeToString(buffer), nil
}
