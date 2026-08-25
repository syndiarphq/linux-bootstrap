package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/creack/pty"
)

type stage int

const (
	stageSplash stage = iota
	stagePreflight
	stageProfile
	stageCategories
	stagePackages
	stageExternal
	stageServices
	stageConfigurations
	stageReview
	stageInstall
	stageResult
)

type item struct {
	name, description, category string
	selected                    bool
	unavailable                 bool
	installed                   bool
}

type categoryDef struct {
	slug, label string
}

type model struct {
	root, family, pretty, output string
	lastPlan                     string
	version                      string
	profile                      string
	stage                        stage
	profiles                     []item
	preflight                    []item
	preflightBlock               string
	splashNotice                 string
	packages                     []item
	external                     []item
	services                     []item
	configurations               []item
	configureOnly                bool
	categories                   []categoryDef
	activeCategory               string
	descriptions                 map[string]string
	installedPackages            map[string]bool
	unavailablePackages          map[string]string
	unavailableExternal          map[string]string
	cursor, width, height        int
	search                       textinput.Model
	confirmed, cancelled         bool
	err                          error
	executeScript                string
	childDryRun                  bool
	installPTY                   *os.File
	installEvents                chan tea.Msg
	installLines                 []string
	installStatus                int
	showRaw                      bool
}

type installLineMsg string
type installDoneMsg struct{ err error }
type installStartedMsg struct {
	terminal *os.File
	events   chan tea.Msg
}

var (
	cyan      = lipgloss.Color("#32d6d9")
	dim       = lipgloss.Color("#697386")
	white     = lipgloss.Color("#e5e9f0")
	panel     = lipgloss.Color("#3b4353")
	selection = lipgloss.Color("#26363d")
	green     = lipgloss.Color("#7bd88f")
	yellow    = lipgloss.Color("#e5c07b")
	red       = lipgloss.Color("#e06c75")
	cyanStyle = lipgloss.NewStyle().Foreground(cyan)
	muted     = lipgloss.NewStyle().Foreground(dim)
	active    = lipgloss.NewStyle().Foreground(cyan).Bold(true)
	success   = lipgloss.NewStyle().Foreground(green)
	warning   = lipgloss.NewStyle().Foreground(yellow)
	danger    = lipgloss.NewStyle().Foreground(red)
)

