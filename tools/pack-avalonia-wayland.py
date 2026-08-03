#!/usr/bin/env python3
"""Build the patched `Avalonia.Wayland` package for `wlrix-apps/localfeed`.

`dotnet pack` alone does not produce a usable package here, for two reasons that both come
from upstream Avalonia assembling its own packages with Nuke rather than with pack:

1.  Upstream *merges* `Avalonia.Dialogs` and friends into the single `Avalonia` package
    (`nukebuild/numerge.json`). A plain `dotnet pack` leaves them as separate dependencies, and
    the apps would try to restore a package that is not published on its own.
2.  `-p:PackageVersion=` propagates to project references, so the dependency versions come out
    matching the *package's* version instead of the version the code was built from. They have
    to say 12.1.0 -- the tag the fork branches off, and what the assembly references resolve to.

So the package is produced by pack and its nuspec is then rewritten to the shape upstream's own
`Avalonia.Wayland` has. Nothing else in the package is touched.

Run through `just feed`, which passes the right paths.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

# The Avalonia release the fork branches from. The built assembly references `Avalonia.* 12.1.0`,
# so the package has to ask for the same or the app loads a version its code was not built for.
BASE_VERSION = "12.1.0"

# What upstream's own Avalonia.Wayland declares, once numerge has folded the rest of the
# Avalonia libraries into the `Avalonia` package.
DEPENDENCIES = f"""      <group targetFramework="{{tfm}}">
        <dependency id="NWayland" version="0.11.0" exclude="Build,Analyzers" />
        <dependency id="Avalonia" version="{BASE_VERSION}" />
        <dependency id="Avalonia.FreeDesktop" version="{BASE_VERSION}" exclude="Build,Analyzers" />
      </group>"""
TARGET_FRAMEWORKS = ("net10.0", "net8.0")


def source_version(source: str) -> str:
    """The Avalonia version the checkout builds as, from its shared version properties."""
    props = os.path.join(source, "build/SharedVersion.props")
    try:
        text = open(props, encoding="utf-8").read()
    except OSError:
        return "unknown"
    found = re.search(r"<Version>([^<]+)</Version>", text)
    return found.group(1).strip() if found else "unknown"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, help="the Avalonia fork checkout")
    parser.add_argument("--version", required=True, help="package version, e.g. 12.1.1-wlrix.1")
    parser.add_argument("--out", required=True, help="the localfeed directory")
    args = parser.parse_args()

    project = os.path.join(args.source, "src/Avalonia.Wayland/Avalonia.Wayland.csproj")
    if not os.path.isfile(project):
        print(f"no Avalonia.Wayland project under {args.source}", file=sys.stderr)
        return 1

    if (found := source_version(args.source)) != BASE_VERSION:
        print(
            f"{args.source} is Avalonia {found}, not {BASE_VERSION}.\n"
            "\n"
            "The package has to be built from the release the apps pin, because the assembly\n"
            "it produces references the Avalonia assemblies it was compiled against -- and .NET\n"
            f"will not load {found} references against the {BASE_VERSION} the apps restore. The\n"
            "failure is a MissingMethod or FileNotFound at startup, long after the build looked\n"
            "fine, which is why this is checked here instead.\n"
            "\n"
            f"Check the submodule out on a branch of upstream's {BASE_VERSION} tag carrying the\n"
            "wlRIX Wayland patches, and point .gitmodules at it.",
            file=sys.stderr,
        )
        return 1

    with tempfile.TemporaryDirectory() as staging:
        packed = os.path.join(staging, "packed")
        subprocess.run(
            ["dotnet", "pack", project, "-c", "Release",
             f"-p:PackageVersion={args.version}", "-o", packed, "--nologo"],
            check=True,
        )
        nupkg = os.path.join(packed, f"Avalonia.Wayland.{args.version}.nupkg")

        opened = os.path.join(staging, "opened")
        with zipfile.ZipFile(nupkg) as archive:
            archive.extractall(opened)

        nuspec = os.path.join(opened, "Avalonia.Wayland.nuspec")
        # utf-8-sig: pack writes a BOM, and keeping it would leave one mid-file after a rewrite.
        text = open(nuspec, encoding="utf-8-sig").read()
        groups = "\n".join(DEPENDENCIES.format(tfm=tfm) for tfm in TARGET_FRAMEWORKS)
        text, count = re.subn(
            r"<dependencies>.*?</dependencies>",
            f"<dependencies>\n{groups}\n    </dependencies>",
            text,
            flags=re.S,
        )
        if count != 1:
            print("could not find the nuspec's dependency block", file=sys.stderr)
            return 1
        open(nuspec, "w", encoding="utf-8").write(text)

        os.makedirs(args.out, exist_ok=True)
        # Older builds of the same package would keep being restored in preference to this one,
        # so they go before it lands.
        for stale in os.listdir(args.out):
            if stale.lower().startswith("avalonia.wayland."):
                os.remove(os.path.join(args.out, stale))

        target = os.path.join(args.out, f"avalonia.wayland.{args.version}.nupkg")
        with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
            for root, _, files in os.walk(opened):
                for name in files:
                    full = os.path.join(root, name)
                    archive.write(full, os.path.relpath(full, opened))

    print(f"wrote {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
