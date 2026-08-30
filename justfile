# wlrix-epoch — build orchestration for the wlRIX desktop environment.
# Requires `just` (https://github.com/casey/just).

# GitHub org/base used when wiring submodules. Override as needed.
base := "https://github.com/wlRIX"

# The Rust components. Every one of them installs itself: `just install` in the component, with
# this repo's prefix and staging root passed down.
#
# Not a loop of `install -Dm755` here. Three of them are a single binary and would fit one, but
# the greeter brings a system account, two PAM stacks, a systemd unit and a greetd
# configuration, and the session brings a launcher, a systemd user target and the entry a
# display manager offers. Where a second copy of that knowledge lived here it drifted -- this
# repo went on installing `wlrix-session/share/wayland-sessions/wlrix.desktop` after the session
# had moved the file. One rule for all five, kept where the files are.
#
# `xdg-desktop-portal-wlrix` is in the list despite not being named `wlrix-*`: the name is fixed
# by xdg-desktop-portal's backend discovery, not chosen. It installs five files of its own --
# a .portal, a portals.conf, a D-Bus activation file and a systemd unit alongside the binary --
# which is exactly the knowledge the comment above says to keep in the component.
rust_repos := "wlrix-compositor wlrix-greeter wlrix-session wlrix-desktop wlrix-bg wlrix-idle wlrix-settings-daemon xdg-desktop-portal-wlrix wlrix-screenshot"

# The Rust library the components share. Separate from `rust_repos` because it is a library:
# it installs nothing, so it has no place in `install`, and it ships inside the binaries that
# depend on it. It is built and tested here so a change to it is caught before four consumers
# bump their pinned rev onto it.
#
# Consumers depend on it by git rev, not by path, so each of them still builds from a fresh
# standalone clone. See `link-ui` for working on both sides at once.
lib_repos  := "wlrix-ui"

cs_repos   := "wlrix-avalonia wlrix-apps"

# The data repos, which install themselves the same way the components do. Only one so far, and
# it installs its wallpapers and the sgi cursor theme -- see its own justfile for why the palette
# and the (still empty) icon directory are deliberately left out.
#
# It has no build step, so it is absent from `build` and present here: `wlrix-bg`'s default config
# names `share/wlrix/wallpapers/scatter.png` and the compositor's names the `sgi` cursor theme, so
# without this the desktop of a fresh install comes up plain gray, with a stranger's pointer over
# it and two lines in the log about what is missing.
data_repos := "wlrix-assets"

# Upstream forks the C# side builds against, carrying patches not yet upstream. Submodules like
# the components, but they are build dependencies rather than parts of the desktop -- nothing
# from them is installed except by way of wlrix-apps.
#
# They sit *beside* the components on purpose: `Wlrix.Desks.csproj` reaches the NWayland
# generator and the wlrix-desks protocol XML by relative path, which resolves the same here as
# it does in a development workspace of sibling clones.
forks := "NWayland Avalonia"

# The C# applications, as `<project>:<installed name>`. The installed name is what
# `session.toml` and wlrix-session's defaults call them.
cs_apps := "Wlrix.Toolchest:wlrix-toolchest Wlrix.Desks:wlrix-desks Wlrix.Console:wlrix-console Wlrix.Settings.Keyboard:wlrix-settings-keyboard Wlrix.Settings.Windows:wlrix-settings-windows Wlrix.SourcePicker:wlrix-source-picker Wlrix.SoftwareManager:wlrix-software-manager"

# The privileged helper, in the same `<project>:<installed name>` shape so it can be published
# by the same loop -- but kept out of `cs_apps` because it is not one. Nothing launches it from
# a menu or the session; only the Software Manager does, through pkexec, and only ever at the
# absolute path its polkit action names. See `polkit_policy`.
cs_helpers := "Wlrix.Packages.Helper:wlrix-pkg-helper"

# The polkit action that lets the Software Manager run that helper as root. Without it installed
# the app runs, browses and does nothing else: `PkexecRunner` refuses to start a transaction it
# cannot find the helper for, and polkit would fall back to prompting for the admin password on
# every single one.
polkit_policy := "wlrix-apps/src/Wlrix.Packages.Helper/polkit/com.wlrix.softwaremanager.policy"

