# wlrix-epoch — build orchestration for the wlRIX desktop environment.
# Requires `just` (https://github.com/casey/just).

# GitHub org/base used when wiring submodules. Override as needed.
base := "https://github.com/wlrix"

rust_repos := "wlrix-compositor wlrix-greeter wlrix-session"
cs_repos   := "wlrix-avalonia wlrix-apps"

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

# Launch the session (compositor + core apps) for local testing.
run:
    cd wlrix-session && cargo run --release

# Clean all build artifacts.
clean:
    for r in {{rust_repos}}; do (cd $r && cargo clean); done
    for r in {{cs_repos}}; do (cd $r && dotnet clean); done
