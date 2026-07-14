package main

import "testing"

func TestStableIDUsesFilesystemUUID(t *testing.T) {
	if stableID("ABCD-1234") != stableID("abcd-1234") {
		t.Fatal("stable id is case-sensitive")
	}
}

func TestSupportedFilesystems(t *testing.T) {
	for _, filesystem := range []string{"ext4", "ntfs", "ntfs3", "exfat"} {
		if !supportedFilesystem(filesystem) {
			t.Fatalf("expected %s support", filesystem)
		}
	}
}

func TestSystemDiskTreeIsRejected(t *testing.T) {
	device := blockDevice{Children: []blockDevice{{Mountpoints: []interface{}{string("/")}}}}
	if !hasSystemMount(device) {
		t.Fatal("system disk tree was accepted")
	}
}