# Which distribution's PAM stack the components that ship one should install. Passed through
# to their own justfiles; `arch` and `debian` are not interchangeable and nothing is detected.
pam_flavor := env("PAM_FLAVOR", "arch")

# The patched Avalonia.Wayland the apps pin. Keep in step with
# wlrix-apps/Directory.Packages.props; `feed` builds exactly this version.
wayland_version := "12.1.1-wlrix.2"

# Which platform the apps are published for. Avalonia carries native libraries for every
# platform it supports -- Windows, macOS, Android, several Linux architectures -- and a publish
# that names no platform copies all of them: 550 MB per app, against 40 MB for one. Detected
# from the SDK; set `RID=` to cross-publish.
rid := env("RID", `dotnet --info | sed -n 's/^ *RID: *//p' | head -1`)

# Where `install` puts things. `PREFIX=/usr` for a system package; DESTDIR for a
# staged install, as a package build does. Concatenated rather than path-joined
# because prefix is already absolute.
# `/usr`, matching what every component's own justfile defaults to. They have to agree: the
# components are started **by name**, so a set installed under one prefix and a set under
# another means PATH order decides which desktop actually runs -- and `/usr/local/bin` comes
# first on most systems, so the stale copy wins and an install appears to do nothing.
prefix  := env("PREFIX", "/usr")
destdir := env("DESTDIR", "")

# What a delegated install is handed. `just`'s `absolute_path` resolves a relative path against
# the justfile it is written in, so a relative DESTDIR would land inside the component's own
# directory rather than here; absolutise it before passing it down. Empty has to stay empty --
# absolutising "" would give the working directory, which is not "no staging root".
sub_rootdir := if destdir == "" { "" } else { absolute_path(destdir) }

bindir     := destdir + prefix + "/bin"
# A published .NET app is a directory of assemblies beside its launcher, not one file, so the
# apps live here and `bindir` gets a shell wrapper for each.
appdir     := destdir + prefix + "/lib/wlrix"
polkitdir  := destdir + prefix + "/share/polkit-1/actions"

# List available recipes.
default:
    @just --list

# Add the component repos as git submodules. Run once, after the repos have
# remotes. Until then, develop against the sibling clones in the workspace root.
[doc("Add the component and fork repos as submodules")]
init:
    #!/usr/bin/env bash
    set -euo pipefail
    for r in {{rust_repos}} {{lib_repos}} {{cs_repos}} wlrix-assets; do
        git submodule add {{base}}/$r.git $r || true
    done
    # The forks are not under the wlRIX org's naming, and Avalonia is on a branch of its own.
    git submodule add -b master https://github.com/wlRIX/NWayland.git NWayland || true
    git submodule add -b add-wayland-app-id https://github.com/wlRIX/Avalonia.git Avalonia || true
    git submodule update --init --recursive

# Build everything.
build: build-rust build-cs

# Regenerate the theme scheme dictionaries and the compositor palette module
# from wlrix-assets/palette/*.json. The generated files are checked in, so this
# only needs running after a palette edit; a dirty tree afterwards means a
# generated file was hand-edited.
[doc("Regenerate the theme dictionaries and palette modules")]
palette:
    cd wlrix-assets && dotnet run --project tools/palettegen -- ..

