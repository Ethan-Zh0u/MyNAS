//go:build darwin

package main

// macOS local development uses an explicitly configured directory inside the
// repository as its primary volume. External-disk discovery remains a Linux
// deployment concern, so Darwin reports only that configured development root.
func mountedVolumeInfo(mount string) (device, filesystem, uuid, label string) {
	return mount, "macOS 文件系统", "", "NAS 开发数据"
}

func discoverVolumeCandidates(registered map[string]bool) ([]VolumeCandidate, error) {
	return []VolumeCandidate{}, nil
}

func diskIOForDevice(device string) (uint64, uint64) { return 0, 0 }
