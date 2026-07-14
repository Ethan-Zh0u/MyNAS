package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	reset  = "\033[0m"
	bold   = "\033[1m"
	orange = "\033[38;5;208m"
	green  = "\033[32m"
	yellow = "\033[33m"
	red    = "\033[31m"
)

type blockDevice struct {
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
	ReadOnly    json.Number   `json:"ro"`
	Children    []blockDevice `json:"children"`
}

type candidate struct {
	Device, Type, Filesystem, UUID, Label, Model, Serial, Mount string
	Size                                                        uint64
	Blank                                                       bool
}

type registry struct {
	Volumes []registeredVolume `json:"volumes"`
}

type registeredVolume struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	UUID       string `json:"uuid"`
	Device     string `json:"device"`
	Filesystem string `json:"filesystem"`
	Mount      string `json:"mount"`
}

var reader = bufio.NewReader(os.Stdin)

func main() {
	if err := requireRoot(); err != nil {
		fatal(err.Error())
	}
	clear()
	box("MyNAS 硬盘接入向导", []string{"安全识别硬盘 · 保留已有数据 · UUID 持久挂载", "支持 ext4 / NTFS3 / exFAT"})
	step(1, 6, "扫描树莓派硬盘")
	candidates, err := scanCandidates()
	if err != nil {
		fatal(err.Error())
	}
	if len(candidates) == 0 {
		fatal("没有发现可安全接入的非系统硬盘。")
	}
	selected := chooseCandidate(candidates)

	step(2, 6, "确认硬盘信息")
	printCandidate(selected)
	fmt.Println(yellow + "系统盘、启动盘和交换分区已被自动排除。" + reset)
	confirm("确认选择这块硬盘？")

	filesystem := normalizeFilesystem(selected.Filesystem)
	if selected.Blank {
		step(3, 6, "初始化空白硬盘")
		filesystem = chooseFilesystem()
		fmt.Printf("\n%s警告：%s 上的全部数据将被清除。%s\n", red+bold, selected.Device, reset)
		expected := "ERASE " + selected.Device
		if prompt("请输入 “"+expected+"” 继续") != expected {
			fatal("确认文字不匹配，操作已取消。")
		}
		selected, err = initializeDisk(selected, filesystem)
		if err != nil {
			fatal(err.Error())
		}
	} else {
		step(3, 6, "保留已有数据")
		if !supportedFilesystem(filesystem) {
			fatal("当前文件系统不受支持；为保护数据，向导不会自动转换文件系统。")
		}
		fmt.Println(green + "已选择无损接入，不会格式化硬盘。" + reset)
	}

	step(4, 6, "设置硬盘名称")
	defaultName := strings.TrimSpace(selected.Label)
	if defaultName == "" {
		defaultName = strings.TrimSpace(selected.Model)
	}
	if defaultName == "" {
		defaultName = "存储硬盘"
	}
	name := promptDefault("网页显示名称", defaultName)

	step(5, 6, "挂载并注册")
	volume, err := mountAndRegister(selected, filesystem, name)
	if err != nil {
		fatal(err.Error())
	}

	step(6, 6, "验证 MyNAS 读写")
	if err = verifyAndRestart(volume); err != nil {
		fatal(err.Error())
	}
	box("接入成功", []string{"硬盘：" + volume.Name, "设备：" + volume.Device, "挂载：" + volume.Mount, "现在刷新 MyNAS 网页即可看到这块硬盘。"})
}

func clear() { fmt.Print("\033[2J\033[H") }

func box(title string, lines []string) {
	width := 66
	fmt.Println(orange + "┌" + strings.Repeat("─", width) + "┐" + reset)
	fmt.Printf("%s│ %-64s │%s\n", orange, bold+title+reset+orange, reset)
	fmt.Println(orange + "├" + strings.Repeat("─", width) + "┤" + reset)
	for _, line := range lines {
		fmt.Printf("%s│%s %-64s %s│%s\n", orange, reset, line, orange, reset)
	}
	fmt.Println(orange + "└" + strings.Repeat("─", width) + "┘" + reset)
}

func step(current, total int, title string) {
	fmt.Printf("\n%s[%d/%d] %s%s\n", orange+bold, current, total, title, reset)
	fmt.Println(strings.Repeat("─", 68))
}