func main() {
	var root, family, pretty, output, defaultProfile, lastPlan, availability, executeScript string
	var configureOnly bool
	var childDryRun bool
	flag.StringVar(&root, "root", ".", "repository root")
	flag.StringVar(&family, "family", "", "arch or debian")
	flag.StringVar(&pretty, "pretty", "Linux", "distribution display name")
	flag.StringVar(&output, "output", "", "selection output file")
	flag.StringVar(&defaultProfile, "default-profile", "desktop", "desktop or server")
	flag.StringVar(&lastPlan, "last-plan", "", "previous validated selection plan")
	flag.StringVar(&availability, "availability", "", "package and dependency availability report")
	flag.BoolVar(&configureOnly, "configure-only", false, "select configuration tasks without package installation")
	flag.StringVar(&executeScript, "execute-script", "", "run this setup script after selection")
	flag.BoolVar(&childDryRun, "child-dry-run", false, "pass --dry-run to the setup child")
	flag.Parse()
	if output == "" || (family != "arch" && family != "debian" && family != "fedora" && family != "suse") {
		fmt.Fprintln(os.Stderr, "missing --output or unsupported --family")
		os.Exit(2)
	}

	if defaultProfile != "desktop" && defaultProfile != "server" {
		defaultProfile = "desktop"
	}
	m := newModel(root, family, pretty, output, defaultProfile)
	if availability != "" {
		if err := m.loadAvailability(availability); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
	if lastPlan != "" {
		if info, err := os.Stat(lastPlan); err == nil && !info.IsDir() {
			m.lastPlan = lastPlan
		}
	}
	m.configureOnly = configureOnly
	m.executeScript = executeScript
	m.childDryRun = childDryRun
	m.loadInstalledPackages()
	if configureOnly {
		m.loadConfigurations()
	} else {
		m.detectServices()
		m.runPreflight()
	}
	result, err := tea.NewProgram(m, tea.WithAltScreen()).Run()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	final := result.(model)
	if final.err != nil {
		fmt.Fprintln(os.Stderr, final.err)
		os.Exit(1)
	}
	if executeScript != "" {
		if final.cancelled || final.stage != stageResult {
			os.Exit(130)
		}
		if final.installStatus != 0 {
			os.Exit(1)
		}
		return
	}
	if final.cancelled || !final.confirmed {
		os.Exit(130)
	}
	if err := final.writeSelection(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func newModel(root, family, pretty, output, defaultProfile string) model {
	ti := textinput.New()
	ti.Placeholder = "Type to search packages..."
	ti.Prompt = "# "
	ti.PromptStyle = cyanStyle
	ti.TextStyle = lipgloss.NewStyle().Foreground(white)
	ti.Cursor.Style = cyanStyle
	m := model{
		root: root, family: family, pretty: pretty, output: output, search: ti, width: 100, height: 30,
		installedPackages: map[string]bool{}, unavailablePackages: map[string]string{}, unavailableExternal: map[string]string{},
	}
	m.descriptions = loadDescriptions(root)
	if version, err := os.ReadFile(filepath.Join(root, "VERSION")); err == nil {
		m.version = strings.TrimSpace(string(version))
	}
	m.profiles = []item{{name: "desktop", description: "Graphical workstation"}, {name: "server", description: "Headless server"}}
	m.profile = defaultProfile
	if defaultProfile == "server" {
		m.cursor = 1
	}
	m.profiles[m.cursor].selected = true
	m.stage = stageSplash
	m.cursor = 0
	m.services = []item{
		{name: "tailscale", description: "Private mesh networking"},
		{name: "docker", description: "Container runtime"},
		{name: "ssh", description: "OpenSSH server (configuration unchanged)"},
	}
	return m
}

func (m model) Init() tea.Cmd { return textinput.Blink }

func (m model) startInstall() tea.Cmd {
	return func() tea.Msg {
		args := []string{m.executeScript, "--plan", m.output}
		if m.childDryRun {
			args = append(args, "--dry-run")
		}
		command := exec.Command("bash", args...)
		terminal, err := pty.Start(command)
		if err != nil {
			return installDoneMsg{err: err}
		}
		_ = pty.Setsize(terminal, &pty.Winsize{Rows: uint16(max(24, m.height)), Cols: uint16(max(80, m.width))})
		events := make(chan tea.Msg, 64)
		go func() {
			scanner := bufio.NewScanner(terminal)
			scanner.Buffer(make([]byte, 4096), 1024*1024)
			for scanner.Scan() {
				events <- installLineMsg(scanner.Text())
			}
			err := command.Wait()
			_ = terminal.Close()
			events <- installDoneMsg{err: err}
		}()
		return installStartedMsg{terminal: terminal, events: events}
	}
}

func (m model) waitInstallEvent() tea.Cmd {
	return func() tea.Msg {
		if m.installEvents == nil {
			return installDoneMsg{err: fmt.Errorf("installation event stream unavailable")}
		}
		return <-m.installEvents
	}
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.search.Width = max(20, msg.Width-34)
		return m, nil
	case installStartedMsg:
		m.installPTY = msg.terminal
		m.installEvents = msg.events
		return m, m.waitInstallEvent()
	case installLineMsg:
		line := strings.TrimSpace(ansi.Strip(string(msg)))
		if line != "" {
			m.installLines = append(m.installLines, line)
			if strings.Contains(strings.ToLower(line), "password") || strings.Contains(strings.ToLower(line), "authenticate") {
				m.showRaw = true
			}
			if len(m.installLines) > 500 {
				m.installLines = m.installLines[len(m.installLines)-500:]
			}
		}
		return m, m.waitInstallEvent()
	case installDoneMsg:
		m.installStatus = 0
		if msg.err != nil {
			m.installStatus = 1
		}
		m.stage = stageResult
		return m, nil
	case tea.KeyMsg:
		key := msg.String()
		if m.stage == stageInstall {
			if key == "f2" {
				m.showRaw = !m.showRaw
				return m, nil
			}
			if m.installPTY != nil {
				_, _ = m.installPTY.Write(keyBytes(msg))
			}
			return m, nil
		}
		if m.stage == stageResult {
			if key == "f2" {
				m.showRaw = !m.showRaw
				return m, nil
			}
			if key == "enter" || key == "q" || key == "esc" {
				m.confirmed = m.installStatus == 0
				m.cancelled = m.installStatus != 0
				return m, tea.Quit
			}
			return m, nil
		}
		if key == "ctrl+c" || key == "q" && m.stage != stagePackages {
			m.cancelled = true
			return m, tea.Quit
		}
		if m.stage == stagePackages && m.search.Focused() {
			switch key {
			case "esc":
				m.search.Blur()
				return m, nil
			case "enter":
				m.search.Blur()
				return m, nil
			case "ctrl+a":
				m.selectVisible(true)
				return m, nil
			}
			var cmd tea.Cmd
			m.search, cmd = m.search.Update(msg)
			m.clampCursor()
			return m, cmd
		}
		switch key {
		case "up", "k":
			if m.cursor > 0 {
				m.cursor--
			}
		case "down", "j":
			if m.cursor < m.itemCount()-1 {
				m.cursor++
			}
		case " ":
			m.toggleCurrent()
		case "/":
			if m.stage == stagePackages {
				m.search.Focus()
				return m, textinput.Blink
			}
		case "ctrl+a":
			if m.stage == stagePackages {
				m.selectVisible(!m.allVisibleSelected())
			}
		case "enter", "right", "l":
			if m.stage == stageSplash && (key == "right" || key == "l") {
				m.cursor = 1
				break
			}
			m.next()
			if m.stage == stageInstall {
				return m, m.startInstall()
			}
			if m.confirmed || m.cancelled {
				return m, tea.Quit
			}
		case "esc", "left", "h":
			if m.stage == stageSplash && (key == "left" || key == "h") {
				m.cursor = 0
				break
			}
			m.back()
			if m.cancelled {
				return m, tea.Quit
			}
		}
	}
	return m, nil
}

func keyBytes(msg tea.KeyMsg) []byte {
	if len(msg.Runes) > 0 {
		return []byte(string(msg.Runes))
	}
	switch msg.String() {
	case "enter":
		return []byte{'\r'}
	case "tab":
		return []byte{'\t'}
	case "backspace":
		return []byte{0x7f}
	case "ctrl+c":
		return []byte{0x03}
	case "up":
		return []byte("\x1b[A")
	case "down":
		return []byte("\x1b[B")
	case "right":
		return []byte("\x1b[C")
	case "left":
		return []byte("\x1b[D")
	case "esc":
		return []byte{0x1b}
	}
	return nil
}

func (m *model) next() {
	switch m.stage {
	case stageSplash:
		if m.lastPlan != "" && m.cursor == 1 {
			if err := m.loadPlan(m.lastPlan); err != nil {
				m.splashNotice = "Last selection unavailable: " + err.Error()
				m.lastPlan = ""
				m.cursor = 0
				return
			}
			if m.executeScript == "" {
				m.confirmed = true
			} else {
				if err := m.writeSelection(); err != nil {
					m.err = err
					return
				}
				m.stage = stageInstall
				m.installLines = []string{"Preparing installation…"}
			}
			return
		}
		exitIndex := 1
		if m.lastPlan != "" {
			exitIndex = 2
		}
		if m.cursor == exitIndex {
			m.cancelled = true
			return
		}
		if m.configureOnly {
			m.loadConfigurations()
			m.stage = stageConfigurations
		} else {
			m.stage = stagePreflight
		}
		m.cursor = 0
		return
	case stagePreflight:
		m.preflightBlock = ""
		for _, check := range m.preflight {
			if (check.name == "Package manager" || check.name == "Privilege escalation" || check.name == "Free disk space") && !check.selected {
				m.preflightBlock = "Resolve failed required checks before continuing."
				return
			}
		}
		m.stage = stageProfile
		m.cursor = 0
		if m.profile == "server" {
			m.cursor = 1
		}
		return
	case stageProfile:
		m.profile = m.profiles[m.cursor].name
		for i := range m.profiles {
			m.profiles[i].selected = i == m.cursor
		}
		m.loadPackages()
		m.loadExternal()
		m.stage = stageCategories
	case stageCategories:
		menu := m.categoryItems()
		if m.cursor >= len(menu) {
			return
		}
		if menu[m.cursor].category == "__continue" {
			m.reconcileExternalSelections()
			m.stage = stageExternal
		} else {
			m.activeCategory = menu[m.cursor].category
			m.search.SetValue("")
			m.stage = stagePackages
		}
	case stagePackages:
		current := -1
		for i, category := range m.categories {
			if category.slug == m.activeCategory {
				current = i
				break
			}
		}
		if current >= 0 && current+1 < len(m.categories) {
			m.activeCategory = m.categories[current+1].slug
			m.search.SetValue("")
		} else {
			m.stage = stageCategories
			m.cursor = len(m.categories)
			return
		}
	case stageExternal:
		m.stage = stageServices
	case stageServices:
		m.loadConfigurations()
		m.stage = stageConfigurations
	case stageConfigurations:
		m.stage = stageReview
	case stageReview:
		if m.executeScript == "" {
			m.confirmed = true
		} else {
			if err := m.writeSelection(); err != nil {
				m.err = err
				return
			}
			m.stage = stageInstall
			m.installLines = []string{"Preparing installation…"}
		}
	}
	m.cursor = 0
}

func (m *model) back() {
	switch m.stage {
	case stageSplash:
		m.cancelled = true
	case stagePreflight:
		m.stage = stageSplash
	case stageProfile:
		m.stage = stagePreflight
	case stagePackages:
		m.stage = stageCategories
	case stageCategories:
		m.stage = stageProfile
	case stageServices:
		m.stage = stageExternal
	case stageConfigurations:
		if m.configureOnly {
			m.stage = stageSplash
		} else {
			m.stage = stageServices
		}
	case stageExternal:
		m.stage = stageCategories
	case stageReview:
		m.stage = stageConfigurations
	}
	m.cursor = 0
}

func (m model) itemCount() int {
	switch m.stage {
	case stageSplash:
		if m.lastPlan != "" {
			return 3
		}
		return 2
	case stagePreflight:
		return len(m.preflight)
	case stageProfile:
		return len(m.profiles)
	case stageCategories:
		return len(m.categoryItems())
	case stagePackages:
		return len(m.visiblePackages())
	case stageExternal:
		return len(m.external)
	case stageServices:
		return len(m.services)
	case stageConfigurations:
		return len(m.configurations)
	default:
		return 1
	}
}

func (m *model) toggleCurrent() {
	switch m.stage {
	case stageProfile:
		m.next()
		m.stage = stageProfile
	case stageCategories:
		menu := m.categoryItems()
		if m.cursor < len(menu) && menu[m.cursor].category != "__continue" {
			category := menu[m.cursor].category
			selectAll := !m.categoryAllSelected(category)
			for i := range m.packages {
				if m.packages[i].category == category && !m.packages[i].installed && !m.packages[i].unavailable {
					m.packages[i].selected = selectAll
				}
			}
		}
	case stagePackages:
		visible := m.visiblePackageIndexes()
		if m.cursor < len(visible) {
			i := visible[m.cursor]
			if !m.packages[i].installed && !m.packages[i].unavailable {
				m.packages[i].selected = !m.packages[i].selected
			}
		}
	case stageExternal:
		if m.cursor < len(m.external) && !m.external[m.cursor].unavailable && !m.external[m.cursor].installed && !m.officialPackageCovered(m.external[m.cursor]) {
			m.external[m.cursor].selected = !m.external[m.cursor].selected
		}
	case stageServices:
		if m.cursor < len(m.services) && !m.services[m.cursor].installed {
			m.services[m.cursor].selected = !m.services[m.cursor].selected
		}
	case stageConfigurations:
		if m.cursor < len(m.configurations) && !m.configurations[m.cursor].unavailable && !m.configurations[m.cursor].installed {
			if strings.HasPrefix(m.configurations[m.cursor].category, "starship-preset-") && !m.configurations[m.cursor].selected {
				for i := range m.configurations {
					if strings.HasPrefix(m.configurations[i].category, "starship-preset-") {
						m.configurations[i].selected = false
					}
				}
			}
			m.configurations[m.cursor].selected = !m.configurations[m.cursor].selected
		}
	}
}

func (m *model) selectVisible(selected bool) {
	for _, i := range m.visiblePackageIndexes() {
		if !m.packages[i].installed && !m.packages[i].unavailable {
			m.packages[i].selected = selected
		}
	}
}

func (m model) allVisibleSelected() bool {
	idx := m.visiblePackageIndexes()
	if len(idx) == 0 {
		return false
	}
	found := false
	for _, i := range idx {
		if m.packages[i].installed || m.packages[i].unavailable {
			continue
		}
		found = true
		if !m.packages[i].selected {
			return false
		}
	}
	return found
}

func (m *model) clampCursor() {
	n := m.itemCount()
	if n == 0 {
		m.cursor = 0
	} else if m.cursor >= n {
		m.cursor = n - 1
	}
}

func (m *model) loadPackages() {
	m.packages = nil
	m.categories = map[string][]categoryDef{
		"arch/desktop": {
			{slug: "base", label: "Core CLI"},
			{slug: "terminal", label: "Terminal applications"},
			{slug: "graphical", label: "Graphical applications"},
			{slug: "development", label: "Development"},
			{slug: "backup", label: "Backup & sync"},
			{slug: "storage", label: "Storage & recovery"},
			{slug: "network", label: "Network & security"},
			{slug: "virtualization", label: "Virtualization"},
			{slug: "gaming", label: "Gaming"},
			{slug: "fonts", label: "Fonts"},
		},
		"arch/server": {
			{slug: "base", label: "Core CLI"},
			{slug: "server", label: "Server & remote access"},
			{slug: "development", label: "Development"},
			{slug: "monitoring", label: "Monitoring"},
			{slug: "backup", label: "Backup & sync"},
			{slug: "storage", label: "Storage & recovery"},
			{slug: "network", label: "Network & security"},
		},
		"debian/server": {
			{slug: "base", label: "Core CLI"},
			{slug: "server", label: "Server & remote access"},
			{slug: "development", label: "Development"},
			{slug: "monitoring", label: "Monitoring"},
		},
		"debian/desktop": {
			{slug: "base", label: "Core CLI"}, {slug: "terminal", label: "Terminal applications"},
			{slug: "graphical", label: "Graphical applications"}, {slug: "development", label: "Development"},
			{slug: "fonts", label: "Fonts"},
		},
		"fedora/desktop": {
			{slug: "base", label: "Core CLI"}, {slug: "terminal", label: "Terminal applications"},
			{slug: "graphical", label: "Graphical applications"}, {slug: "development", label: "Development"},
			{slug: "gaming", label: "Gaming"}, {slug: "fonts", label: "Fonts"},
		},
		"fedora/server": {
			{slug: "base", label: "Core CLI"}, {slug: "server", label: "Server & remote access"},
			{slug: "development", label: "Development"}, {slug: "monitoring", label: "Monitoring"},
		},
		"suse/desktop": {
			{slug: "base", label: "Core CLI"}, {slug: "terminal", label: "Terminal applications"},
			{slug: "graphical", label: "Graphical applications"}, {slug: "development", label: "Development"},
			{slug: "fonts", label: "Fonts"},
		},
		"suse/server": {
			{slug: "base", label: "Core CLI"}, {slug: "server", label: "Server & remote access"},
			{slug: "development", label: "Development"}, {slug: "monitoring", label: "Monitoring"},
		},
	}[m.family+"/"+m.profile]
	seen := map[string]bool{}
	for _, category := range m.categories {
		path := filepath.Join(m.root, "packages", m.family, m.profile, category.slug+".txt")
		f, err := os.Open(path)
		if err != nil {
			m.err = err
			return
		}
		s := bufio.NewScanner(f)
		for s.Scan() {
			name := strings.TrimSpace(strings.SplitN(s.Text(), "#", 2)[0])
			if name != "" && !seen[name] {
				seen[name] = true
				description := m.descriptions[name]
				reason, unavailable := m.unavailablePackages[name]
				if unavailable {
					description += " [blocked: " + reason + "]"
				}
				m.packages = append(m.packages, item{name: name, description: description, category: category.slug, installed: m.installedPackages[name], unavailable: unavailable})
			}
		}
		if err := s.Err(); err != nil {
			m.err = err
		}
		_ = f.Close()
	}
	sort.Slice(m.packages, func(i, j int) bool { return m.packages[i].name < m.packages[j].name })
}

func (m model) categoryItems() []item {
	items := make([]item, 0, len(m.categories)+1)
	for _, category := range m.categories {
		selected, total := 0, 0
		for _, p := range m.packages {
			if p.category == category.slug && !p.installed && !p.unavailable {
				total++
				if p.selected {
					selected++
				}
			}
		}
		items = append(items, item{
			name: category.label, category: category.slug,
			description: fmt.Sprintf("%d of %d selected", selected, total),
			selected:    total > 0 && selected == total,
		})
	}
	items = append(items, item{name: "Continue to external applications", category: "__continue"})
	return items
}

func (m model) categoryAllSelected(category string) bool {
	found := false
	for _, p := range m.packages {
		if p.category == category && !p.installed && !p.unavailable {
			found = true
			if !p.selected {
				return false
			}
		}
	}
	return found
}

func (m model) categoryCounts(category string) (selected, total int) {
	for _, p := range m.packages {
		if p.category == category && !p.installed && !p.unavailable {
			total++
			if p.selected {
				selected++
			}
		}
	}
	return selected, total
}

func loadDescriptions(root string) map[string]string {
	descriptions := map[string]string{}
	f, err := os.Open(filepath.Join(root, "packages", "descriptions.tsv"))
	if err != nil {
		return descriptions
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		parts := strings.SplitN(s.Text(), "\t", 2)
		if len(parts) == 2 {
			descriptions[strings.TrimSpace(parts[0])] = strings.TrimSpace(parts[1])
		}
	}
	return descriptions
}

func (m *model) loadAvailability(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("read availability report: %w", err)
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		parts := strings.SplitN(s.Text(), "\t", 3)
		if len(parts) != 3 {
			continue
		}
		switch parts[0] {
		case "PACKAGE":
			m.unavailablePackages[parts[1]] = parts[2]
		case "EXTERNAL":
			m.unavailableExternal[parts[1]] = parts[2]
		}
	}
	return s.Err()
}

func (m *model) loadInstalledPackages() {
	var command string
	var args []string
	switch m.family {
	case "arch":
		command, args = "pacman", []string{"-Qq"}
	case "debian":
		command, args = "dpkg-query", []string{"-W", "-f=${binary:Package}\n"}
	case "fedora", "suse":
		command, args = "rpm", []string{"-qa", "--qf", "%{NAME}\n"}
	default:
		return
	}
	out, err := exec.Command(command, args...).Output()
	if err != nil {
		return
	}
	for _, name := range strings.Fields(string(out)) {
		if m.family == "debian" {
			name = strings.SplitN(name, ":", 2)[0]
		}
		m.installedPackages[name] = true
	}
}

func (m *model) runPreflight() {
	architecture := runtime.GOARCH
	m.preflight = append(m.preflight, item{name: "Architecture", description: architecture, selected: architecture == "amd64" || architecture == "arm64"})
	manager := map[string]string{"arch": "pacman", "debian": "apt-get", "fedora": "dnf", "suse": "zypper"}[m.family]
	_, managerErr := exec.LookPath(manager)
	m.preflight = append(m.preflight, item{name: "Package manager", description: manager, selected: managerErr == nil})
	_, sudoErr := exec.LookPath("sudo")
	m.preflight = append(m.preflight, item{name: "Privilege escalation", description: "sudo available", selected: os.Geteuid() == 0 || sudoErr == nil})
	var fs syscall.Statfs_t
	diskOK := syscall.Statfs(m.root, &fs) == nil && fs.Bavail*uint64(fs.Bsize) >= 2*1024*1024*1024
	diskGB := float64(fs.Bavail*uint64(fs.Bsize)) / (1024 * 1024 * 1024)
	m.preflight = append(m.preflight, item{name: "Free disk space", description: fmt.Sprintf("%.1f GiB available", diskGB), selected: diskOK})
	connection, err := net.DialTimeout("tcp", "github.com:443", 1500*time.Millisecond)
	if err == nil {
		_ = connection.Close()
	}
	m.preflight = append(m.preflight, item{name: "Internet access", description: "GitHub and external installers", selected: err == nil})
	var missing []string
	for _, tool := range []string{"git", "curl", "make", "go", "cargo", "nimble"} {
		if _, err := exec.LookPath(tool); err != nil {
			missing = append(missing, tool)
		}
	}
	detail := "all optional build tools already available"
	if len(missing) > 0 {
		detail = "installed on demand: " + strings.Join(missing, ", ")
	}
	m.preflight = append(m.preflight, item{name: "External build tools", description: detail, selected: true})
}

func (m *model) loadExternal() {
	m.external = nil
	f, err := os.Open(filepath.Join(m.root, "external", "catalog.tsv"))
	if err != nil {
		m.err = err
		return
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.Split(line, "\t")
		if len(parts) < 6 || (parts[2] != "all" && parts[2] != m.profile) {
			continue
		}
		description := parts[4]
		unavailable := parts[3] == "manual"
		if unavailable {
			description += " [manual only]"
		}
		if reason := m.unavailableExternal[parts[0]]; reason != "" {
			unavailable = true
			description += " [blocked: " + reason + "]"
		}
		m.external = append(m.external, item{name: parts[1], category: parts[0], description: description, unavailable: unavailable, installed: externalInstalled(parts[5])})
	}
	if err := s.Err(); err != nil {
		m.err = err
	}
}

func (m model) officialPackageCovered(app item) bool {
	for _, pkg := range m.packages {
		if pkg.name == app.category && (pkg.selected || pkg.installed) {
			return true
		}
	}
	return false
}

func (m *model) reconcileExternalSelections() {
	for i := range m.external {
		if m.external[i].installed || m.officialPackageCovered(m.external[i]) {
			m.external[i].selected = false
		}
	}
}

func externalInstalled(detection string) bool {
	kind, payload, found := strings.Cut(detection, ":")
	if !found {
		return false
	}
	if kind == "font" {
		return nerdFontInstalled(payload)
	}
	if kind != "cmd" {
		return false
	}
	for _, binary := range strings.Split(payload, ",") {
		if _, err := exec.LookPath(binary); err == nil {
			return true
		}
		for _, dir := range []string{filepath.Join(os.Getenv("HOME"), ".local", "bin"), filepath.Join(os.Getenv("HOME"), ".cargo", "bin"), filepath.Join(os.Getenv("HOME"), ".nimble", "bin")} {
			if info, err := os.Stat(filepath.Join(dir, binary)); err == nil && !info.IsDir() && info.Mode()&0111 != 0 {
				return true
			}
		}
	}
	return false
}

func nerdFontInstalled(family string) bool {
	normalize := func(value string) string {
		replacer := strings.NewReplacer("-", "", "_", "", " ", "")
		return replacer.Replace(strings.ToLower(value))
	}
	needle := normalize(family)
	roots := []string{
		filepath.Join(os.Getenv("HOME"), ".local", "share", "fonts"),
		"/usr/local/share/fonts",
		"/usr/share/fonts",
	}
	for _, root := range roots {
		found := false
		_ = filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
			if err != nil || found || entry.IsDir() {
				return nil
			}
			extension := strings.ToLower(filepath.Ext(path))
			normalizedPath := normalize(path)
			if (extension == ".ttf" || extension == ".otf") && strings.Contains(normalizedPath, needle) && strings.Contains(normalizedPath, "nerdfont") {
				found = true
			}
			return nil
		})
		if found {
			return true
		}
	}
	return false
}

