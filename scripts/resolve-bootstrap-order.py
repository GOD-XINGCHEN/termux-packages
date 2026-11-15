#!/usr/bin/env python3
"""Resolve a bootstrap build order for one or more root packages.

Why this script exists
----------------------
scripts/build-bootstraps.sh builds a flat list of package names in the order
they were written. Dependency resolution happens later, per package, inside
scripts/build/termux_step_get_dependencies.sh. That arrangement assumes the
prebuilt-deb download path ("-i") is usable.

In a renamed fork the repo package name does not equal the app package name,
so build-package.sh disables "-i" outright:

    if [[ "$TERMUX_REPO_APP__PACKAGE_NAME" != "$TERMUX_APP_PACKAGE" ]]; then
        echo "Ignoring -i option to download dependencies ..."
        TERMUX_INSTALL_DEPS=false
    fi

Every dependency then falls back to building from source. That fallback goes
through scripts/buildorder.py, which mixes TERMUX_PKG_BUILD_DEPENDS into the
graph. On the audio chain that mix creates a genuine cycle:

    pulseaudio  --DEPENDS------->  libsndfile
    libsndfile  --DEPENDS------->  libmp3lame
    libmp3lame  --DEPENDS------->  libmpg123
    libmpg123   --BUILD_DEPENDS->  pulseaudio        <- closes the cycle

A build-dep only needs to be present while compiling, not while the
dependency itself is being built and staged into the sysroot. Mixing the two
kinds of edge into one topological sort is what breaks the order: the sorter
emits pulseaudio before libsndfile, pulseaudio configures without
libsndfile.pc, and the build dies at

    ../src/meson.build:613:14: ERROR: Dependency "sndfile" not found

Upstream never sees this because its repo package name matches the app package
name, so "-i" stays enabled, dependencies come from the apt repo as prebuilt
debs, and the source-build fallback that would expose the cycle never runs.

What this script does
---------------------
Orders packages using runtime edges only (TERMUX_PKG_DEPENDS, plus subpackage
membership). Build-dep edges are dropped for ordering purposes, which removes
the cycle and guarantees every runtime dependency is built and installed
before its consumer. Build-deps still get satisfied at compile time by the
per-package resolver, exactly as before.

Output format matches scripts/buildorder.py so callers can treat them alike:

    <package name>                 <package dir>

Usage
-----
    resolve-bootstrap-order.py <root-package> [<root-package> ...] \
        --packages-dir <dir> [--packages-dir <dir> ...]

Package directories must be given explicitly. This repository splits recipes
across packages/, x11-packages/ and root-packages/, and a bootstrap list may
reference any of them (dbus-glib lives in x11-packages/, for example).

Root packages may be main package names or subpackage names; subpackage names
are mapped back to their parent, since only main packages are built.
"""

import argparse
import importlib.util
import os
import sys


