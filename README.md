# Linux Bootstrap

Current release: **v1.1.2**

This is the setup script I wanted for reinstalling my desktop or bringing up a
new server without rebuilding everything by hand.

It is mainly for my CachyOS desktop and the Arch or Debian servers I SSH into.
Fedora, Ubuntu, and openSUSE are supported too. It is personal, maybe useful to
a few friends, and the lists will probably change after I use it on more
machines.

## Run it

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/syndiarphq/linux-bootstrap/main/bootstrap.sh)
```

If Fish is already your shell, run the Bash command through Bash:

```fish
bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/syndiarphq/linux-bootstrap/main/bootstrap.sh)'
```

That downloads the current release, verifies it, and opens the installer. Or
clone it if you want to look around first:

```bash
git clone https://github.com/syndiarphq/linux-bootstrap.git
cd linux-bootstrap
./tools/build-tui.sh  # only needed for a source clone; requires Go 1.25+
./setup.sh
```

The release includes static x86-64 and ARM64 TUI binaries and selects the right
one automatically. A source clone can build the binary for the current machine
with the command above. Gum is not needed.

## What it does

- Detects the distro and suggests desktop or headless based on the system
- Lets you choose packages individually, sorted into useful submenus
- Dims anything already installed so it cannot be selected twice
- Handles extra applications from GitHub, Cargo, Go, and upstream releases
- Offers Docker, Tailscale, and SSH as separate options
- Checks internet, sudo, disk space, architecture, and dependencies first
- Disables choices whose packages or dependencies are not available
- Finishes with installed, already present, skipped, and failed lists

Supported systems are Arch/CachyOS, Debian/Ubuntu, Fedora, and openSUSE, with
desktop and server profiles for each. The suggested profile is only a default,
so a headless Arch server works fine.

NixOS and immutable/atomic systems are detected, but this installer does not
change them. They really need their own setup, so that can be handled separately
if I ever need it.

## Useful commands

```bash
./setup.sh --dry-run          # preview a normal run
./setup.sh --validate         # check catalogs and available repositories
./setup.sh --configure        # only run application setup
./setup.sh --doctor           # check a saved setup
./setup.sh --retry-failed     # retry failures from the last real run
./setup.sh --no-fullscreen    # deliberately use normal scrolling output
./tools/test.sh               # run project checks
```

Normal interactive runs require the full TUI. If its binary is missing,
unsupported, or cannot start, the installer explains the problem instead of
quietly changing interfaces. `--no-fullscreen` is still there for unusual
terminals or when normal scrolling output is preferred.

Logs and reports are kept in `~/.local/state/linux-bootstrap/`.

## Saved setups

The installer remembers the last successful selection. Named plans can also be
saved and reused:

```bash
./setup.sh --save-plan plans/arch-server.plan
./setup.sh --plan plans/arch-server.plan --dry-run
./setup.sh --plan plans/arch-server.plan
```

Plans are plain text and are checked against the current machine before use.

## Packages, external apps, and configs

Normal packages come from the distro's enabled repositories. External apps are
used when a tool is not there, or when the upstream version makes more sense.
Those include things like Starship, Lazygit, Superfile, Matcha, Concord, Browsh,
Spotify Player, Caligula, and Nerd Fonts.

The installer does not pipe third-party install scripts into a privileged
shell. User binaries normally go in `~/.local/bin`.

The configuration menu can set Fish as the login shell, initialize Starship,
apply a Starship preset, install my Micro setup, and open login or connection
flows for GitHub, Spotify Player, and Tailscale. Anything interactive closes the
installer view, runs normally, and then returns to it.

The Micro setup keeps regular editor-style controls and adds LSP, fuzzy search,
a file tree, snippets, format-on-save, indent detection, symbol jumping, a
command palette, quickfix, EditorConfig, and run/build shortcuts.

## Services and SSH

Docker, Tailscale, and SSH are never enabled just because a general profile was
selected.

The SSH option installs and enables OpenSSH. It does not rewrite `sshd_config`,
replace keys, create users, open firewall ports, or change password/root login.
Those choices are better left visible.

Docker group membership is also left alone since it is effectively root access.

## Dotfiles

My portable terminal configs are in a separate private repo. Right now that is
Fish, Starship, Fastfetch, Micro, and Superfile. Graphical configs can wait until
I know which ones I actually want shared between machines.

```bash
export LINUX_BOOTSTRAP_DOTFILES_REPO=https://github.com/syndiarphq/dotfiles.git

./setup.sh --dotfiles apply          # preview
./setup.sh --dotfiles apply --apply  # apply with backups
./setup.sh --dotfiles status
./setup.sh --dotfiles restore --apply
./setup.sh --dotfiles sync
./setup.sh --dotfiles enable-auto --apply
```

Automatic sync checks for secret-looking files and stops on conflicts instead
of guessing.

## Changing things

- `packages/` contains the official package lists.
- `packages/descriptions.tsv` controls package descriptions and categories.
- `external/catalog.tsv` and `external/installers.sh` handle external apps.
- `configurations/` handles application setup.
- `services/services.sh` handles optional services.

Most additions only need a catalog entry and an install function. Before using
this on an important machine, I would still check the selections and use
`--dry-run` first.

That is pretty much it. I expect to keep adjusting it as I find out what is
actually useful and what I never select.