# Run the compositor nested inside the running session, isolated from it.
#
# Three env vars, and the third is the awkward one.
#
# `XDG_CONFIG_HOME` and `XDG_STATE_HOME` keep the nested instance off the live session's
# config, `desks.toml` and `outputs.toml`. Both have `$HOME` fallbacks, so they must be *set*
# rather than unset.
#
# `XDG_RUNTIME_DIR` has to move too, and not for tidiness: `wlrix-settings-daemon` finds the
# compositor *through* `$XDG_RUNTIME_DIR/wlrix-compositor.pid`, so a shared runtime dir would
# send the live session's reload signals to the throwaway instance instead. But that is also
# where the host's Wayland socket lives -- so the host display is passed by absolute path,
# which libwayland accepts for any `WAYLAND_DISPLAY` containing a slash.
#
# Nothing here reaches the real session. Verify after a run: the live pidfile and
# `~/.local/state/wlrix/desks.toml` must be untouched.
#
#     just nested                       # release build, classic
#     just nested gotham                # ...in another scheme
#
# Clients connect with XDG_RUNTIME_DIR=<sandbox>/run WAYLAND_DISPLAY=wayland-1, and `grim`
# under the same two variables screenshots it.
[doc("Run the compositor nested in the current session, fully isolated")]
nested scheme='classic':
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "${WAYLAND_DISPLAY:-}" ]; then
        echo "no host WAYLAND_DISPLAY; this recipe nests inside a running session" >&2
        exit 1
    fi
    sandbox="${XDG_RUNTIME_DIR:-/tmp}/wlrix-nested"
    rm -rf "$sandbox"
    mkdir -p "$sandbox"/{config/wlrix,state/wlrix,run}
    chmod 700 "$sandbox/run"
    printf '[appearance]\npalette = "%s"\n' '{{scheme}}' \
        > "$sandbox/config/wlrix/compositor.toml"
    binary=wlrix-compositor/target/release/wlrix-compositor
    if [ ! -x "$binary" ]; then
        echo "no release build -- run 'just build-rust' first" >&2
        exit 1
    fi
    echo "sandbox: $sandbox"
    echo "clients: XDG_RUNTIME_DIR=$sandbox/run WAYLAND_DISPLAY=wayland-1 <command>"
    echo
    exec env \
        XDG_CONFIG_HOME="$sandbox/config" \
        XDG_STATE_HOME="$sandbox/state" \
        WAYLAND_DISPLAY="${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" \
        XDG_RUNTIME_DIR="$sandbox/run" \
        "$binary"

# The components that depend on `wlrix-ui`.
#
# Not all of `rust_repos`: `wlrix-bg` draws wallpapers with no chrome and no text,
# `wlrix-idle` and `wlrix-session` draw nothing at all, and the settings daemon and the portal
# have no screen.
ui_consumers := "wlrix-compositor wlrix-greeter wlrix-desktop"

# Build the components against the `wlrix-ui` checkout beside them instead of its pinned rev.
#
# The pin is what lets each component build from a fresh standalone clone, and that is worth
# keeping -- but it makes editing both sides at once a commit-and-bump for every change. This
# writes cargo's `[patch]` into each consumer, which is the supported way to say "use the one
# next door". These are single-crate repos, so the repo root is the workspace root and that is
# where the patch has to go.
#
# Expect `Cargo.lock` to go dirty while linked: a patch rewrites the source entry, and all
# three consumers track their lock. `unlink-ui` puts it back.
[doc("Point the components at the local wlrix-ui checkout")]
link-ui:
    #!/usr/bin/env bash
    set -euo pipefail
    for r in {{ui_consumers}}; do
        mkdir -p "$r/.cargo"
        # printf rather than a heredoc: an unindented heredoc body would leave the recipe as
        # far as just is concerned, and `[patch."..."]` then reads as a malformed attribute.
        printf '%s\n' \
            '# Written by `just link-ui`; removed by `just unlink-ui`. Not checked in.' \
            '[patch."https://github.com/wlRIX/wlrix-ui"]' \
            'wlrix-ui = { path = "../wlrix-ui" }' \
            > "$r/.cargo/config.toml"
        echo "linked $r -> ../wlrix-ui"
    done
    echo
    echo "Cargo.lock will go dirty in each; 'just unlink-ui' restores it."

[doc("Undo link-ui and restore the pinned rev")]
unlink-ui:
    #!/usr/bin/env bash
    set -euo pipefail
    for r in {{ui_consumers}}; do
        rm -f "$r/.cargo/config.toml"
        rmdir "$r/.cargo" 2>/dev/null || true
        # Regenerate rather than `git checkout`: while linked, the lock records the *path*
        # override with no `source` line at all, and committing that is a lock a fresh clone
        # cannot resolve. Restoring the old one is not enough either -- the pinned rev may
        # have moved since. Ask cargo for the entry the manifest now names.
        (cd "$r" && cargo update --quiet -p wlrix-ui 2>/dev/null) || true
        if ! grep -A2 'name = "wlrix-ui"' "$r/Cargo.lock" | grep -q 'source = "git'; then
            echo "    $r: Cargo.lock still has no git source -- is the pinned rev pushed?" >&2
        fi
        echo "unlinked $r"
    done

