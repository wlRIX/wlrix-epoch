# wlrix-epoch — build orchestration for the wlRIX desktop environment.
# Requires `just` (https://github.com/casey/just).

# GitHub org/base used when wiring submodules. Override as needed.
base := "https://github.com/wlRIX"

# Rust components the epoch installs itself: one release binary each, named after its repo.
rust_repos := "wlrix-compositor wlrix-session wlrix-desktop wlrix-idle"
# Components that install themselves. The greeter needs a system account, two PAM stacks, a
# systemd unit and a greetd configuration -- knowledge that belongs with the greeter, not
# duplicated here where it would drift the first time either side changed.
self_install_repos := "wlrix-greeter"
# Everything Rust, for the operations that treat the components alike.
all_rust_repos := rust_repos + " " + self_install_repos

cs_repos   := "wlrix-avalonia wlrix-apps"

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
cs_apps := "Wlrix.Toolchest:wlrix-toolchest Wlrix.Desks:wlrix-desks Wlrix.Console:wlrix-console Wlrix.Settings.Keyboard:wlrix-settings-keyboard"

# Which distribution's PAM stack the components that ship one should install. Passed through
# to their own justfiles; `arch` and `debian` are not interchangeable and nothing is detected.
pam_flavor := env("PAM_FLAVOR", "arch")

# The patched Avalonia.Wayland the apps pin. Keep in step with
# wlrix-apps/Directory.Packages.props; `feed` builds exactly this version.
wayland_version := "12.1.1-wlrix.1"

# Which platform the apps are published for. Avalonia carries native libraries for every
# platform it supports -- Windows, macOS, Android, several Linux architectures -- and a publish
# that names no platform copies all of them: 550 MB per app, against 40 MB for one. Detected
# from the SDK; set `RID=` to cross-publish.
rid := env("RID", `dotnet --info | sed -n 's/^ *RID: *//p' | head -1`)

# Where `install` puts things. `PREFIX=/usr` for a system package; DESTDIR for a
# staged install, as a package build does. Concatenated rather than path-joined
# because prefix is already absolute.
prefix  := env("PREFIX", "/usr/local")
destdir := env("DESTDIR", "")

# What a delegated install is handed. `just`'s `absolute_path` resolves a relative path against
# the justfile it is written in, so a relative DESTDIR would land inside the component's own
# directory rather than here; absolutise it before passing it down. Empty has to stay empty --
# absolutising "" would give the working directory, which is not "no staging root".
sub_rootdir := if destdir == "" { "" } else { absolute_path(destdir) }

bindir     := destdir + prefix + "/bin"
sessiondir := destdir + prefix + "/share/wayland-sessions"
# A published .NET app is a directory of assemblies beside its launcher, not one file, so the
# apps live here and `bindir` gets a shell wrapper for each.
appdir     := destdir + prefix + "/lib/wlrix"

# List available recipes.
default:
    @just --list

# Add the component repos as git submodules. Run once, after the repos have
# remotes. Until then, develop against the sibling clones in the workspace root.
[doc("Add the component and fork repos as submodules")]
init:
    #!/usr/bin/env bash
    set -euo pipefail
    for r in {{rust_repos}} {{cs_repos}} wlrix-assets; do
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
    git -C wlrix-compositor diff --exit-code -- src/palette.rs
    git -C wlrix-greeter diff --exit-code -- src/theme/palette.rs
    git -C wlrix-desktop diff --exit-code -- src/theme/palette.rs
    echo "generated palette files are current"

# Build the Rust system components.
build-rust:
    for r in {{all_rust_repos}}; do \
        echo "==> building $r"; (cd $r && cargo build --release); \
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
install: install-rust install-cs
    #!/usr/bin/env bash
    set -euo pipefail
    echo
    echo "The greeter, the session and the apps all start each other **by name**, so"
    echo "{{prefix}}/bin has to be on the PATH greetd gives the session."
    echo
    echo "The greeter's own install printed what is left to do: create its account,"
    echo "and enable wlrix-greeter.service as the display manager."

# Install the Rust components and the session entry.
#
# `pam-flavor` is passed straight through to whichever components want it; see the greeter's
# own justfile for what it selects and why nothing is auto-detected.
[doc("Install the Rust binaries and the session entry")]
install-rust:
    #!/usr/bin/env bash
    set -euo pipefail
    for r in {{all_rust_repos}}; do
        if [ ! -x "$r/target/release/$r" ]; then
            echo "no release build of $r -- run 'just build-rust' first" >&2
            exit 1
        fi
    done
    for r in {{rust_repos}}; do
        install -Dm755 "$r/target/release/$r" "{{bindir}}/$r"
        echo "installed {{bindir}}/$r"
    done
    install -Dm644 wlrix-session/share/wayland-sessions/wlrix.desktop \
        "{{sessiondir}}/wlrix.desktop"
    echo "installed {{sessiondir}}/wlrix.desktop"
    # The components that bring more than a binary put it down themselves.
    for r in {{self_install_repos}}; do
        echo "==> $r installs itself"
        (cd "$r" && just rootdir='{{sub_rootdir}}' prefix='{{prefix}}' \
            pam-flavour='{{pam_flavor}}' install)
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
    for entry in {{cs_apps}}; do
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

# Remove what `install` put down. Leaves configuration and logs alone.
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail
    for r in {{rust_repos}}; do
        rm -f "{{bindir}}/$r"
    done
    for r in {{self_install_repos}}; do
        (cd "$r" && just rootdir='{{sub_rootdir}}' prefix='{{prefix}}' uninstall)
    done
    for entry in {{cs_apps}}; do
        name="${entry##*:}"
        rm -f "{{bindir}}/$name"
        rm -rf "{{appdir}}/$name"
    done
    # Only if this left it empty: the prefix may be shared with something else.
    rmdir "{{appdir}}" 2>/dev/null || true
    rm -f "{{sessiondir}}/wlrix.desktop"
    echo "removed the wlRIX binaries, apps and session entry"

# Launch the session (compositor + core apps) for local testing.
run:
    cd wlrix-session && cargo run --release

# Clean all build artifacts, the local feed included -- `feed` rebuilds it.
clean:
    #!/usr/bin/env bash
    set -euo pipefail
    for r in {{all_rust_repos}}; do (cd "$r" && cargo clean); done
    for r in {{cs_repos}}; do (cd "$r" && dotnet clean -v q --nologo || true); done
    rm -rf wlrix-apps/localfeed
