package main

const (
	photosBackupStateModelVersion = 1
	photosDerivativePolicyVersion = "photos-browse-v1"

	photosSourceStateCommitted = "sourceCommitted"

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

// photosBrowseRecipesV1 is the contract E2's worker must implement. These
// derivatives are disposable, versioned views of the immutable original
// resources; none of them may replace a Live Photo pair, HDR original, or RAW.
var photosBrowseRecipesV1 = []photosDerivativeRecipe{
	{
		ID:                "photos.tiny.center-crop.v1",
		Kind:              "tiny",
		MaxPixelDimension: 256,
		ResizeMode:        "centerCrop",
		RequiredForBrowse: true,
	},
	{
		ID:                "photos.grid.center-crop.v1",
		Kind:              "grid",
		MaxPixelDimension: 768,
		ResizeMode:        "centerCrop",
		RequiredForBrowse: true,
	},
	{
		ID:                "photos.preview.aspect-fit.v1",
		Kind:              "preview",
		MaxPixelDimension: 2560,
		ResizeMode:        "aspectFit",
		RequiredForBrowse: true,
	},
}

func requiredPhotosDerivativeKinds() []string {
	kinds := make([]string, 0, len(photosBrowseRecipesV1))
	for _, recipe := range photosBrowseRecipesV1 {
		if recipe.RequiredForBrowse {
			kinds = append(kinds, recipe.Kind)
		}
	}
	return kinds
}
