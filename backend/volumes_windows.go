//go:build windows

package main

func mountedVolumeInfo(mount string) (device, filesystem, uuid, label string) {
	return mount, "Windows 文件系统", "", "NAS 数据盘"
}

func discoverVolumeCandidates(registered map[string]bool) ([]VolumeCandidate, error) {
	return []VolumeCandidate{}, nil
}

func diskIOForDevice(device string) (uint64, uint64) { return 0, 0 }
