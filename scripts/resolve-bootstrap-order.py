#!/usr/bin/env python3
"""Resolve a bootstrap build order for one or more root packages.

Why this script exists
----------------------
scripts/build-bootstraps.sh builds a flat list of package names in the order
they were written. Dependency resolution happens later, per package, inside
scripts/build/termux_step_get_dependencies.sh. That only works while the
prebuilt-deb path ("-i") is usable.

In this fork the repo package name does not equal the app package name, so
build-package.sh disables "-i" outright, and the failing build log says so 429
times:

    Ignoring -i option to download dependencies since repo package name
    (com.termux) does not equal app package name (me.sources.ai.debug)

Every dependency is then built from source, which exposes two ordering defects
that upstream never reaches.

Defect 1: a genuine cycle through build-deps
--------------------------------------------
scripts/buildorder.py merges TERMUX_PKG_BUILD_DEPENDS into the graph it sorts.
On the audio chain that makes the graph cyclic:

    pulseaudio  --DEPENDS------->  libsndfile
    libsndfile  --DEPENDS------->  libmp3lame
    libmp3lame  --DEPENDS------->  libmpg123
    libmpg123   --BUILD_DEPENDS->  pulseaudio        <- closes the cycle

A cyclic graph has no valid order, so the emitted order put pulseaudio before
libsndfile. libsndfile.pc did not exist yet when pulseaudio configured:

    ../src/meson.build:613:14: ERROR: Dependency "sndfile" not found
    Failed to build package 'apktool' for arch 'aarch64'
    BUILD_EXIT_CODE=1

Defect 2: build-deps treated as unordered
-----------------------------------------
A recursive dependency build runs with "-s" (TERMUX_SKIP_DEPCHECK), so the
build-dep's own runtime dependencies are deliberately not installed for it.
If a build-dep is built lazily during some other package's build, its runtime
closure may be missing and its own configure can fail. Build-dep edges
therefore do need to be honoured wherever doing so is possible.

What this script does
---------------------
Runtime edges (TERMUX_PKG_DEPENDS, plus subpackage membership) are hard
constraints: the sysroot must contain the .pc files and headers before the
consumer configures.

Build-dep edges (TERMUX_PKG_BUILD_DEPENDS) are hard constraints too, except
when they are part of a cycle. A build-dep edge inside a strongly connected
component cannot be honoured by any ordering, so it is dropped; runtime edges
inside the same component are kept, and if those alone still form a cycle the
script reports a real packaging bug instead of emitting a wrong order.

Order of operations:
  1. Transitive closure over runtime + build-dep edges (everything needed).
  2. Tarjan SCC over the full graph.
  3. Keep every runtime edge. Keep build-dep edges that cross components.
  4. Re-check for cycles using only the kept edges; a cycle there is a real
     TERMUX_PKG_DEPENDS loop and is reported as an error.
  5. Kahn sort the condensation, ties broken by name for reproducibility.

Output format matches scripts/buildorder.py:

    <package name>                 <package dir>

Use --names-only to emit just the names, one per line.

Usage
-----
    resolve-bootstrap-order.py <root-package> [<root-package> ...] \
        --packages-dir <dir> [--packages-dir <dir> ...]

Package directories must be passed explicitly: recipes live under packages/,
x11-packages/ and root-packages/, and a bootstrap list may reference any of
them (dbus-glib is in x11-packages/, for example).

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


def _read_var(package, variable):
    """Read one comma-separated TERMUX_PKG_* variable from build.sh."""
    values = []
    build_sh = os.path.join(package.dir, 'build.sh')
    try:
        with open(build_sh, encoding='utf-8') as handle:
            for line in handle:
                if not line.startswith(variable + '='):
                    continue
                raw = line.split('=', 1)[1].strip().strip('"\'')
                values.extend(item.strip() for item in raw.split(',') if item.strip())
    except OSError as exc:
        sys.stderr.write('WARN: cannot read %s: %s\n' % (build_sh, exc))
    return values


def map_names(buildorder, packages_dirs):
    """Map every package name, main or subpackage, to its main package."""
    pkgs_map = buildorder.read_packages_from_directories(packages_dirs, False, False)
    owner = {}
    for name, item in pkgs_map.items():
        owner[name] = item if isinstance(item, buildorder.TermuxPackage) else item.parent
    return owner


def runtime_deps(owner, package):
    deps = set()
    for name in _read_var(package, 'TERMUX_PKG_DEPENDS'):
        target = owner.get(name)
        if target is not None and target.name != package.name:
            deps.add(target.name)
    return deps


def build_deps(owner, package):
    deps = set()
    for name in _read_var(package, 'TERMUX_PKG_BUILD_DEPENDS'):
        target = owner.get(name)
        if target is not None and target.name != package.name:
            deps.add(target.name)
    return deps


def resolve_closure(owner, roots):
    """Everything that has to exist, following both edge kinds."""
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
        for dep in runtime_deps(owner, package) | build_deps(owner, package):
            if dep not in needed:
                stack.append(dep)
    return needed, unknown


def strongly_connected_components(nodes, edges):
    """Tarjan's algorithm, iterative so deep graphs cannot hit recursion limits."""
    index = {}
    low = {}
    on_stack = {}
    stack = []
    components = []
    counter = [0]

    for start in sorted(nodes):
        if start in index:
            continue
        work = [(start, iter(sorted(edges.get(start, ()))))]
        index[start] = low[start] = counter[0]
        counter[0] += 1
        stack.append(start)
        on_stack[start] = True

        while work:
            node, neighbours = work[-1]
            descended = False
            for nxt in neighbours:
                if nxt not in nodes:
                    continue
                if nxt not in index:
                    index[nxt] = low[nxt] = counter[0]
                    counter[0] += 1
                    stack.append(nxt)
                    on_stack[nxt] = True
                    work.append((nxt, iter(sorted(edges.get(nxt, ())))))
                    descended = True
                    break
                if on_stack.get(nxt):
                    low[node] = min(low[node], index[nxt])
            if descended:
                continue
            work.pop()
            if work:
                low[work[-1][0]] = min(low[work[-1][0]], low[node])
            if low[node] == index[node]:
                component = []
                while True:
                    member = stack.pop()
                    on_stack[member] = False
                    component.append(member)
                    if member == node:
                        break
                components.append(component)

    return components


