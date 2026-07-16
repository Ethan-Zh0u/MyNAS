//go:build linux

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

func readUintFile(path string, field int) (uint64, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	fields := strings.Fields(string(data))
	if field < 0 || field >= len(fields) {
		return 0, fmt.Errorf("missing stat field %d", field)
	}
	return strconv.ParseUint(fields[field], 10, 64)
}

type lsblkDevice struct {
	Name        string        `json:"name"`
	Path        string        `json:"path"`
	Type        string        `json:"type"`
	Size        json.Number   `json:"size"`
	Filesystem  string        `json:"fstype"`
	UUID        string        `json:"uuid"`
	Label       string        `json:"label"`
	Mountpoints []interface{} `json:"mountpoints"`
	Model       string        `json:"model"`
	Serial      string        `json:"serial"`
	Removable   json.Number   `json:"rm"`
	ReadOnly    json.Number   `json:"ro"`
	Children    []lsblkDevice `json:"children"`
}

func mountedVolumeInfo(mount string) (device, filesystem, uuid, label string) {
	output, err := exec.Command("findmnt", "-J", "-o", "SOURCE,FSTYPE,TARGET,UUID,LABEL", "--target", mount).Output()
	if err != nil {
		return "", "", "", ""
	}
	var result struct {
		Filesystems []struct {
			Source string `json:"source"`
			FSType string `json:"fstype"`
			UUID   string `json:"uuid"`
			Label  string `json:"label"`
		} `json:"filesystems"`
	}
	if json.Unmarshal(output, &result) != nil || len(result.Filesystems) == 0 {
		return "", "", "", ""
	}
	row := result.Filesystems[0]
	return row.Source, row.FSType, row.UUID, row.Label
}

func candidateMountpoints(device lsblkDevice) []string {
	result := make([]string, 0)
	for _, raw := range device.Mountpoints {
		if value, ok := raw.(string); ok && value != "" {
			result = append(result, value)
		}
	}
	return result
}

func hasSystemMount(device lsblkDevice) bool {
	for _, mount := range candidateMountpoints(device) {
		if mount == "/" || mount == "/boot" || mount == "/boot/firmware" || mount == "[SWAP]" {
			return true
		}
	}
	for _, child := range device.Children {
		if hasSystemMount(child) {
			return true
		}
	}
	return false
}

func appendCandidates(out *[]VolumeCandidate, device lsblkDevice, parentBlocked bool, registered map[string]bool) {
	blocked := parentBlocked || hasSystemMount(device)
	if !blocked && (device.Type == "part" || (device.Type == "disk" && len(device.Children) == 0)) {
		size, _ := strconv.ParseUint(device.Size.String(), 10, 64)
		removable, _ := strconv.ParseUint(device.Removable.String(), 10, 64)
		readOnly, _ := strconv.ParseUint(device.ReadOnly.String(), 10, 64)
		mounts := candidateMountpoints(device)
		mount := ""
		if len(mounts) > 0 {
			mount = mounts[0]
		}
		candidate := VolumeCandidate{Device: device.Path, UUID: device.UUID, Label: device.Label, Model: strings.TrimSpace(device.Model), Serial: strings.TrimSpace(device.Serial), Filesystem: normalizeFilesystem(device.Filesystem), Mount: mount, Size: size, Removable: removable == 1, Supported: supportedFilesystem(device.Filesystem), Registered: registered != nil && registered[strings.ToLower(device.UUID)]}
		if readOnly == 1 {
			candidate.Supported = false
			candidate.Reason = "设备为只读"
		} else if device.Filesystem == "" {
			candidate.Reason = "未检测到文件系统，需要初始化"
		} else if !candidate.Supported {
			candidate.Reason = "暂不支持此文件系统"
		} else if candidate.UUID == "" {
			candidate.Supported = false
			candidate.Reason = "文件系统缺少 UUID"
		}
		*out = append(*out, candidate)
	}
	for _, child := range device.Children {
		appendCandidates(out, child, blocked, registered)
	}
}

func discoverVolumeCandidates(registered map[string]bool) ([]VolumeCandidate, error) {
	output, err := exec.Command("lsblk", "--json", "--bytes", "--output", "NAME,PATH,TYPE,SIZE,FSTYPE,UUID,LABEL,MOUNTPOINTS,MODEL,SERIAL,RM,RO").Output()
	if err != nil {
		return nil, fmt.Errorf("lsblk failed: %w", err)
	}
	var result struct {
		Devices []lsblkDevice `json:"blockdevices"`
	}
	decoder := json.NewDecoder(strings.NewReader(string(output)))
	decoder.UseNumber()
	if err = decoder.Decode(&result); err != nil {
		return nil, fmt.Errorf("invalid lsblk output: %w", err)
	}
	candidates := make([]VolumeCandidate, 0)
	for _, device := range result.Devices {
		appendCandidates(&candidates, device, false, registered)
	}
	return candidates, nil
}

func diskIOForDevice(device string) (uint64, uint64) {
	name := filepath.Base(device)
	output, err := exec.Command("lsblk", "-ndo", "PKNAME", device).Output()
	if err == nil && strings.TrimSpace(string(output)) != "" {
		name = strings.TrimSpace(string(output))
	}
	readSectors, errRead := readUintFile(filepath.Join("/sys/class/block", name, "stat"), 2)
	writeSectors, errWrite := readUintFile(filepath.Join("/sys/class/block", name, "stat"), 6)
	if errRead != nil || errWrite != nil {
		return 0, 0
	}
	return readSectors * 512, writeSectors * 512
}
