package main

import (
	"os"
	"strconv"
	"strings"
)

func (a *App) systemHealth() SystemHealth {
	return SystemHealth{TemperatureC: readTemperatureC(a.c.ThermalPath)}
}

func readTemperatureC(path string) *float64 {
	if path == "" {
		return nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	milliCelsius, err := strconv.ParseFloat(strings.TrimSpace(string(data)), 64)
	if err != nil || !(milliCelsius >= -40_000 && milliCelsius <= 150_000) {
		return nil
	}
	celsius := milliCelsius / 1_000
	return &celsius
}