func (m *model) detectServices() {
	type serviceProbe struct {
		units, commands, packages []string
	}
	probes := map[string]serviceProbe{
		"tailscale": {units: []string{"tailscaled"}, commands: []string{"tailscale"}, packages: []string{"tailscale"}},
		"docker":    {units: []string{"docker"}, commands: []string{"docker"}, packages: []string{"docker", "docker-ce"}},
		"ssh":       {units: []string{"sshd", "ssh"}, commands: []string{"sshd"}, packages: []string{"openssh", "openssh-server"}},
	}
	for i := range m.services {
		probe := probes[m.services[i].name]
		present, activeNow := false, false
		for _, unit := range probe.units {
			if exec.Command("systemctl", "is-active", "--quiet", unit).Run() == nil {
				present, activeNow = true, true
				break
			}
			if exec.Command("systemctl", "cat", unit).Run() == nil {
				present = true
			}
		}
		for _, command := range probe.commands {
			if _, err := exec.LookPath(command); err == nil {
				present = true
			}
		}
		for _, pkg := range probe.packages {
			present = present || m.installedPackages[pkg]
		}
		if activeNow {
			m.services[i].installed = true
			m.services[i].description += " [active]"
		} else if present {
			m.services[i].description += " [installed, inactive — select to enable]"
		} else {
			m.services[i].description += " [not installed]"
		}
	}
}