# Move every consumer's pinned `wlrix-ui` rev to what is checked out here.
#
# Without this a palette edit is a five-commit ritual: change the JSON, regenerate, commit
# wlrix-ui, then hand-edit and commit three more Cargo.toml files. Run it after committing in
# wlrix-ui, then commit the bumps.
[doc("Bump the pinned wlrix-ui rev in every consumer")]
bump-ui:
    #!/usr/bin/env bash
    set -euo pipefail
    rev=$(git -C wlrix-ui rev-parse HEAD)
    echo "wlrix-ui is at $rev"
    for r in {{ui_consumers}}; do
        if ! grep -q 'wlrix-ui' "$r/Cargo.toml"; then
            echo "    $r does not depend on wlrix-ui yet; skipping"
            continue
        fi
        # Only the rev on the wlrix-ui line: smithay is pinned the same way in the compositor
        # and must not be touched.
        sed -i -E "/^wlrix-ui\s*=/ s|rev = \"[0-9a-f]+\"|rev = \"$rev\"|" "$r/Cargo.toml"
        (cd "$r" && cargo update --quiet -p wlrix-ui)
        echo "    bumped $r"
    done

# Fail if the checked-in generated files are stale relative to the palette JSON.
#
# Each diff runs *inside* the component repo. Running it here would check nothing:
# the components are separate repos -- symlinks today, submodules later -- so their
# files are not this repo's to diff.
[doc("Fail if the generated palette files are stale")]
check-palette: palette
    #!/usr/bin/env bash
    set -euo pipefail
    git -C wlrix-avalonia diff --exit-code -- src/Wlrix.Avalonia/Schemes
    if [ -d wlrix-ui ]; then
        git -C wlrix-ui diff --exit-code -- src/palette/generated.rs
    else
        echo "wlrix-ui is not checked out here yet; skipping its palette" >&2
    fi
    echo "generated palette files are current"

    # There were three more lines here, one per component. The generator emitted a different
    # hand-picked subset of the palette into each of them, in two incompatible color types;
    # `wlrix-ui` now gets the whole thing once and the components read it from there. Until a
    # component has migrated its own `palette.rs` is an orphan -- still correct, no longer
    # generated, and deleted when that component moves.

