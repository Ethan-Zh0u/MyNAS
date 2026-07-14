//go:build !linux

package main

import "errors"

func requireRoot() error { return errors.New("mynas-setup 只能在树莓派 Linux 上运行") }
