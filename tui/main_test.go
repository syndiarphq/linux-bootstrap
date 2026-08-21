package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSplashChoices(t *testing.T) {
	m := newModel("..", "arch", "Arch Linux", filepath.Join(t.TempDir(), "selection"), "server")
	if m.stage != stageSplash || m.itemCount() != 2 {
		t.Fatal("splash did not open with two choices")
	}
	m.cursor = 0
	m.next()
	if m.stage != stagePreflight || m.cancelled {
		t.Fatal("Begin did not advance to preflight")
	}
	m.stage, m.cursor = stageSplash, 1
	m.next()
	if !m.cancelled {
		t.Fatal("Exit did not cancel the installer")
	}
}

func TestSplashUsesMinimalWelcomeLayout(t *testing.T) {
	m := newModel("..", "arch", "Arch Linux", filepath.Join(t.TempDir(), "selection"), "server")
	m.version = "1.0.0"
	view := m.renderSplash(100, 30)
	for _, want := range []string{"L I N U X", "version 1.0.0", "Begin a new setup", "↑/↓ move"} {
		if !strings.Contains(view, want) {
			t.Fatalf("splash is missing %q", want)
		}
	}
	if strings.Contains(view, "██") || strings.Contains(view, "[ Enter ]") {
		t.Fatal("splash still contains the old block-art treatment")
	}
}

func TestRepeatLastPlanFromSplash(t *testing.T) {
	plan := filepath.Join(t.TempDir(), "last-plan.conf")
	data := "FORMAT=1\nFAMILY=arch\nPROFILE=server\nPACKAGE=git\nEXTERNAL=starship\nSERVICE=ssh\n"
	if err := os.WriteFile(plan, []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
	m := newModel("..", "arch", "Arch Linux", filepath.Join(t.TempDir(), "selection"), "desktop")
	m.lastPlan = plan
	if m.itemCount() != 3 {
		t.Fatal("repeatable plan did not add a splash choice")
	}
	m.cursor = 1
	m.next()
	if m.err != nil {
		t.Fatal(m.err)
	}
	if !m.confirmed || m.profile != "server" {
		t.Fatal("repeat last selection did not confirm the saved server plan")
	}
	wantPackage, wantExternal, wantService := false, false, false
	for _, item := range m.packages {
		wantPackage = wantPackage || item.name == "git" && item.selected
	}
	for _, item := range m.external {
		wantExternal = wantExternal || item.category == "starship" && item.selected
	}
	for _, item := range m.services {
		wantService = wantService || item.name == "ssh" && item.selected
	}
	if !wantPackage || !wantExternal || !wantService {
		t.Fatal("saved selections were not restored")
	}
}

func TestLastPlanRejectsWrongFamilyAndUnknownItem(t *testing.T) {
	for _, data := range []string{
		"FORMAT=1\nFAMILY=debian\nPROFILE=server\nPACKAGE=git\n",
		"FORMAT=1\nFAMILY=arch\nPROFILE=server\nPACKAGE=not-a-real-package\n",
	} {
		plan := filepath.Join(t.TempDir(), "invalid-plan.conf")
		if err := os.WriteFile(plan, []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
		m := newModel("..", "arch", "Arch Linux", filepath.Join(t.TempDir(), "selection"), "server")
		if err := m.loadPlan(plan); err == nil {
			t.Fatalf("invalid plan was accepted: %s", data)
		}
	}
}

func TestAvailabilityDisablesPackagesAndExternalDependencies(t *testing.T) {
	report := filepath.Join(t.TempDir(), "availability.tsv")
	if err := os.WriteFile(report, []byte("PACKAGE\tgit\tUnavailable in test repository\nEXTERNAL\tstarship\tMissing repository dependencies: rust\n"), 0600); err != nil {
		t.Fatal(err)
	}
	m := newModel("..", "arch", "Arch Linux", filepath.Join(t.TempDir(), "selection"), "server")
	if err := m.loadAvailability(report); err != nil {
		t.Fatal(err)
	}
	m.profile = "server"
	m.loadPackages()
	m.loadExternal()
	foundPackage, foundExternal := false, false
	for _, item := range m.packages {
		if item.name == "git" {
			foundPackage = item.unavailable && strings.Contains(item.description, "blocked")
		}
	}
	for _, item := range m.external {
		if item.category == "starship" {
			foundExternal = item.unavailable && strings.Contains(item.description, "rust")
		}
	}
	if !foundPackage || !foundExternal {
		t.Fatal("availability failures did not disable their TUI choices")
	}
}

func TestRequiredPreflightBlocksProgress(t *testing.T) {
	m := newModel("..", "arch", "Arch Linux", filepath.Join(t.TempDir(), "selection"), "server")
	m.stage = stagePreflight
	m.preflight = []item{
		{name: "Package manager", selected: true},
		{name: "Privilege escalation", selected: false},
		{name: "Free disk space", selected: true},
		{name: "Internet access", selected: false},
	}
	m.next()
	if m.stage != stagePreflight || m.preflightBlock == "" {
		t.Fatal("failed required preflight did not block progress")
	}
	m.preflight[1].selected = true
	m.next()
	if m.stage != stageProfile {
		t.Fatal("successful required checks did not advance to profile")
	}
}

func TestProfileCatalogs(t *testing.T) {
	root := filepath.Clean("..")
	for _, tc := range []struct{ family, profile string }{
		{"arch", "desktop"}, {"arch", "server"},
		{"debian", "desktop"}, {"debian", "server"},
		{"fedora", "desktop"}, {"fedora", "server"},
		{"suse", "desktop"}, {"suse", "server"},
	} {
		m := newModel(root, tc.family, tc.family, filepath.Join(t.TempDir(), "selection"), "desktop")
		m.profile = tc.profile
		m.loadPackages()
		if m.err != nil {
			t.Fatalf("%s/%s: %v", tc.family, tc.profile, m.err)
		}
		if len(m.packages) < 15 {
			t.Fatalf("%s/%s loaded only %d packages", tc.family, tc.profile, len(m.packages))
		}
		seen := map[string]bool{}
		for _, p := range m.packages {
			if seen[p.name] {
				t.Fatalf("%s/%s contains duplicate %q", tc.family, tc.profile, p.name)
			}
			seen[p.name] = true
			if p.description == "" {
				t.Fatalf("%s/%s package %q has no description", tc.family, tc.profile, p.name)
			}
		}
	}
}

func TestSelectionFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "selection")
	m := newModel("..", "arch", "Arch", path, "desktop")
	m.profile = "server"
	m.loadPackages()
	m.packages[0].selected = true
	m.loadExternal()
	m.external[0].selected = true
	m.services[1].selected = true
	m.installedPackages["fish"] = true
	m.installedPackages["starship"] = true
	m.loadConfigurations()
	m.configurations[1].selected = true
	if err := m.writeSelection(); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	out := string(b)
	for _, want := range []string{"PROFILE=server", "PACKAGE=" + m.packages[0].name, "EXTERNAL=" + m.external[0].category, "SERVICE=docker", "CONFIG=fish-starship"} {
		if !strings.Contains(out, want+"\n") {
			t.Fatalf("selection file missing %q:\n%s", want, out)
		}
	}
}