func (m *model) loadConfigurations() {
	m.configurations = nil
	f, err := os.Open(filepath.Join(m.root, "configurations", "catalog.tsv"))
	if err != nil {
		m.err = err
		return
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) < 6 {
			m.err = fmt.Errorf("invalid configuration catalog row: %s", line)
			return
		}
		available := true
		for _, requirement := range strings.Split(fields[2], ",") {
			if requirement != "" && !m.choiceAvailable(requirement) {
				available = false
			}
		}
		description := fields[5]
		if !available {
			description += " [required application is not installed or selected]"
		}
		m.configurations = append(m.configurations, item{
			name: fields[1], category: fields[0], description: description,
			unavailable: !available, installed: configurationDetected(fields[3]),
		})
	}
	if err := scanner.Err(); err != nil {
		m.err = err
	}
}

func (m model) choiceAvailable(name string) bool {
	if m.installedPackages[name] {
		return true
	}
	for _, pkg := range m.packages {
		if pkg.name == name && (pkg.selected || pkg.installed) {
			return true
		}
	}
	for _, app := range m.external {
		if app.category == name && (app.selected || app.installed || m.officialPackageCovered(app)) {
			return true
		}
	}
	for _, service := range m.services {
		if service.name == name && (service.selected || service.installed) {
			return true
		}
	}
	aliases := map[string][]string{
		"ctags":          {"universal-ctags"},
		"github-cli":     {"gh"},
		"spotify-player": {"spotify_player", "spotify-player"},
	}
	commands := append([]string{name}, aliases[name]...)
	for _, command := range commands {
		if _, err := exec.LookPath(command); err == nil {
			return true
		}
	}
	return false
}

