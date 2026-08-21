# Linux Bootstrap

Current release: **v1.0.0**

An interactive, repeatable Linux bootstrap with desktop and headless-server
profiles for conventional package-manager families:

- CachyOS/Arch desktop
- CachyOS/Arch headless server
- Debian/Ubuntu desktop and server
- Fedora/RHEL-family desktop and server
- openSUSE desktop and server

It uses [Gum](https://github.com/charmbracelet/gum) when installed and falls back
to plain terminal prompts. An optional Bubble Tea frontend provides the full-screen
multi-pane interface. Gum is optional and is also available as a selectable Arch
package.
The full-screen installer opens with a centered, Vim-inspired welcome screen;
Enter begins preflight and Esc exits without making changes.

## Run it

```bash
git clone https://github.com/syndiarphq/linux-bootstrap.git
cd linux-bootstrap
chmod +x setup.sh
./setup.sh
```

Build the full-screen TUI once (requires Go), then run the installer normally:

```bash
chmod +x tools/build-tui.sh
./tools/build-tui.sh
./setup.sh
```

Run the repeatable validation suite before publishing or transferring a build:

```bash
./tools/test.sh
```

If the TUI binary is missing, the installer automatically uses Gum or plain Bash.

## Saved plans

Every successful full-screen selection is saved locally as
`~/.local/state/linux-bootstrap/last-plan.conf`. On the next launch, the splash
screen offers **Repeat last selection**. Installed items recorded as `PRESENT_*`
remain informational; only explicit `PACKAGE`, `EXTERNAL`, `SERVICE`, and `CONFIG`
lines express desired actions.

Save the next TUI selection under a friendly name as well:

```bash
./setup.sh --save-plan plans/austin-arch-server.plan
```

Run or preview an editable plan without walking through the menus:

```bash
./setup.sh --plan plans/austin-arch-server.plan --dry-run
./setup.sh --plan plans/austin-arch-server.plan
```

Plans use the same small line-oriented format as the TUI handoff:

```text
FORMAT=1
FAMILY=arch
PROFILE=server
PACKAGE=git
PACKAGE=tmux
EXTERNAL=starship
SERVICE=ssh
CONFIG=fish-starship
```

The loader rejects wrong-distro plans, packages outside the selected profile,
manual or profile-incompatible external applications, unknown services, unknown
configuration tasks, and conflicting configuration choices before installation.

## Validate installer data

Run the same catalog and repository checks used to gate the installer menu:

```bash
./setup.sh --validate
```

Static failures include malformed or duplicate catalog rows and packages without
descriptions. The validator also reads the enabled package-manager metadata without
refreshing or changing it. A package confirmed missing from those repositories is
dimmed and disabled in the TUI. An external application is likewise disabled when
one of its Cargo, Go, build, browser, font, or native library dependencies cannot
be installed. Saved plans pass through the same gate and stop before execution.

If repository metadata cannot be queried, validation shows a warning and skips
availability gating instead of incorrectly blocking every option. Installed
packages remain valid even if their former repository no longer provides them.
Use `./setup.sh --classic` to request that fallback explicitly. The TUI binary can
also be supplied with `LINUX_BOOTSTRAP_TUI=/path/to/linux-bootstrap-tui`.

Preview without changing the system:

```bash
./setup.sh --dry-run
```

Run only the application-configuration workflow without selecting or installing
packages:

```bash
./setup.sh --configure
./setup.sh --configure --dry-run
```

Interactive runs use the terminal's full-screen alternate buffer and restore the
previous terminal contents on completion. To keep normal scrolling output instead:

```bash
./setup.sh --no-fullscreen
```

Select all profile packages non-interactively (optional services remain off):

```bash
./setup.sh --yes
```

## What it does

The script detects the distribution through `/etc/os-release`. Arch/CachyOS lets
you choose a desktop or headless-server profile, as do the Debian, Fedora, and
openSUSE families. An active graphical session,
installed desktop session, or recognized WM/DE makes `desktop` the default;
otherwise `server` is selected. This is only a suggested default and can be
overridden on the profile screen.

The full-screen flow begins with a preflight screen covering architecture,
package-manager availability, sudo, free disk space, internet access, and optional
build tools. Missing Cargo, Go, Nim, Git, Make, Firefox, curl, jq, and unzip
dependencies are planned from the final external-app selection, deduplicated, and
installed together before source builds begin.
Package-manager, privilege-escalation, and minimum-disk-space failures block the
installation before changes begin. Architecture and connectivity warnings remain
visible but advisory because repository and architecture coverage differs by selection.

NixOS and immutable OSTree systems are detected and stopped without changes.
They require declarative configuration-generator backends rather than ordinary
package-manager commands.
It then lets you install the complete profile package list or select
exact individual packages. Package groups are not exposed in the installer. It
installs only missing packages. Arch uses
`pacman -S --needed`; Debian checks installed packages before calling `apt-get`.
Runs are logged under `~/.local/state/linux-bootstrap/`.
The final human-readable report is saved alongside the timestamped command log.
External entries in that report include their reviewed source, installation
method, and locally detected version or source commit.

## Doctor and retry

Check the desired items from a named plan, or from the last TUI selection, without
changing the machine:

```bash
./setup.sh --doctor
./setup.sh --doctor --plan plans/austin-arch-server.plan
```

Doctor reports missing packages and applications, inactive services, incomplete
configuration tasks, external sources and methods, installed versions, and cached
or freshly queried upstream release tags. Upstream checks are informational,
time-limited, and cached for six hours; an unavailable upstream never blocks use.

Retry only the typed failures saved by the previous real run:

```bash
./setup.sh --retry-failed
./setup.sh --retry-failed --dry-run
```

The retry state contains only package, external-application, service, and
configuration IDs. It is distro/profile checked and passes through current
availability gates. Dry runs and unrelated startup errors preserve a previous real
failure list. A completed successful retry removes it.

The **External applications** step offers opt-in tools from upstream projects,
including Starship, Lazygit, Superfile, Matcha, Concord, Browsh, spotify-player,
fnf, Caligula, Fetch, Catnap, legacy Neofetch, and several Nerd Font families. Nerd Fonts are available for
both desktop and server profiles (the font still needs to be selected in the
terminal on the computer displaying an SSH session). Neofetch remains clearly
labeled as archived and legacy in the menu.
When Starship, Superfile, Fastfetch, or another matching tool is selected from a
normal package category, its External Applications entry is dimmed automatically
and labeled as coming from the official repository. This prevents duplicate
installation while still leaving the external choice available when the package
was not selected earlier.
External applications are also detected through `PATH`, `~/.local/bin`,
`~/.cargo/bin`, `~/.nimble/bin`, known command aliases such as `spf`, and Nerd Font
files in both user and system font directories. The optional-services page also
labels Tailscale, Docker, and SSH as active, installed but inactive, or not installed;
active services are dimmed and cannot be selected again.
Existing external tools are likewise dimmed and cannot be selected again.

Git-built applications keep their source checkout under
`~/.cache/linux-bootstrap/`. Subsequent runs fetch upstream state, report when the
checkout is current, and fast-forward only when an update exists. New clones are
built in a registered partial directory and moved into place only after cloning
succeeds.

Every run ends with a report separating planned/installed items, items already
present, skipped items, and failures. If a command fails, the report names the
incomplete step and preserves the log path. Registered downloads and partial
source directories are cleaned automatically on success, failure, or interruption.
Independent external applications and services continue after another item fails,
and the process exits unsuccessfully after printing the complete report. Package
results are verified against the package database rather than assumed from a command.

Automated source installs use Cargo, Go, or a checked-out build and place user
binaries under `~/.local/bin`. The installer
does not pipe downloaded scripts into a shell. Font archives install per-user under
`~/.local/share/fonts`. Review `external/catalog.tsv` and
`external/installers.sh` to customize these choices.

Optional Docker, Tailscale, and SSH steps are selected separately. The SSH step
only installs and enables OpenSSH. It does **not** edit `sshd_config`, create or
replace keys, change users, open firewall ports, or disable password/root login.
Review your SSH and firewall policy yourself before exposing a host publicly.

On Debian, the Tailscale step intentionally stops with a link to the official
installation instructions instead of piping a remote script into a privileged
shell. On Arch, it installs the repository package.

## Configure applications

The full installation flow includes a **Configure applications** screen after
optional services. Configuration can also be rerun independently with
`./setup.sh --configure`. Tasks whose applications are missing are disabled, and
completed managed tasks are detected and dimmed.

The initial configuration modules support:

- changing the current local account's login shell to Fish;
- adding an idempotent, clearly marked Starship initialization block to
  `~/.config/fish/config.fish`;
- installing the full non-modal Micro developer bundle (`lsp`, `fzf`,
  `filemanager`, `snippets`, `autofmt`, `detectindent`, `jump`, `palettero`,
  `quickfix`, `editorconfig`, and `runit`) while preserving existing Micro
  settings, bindings, themes, and other plugins;
- selecting one mutually exclusive upstream Starship preset: Nerd Font Symbols,
  Catppuccin Powerline, Gruvbox Rainbow, Pastel Powerline, Tokyo Night, or Pure.
- opening the official GitHub CLI authentication flow with `gh auth login`;
- opening Spotify Player's `spotify_player authenticate` OAuth flow;
- connecting an installed Tailscale client with `tailscale up` after another
  explicit confirmation.

Changing the login shell always requires a second interactive confirmation—even
when `--yes` is present. Fish is added to `/etc/shells` only when necessary, and
the change is made through `chsh`; system account safeguards are never bypassed.
The Starship Fish block is appended without replacing unrelated Fish settings.
The Micro task adds only missing plugins, discovers locally installed language
servers, and safely merges familiar shortcuts into Micro's JSON files. Existing
key choices and LSP settings take precedence. Any changed settings or bindings
file receives a timestamped `bootstrap-backup-*` copy first.
Selecting a Starship preset explicitly authorizes replacement of `starship.toml`,
but the existing file is first copied to a timestamped
`starship.toml.bootstrap-backup-*` backup. Configuration results participate in
the same installed/already-present/skipped/failed final report as packages.

Upstream interactive tasks are labeled in the configuration menu. After review,
the full-screen installer closes normally, explains which upstream program is
taking control, and resumes reporting when it exits. Interactive OAuth output,
browser URLs, and one-time codes are intentionally not copied into the bootstrap
log. GitHub CLI authentication uses its official device/browser flow. Spotify
Player requires Spotify Premium and normally uses a loopback callback on port
8989; over SSH, use local forwarding such as
`ssh -L 8989:127.0.0.1:8989 HOST` if the callback cannot reach the server.

## Dotfiles

The dotfiles engine is preview-first and reads `dotfiles/catalog.tsv`. Its initial
catalog covers Fish, Starship, Kitty, Fastfetch, Micro, Lazygit, Superfile,
portable and per-host KDE settings, and Niri/DMS settings. Each entry declares a
repository path, live target, management mode, desktop scope, and risk class.

Micro is intentionally split into settings, bindings, and custom color schemes.
Downloaded plugins, editor history, generated syntax files, and bootstrap backup
files are excluded; plugins are restored by the **Micro developer essentials**
configuration task instead of being committed to dotfiles.
KDE and Niri/DMS settings use reviewed copies, while display layouts, panels, and other
machine-shaped state remain per-host. None of those reviewed or per-host entries
participates in automatic synchronization.

Set the eventual Git remote and optionally choose a non-default local checkout:

```bash
export LINUX_BOOTSTRAP_DOTFILES_REPO=git@github.com:syndiarphq/dotfiles.git
export LINUX_BOOTSTRAP_DOTFILES_DIR="$HOME/.local/share/linux-bootstrap/dotfiles"
```

Preview and then perform the first import:

```bash
./setup.sh --dotfiles import
./setup.sh --dotfiles import --apply
git -C "$LINUX_BOOTSTRAP_DOTFILES_DIR" status
```

The first command never changes files. The applied import clones or initializes
the repository, copies approved targets, converts `symlink` entries to live links,
and preserves replaced targets in a timestamped backup. Existing unmanaged
symlinks and sensitive-looking filenames or content are blocked for review.
Backups are created only when a path actually changes and are labeled by operation.
Restore selects the newest unused import/apply backup, never a newer automatic-sync
or service-unit backup, and marks a successful restore so an older backup can be
selected on a later restore. Every manifest and referenced backup is checked before
the first path is moved, so an incomplete backup cannot cause a partial restore.

Other operations are:

```bash
./setup.sh --dotfiles status
./setup.sh --dotfiles apply           # preview repository → home
./setup.sh --dotfiles apply --apply   # apply with backups
./setup.sh --dotfiles restore --apply
./setup.sh --dotfiles sync
./setup.sh --dotfiles enable-auto --apply
./setup.sh --dotfiles disable-auto --apply
```

Automatic synchronization uses a systemd user timer every two minutes. Symlinked
portable files have immediate local parity; portable `watched-copy` entries are
refreshed before commits. The sync refuses secret-like data, serializes runs with
a lock, rebases before pushing, and stops on conflicts. The repository is scanned
before watched copies are refreshed and again before staging. Remote `watched-copy` and
`review` changes are never applied automatically; inspect status and run the
explicit apply workflow. Git credentials and author identity must already be
configured before enabling the timer.
Existing Linux Bootstrap sync unit files are backed up before replacement, and
filesystem paths are escaped when written into the service definition.

## Customize packages

Edit the one-package-per-line files under `packages/`. Blank lines and text after
`#` are ignored. The installer automatically combines the files for the active
profile, removes duplicate names, and presents one package list. The subfiles are
only an internal organization detail and are not shown in the interface.

The full-screen TUI reads its short package explanations from
`packages/descriptions.tsv`. Each row contains a package name, a tab, and its
description.

The Packages step is a category browser. Enter opens a category, Space on a
category selects or clears all of its packages, and each submenu preserves its
individual selections. The Arch desktop catalog separates Core CLI, Terminal
Applications, Graphical Applications, Development, Gaming, and Fonts. Server
profiles expose Core CLI, Server & Remote Access, Development, and Monitoring.
Inside a category, Enter advances to the next category and Esc returns to the
category menu. Category screens show local counts; the category menu shows the
overall selected-package count.
Before displaying the package lists, the full-screen interface queries the active
package manager. Already-installed packages remain visible but dimmed, carry an
`[installed]` label, cannot be selected, and are excluded from available-package
counts. The classic fallback omits installed packages from its selection list.

```text
packages/
├── arch/desktop/{base,desktop,development,gaming,fonts}.txt
├── arch/server/{base,server,development,monitoring}.txt
└── debian/server/{base,server,development,monitoring}.txt
```

## Add external applications and configuration tasks

Menu metadata is catalog-driven. Adding an external application starts with one
tab-separated row in `external/catalog.tsv` containing its ID, label, supported
profiles, installation method, description, detection rule, and reviewed upstream
source URL. Detection rules
use `cmd:name,alias` or `font:Family`. Add the reviewed installation case to
`external/installers.sh`; no Go interface edit is required.

Configuration entries come from `configurations/catalog.tsv`. Its fields are ID,
label, comma-separated prerequisites, completion detector, mode, and description.
Supported generic detectors include login shells, file markers, required files,
and commands. Add the corresponding apply function/case to
`configurations/configurations.sh`. Labels, prerequisite dimming, completion
detection, and menu rendering are loaded automatically without editing the TUI.

Both catalogs are checked for malformed rows, duplicate IDs, and unsupported
detection schemes by `tools/test.sh`.

Service logic lives in `services/services.sh`. Package installation and UI code
are kept in `lib/` so additional distributions and profiles can be added without
turning `setup.sh` into a monolith.

## Safety notes

- Read the package lists and scripts before running them as root.
- Use `--dry-run` first on an unfamiliar system.
- Docker group membership is not changed because it grants root-equivalent access.
- Tailscale authentication is left to an explicit `sudo tailscale up` command.
- This is a bootstrap, not a security-hardening or unattended-upgrades policy.
