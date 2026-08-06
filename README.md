# wlrix-epoch

Meta / aggregator repo for the **wlRIX** desktop environment — the equivalent of
[`cosmic-epoch`](https://github.com/pop-os/cosmic-epoch). It pins a known-good set of component commits and orchestrates
building/packaging the whole DE.

## Building and installing

```sh
just build                      # the Rust components, the local package feed, and the C# apps
sudo just install               # binaries, apps, and the session entry
```

`install` deliberately does not build. It is normally run as root, and building as root leaves a target directory nobody
can write to afterwards. Either half can be run on its own — `build-rust`/`install-rust`, `build-cs`/`install-cs`.

| Variable     | Default   | Purpose                                                  |
|--------------|-----------|----------------------------------------------------------|
| `PREFIX`     | `/usr`    | where things go                                          |
| `DESTDIR`    | *(empty)* | staged install, as a package build does                  |
| `PAM_FLAVOR` | `arch`    | which PAM stack the greeter installs (`arch` / `debian`) |

```sh
sudo just install               # a system install, into /usr
DESTDIR=/tmp/stage just install # staged, touches nothing
just uninstall                  # removes what install put down
```

What lands:

| Path                                                            |                                            |
|-----------------------------------------------------------------|--------------------------------------------|
| `$PREFIX/bin/wlrix-{compositor,greeter,session,desktop,idle}`   | the Rust components                        |
| `$PREFIX/bin/wlrix-{toolchest,desks,console,settings-keyboard}` | wrappers for the C# apps                   |
| `$PREFIX/lib/wlrix/<app>/`                                      | each C# app's published assemblies         |
| `$PREFIX/share/wayland-sessions/wlrix.desktop`                  | the session entry a display manager offers |

The greeter starts `wlrix-session`, which starts `wlrix-compositor`, both **by name** — so `$PREFIX/bin` has to be on
the PATH greetd hands the session. That is the usual reason a build that runs by hand fails under greetd. The same goes
for the apps: `wlrix-session` starts `wlrix-toolchest` and `wlrix-desks` by name too.

Being started by name is also why `PREFIX` defaults to `/usr` here, matching what each component's own justfile defaults
to. Installing under two prefixes does not conflict — it leaves two complete sets, and PATH order picks the winner.
`/usr/local/bin` comes before `/usr/bin` on most systems, so the *older* set keeps running and installing the new one
appears to do nothing at all. `install` finishes by checking for exactly that, and `just check-path` runs the check on
its own.

### The components install themselves

`install-rust` does not copy binaries. It runs `just install` in each component, with `PREFIX` and `DESTDIR` passed
down.

Three of the five are a single binary and would have fitted a loop here. The other two are not: the greeter needs a
system account, two PAM stacks, a systemd unit and a greetd configuration, and the session a launcher, a systemd user
target and the entry a display manager offers. That knowledge belongs with the files, and where a second copy of it
lived here it drifted — this repo went on installing `wlrix-session/share/wayland-sessions/wlrix.desktop` for a while
after the session had moved the file. One rule for all five is simpler than two rules and a list of which is which.

`PAM_FLAVOR` travels in the environment rather than as a `just` variable: only the greeter reads it, and `just` refuses
an override for a variable a justfile does not declare, so passing it as one would break the other four.

Two steps are left to the administrator afterwards, and the greeter's install prints both: create the account with
`systemd-sysusers && systemd-tmpfiles --create`, and make it the display manager with `systemctl enable
wlrix-greeter.service` — which replaces the distribution's `greetd.service`, being the same daemon on the same VT.

### The C# apps

A published .NET app is a directory — a launcher plus its assemblies — so each one goes under `$PREFIX/lib/wlrix/` and
gets a one-line wrapper in `$PREFIX/bin`. Not a symlink: the .NET host looks for an app's assemblies beside
`/proc/self/exe`, which resolves symlinks, so a link in `bin` would send it hunting for them in `bin`.

They are published **framework-dependent**, so the target needs the .NET runtime installed; bundling a copy with each of
four apps is a lot of megabytes for a desktop already built from source. They are also published for **one platform**,
detected from the SDK and overridable with `RID=`. Avalonia carries native libraries for every platform it supports, and
a publish that names none copies all of them — 550 MB per app against 26 MB.

### The local package feed

`wlrix-apps` restores from `wlrix-apps/localfeed` as well as nuget.org, for packages nuget.org does not have: the wlRIX
theme and dialogs out of `wlrix-avalonia`, and a **patched `Avalonia.Wayland`** carrying app-id support and
`CanResize=false` on the wire. The feed is gitignored, so a fresh clone has to build it — `just feed`, which `build-cs`
depends on.

The patched package cannot come straight out of `dotnet pack`; `tools/pack-avalonia-wayland.py` explains why and does
the reshaping. It refuses to build from an Avalonia checkout whose version is not the release the apps pin, because the
mismatch would otherwise surface as a `MissingMethod` at app startup rather than as a build error.

## Model

Each component is an independent git repository. During day-to-day development you work in your sibling clones under the
workspace root; `wlrix-epoch` is the **reproducible-build source of truth**: at release time you bump its submodule
pointers to the tested commit set and tag `epoch-X.Y.Z`.

Components aggregated here (added as submodules once they have remotes — see
`repos.txt`):

| Component          | Language | Role                                        |
|--------------------|----------|---------------------------------------------|
| `wlrix-compositor` | Rust     | Wayland compositor (4Dwm-style WM)          |
| `wlrix-greeter`    | Rust     | greetd greeter (login)                      |
| `wlrix-session`    | Rust     | session manager                             |
| `wlrix-desktop`    | Rust     | desktop icons                               |
| `wlrix-idle`       | Rust     | idle timer                                  |
| `wlrix-avalonia`   | C#       | Avalonia theme library                      |
| `wlrix-apps`       | C#       | user apps (toolchest, desks, …)             |
| `wlrix-assets`     | data     | shared icons/cursors/wallpapers/palette     |
| `NWayland`         | C#       | fork: protocol codegen + wlrix-desks XML    |
| `Avalonia`         | C#       | fork: Wayland app id, CanResize on the wire |

The last two are **build dependencies**, not parts of the desktop: nothing from them is installed except by way of
`wlrix-apps`. They are submodules here rather than sibling clones because `Wlrix.Desks.csproj` reaches the NWayland
generator and the `wlrix-desks` protocol XML by relative path, which resolves the same in this layout as in a
development workspace.

## Usage

Requires [`just`](https://github.com/casey/just) (`cargo install just`or your distro package).

Building the C# half also needs the **.NET SDK** (10.0).

```sh
just init      # add the component and fork repos as submodules
just build     # build everything: Rust components, package feed, C# apps
just feed      # just the local package feed
just run       # launch the session (compositor + apps) for local testing
just clean     # clean all build artifacts, the feed included
```

## Releasing

1. Verify the sibling clones build and work together.
2. Update submodule pointers here to those commits.
3. Commit and tag `epoch-X.Y.Z`.