func TestConfigurationAvailabilityAndDetection(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	m := newModel("..", "arch", "Arch", filepath.Join(t.TempDir(), "selection"), "server")
	m.installedPackages["fish"] = true
	m.installedPackages["starship"] = true
	m.installedPackages["micro"] = true
	m.installedPackages["fzf"] = true
	m.installedPackages["ctags"] = true
	m.installedPackages["jq"] = true
	m.loadConfigurations()
	if len(m.configurations) != 12 {
		t.Fatalf("expected twelve configuration tasks, got %d", len(m.configurations))
	}
	for _, configuration := range m.configurations[:9] {
		if configuration.unavailable {
			t.Fatalf("installed prerequisites did not enable %q", configuration.category)
		}
	}
	fishConfig := filepath.Join(home, ".config", "fish", "config.fish")
	if err := os.MkdirAll(filepath.Dir(fishConfig), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fishConfig, []byte("# >>> linux-bootstrap starship >>>\n"), 0644); err != nil {
		t.Fatal(err)
	}
	starshipConfig := filepath.Join(home, ".config", "starship.toml")
	if err := os.WriteFile(starshipConfig, []byte("# Generated by linux-bootstrap: nerd-font-symbols\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if !configurationDetected("contains:$CONFIG/fish/config.fish|# >>> linux-bootstrap starship >>>") ||
		!configurationDetected("contains:$CONFIG/starship.toml|# Generated by linux-bootstrap: nerd-font-symbols") {
		t.Fatal("managed configuration markers were not detected")
	}
}

func TestStarshipPresetSelectionIsExclusive(t *testing.T) {
	m := newModel("..", "arch", "Arch", filepath.Join(t.TempDir(), "selection"), "server")
	m.installedPackages["starship"] = true
	m.loadConfigurations()
	m.stage = stageConfigurations
	m.cursor = 3
	m.toggleCurrent()
	m.cursor = 4
	m.toggleCurrent()
	if m.configurations[3].selected || !m.configurations[4].selected {
		t.Fatal("selecting a Starship preset did not clear the previous preset")
	}
}

func TestExternalCatalogProfiles(t *testing.T) {
	m := newModel("..", "arch", "Arch", filepath.Join(t.TempDir(), "selection"), "server")
	m.profile = "server"
	m.loadExternal()
	foundFont, foundDesktopOnly, foundBrowsh := false, false, false
	for _, app := range m.external {
		if strings.HasPrefix(app.category, "nerd-font-") {
			foundFont = true
		}
		if app.category == "concord" || app.category == "spotify-player" {
			foundDesktopOnly = true
		}
		if app.category == "browsh" && !app.unavailable {
			foundBrowsh = true
		}
	}
	if !foundFont || foundDesktopOnly || !foundBrowsh {
		t.Fatalf("external profile filtering or recipe status is incorrect")
	}
}

func TestExternalInstalledDetection(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	binDir := filepath.Join(home, ".local", "bin")
	t.Setenv("PATH", binDir)
	if err := os.MkdirAll(binDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(binDir, "caligula"), []byte("#!/bin/sh\n"), 0755); err != nil {
		t.Fatal(err)
	}
	if !externalInstalled("cmd:caligula") {
		t.Fatal("user-local Caligula was not detected")
	}
	if externalInstalled("cmd:fnf") {
		t.Fatal("missing fnf was incorrectly detected")
	}
	fontDir := filepath.Join(home, ".local", "share", "fonts", "NerdFonts", "JetBrainsMono")
	if err := os.MkdirAll(fontDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(fontDir, "JetBrainsMonoNerdFont-Regular.ttf"), []byte("test font"), 0644); err != nil {
		t.Fatal(err)
	}
	if !externalInstalled("font:JetBrainsMono") {
		t.Fatal("installed JetBrainsMono Nerd Font was not detected")
	}
	if externalInstalled("font:FiraCode") {
		t.Fatal("missing FiraCode Nerd Font was incorrectly detected")
	}
}

func TestOfficialPackageDimsMatchingExternalChoice(t *testing.T) {
	m := newModel("..", "arch", "Arch", filepath.Join(t.TempDir(), "selection"), "server")
	m.profile = "server"
	m.loadPackages()
	m.loadExternal()
	for i := range m.packages {
		if m.packages[i].name == "starship" {
			m.packages[i].selected = true
		}
	}
	m.reconcileExternalSelections()
	for _, app := range m.externalItems() {
		if app.category == "starship" {
			if !app.unavailable || !strings.Contains(app.description, "official repository") {
				t.Fatalf("official Starship selection did not dim its external entry")
			}
			return
		}
	}
	t.Fatal("Starship external entry not found")
}

func TestInstalledPackagesAreVisibleButNotSelectable(t *testing.T) {
	m := newModel("..", "arch", "Arch", filepath.Join(t.TempDir(), "selection"), "server")
	m.profile = "server"
	m.installedPackages["openssh"] = true
	m.loadPackages()
	found := false
	for _, pkg := range m.packages {
		if pkg.name == "openssh" {
			found = true
			if !pkg.installed {
				t.Fatal("OpenSSH was not marked installed")
			}
		}
	}
	if !found {
		t.Fatal("OpenSSH package not found")
	}
	m.activeCategory = "server"
	m.selectVisible(true)
	for _, pkg := range m.packages {
		if pkg.name == "openssh" && pkg.selected {
			t.Fatal("installed OpenSSH was selectable")
		}
	}
}

func TestCategorySelectionIsIsolated(t *testing.T) {
	m := newModel("..", "arch", "Arch", filepath.Join(t.TempDir(), "selection"), "desktop")
	m.profile = "desktop"
	m.loadPackages()
	m.activeCategory = "fonts"
	m.selectVisible(true)
	for _, p := range m.packages {
		if p.category == "fonts" && !p.selected {
			t.Fatalf("font %q was not selected", p.name)
		}
		if p.category != "fonts" && p.selected {
			t.Fatalf("non-font package %q was selected", p.name)
		}
	}
}

func TestPackageEnterAdvancesAndEscapeReturns(t *testing.T) {
	m := newModel("..", "arch", "Arch", filepath.Join(t.TempDir(), "selection"), "desktop")
	m.profile = "desktop"
	m.loadPackages()
	m.stage = stagePackages
	m.activeCategory = m.categories[0].slug
	m.next()
	if m.stage != stagePackages || m.activeCategory != m.categories[1].slug {
		t.Fatalf("Enter did not advance to the next category")
	}
	m.back()
	if m.stage != stageCategories {
		t.Fatalf("Escape/back did not return to the category menu")
	}
}

func TestLastPackageCategoryHighlightsContinue(t *testing.T) {
	m := newModel("..", "arch", "Arch", filepath.Join(t.TempDir(), "selection"), "server")
	m.profile = "server"
	m.loadPackages()
	m.stage = stagePackages
	m.activeCategory = m.categories[len(m.categories)-1].slug
	m.next()
	if m.stage != stageCategories {
		t.Fatalf("last category did not return to category menu")
	}
	if m.cursor != len(m.categories) {
		t.Fatalf("Continue was not highlighted: cursor=%d, want %d", m.cursor, len(m.categories))
	}
	menu := m.categoryItems()
	if menu[m.cursor].category != "__continue" {
		t.Fatalf("highlighted row is not Continue")
	}
}