func catalogPath(value string) string {
	configRoot := os.Getenv("XDG_CONFIG_HOME")
	if configRoot == "" {
		configRoot = filepath.Join(os.Getenv("HOME"), ".config")
	}
	cacheRoot := os.Getenv("XDG_CACHE_HOME")
	if cacheRoot == "" {
		cacheRoot = filepath.Join(os.Getenv("HOME"), ".cache")
	}
	value = strings.ReplaceAll(value, "$CONFIG", configRoot)
	value = strings.ReplaceAll(value, "$CACHE", cacheRoot)
	return strings.ReplaceAll(value, "$HOME", os.Getenv("HOME"))
}

func configurationDetected(detector string) bool {
	kind, payload, found := strings.Cut(detector, ":")
	if !found {
		return false
	}
	parts := strings.Split(payload, "|")
	switch kind {
	case "login-shell":
		commandPath, err := exec.LookPath(payload)
		if err != nil {
			return false
		}
		account := os.Getenv("USER")
		if output, err := exec.Command("getent", "passwd", account).Output(); err == nil {
			fields := strings.Split(strings.TrimSpace(string(output)), ":")
			return len(fields) >= 7 && fields[6] == commandPath
		}
		return os.Getenv("SHELL") == commandPath
	case "contains":
		if len(parts) != 2 {
			return false
		}
		data, err := os.ReadFile(catalogPath(parts[0]))
		return err == nil && strings.Contains(string(data), parts[1])
	case "files":
		for _, path := range parts {
			info, err := os.Stat(catalogPath(path))
			if err != nil || info.Size() == 0 {
				return false
			}
		}
		return len(parts) > 0
	case "command":
		if len(parts) == 0 {
			return false
		}
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		return exec.CommandContext(ctx, parts[0], parts[1:]...).Run() == nil
	}
	return false
}

func (m model) externalItems() []item {
	items := make([]item, len(m.external))
	copy(items, m.external)
	for i := range items {
		if m.officialPackageCovered(items[i]) {
			items[i].unavailable = true
			items[i].description += " [installed or selected from official repository]"
		}
	}
	return items
}

func (m model) visiblePackageIndexes() []int {
	query := strings.ToLower(strings.TrimSpace(m.search.Value()))
	var out []int
	for i, p := range m.packages {
		if p.category == m.activeCategory && (query == "" || strings.Contains(strings.ToLower(p.name+" "+p.description), query)) {
			out = append(out, i)
		}
	}
	return out
}

func (m model) visiblePackages() []item {
	idx := m.visiblePackageIndexes()
	out := make([]item, 0, len(idx))
	for _, i := range idx {
		out = append(out, m.packages[i])
	}
	return out
}