def load_buildorder():
    """Import the sibling buildorder.py module.

    Reusing it keeps the recipe metadata grammar in one place instead of
    duplicating TERMUX_PKG_DEPENDS parsing rules here. buildorder.py reads
    TERMUX_ARCH at import time, so the caller must set that env var first.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, 'buildorder.py')
    if not os.path.isfile(path):
        sys.exit('ERROR: buildorder.py not found next to this script')
    spec = importlib.util.spec_from_file_location('_termux_buildorder', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parse_runtime_depends(package):
    """Return the runtime dependencies declared by TERMUX_PKG_DEPENDS.

    TERMUX_PKG_BUILD_DEPENDS is deliberately excluded. Those edges only need to
    be present while this package compiles; they do not need to be installed
    before this package is configured, and including them is what makes the
    audio chain cyclic. buildorder.py includes them, which is correct for its
    own job (deciding what to have available) but wrong for deciding install
    order.
    """
    deps = set()
    build_sh = os.path.join(package.dir, 'build.sh')
    try:
        with open(build_sh, encoding='utf-8') as handle:
            for line in handle:
                if not line.startswith('TERMUX_PKG_DEPENDS='):
                    continue
                value = line.split('=', 1)[1].strip().strip('"\'')
                for item in value.split(','):
                    item = item.strip()
                    if item:
                        deps.add(item)
    except OSError as exc:
        sys.stderr.write('WARN: cannot read %s: %s\n' % (build_sh, exc))
    return deps


def build_owner_map(buildorder, packages_dirs):
    """Map every package name, main or subpackage, to its main package."""
    pkgs_map = buildorder.read_packages_from_directories(packages_dirs, False, False)
    owner = {}
    for name, item in pkgs_map.items():
        owner[name] = item if isinstance(item, buildorder.TermuxPackage) else item.parent
    return owner


def resolve_closure(owner, roots):
    """Transitive closure of runtime dependencies starting from roots."""
    needed = set()
    unknown = set()
    stack = list(roots)
    while stack:
        name = stack.pop()
        package = owner.get(name)
        if package is None:
            if name in roots:
                unknown.add(name)
            continue
        if package.name in needed:
            continue
        needed.add(package.name)
        for dep in parse_runtime_depends(package):
            dep_package = owner.get(dep)
            if dep_package is not None and dep_package.name not in needed:
                stack.append(dep_package.name)
    return needed, unknown


def topological_order(owner, needed):
    """Kahn sort over the closure using runtime edges only."""
    pending = {}
    for name in needed:
        deps = set()
        for dep in parse_runtime_depends(owner[name]):
            dep_package = owner.get(dep)
            if dep_package is None:
                continue
            if dep_package.name != name and dep_package.name in needed:
                deps.add(dep_package.name)
        pending[name] = deps

    ordered = []
    ready = sorted(name for name in needed if not pending[name])
    while ready:
        name = ready.pop(0)
        ordered.append(name)
        for other in sorted(needed):
            if name not in pending[other]:
                continue
            pending[other].discard(name)
            if not pending[other] and other not in ordered and other not in ready:
                ready.append(other)
        ready.sort()

    return ordered, sorted(name for name in needed if name not in ordered)


def main():
    parser = argparse.ArgumentParser(
        description='Emit a bootstrap build order using runtime dependencies only.',
        add_help=True,
    )
    parser.add_argument('roots', nargs='+', help='Root package names (main or subpackage).')
    parser.add_argument(
        '--packages-dir',
        action='append',
        dest='packages_dirs',
        metavar='DIR',
        help='Directory containing package sources. Repeatable.',
    )
    parser.add_argument(
        '--names-only',
        action='store_true',
        help='Print package names only, one per line, without the source directory.',
    )
    args = parser.parse_args()

    packages_dirs = args.packages_dirs or []
    if not packages_dirs:
        sys.exit('ERROR: at least one --packages-dir is required')
    for directory in packages_dirs:
        if not os.path.isdir(directory):
            sys.exit('ERROR: not a directory: %s' % directory)

    buildorder = load_buildorder()
    owner = build_owner_map(buildorder, packages_dirs)

    needed, unknown = resolve_closure(owner, args.roots)
    if unknown:
        sys.exit('ERROR: unknown package(s): %s' % ', '.join(sorted(unknown)))
    if not needed:
        sys.exit('ERROR: empty dependency closure for: %s' % ', '.join(args.roots))

    ordered, stuck = topological_order(owner, needed)

    # A residual cycle can only be a real TERMUX_PKG_DEPENDS loop, which is a
    # packaging bug. Refuse to emit a knowingly wrong order.
    if stuck:
        sys.stderr.write('ERROR: runtime dependency cycle among: %s\n' % ', '.join(stuck))
        sys.stderr.write('       These recipes declare TERMUX_PKG_DEPENDS edges that form a loop.\n')
        sys.stderr.write('       Ordering cannot break a real cycle; fix the recipes.\n')
        return 1

    width = max(len(name) for name in ordered)
    for name in ordered:
        if args.names_only:
            print(name)
        else:
            print('%-*s %s' % (width, name, owner[name].dir))
    return 0


if __name__ == '__main__':
    sys.exit(main())