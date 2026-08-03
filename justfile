# wlrix-epoch — build orchestration for the wlRIX desktop environment.
# Requires `just` (https://github.com/casey/just).

# GitHub org/base used when wiring submodules. Override as needed.
base := "https://github.com/wlrix"

rust_repos := "wlrix-compositor wlrix-greeter wlrix-session wlrix-desktop wlrix-idle"
cs_repos   := "wlrix-avalonia wlrix-apps"

# Where `install` puts things. `PREFIX=/usr` for a system package; DESTDIR for a
# staged install, as a package build does. Concatenated rather than path-joined
# because prefix is already absolute.
prefix  := env("PREFIX", "/usr/local")
destdir := env("DESTDIR", "")

bindir     := destdir + prefix + "/bin"
sessiondir := destdir + prefix + "/share/wayland-sessions"

# List available recipes.
default:
    @just --list

# Add the component repos as git submodules. Run once, after the repos have
# remotes. Until then, develop against the sibling clones in the workspace root.
init:
    for r in {{rust_repos}} {{cs_repos}} wlrix-assets; do \
        git submodule add {{base}}/$r.git $r || true; \
    done
    git submodule update --init --recursive

# Build everything.
build: build-rust build-cs

# Regenerate the theme scheme dictionaries and the compositor palette module
# from wlrix-assets/palette/*.json. The generated files are checked in, so this
# only needs running after a palette edit; a dirty tree afterwards means a
# generated file was hand-edited.
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
    for r in {{rust_repos}}; do \
        echo "==> building $r"; (cd $r && cargo build --release); \
    done

# Build the C# solutions.
build-cs:
    for r in {{cs_repos}}; do \
        echo "==> building $r"; (cd $r && dotnet build -c Release); \
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
[doc("Install the binaries and session entry (build first; run as root)")]
install:
    #!/usr/bin/env bash
    set -euo pipefail
    for r in {{rust_repos}}; do
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
    echo
    echo "To have greetd start it, in /etc/greetd/config.toml:"
    echo
    echo "    [terminal]"
    echo "    vt = 1"
    echo
    echo "    [default_session]"
    echo "    command = \"{{prefix}}/bin/wlrix-compositor -c wlrix-greeter\""
    echo "    user = \"greeter\""
    echo
    echo "The greeter starts wlrix-session, which starts wlrix-compositor, both by"
    echo "name -- so {{prefix}}/bin must be on the PATH greetd gives the session."

# Remove what `install` put down. Leaves configuration and logs alone.
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail
    for r in {{rust_repos}}; do
        rm -f "{{bindir}}/$r"
    done
    rm -f "{{sessiondir}}/wlrix.desktop"
    echo "removed the wlRIX binaries and session entry"

# Launch the session (compositor + core apps) for local testing.
run:
    cd wlrix-session && cargo run --release

# Clean all build artifacts.
clean:
    for r in {{rust_repos}}; do (cd $r && cargo clean); done
    for r in {{cs_repos}}; do (cd $r && dotnet clean); done