func (m model) View() string {
	if m.confirmed {
		return ""
	}
	if m.err != nil {
		return "Error: " + m.err.Error()
	}
	w := max(72, m.width)
	h := max(22, m.height)
	if m.stage == stageSplash {
		return m.renderSplash(w, h)
	}
	if m.stage == stageInstall || m.stage == stageResult {
		return m.renderInstall(w, h)
	}
	sideW := min(34, max(28, w/4))
	contentH := max(12, h-5)
	sidebar := m.renderSidebar(sideW, contentH)
	showDetails := w >= 118 && m.stage != stageReview
	mainW := max(46, w-sideW-1)
	if showDetails {
		detailW := min(40, max(30, w/3))
		mainW = max(46, w-sideW-detailW-1)
		content := m.renderContent(mainW, contentH, true)
		details := m.renderDetails(detailW, contentH)
		body := lipgloss.JoinHorizontal(lipgloss.Top, sidebar, content, details)
		footer := m.renderFooter(w)
		return body + "\n" + footer
	}
	content := m.renderContent(mainW, contentH, false)
	body := lipgloss.JoinHorizontal(lipgloss.Top, sidebar, content)
	footer := m.renderFooter(w)
	return body + "\n" + footer
}

func (m model) renderSplash(width, height int) string {
	title := lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color(cyan)).
		Render("L I N U X")
	version := ""
	if m.version != "" {
		version = muted.Render("version " + m.version)
	}
	actionNames := []string{"Begin a new setup"}
	if m.lastPlan != "" {
		actionNames = append(actionNames, "Repeat the last setup")
	}
	actionNames = append(actionNames, "Exit")
	var actionRows []string
	for i, name := range actionNames {
		marker, style := "  ", lipgloss.NewStyle().Foreground(white)
		if i == m.cursor {
			marker, style = "> ", active
		}
		actionRows = append(actionRows, style.Render(marker+name))
	}
	actions := strings.Join(actionRows, "\n")
	card := title + "\n" + muted.Render("personal system bootstrap")
	if version != "" {
		card += "\n\n" + version
	}
	card += "\n\n" +
		muted.Render("Detected: "+m.pretty) + "\n" +
		muted.Render("Suggested profile: "+m.profile) + "\n"
	if m.splashNotice != "" {
		card += "\n" + warning.Render(m.splashNotice) + "\n"
	}
	card += "\n\n" + muted.Render("Choose an action") + "\n\n" +
		actions + "\n\n\n" + muted.Render("↑/↓ move    enter select    esc exit")
	return lipgloss.Place(width, height, lipgloss.Center, lipgloss.Center, card)
}

func (m model) renderInstall(width, height int) string {
	title := active.Render("Linux Bootstrap")
	state := cyanStyle.Render("● Installation in progress")
	footer := muted.Render("F2 raw output   Type normally when an installer asks a question")
	if m.stage == stageResult {
		if m.installStatus == 0 {
			state = success.Bold(true).Render("✓ Installation complete")
		} else {
			state = danger.Bold(true).Render("× Installation finished with failures")
		}
		footer = muted.Render("F2 raw output   Enter close")
	}
	availableRows := max(5, height-12)
	var body string
	if m.showRaw {
		start := max(0, len(m.installLines)-availableRows)
		body = muted.Render("Raw output") + "\n\n" + strings.Join(m.installLines[start:], "\n")
	} else {
		latest := "Preparing installation…"
		if len(m.installLines) > 0 {
			latest = m.installLines[len(m.installLines)-1]
		}
		body = muted.Render("Current activity") + "\n\n" +
			lipgloss.NewStyle().Foreground(white).Width(max(40, width-12)).Render(latest) +
			"\n\n\n" + muted.Render("Normal command output is still being saved to the bootstrap log.")
	}
	panelBody := title + "\n\n" + state + "\n\n\n" + body
	panel := lipgloss.NewStyle().
		Width(max(60, width-8)).Height(max(14, height-5)).
		Border(lipgloss.RoundedBorder()).BorderForeground(cyan).
		Padding(1, 2).
		Render(panelBody)
	return lipgloss.Place(width, height, lipgloss.Center, lipgloss.Center, panel+"\n"+footer)
}

func (m model) renderSidebar(width, height int) string {
	title := active.Render(">> LINUX") + "\n" + muted.Render("bootstrap") + "\n\n"
	if m.configureOnly {
		lines := muted.Render("Configuration-only mode") + "\n\n"
		for i, name := range []string{"Configure applications", "Review & apply"} {
			selected := (i == 0 && m.stage == stageConfigurations) || (i == 1 && m.stage == stageReview)
			mark, style := "*", lipgloss.NewStyle().Foreground(white)
			if selected {
				mark, style = ">", active
			} else if i == 0 && m.stage == stageReview {
				mark = "✓"
			}
			lines += style.Render(fmt.Sprintf("%s %02d %s", mark, i+1, name)) + "\n"
		}
		info := "\n" + muted.Render(m.pretty)
		if m.version != "" {
			info += "\n" + muted.Render("version: "+m.version)
		}
		return m.sidebarFrame(width, height).Render(title + lines + info)
	}
	names := []string{"Preflight", "Profile", "Packages", "External applications", "Services", "Configure applications", "Review & install"}
	lines := ""
	for i, name := range names {
		isActive := (i == 0 && m.stage == stagePreflight) || (i == 1 && m.stage == stageProfile) ||
			(i == 2 && (m.stage == stageCategories || m.stage == stagePackages)) ||
			(i == 3 && m.stage == stageExternal) || (i == 4 && m.stage == stageServices) ||
			(i == 5 && m.stage == stageConfigurations) || (i == 6 && m.stage == stageReview)
		isComplete := (i == 0 && m.stage > stagePreflight) || (i == 1 && m.stage > stageProfile) ||
			(i == 2 && m.stage >= stageExternal) || (i == 3 && m.stage >= stageServices) ||
			(i == 4 && m.stage >= stageConfigurations) || (i == 5 && m.stage >= stageReview)
		mark := "*"
		style := lipgloss.NewStyle().Foreground(white)
		if isActive {
			mark = ">"
			style = active
		}
		if isComplete {
			mark = "✓"
		}
		lines += style.Render(fmt.Sprintf("%s %02d %s", mark, i+1, name)) + "\n"
		if i == 2 && (m.stage == stageCategories || m.stage == stagePackages) {
			for _, category := range m.categoryItems()[:len(m.categories)] {
				childMark := "·"
				childStyle := muted
				if category.selected {
					childMark = "✓"
				}
				if m.stage == stagePackages && category.category == m.activeCategory {
					childMark = ">"
					childStyle = active
				}
				lines += childStyle.Render(fmt.Sprintf("  %s %s", childMark, category.name)) + "\n"
			}
		}
	}
	info := "\n" + muted.Render(m.pretty) + "\n" + cyanStyle.Render("profile: "+m.profile)
	if m.version != "" {
		info += "\n" + muted.Render("version: "+m.version)
	}
	return m.sidebarFrame(width, height).Render(title + lines + info)
}

