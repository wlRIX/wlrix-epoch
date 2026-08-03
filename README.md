# wlrix-epoch

Meta / aggregator repo for the **wlRIX** desktop environment — the equivalent of
[`cosmic-epoch`](https://github.com/pop-os/cosmic-epoch). It pins a known-good set of component commits and orchestrates
building/packaging the whole DE.

## Building and installing

```sh
just build-rust                 # release builds of the Rust components
sudo just install               # binaries + the session entry
```

`install` deliberately does not build. It is normally run as root, and building as root leaves a target directory nobody
can write to afterwards.

| Variable  | Default      | Purpose                                 |
|-----------|--------------|-----------------------------------------|
| `PREFIX`  | `/usr/local` | where things go                         |
| `DESTDIR` | *(empty)*    | staged install, as a package build does |

```sh
sudo PREFIX=/usr just install   # a system package
DESTDIR=/tmp/stage just install # staged, touches nothing
just uninstall                  # removes what install put down
```

What lands:

| Path                                             |                                            |
|--------------------------------------------------|--------------------------------------------|
| `$PREFIX/bin/wlrix-{compositor,session,greeter}` | the components                             |
| `$PREFIX/share/wayland-sessions/wlrix.desktop`   | the session entry a display manager offers |

The greeter starts `wlrix-session`, which starts `wlrix-compositor`, both **by name** — so `$PREFIX/bin` has to be on
the PATH greetd hands the session. That is the usual reason a build that runs by hand fails under greetd.

The C# apps (toolchest, desks) are **not installed yet**: `build-cs` builds them, but there is no publish/install step.
Until there is, name them by absolute path in
`session.toml`, or the session will report that it could not start them.

## Model

Each component is an independent git repository. During day-to-day development you work in your sibling clones under the
workspace root; `wlrix-epoch` is the **reproducible-build source of truth**: at release time you bump its submodule
pointers to the tested commit set and tag `epoch-X.Y.Z`.

Components aggregated here (added as submodules once they have remotes — see
`repos.txt`):

| Component          | Language | Role                                    |
|--------------------|----------|-----------------------------------------|
| `wlrix-compositor` | Rust     | Wayland compositor (4Dwm-style WM)      |
| `wlrix-greeter`    | Rust     | greetd greeter (login)                  |
| `wlrix-session`    | Rust     | session manager                         |
| `wlrix-desktop`    | Rust     | desktop icons                           |
| `wlrix-idle`       | Rust     | idle timer                              |
| `wlrix-avalonia`   | C#       | Avalonia theme library                  |
| `wlrix-apps`       | C#       | user apps (toolchest, desks, …)         |
| `wlrix-assets`     | data     | shared icons/cursors/wallpapers/palette |

## Usage

Requires [`just`](https://github.com/casey/just) (`cargo install just`or your distro package).

```sh
just init      # add the component repos as submodules (once they have remotes)
just build     # build every component
just run       # launch the session (compositor + apps) for local testing
just clean      # clean all build artifacts
```

## Releasing

1. Verify the sibling clones build and work together.
2. Update submodule pointers here to those commits.
3. Commit and tag `epoch-X.Y.Z`.
