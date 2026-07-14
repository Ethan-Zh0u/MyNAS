//go:build linux

package main

import (
	"errors"
	"os"
)

func requireRoot() error {
	if os.Geteuid() != 0 {
		return errors.New("请使用 sudo mynas-setup 运行此向导")
	}
	return nil
}