func (m model) sidebarFrame(width, height int) lipgloss.Style {
	return lipgloss.NewStyle().
		Width(width).Height(height).
		Border(lipgloss.NormalBorder()).
		BorderForeground(panel).
		BorderRight(false).
		BorderBottom(false).
		Padding(1)
}

func (m model) renderContent(width, height int, sharedRight bool) string {
	var title, body string
	switch m.stage {
	case stagePreflight:
		title = "01 · Preflight · v" + m.version
		body = muted.Render("Package manager, privilege, and disk checks are required. Network and build-tool checks are advisory.") + "\n\n"
		body += m.renderItems(m.preflight, height-8)
		if m.preflightBlock != "" {
			body += "\n\n" + danger.Bold(true).Render(m.preflightBlock)
		}
	case stageProfile:
		title, body = "02 · Profile", m.renderItems(m.profiles, height-5)
	case stageCategories:
		title = "03 · Package categories"
		body = muted.Render("Enter opens a category. Space selects or clears the entire category.") + "\n\n"
		body += m.renderItems(m.categoryItems(), height-9)
		body += "\n\n" + muted.Render(fmt.Sprintf("Total selected: %d of %d available packages", countSelected(m.packages), countAvailable(m.packages)))
	case stagePackages:
		title = "03 · Packages · " + m.categoryLabel(m.activeCategory)
		search := cyanStyle.Render("Search") + "\n" + m.search.View()
		body = search + "\n\n" + m.renderItems(m.visiblePackages(), height-11)
		selected, total := m.categoryCounts(m.activeCategory)
		body += "\n" + muted.Render(fmt.Sprintf("Category selected: %d of %d", selected, total))
	case stageExternal:
		title = "04 · External applications"
		body = muted.Render("Official repository selections are dimmed here to prevent duplicate installs. Legacy choices are clearly labeled.") + "\n\n"
		body += m.renderItems(m.externalItems(), height-8)
	case stageServices:
		title, body = "05 · Optional services", m.renderItems(m.services, height-5)
	case stageConfigurations:
		title = "06 · Configure applications"
		if m.configureOnly {
			title = "01 · Configure applications"
		}
		body = muted.Render("Simple settings are applied safely here. Sensitive account changes request confirmation after installation.") + "\n\n"
		body += m.renderItems(m.configurations, max(3, (height-8)/2))
	case stageReview:
		title, body = "07 · Review & install", m.renderReview()
		if m.configureOnly {
			title = "02 · Review & apply"
		}
	}
	header := active.Render(title)
	frame := lipgloss.NewStyle().
		Width(width).Height(height).
		Border(lipgloss.NormalBorder()).
		BorderForeground(cyan).
		BorderBottom(false).
		Padding(1)
	if sharedRight {
		frame = frame.BorderRight(false)
	}
	return frame.Render(header + "\n\n" + body)
}

func (m model) renderDetails(width, height int) string {
	selected, ok := m.currentItem()
	title := active.Render("Details")
	body := muted.Render("Move through the list to inspect an option.")
	if ok {
		body = lipgloss.NewStyle().Foreground(white).Bold(true).Render(selected.name)
		if selected.description != "" {
			body += "\n\n" + lipgloss.NewStyle().Foreground(dim).Width(max(20, width-4)).Render(selected.description)
		}
		body += "\n\n" + muted.Render("Status") + "\n" + m.itemStatus(selected)
		if selected.category != "" && selected.category != "__continue" {
			body += "\n\n" + muted.Render("Category") + "\n" + cyanStyle.Render(m.categoryLabel(selected.category))
		}
	}
	return lipgloss.NewStyle().
		Width(width).Height(height).
		Border(lipgloss.NormalBorder()).
		BorderForeground(panel).
		BorderBottom(false).
		Padding(1).
		Render(title + "\n\n" + body)
}

func (m model) currentItem() (item, bool) {
	var items []item
	switch m.stage {
	case stagePreflight:
		items = m.preflight
	case stageProfile:
		items = m.profiles
	case stageCategories:
		items = m.categoryItems()
	case stagePackages:
		items = m.visiblePackages()
	case stageExternal:
		items = m.externalItems()
	case stageServices:
		items = m.services
	case stageConfigurations:
		items = m.configurations
	}
	if m.cursor < 0 || m.cursor >= len(items) {
		return item{}, false
	}
	return items[m.cursor], true
}

func (m model) itemStatus(selected item) string {
	switch {
	case selected.installed:
		return success.Render("Already installed")
	case selected.unavailable:
		return danger.Render("Unavailable")
	case selected.selected:
		return success.Render("Selected")
	case selected.category == "__continue":
		return cyanStyle.Render("Continue")
	default:
		return muted.Render("Not selected")
	}
}

func (m model) renderItems(items []item, maxRows int) string {
	if len(items) == 0 {
		return muted.Render("No matching packages")
	}
	start := 0
	if m.cursor >= maxRows {
		start = m.cursor - maxRows + 1
	}
	end := min(len(items), start+maxRows)
	var rows []string
	for i := start; i < end; i++ {
		box := " "
		disabled := items[i].unavailable || items[i].installed
		if items[i].unavailable {
			box = "–"
		}
		if items[i].installed {
			box = "•"
		}
		if items[i].selected {
			box = "✓"
		}
		cursor := "  "
		style := lipgloss.NewStyle().Foreground(white)
		if i == m.cursor {
			cursor = "› "
			if disabled {
				style = muted.Background(selection)
			} else {
				style = active.Background(selection)
			}
		} else if disabled {
			style = muted
		} else if items[i].selected {
			style = success
		}
		line := fmt.Sprintf("%s[%s] %s", cursor, box, items[i].name)
		if items[i].description != "" && m.width < 118 {
			line += muted.Render(" — " + items[i].description)
		}
		if items[i].installed {
			line += muted.Render(" [installed]")
		}
		rows = append(rows, style.Render(line))
	}
	return strings.Join(rows, "\n")
}

