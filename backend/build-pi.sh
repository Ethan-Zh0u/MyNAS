#!/usr/bin/env bash
set -euo pipefail
export PATH=/home/rbp/.local/opt/go/bin:$PATH
export GOPROXY=https://goproxy.cn,direct
export GOSUMDB=sum.golang.google.cn
go mod tidy
go test ./...
CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o mynas .
