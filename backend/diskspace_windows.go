//go:build windows

package main

import "golang.org/x/sys/windows"

func diskSpace(path string) (uint64, uint64, error) {
	root, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return 0, 0, err
	}
	var available, total, free uint64
	if err = windows.GetDiskFreeSpaceEx(root, &available, &total, &free); err != nil {
		return 0, 0, err
	}
	return total, available, nil
}