func fatal(message string) {
	fmt.Fprintln(os.Stderr, "\n"+red+bold+"失败："+reset+message)
	os.Exit(1)
}

func prompt(label string) string {
	fmt.Print(label + "：")
	value, _ := reader.ReadString('\n')
	return strings.TrimSpace(value)
}

func promptDefault(label, value string) string {
	answer := prompt(fmt.Sprintf("%s [%s]", label, value))
	if answer == "" {
		return value
	}
	return answer
}

func confirm(label string) {
	if strings.ToLower(prompt(label+" [y/N]")) != "y" {
		fatal("操作已取消。")
	}
}

func mountpoints(device blockDevice) []string {
	var result []string
	for _, raw := range device.Mountpoints {
		if value, ok := raw.(string); ok && value != "" {
			result = append(result, value)
		}
	}
	return result
}

func hasSystemMount(device blockDevice) bool {
	for _, mount := range mountpoints(device) {
		if mount == "/" || mount == "/boot" || mount == "/boot/firmware" || mount == "[SWAP]" || mount == "/mnt/nas" || strings.HasPrefix(mount, "/mnt/mynas/") {
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

func flattenCandidates(out *[]candidate, device blockDevice, blocked bool) {
	blocked = blocked || hasSystemMount(device)
	readOnly, _ := strconv.ParseUint(device.ReadOnly.String(), 10, 64)
	if !blocked && readOnly == 0 && (device.Type == "part" || (device.Type == "disk" && len(device.Children) == 0)) {
		size, _ := strconv.ParseUint(device.Size.String(), 10, 64)
		mount := ""
		if points := mountpoints(device); len(points) > 0 {
			mount = points[0]
		}
		*out = append(*out, candidate{Device: device.Path, Type: device.Type, Filesystem: device.Filesystem, UUID: device.UUID, Label: device.Label, Model: strings.TrimSpace(device.Model), Serial: strings.TrimSpace(device.Serial), Mount: mount, Size: size, Blank: device.Filesystem == ""})
	}
	for _, child := range device.Children {
		flattenCandidates(out, child, blocked)
	}
}

func scanCandidates() ([]candidate, error) {
	output, err := exec.Command("lsblk", "--json", "--bytes", "--output", "NAME,PATH,TYPE,SIZE,FSTYPE,UUID,LABEL,MOUNTPOINTS,MODEL,SERIAL,RO").Output()
	if err != nil {
		return nil, fmt.Errorf("无法运行 lsblk：%w", err)
	}
	var result struct {
		Devices []blockDevice `json:"blockdevices"`
	}
	decoder := json.NewDecoder(strings.NewReader(string(output)))
	decoder.UseNumber()
	if err = decoder.Decode(&result); err != nil {
		return nil, fmt.Errorf("无法解析硬盘列表：%w", err)
	}
	var candidates []candidate
	for _, device := range result.Devices {
		flattenCandidates(&candidates, device, false)
	}
	return candidates, nil
}

func chooseCandidate(candidates []candidate) candidate {
	for index, item := range candidates {
		fs := normalizeFilesystem(item.Filesystem)
		if fs == "" {
			fs = "空白/未格式化"
		}
		fmt.Printf("  %s%d)%s %-14s %-12s %-10s %s\n", orange, index+1, reset, item.Device, humanSize(item.Size), fs, firstNonEmpty(item.Label, item.Model, "未命名硬盘"))
	}
	for {
		choice, err := strconv.Atoi(prompt("请选择硬盘编号"))
		if err == nil && choice > 0 && choice <= len(candidates) {
			return candidates[choice-1]
		}
		fmt.Println(yellow + "请输入列表中的有效编号。" + reset)
	}
}

func printCandidate(item candidate) {
	fmt.Printf("设备      %s\n容量      %s\n型号      %s\n序列号    %s\n文件系统  %s\nUUID      %s\n当前挂载  %s\n", item.Device, humanSize(item.Size), firstNonEmpty(item.Model, "—"), firstNonEmpty(item.Serial, "—"), firstNonEmpty(normalizeFilesystem(item.Filesystem), "未格式化"), firstNonEmpty(item.UUID, "—"), firstNonEmpty(item.Mount, "未挂载"))
}

func chooseFilesystem() string {
	fmt.Println("  1) ext4   推荐用于长期连接树莓派")
	fmt.Println("  2) exFAT  兼容 Windows/macOS/Linux")
	fmt.Println("  3) NTFS3  兼容 Windows")
	for {
		switch prompt("请选择文件系统") {
		case "1":
			return "ext4"
		case "2":
			return "exfat"
		case "3":
			return "ntfs3"
		default:
			fmt.Println(yellow + "请输入 1、2 或 3。" + reset)
		}
	}
}

func initializeDisk(selected candidate, filesystem string) (candidate, error) {
	target := selected.Device
	if selected.Type == "disk" {
		command := exec.Command("sfdisk", "--wipe", "always", selected.Device)
		command.Stdin = strings.NewReader("label: gpt\n,;\n")
		if output, err := command.CombinedOutput(); err != nil {
			return selected, fmt.Errorf("创建 GPT 分区失败：%s", strings.TrimSpace(string(output)))
		}
		_ = exec.Command("partprobe", selected.Device).Run()
		_ = exec.Command("udevadm", "settle").Run()
		children, err := exec.Command("lsblk", "-nrpo", "PATH,TYPE", selected.Device).Output()
		if err != nil {
			return selected, errors.New("分区后无法重新读取硬盘")
		}
		for _, line := range strings.Split(string(children), "\n") {
			fields := strings.Fields(line)
			if len(fields) == 2 && fields[1] == "part" {
				target = fields[0]
				break
			}
		}
		if target == selected.Device {
			return selected, errors.New("没有找到新建分区")
		}
	}
	label := "MYNAS"
	var command *exec.Cmd
	switch filesystem {
	case "ext4":
		command = exec.Command("mkfs.ext4", "-F", "-L", label, target)
	case "exfat":
		command = exec.Command("mkfs.exfat", "-n", label, target)
	case "ntfs3":
		command = exec.Command("mkfs.ntfs", "-F", "-L", label, target)
	default:
		return selected, errors.New("不支持的文件系统")
	}
	if output, err := command.CombinedOutput(); err != nil {
		return selected, fmt.Errorf("格式化失败：%s", strings.TrimSpace(string(output)))
	}
	_ = exec.Command("udevadm", "settle").Run()
	uuidOutput, err := exec.Command("blkid", "-s", "UUID", "-o", "value", target).Output()
	if err != nil || strings.TrimSpace(string(uuidOutput)) == "" {
		return selected, errors.New("格式化完成但未能读取 UUID")
	}
	selected.Device, selected.Type, selected.Filesystem, selected.UUID, selected.Label, selected.Mount, selected.Blank = target, "part", filesystem, strings.TrimSpace(string(uuidOutput)), label, "", false
	return selected, nil
}

func mountAndRegister(selected candidate, filesystem, name string) (registeredVolume, error) {
	if selected.UUID == "" {
		return registeredVolume{}, errors.New("硬盘没有 UUID，无法安全持久挂载")
	}
	id := stableID(selected.UUID)
	mount := filepath.Join("/mnt/mynas", id)
	if selected.Mount != "" && filepath.Clean(selected.Mount) != filepath.Clean(mount) {
		if output, err := exec.Command("umount", selected.Device).CombinedOutput(); err != nil {
			return registeredVolume{}, fmt.Errorf("卸载原挂载点失败：%s", strings.TrimSpace(string(output)))
		}
	}
	if err := os.MkdirAll(mount, 0750); err != nil {
		return registeredVolume{}, err
	}
	if err := updateFstab(selected.UUID, mount, filesystem); err != nil {
		return registeredVolume{}, err
	}
	if output, err := exec.Command("mount", mount).CombinedOutput(); err != nil {
		return registeredVolume{}, fmt.Errorf("挂载失败：%s", strings.TrimSpace(string(output)))
	}
	if filesystem == "ext4" {
		_ = exec.Command("chown", "rbp:rbp", mount).Run()
	}
	serviceDir := filepath.Join(mount, ".mynas")
	for _, directory := range []string{"staging", "trash"} {
		if err := os.MkdirAll(filepath.Join(serviceDir, directory), 0700); err != nil {
			return registeredVolume{}, err
		}
	}
	if output, err := exec.Command("chown", "-R", "rbp:rbp", serviceDir).CombinedOutput(); err != nil {
		return registeredVolume{}, fmt.Errorf("设置服务目录权限失败：%s", strings.TrimSpace(string(output)))
	}
	volume := registeredVolume{ID: id, Name: name, UUID: selected.UUID, Device: selected.Device, Filesystem: filesystem, Mount: mount}
	if err := updateRegistry(volume); err != nil {
		return registeredVolume{}, err
	}
	return volume, nil
}

func updateFstab(uuid, mount, filesystem string) error {
	data, err := os.ReadFile("/etc/fstab")
	if err != nil {
		return err
	}
	backup := "/etc/fstab.mynas-" + time.Now().UTC().Format("20060102T150405Z")
	if err = os.WriteFile(backup, data, 0600); err != nil {
		return fmt.Errorf("备份 fstab 失败：%w", err)
	}
	options := "defaults,nofail,x-systemd.device-timeout=10s"
	pass := "2"
	if filesystem == "ntfs3" || filesystem == "exfat" {
		options += ",uid=rbp,gid=rbp,umask=0027"
		pass = "0"
	}
	kept := make([]string, 0)
	needle := "UUID=" + uuid
	for _, line := range strings.Split(string(data), "\n") {
		if !strings.Contains(line, needle) && !strings.Contains(line, mount) {
			kept = append(kept, line)
		}
	}
	kept = append(kept, fmt.Sprintf("UUID=%s %s %s %s 0 %s", uuid, mount, filesystem, options, pass))
	return atomicWrite("/etc/fstab", []byte(strings.TrimRight(strings.Join(kept, "\n"), "\n")+"\n"), 0644)
}

func updateRegistry(volume registeredVolume) error {
	path := "/etc/mynas/volumes.json"
	var config registry
	if data, err := os.ReadFile(path); err == nil {
		if err = json.Unmarshal(data, &config); err != nil {
			return fmt.Errorf("卷配置损坏：%w", err)
		}
	}
	found := false
	for index := range config.Volumes {
		if strings.EqualFold(config.Volumes[index].UUID, volume.UUID) {
			config.Volumes[index] = volume
			found = true
		}
	}
	if !found {
		config.Volumes = append(config.Volumes, volume)
	}
	data, _ := json.MarshalIndent(config, "", "  ")
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	return atomicWrite(path, append(data, '\n'), 0644)
}

func atomicWrite(path string, data []byte, mode os.FileMode) error {
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, data, mode); err != nil {
		return err
	}
	if file, err := os.OpenFile(temporary, os.O_RDWR, mode); err == nil {
		_ = file.Sync()
		_ = file.Close()
	}
	return os.Rename(temporary, path)
}

func verifyAndRestart(volume registeredVolume) error {
	testPath := filepath.Join(volume.Mount, ".mynas", ".write-test")
	command := exec.Command("runuser", "-u", "rbp", "--", "sh", "-c", "umask 077; : > \"$1\"", "mynas-setup", testPath)
	if output, err := command.CombinedOutput(); err != nil {
		return fmt.Errorf("rbp 用户写入验证失败：%s", strings.TrimSpace(string(output)))
	}
	_ = os.Remove(testPath)
	if _, err := os.Stat("/etc/systemd/system/mynas.service"); err == nil {
		if output, restartErr := exec.Command("systemctl", "restart", "mynas").CombinedOutput(); restartErr != nil {
			return fmt.Errorf("硬盘已接入，但重启 MyNAS 失败：%s", strings.TrimSpace(string(output)))
		}
	}
	return nil
}

func stableID(uuid string) string {
	sum := sha256.Sum256([]byte(strings.ToLower(strings.TrimSpace(uuid))))
	return "vol-" + hex.EncodeToString(sum[:6])
}

func normalizeFilesystem(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "ntfs", "ntfs3":
		return "ntfs3"
	case "ext4":
		return "ext4"
	case "exfat":
		return "exfat"
	default:
		return strings.ToLower(strings.TrimSpace(value))
	}
}

func supportedFilesystem(value string) bool {
	switch normalizeFilesystem(value) {
	case "ext4", "ntfs3", "exfat":
		return true
	default:
		return false
	}
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func humanSize(value uint64) string {
	const unit = 1024
	if value < unit {
		return fmt.Sprintf("%d B", value)
	}
	divisor, exponent := uint64(unit), 0
	for amount := value / unit; amount >= unit && exponent < 4; amount /= unit {
		divisor *= unit
		exponent++
	}
	return fmt.Sprintf("%.1f %ciB", float64(value)/float64(divisor), "KMGTPE"[exponent])
}