# Fail if the settings daemon's schema has drifted from the types it describes.
#
# `wlrix-settings-daemon/src/schema/table.rs` is a hand-kept copy of five other repos' serde
# structs, because the repos build standalone and it cannot link them. A hand-kept copy drifts,
# and with `#[serde(deny_unknown_fields)]` everywhere a drifted key is not a wrong setting --
# it is the owner rejecting the *whole file* and the user silently getting built-in defaults.
#
# The daemon guards against that at runtime by running `--check-config` before every write. This
# is the same check run ahead of time, against the schema's own dump, so drift is a red CI run
# rather than a settings app that has quietly stopped working. This is the one place with all
# the repos checked out, which is why it lives here -- the same reason as `check-palette`.
#
# Requires the components to be built: `just build-rust` first.
[doc("Fail if the settings schema has drifted from the components' config types")]
check-schema:
    #!/usr/bin/env bash
    set -euo pipefail
    daemon=wlrix-settings-daemon
    if [ ! -d "$daemon" ]; then
        echo "$daemon is not checked out here yet; skipping" >&2
        exit 0
    fi
    dump=$(mktemp -d)/schema.toml
    trap 'rm -rf "$(dirname "$dump")"' EXIT
    "$daemon/target/release/$daemon" --dump-schema > "$dump"
    # One namespace at a time: the dump is every file's settings in one document, and each
    # component only accepts its own.
    fail=0
    check() {
        local repo="$1" namespace="$2" section binary status
        binary="$repo/target/release/$repo"
        if [ ! -x "$binary" ]; then
            echo "==> $namespace: no release build of $repo; run 'just build-rust'" >&2
            fail=1
            return
        fi
        section=$(awk -v ns="# ---- ${namespace}.toml ----" \
            'index($0, ns) == 1 {on=1; next} /^# ---- /{on=0} on' "$dump")
        printf '%s\n' "$section" > "$dump.$namespace"

        # `timeout`, and no display for the child, because a component that predates
        # `--check-config` does not necessarily *reject* it: `wlrix-compositor` ignored unknown
        # arguments until the flag was added, so an old one here would start a compositor
        # instead of checking a file. It did exactly that the first time this recipe ran
        # against a stale submodule pin. Unsetting the display makes such a compositor fail to
        # start at all, and the timeout catches whatever else might sit there; none of the four
        # needs a display to parse a config file. Same reasoning as `validate()` in the daemon.
        status=0
        env -u WAYLAND_DISPLAY -u DISPLAY timeout 10 "$binary" --check-config "$dump.$namespace" \
            || status=$?
        # Exit 1 is the only one that means what this recipe is looking for. 2 is the usage
        # error every wlRIX component answers an unknown argument with, and 124 is the timeout
        # above -- both mean the binary predates `--check-config` rather than that the schema is
        # wrong, and saying "the schema declares something it will not accept" for those would
        # send the next person to the wrong file entirely.
        case "$status" in
            0) ;;
            1)
                echo "==> $namespace: the schema declares something $repo will not accept" >&2
                fail=1
                ;;
            *)
                echo "==> $namespace: $repo does not understand --check-config (exit $status);" >&2
                echo "    it predates the flag. Bump the submodule pin, or 'just build-rust'." >&2
                fail=1
                ;;
        esac
    }
    check wlrix-bg background
    check wlrix-compositor compositor
    check wlrix-desktop desktop
    check wlrix-idle idle
    check xdg-desktop-portal-wlrix portal
    check wlrix-screenshot screenshot
    [ "$fail" -eq 0 ] && echo "the settings schema matches every component's config types"
    exit "$fail"

# Build the Rust system components.
build-rust:
    #!/usr/bin/env bash
    set -euo pipefail
    # The library first, and tested rather than merely built: it is the one place in the Rust
    # tree where the bevel rule, the text wrapping and the palette values can be checked
    # without a display, and a break here is a break in all four components at once.
    for r in {{lib_repos}}; do
        echo "==> testing $r"; (cd "$r" && cargo test --all-features --quiet)
    done
    for r in {{rust_repos}}; do
        echo "==> building $r"; (cd "$r" && cargo build --release)
    done

# Assemble wlrix-apps/localfeed: the packages the apps need that nuget.org does not have.
#
# Two kinds. The wlRIX theme and dialogs come straight out of `wlrix-avalonia`. The patched
# `Avalonia.Wayland` -- app id support, and `CanResize=false` on the wire so the compositor can
# drop a fixed-size window's maximize button -- has to be reshaped after packing; see
# `tools/pack-avalonia-wayland.py` for why.
#
# The feed is gitignored in wlrix-apps, so a fresh checkout has to run this before anything C#
# will restore. `build-cs` does.
[doc("Assemble wlrix-apps/localfeed (the packages nuget.org does not have)")]
feed:
    #!/usr/bin/env bash
    set -euo pipefail
    feed="$PWD/wlrix-apps/localfeed"
    mkdir -p "$feed"
    echo "==> packing wlrix-avalonia"
    (cd wlrix-avalonia && dotnet pack -c Release --nologo)
    find wlrix-avalonia/src -name 'Wlrix.Avalonia*.nupkg' -exec cp {} "$feed/" \;
    echo "==> packing the patched Avalonia.Wayland"
    ./tools/pack-avalonia-wayland.py --source Avalonia \
        --version {{wayland_version}} --out "$feed"

# Build the C# solutions. The feed has to exist first or restore cannot resolve the apps.
build-cs: feed
    for r in {{cs_repos}}; do \
        echo "==> building $r"; (cd $r && dotnet build -c Release --nologo); \
    done