def plan_order(owner, needed):
    """Compute build order, dropping only those build-dep edges that cannot hold.

    Returns (order, dropped_build_edges, blocking_cycles). order is None when
    runtime edges alone form a cycle, which is a real packaging bug.
    """
    full = {}
    for name in needed:
        package = owner[name]
        full[name] = (runtime_deps(owner, package) | build_deps(owner, package)) & needed

    component_of = {}
    for i, component in enumerate(strongly_connected_components(needed, full)):
        for name in component:
            component_of[name] = i

    kept = {name: set(runtime_deps(owner, owner[name]) & needed) for name in needed}
    dropped = []
    for name in needed:
        for dep in build_deps(owner, owner[name]) & needed:
            if component_of.get(name) == component_of.get(dep):
                # Same SCC: no ordering can satisfy this build-dep edge.
                dropped.append((name, dep))
            else:
                kept[name].add(dep)

    blocking = [
        component for component in strongly_connected_components(needed, kept)
        if len(component) > 1
    ]
    if blocking:
        return None, dropped, blocking

    pending = {name: set(kept[name]) for name in needed}
    ready = sorted(name for name in needed if not pending[name])
    order = []
    while ready:
        name = ready.pop(0)
        order.append(name)
        for other in sorted(needed):
            if name not in pending[other]:
                continue
            pending[other].discard(name)
            if not pending[other] and other not in order and other not in ready:
                ready.append(other)
        ready.sort()

    return order, dropped, []


def main():
    parser = argparse.ArgumentParser(
        description='Emit a bootstrap build order honouring runtime and build dependencies.',
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
    owner = map_names(buildorder, packages_dirs)

    needed, unknown = resolve_closure(owner, args.roots)
    if unknown:
        sys.exit('ERROR: unknown package(s): %s' % ', '.join(sorted(unknown)))
    if not needed:
        sys.exit('ERROR: empty dependency closure for: %s' % ', '.join(args.roots))

    order, dropped, blocking = plan_order(owner, needed)

    if order is None:
        sys.stderr.write('ERROR: runtime dependency cycle among: %s\n'
                         % ', '.join(sorted(blocking[0])))
        sys.stderr.write('       These recipes declare TERMUX_PKG_DEPENDS edges that form a loop.\n')
        sys.stderr.write('       Ordering cannot break a real cycle; fix the recipes.\n')
        return 1

    for name, dep in dropped:
        sys.stderr.write('note: build-dependency %s -> %s is cyclic, ordering without it\n'
                         % (name, dep))

    width = max(len(name) for name in order)
    for name in order:
        if args.names_only:
            print(name)
        else:
            print('%-*s %s' % (width, name, owner[name].dir))
    return 0


if __name__ == '__main__':
    sys.exit(main())