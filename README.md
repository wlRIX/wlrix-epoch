# wlrix-epoch

Meta / aggregator repo for the **wlRIX** desktop environment — the equivalent of
[`cosmic-epoch`](https://github.com/pop-os/cosmic-epoch). It pins a known-good set of component commits and orchestrates
building/packaging the whole DE.

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
| `wlrix-avalonia`   | C#       | Avalonia theme library                  |
| `wlrix-apps`       | C#       | user apps (toolchest, desks, …)         |
| `wlrix-assets`     | data     | shared icons/cursors/wallpapers/palette |

## Usage

Requires [`just`](https://github.com/casey/just) (`cargo install just`
or your distro package).

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