func (m model) renderReview() string {
	pkgs, apps, svcs, configs := selectedNames(m.packages), selectedNames(m.external), selectedNames(m.services), selectedNames(m.configurations)
	if m.configureOnly {
		body := cyanStyle.Render(fmt.Sprintf("Configuration tasks (%d)", len(configs))) + "\n  " + wrapNames(configs, 6) + "\n\n"
		body += active.Render("Press Enter to apply configuration")
		return body
	}
	body := cyanStyle.Render("Profile") + "\n  " + m.family + " / " + m.profile + "\n\n"
	body += cyanStyle.Render(fmt.Sprintf("Packages (%d)", len(pkgs))) + "\n  " + wrapNames(pkgs, 8) + "\n\n"
	body += cyanStyle.Render(fmt.Sprintf("External applications (%d)", len(apps))) + "\n  " + wrapNames(apps, 6) + "\n\n"
	body += cyanStyle.Render(fmt.Sprintf("Services (%d)", len(svcs))) + "\n  " + wrapNames(svcs, 8) + "\n\n"
	body += cyanStyle.Render(fmt.Sprintf("Configuration tasks (%d)", len(configs))) + "\n  " + wrapNames(configs, 6) + "\n\n"
	body += active.Render("Press Enter to begin installation")
	return body
}

func (m model) renderFooter(width int) string {
	help := map[stage]string{
		stagePreflight:      "↑/↓ inspect   Enter continue   Esc welcome",
		stageProfile:        "↑/↓ choose   Enter select   Esc back",
		stageCategories:     "↑/↓ move   Space all/none   Enter open   Esc back",
		stagePackages:       "↑/↓ move   Space toggle   Ctrl+A all/none   / search   Enter next   Esc categories",
		stageExternal:       "↑/↓ move   Space toggle   Enter continue   Esc packages",
		stageServices:       "↑/↓ move   Space toggle   Enter continue   Esc external apps",
		stageConfigurations: "↑/↓ move   Space toggle   Enter continue   Esc services",
		stageReview:         "Enter install   Esc change selections",
	}[m.stage]
	if m.configureOnly {
		if m.stage == stageConfigurations {
			help = "↑/↓ move   Space toggle   Enter review   Esc welcome"
		} else if m.stage == stageReview {
			help = "Enter apply   Esc change selections"
		}
	}
	help += "   Ctrl+C quit"
	return lipgloss.NewStyle().
		Width(width).
		Border(lipgloss.NormalBorder()).
		BorderForeground(panel).
		Foreground(dim).
		Padding(0, 1).
		Render(help)
}

func (m model) categoryLabel(slug string) string {
	for _, category := range m.categories {
		if category.slug == slug {
			return category.label
		}
	}
	return slug
}

func (m *model) loadPlan(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("read last plan: %w", err)
	}
	defer f.Close()
	profile, family := "", ""
	requestedPackages, requestedExternal := map[string]bool{}, map[string]bool{}
	requestedServices, requestedConfigurations := map[string]bool{}, map[string]bool{}
	s := bufio.NewScanner(f)
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		kind, value, found := strings.Cut(line, "=")
		if !found || value == "" {
			return fmt.Errorf("invalid last-plan line %q", line)
		}
		switch kind {
		case "FORMAT":
			if value != "1" {
				return fmt.Errorf("unsupported last-plan format %q", value)
			}
		case "FAMILY":
			family = value
		case "PROFILE":
			profile = value
		case "PACKAGE":
			requestedPackages[value] = true
		case "PRESENT_PACKAGE", "PRESENT_EXTERNAL":
			// Informational state from the machine that created the plan.
		case "EXTERNAL":
			requestedExternal[value] = true
		case "SERVICE":
			requestedServices[value] = true
		case "CONFIG":
			requestedConfigurations[value] = true
		default:
			return fmt.Errorf("unknown last-plan field %q", kind)
		}
	}
	if err := s.Err(); err != nil {
		return err
	}
	if family != "" && family != m.family {
		return fmt.Errorf("last plan targets %s, not %s", family, m.family)
	}
	if profile != "desktop" && profile != "server" {
		return fmt.Errorf("last plan has invalid profile %q", profile)
	}
	m.profile = profile
	m.loadPackages()
	if m.err != nil {
		return m.err
	}
	for name := range requestedPackages {
		found := false
		for i := range m.packages {
			if m.packages[i].name == name {
				if m.packages[i].unavailable {
					return fmt.Errorf("package %q is unavailable: %s", name, m.unavailablePackages[name])
				}
				m.packages[i].selected = true
				found = true
				break
			}
		}
		if !found {
			return fmt.Errorf("package %q is not available for %s/%s", name, m.family, profile)
		}
	}
	m.loadExternal()
	if m.err != nil {
		return m.err
	}
	for id := range requestedExternal {
		found := false
		for i := range m.external {
			if m.external[i].category == id && !m.external[i].unavailable {
				m.external[i].selected = true
				found = true
				break
			}
		}
		if !found {
			return fmt.Errorf("external application %q is unavailable for %s", id, profile)
		}
	}
	for id := range requestedServices {
		found := false
		for i := range m.services {
			if m.services[i].name == id {
				m.services[i].selected = true
				found = true
				break
			}
		}
		if !found {
			return fmt.Errorf("unknown service %q", id)
		}
	}
	m.loadConfigurations()
	if m.err != nil {
		return m.err
	}
	for id := range requestedConfigurations {
		found := false
		for i := range m.configurations {
			if m.configurations[i].category == id {
				m.configurations[i].selected = true
				found = true
				break
			}
		}
		if !found {
			return fmt.Errorf("unknown configuration task %q", id)
		}
	}
	return nil
}

func (m model) writeSelection() error {
	f, err := os.OpenFile(m.output, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	fmt.Fprintln(f, "FAMILY="+m.family)
	fmt.Fprintln(f, "PROFILE="+m.profile)
	for _, p := range m.packages {
		if p.selected {
			fmt.Fprintln(f, "PACKAGE="+p.name)
		} else if p.installed {
			fmt.Fprintln(f, "PRESENT_PACKAGE="+p.name)
		}
	}
	for _, app := range m.external {
		if app.selected {
			fmt.Fprintln(f, "EXTERNAL="+app.category)
		} else if app.installed {
			fmt.Fprintln(f, "PRESENT_EXTERNAL="+app.category)
		}
	}
	for _, s := range m.services {
		if s.selected {
			fmt.Fprintln(f, "SERVICE="+s.name)
		}
	}
	for _, configuration := range m.configurations {
		if configuration.selected {
			fmt.Fprintln(f, "CONFIG="+configuration.category)
		}
	}
	return nil
}

func selectedNames(items []item) []string {
	var out []string
	for _, x := range items {
		if x.selected {
			out = append(out, x.name)
		}
	}
	return out
}
func countSelected(items []item) int {
	n := 0
	for _, x := range items {
		if x.selected {
			n++
		}
	}
	return n
}
func countAvailable(items []item) int {
	n := 0
	for _, x := range items {
		if !x.installed {
			n++
		}
	}
	return n
}
func wrapNames(names []string, limit int) string {
	if len(names) == 0 {
		return "none"
	}
	var lines []string
	for len(names) > 0 {
		n := min(limit, len(names))
		lines = append(lines, strings.Join(names[:n], ", "))
		names = names[n:]
	}
	return strings.Join(lines, "\n  ")
}
func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