# Install the Rust components and the session entry.
#
# Deliberately does not build: this is normally run as root, and building as root
# leaves a target directory nobody can write to afterwards. Build first, install
# second:
#
#     just build-rust && sudo just install
#
# Each Rust component's binary is named after its repo, so one loop covers them.
[doc("Install everything and the session entry (build first; run as root)")]
install: install-rust install-cs install-assets
    #!/usr/bin/env bash
    set -euo pipefail
    echo
    echo "The greeter, the session and the apps all start each other **by name**, so"
    echo "{{prefix}}/bin has to be on the PATH greetd gives the session."
    echo
    echo "The greeter's own install printed what is left to do: create its account,"
    echo "and enable wlrix-greeter.service as the display manager."
    just check-path

# Install the Rust components, each through its own justfile.
#
# The release-build check covers all of them before any is installed. A partial install is worse
# than none: finding out at the fifth component that it was never built means unpicking four
# that have already landed.
#
# `PAM_FLAVOR` goes down the environment rather than as a `just` variable. Only the greeter
# reads it -- it is the one component shipping a PAM stack -- and `just` refuses a variable
# override a justfile does not declare, so passing it as one would break the other four.
[doc("Install the Rust components (build first; run as root)")]
install-rust:
    #!/usr/bin/env bash
    set -euo pipefail
    for r in {{rust_repos}}; do
        if [ ! -x "$r/target/release/$r" ]; then
            echo "no release build of $r -- run 'just build-rust' first" >&2
            exit 1
        fi
    done
    export PAM_FLAVOR='{{pam_flavor}}'
    for r in {{rust_repos}}; do
        echo "==> $r"
        (cd "$r" && just rootdir='{{sub_rootdir}}' prefix='{{prefix}}' install)
    done

# Install the shared data files.
#
# Its own justfile, for the same reason the components have one: what belongs in `share` and
# under which layout is that repo's knowledge, not this one's. There is nothing to build first.
[doc("Install the shared data files (run as root)")]
install-assets:
    #!/usr/bin/env bash
    set -euo pipefail
    for r in {{data_repos}}; do
        echo "==> $r"
        (cd "$r" && just rootdir='{{sub_rootdir}}' prefix='{{prefix}}' install)
    done

# Publish and install the C# applications.
#
# A published .NET app is a directory -- the launcher plus its assemblies -- so each one goes
# under `$PREFIX/lib/wlrix/<name>/` and gets a one-line wrapper in `$PREFIX/bin`. Not a symlink:
# the .NET host finds an app's assemblies beside `/proc/self/exe`, which follows symlinks, so a
# link in `bin` would send it looking for them in `bin`.
#
# Framework-dependent, so the target needs the .NET runtime installed. Self-contained would
# bundle a copy of the runtime with each of four apps, which is a lot of megabytes to spend on a
# desktop whose own components are already built from source. Published for one platform for
# the same reason; see `rid`.
#
# This publishes rather than reusing `build-cs`'s output, because a `dotnet build` tree is not
# self-sufficient -- it leaves out the runtime config and dependency manifest an app needs to
# start from somewhere other than its project directory.
[doc("Publish and install the C# apps")]
install-cs:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d wlrix-apps/localfeed ]; then
        echo "no localfeed -- run 'just feed' first" >&2
        exit 1
    fi
    for entry in {{cs_apps}} {{cs_helpers}}; do
        project="${entry%%:*}"
        name="${entry##*:}"
        staged="$(mktemp -d)"
        echo "==> publishing $project as $name for {{rid}}"
        dotnet publish "wlrix-apps/src/$project" -c Release --nologo \
            -r {{rid}} --self-contained false -o "$staged"

        # The launcher is named after the project's *assembly*, which is the project's to
        # choose and mostly is not the project name -- three of the four set `<AssemblyName>`.
        # Publish always writes `<assembly>.runtimeconfig.json` beside it, so that names it.
        config="$(ls "$staged"/*.runtimeconfig.json)"
        launcher="$(basename "$config" .runtimeconfig.json)"

        # Cleared, not copied over. `cp` opens the destination for writing, which fails with
        # ETXTBSY if that binary is running -- reinstalling while the desktop is up is the
        # ordinary case, not an odd one. Unlinking the directory first is fine even then: the
        # running process keeps its inode and the name is free to be recreated. (The Rust
        # components do not hit this; `install` unlinks the target itself.)
        #
        # It also means a file a newer publish no longer produces goes away, rather than
        # lingering in the tree for ever.
        rm -rf "{{appdir}}/$name"
        install -d "{{appdir}}/$name"
        # `cp` rather than `install -D` per file: a published app has subdirectories
        # (satellite assemblies, native libraries) and they have to keep their shape.
        cp -r "$staged/." "{{appdir}}/$name/"
        chmod 755 "{{appdir}}/$name/$launcher"
        rm -rf "$staged"

        install -d "{{bindir}}"
        printf '#!/bin/sh\nexec "%s/lib/wlrix/%s/%s" "$@"\n' \
            "{{prefix}}" "$name" "$launcher" > "{{bindir}}/$name"
        chmod 755 "{{bindir}}/$name"
        echo "installed {{bindir}}/$name -> {{appdir}}/$name/$launcher"
    done

    # The polkit action for the helper just installed. 644 and root-owned: polkit reads it, and
    # an action file a user could edit would let them rewrite the rules that gate root.
    #
    # Its `exec.path` annotation is the literal `/usr/bin/wlrix-pkg-helper`, which is also what
    # `PkexecRunner` looks for -- neither is prefix-aware, so under any other prefix the two
    # agree with each other and disagree with where the helper actually is.
    if [ "{{prefix}}" != "/usr" ]; then
        echo "warning: PREFIX={{prefix}}, but the polkit action and the Software Manager both" >&2
        echo "         name /usr/bin/wlrix-pkg-helper. Package management will not work." >&2
    fi
    install -d "{{polkitdir}}"
    install -m 644 "{{polkit_policy}}" "{{polkitdir}}/"
    echo "installed {{polkitdir}}/$(basename {{polkit_policy}})"

