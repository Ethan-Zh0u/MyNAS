package main

import (
	"database/sql"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

func TestPhotosE1MigratesLegacyBackedUpAssetToPendingDerivativeJob(t *testing.T) {
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "legacy-photos.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	configureDB(db)

	_, err = db.Exec(`CREATE TABLE photo_assets(
		id TEXT PRIMARY KEY,
		owner_user_id TEXT NOT NULL,
		volume_id TEXT NOT NULL,
		content_fingerprint TEXT NOT NULL,
		media_type TEXT NOT NULL,
		capture_date TEXT,
		modification_date TEXT,
		pixel_width INTEGER NOT NULL DEFAULT 0,
		pixel_height INTEGER NOT NULL DEFAULT 0,
		duration REAL NOT NULL DEFAULT 0,
		favorite INTEGER NOT NULL DEFAULT 0,
		backup_state TEXT NOT NULL,
		created TEXT NOT NULL,
		updated TEXT NOT NULL,
		UNIQUE(owner_user_id,volume_id,content_fingerprint)
	);
	INSERT INTO photo_assets(
		id,owner_user_id,volume_id,content_fingerprint,media_type,
		backup_state,created,updated
	) VALUES(
		'ast_legacy','usr_legacy','primary','abcdef','photo',
		'backedUp','2026-07-24T00:00:00Z','2026-07-24T00:00:00Z'
	);`)
	if err != nil {
		t.Fatal(err)
	}

	app := &App{db: db}
	if err = app.migrate(); err != nil {
		t.Fatal(err)
	}
	// Migrations must be safe to repeat during every server startup.
	if err = app.migrate(); err != nil {
		t.Fatal(err)
	}

	var sourceState, derivativeState, recipeVersion string
	if err = db.QueryRow(
		`SELECT source_state,derivative_state,derivative_recipe_version
		 FROM photo_assets WHERE id='ast_legacy'`,
	).Scan(&sourceState, &derivativeState, &recipeVersion); err != nil {
		t.Fatal(err)
	}
	if sourceState != photosSourceStateCommitted ||
		derivativeState != photosDerivativeStatePending ||
		recipeVersion != photosDerivativePolicyVersion {
		t.Fatalf(
			"legacy state=(%q,%q,%q)",
			sourceState,
			derivativeState,
			recipeVersion,
		)
	}

	var jobs int
	if err = db.QueryRow(
		`SELECT COUNT(*) FROM photo_derivative_jobs
		 WHERE asset_id='ast_legacy' AND recipe_version=? AND status=?`,
		photosDerivativePolicyVersion,
		photosDerivativeJobPending,
	).Scan(&jobs); err != nil {
		t.Fatal(err)
	}
	if jobs != 1 {
		t.Fatalf("pending derivative jobs=%d, want 1", jobs)
	}
}
