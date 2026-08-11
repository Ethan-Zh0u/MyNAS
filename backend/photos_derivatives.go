package main

const (
	photosBackupStateModelVersion = 1
	photosDerivativePolicyVersion = "photos-browse-v2"

	photosSourceStateCommitted  = "sourceCommitted"
	photosSourceStateSuperseded = "sourceSuperseded"

	photosDerivativeStatePending    = "pending"
	photosDerivativeStateProcessing = "processing"
	photosDerivativeStateReady      = "ready"
	photosDerivativeStateFailed     = "failed"

	photosDerivativeJobPending = "pending"
)

type photosDerivativeRecipe struct {
	ID                string
	Kind              string
	MaxPixelDimension int
	ResizeMode        string
	RequiredForBrowse bool
}

// photosBrowseRecipesV2 is the contract the worker must implement. These
// derivatives are disposable, versioned views of the immutable original
// resources; none of them may replace a Live Photo pair, HDR original, or RAW.
//
// V2 changes the source decoder for HEIC/HEIF. The version makes every old
// FFmpeg-selected embedded image unservable and schedules a replacement.
var photosBrowseRecipesV2 = []photosDerivativeRecipe{
	{
		ID:                "photos.tiny.center-crop.v2",
		Kind:              "tiny",
		MaxPixelDimension: 256,
		ResizeMode:        "centerCrop",
		RequiredForBrowse: true,
	},
	{
		ID:                "photos.grid.center-crop.v2",
		Kind:              "grid",
		MaxPixelDimension: 768,
		ResizeMode:        "centerCrop",
		RequiredForBrowse: true,
	},
	{
		ID:                "photos.preview.aspect-fit.v2",
		Kind:              "preview",
		MaxPixelDimension: 2560,
		ResizeMode:        "aspectFit",
		RequiredForBrowse: true,
	},
}

func requiredPhotosDerivativeKinds() []string {
	kinds := make([]string, 0, len(photosBrowseRecipesV2))
	for _, recipe := range photosBrowseRecipesV2 {
		if recipe.RequiredForBrowse {
			kinds = append(kinds, recipe.Kind)
		}
	}
	return kinds
}