# Warn if PATH would find some other copy of a component before the one just installed.
#
# Everything here starts everything else by name -- greetd runs `start-wlrix`, that runs
# `wlrix-session`, that runs `wlrix-compositor` and the apps -- so a leftover set under a
# different prefix does not conflict, it silently wins. The symptom is an install that
# changes nothing at all, which is a miserable thing to debug.
[doc("Check PATH finds the components that were just installed")]
check-path:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "{{destdir}}" ]; then
        exit 0    # a staged install is not on PATH and is not meant to be
    fi
    shadowed=0
    for name in {{rust_repos}} start-wlrix; do
        found="$(command -v "$name" 2>/dev/null || true)"
        [ -z "$found" ] && continue
        if [ "$found" != "{{bindir}}/$name" ]; then
            echo "warning: PATH finds $found, not {{bindir}}/$name" >&2
            shadowed=1
        fi
    done
    if [ "$shadowed" = 1 ]; then
        echo >&2
        echo "Those older copies will run instead of what was just installed." >&2
        echo "Remove them, or reinstall with the prefix they are under." >&2
    fi

# Remove what `install` put down. Leaves configuration and logs alone.
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail
    for r in {{rust_repos}} {{data_repos}}; do
        (cd "$r" && just rootdir='{{sub_rootdir}}' prefix='{{prefix}}' uninstall)
    done
    for entry in {{cs_apps}} {{cs_helpers}}; do
        name="${entry##*:}"
        rm -f "{{bindir}}/$name"
        rm -rf "{{appdir}}/$name"
    done
    rm -f "{{polkitdir}}/$(basename {{polkit_policy}})"
    # Only if this left it empty: the prefix may be shared with something else.
    rmdir "{{appdir}}" 2>/dev/null || true
    echo "removed the wlRIX binaries, apps and session entry"

# Launch the session (compositor + core apps) for local testing.
run:
    cd wlrix-session && cargo run --release

# Clean all build artifacts, the local feed included -- `feed` rebuilds it.
clean:
    #!/usr/bin/env bash
    set -euo pipefail
    for r in {{rust_repos}} {{lib_repos}}; do (cd "$r" && cargo clean); done
    for r in {{cs_repos}}; do (cd "$r" && dotnet clean -v q --nologo || true); done
    rm -rf wlrix-apps/localfeed
