# Relocation: why artifacts carry `@loader_path` instead of an absolute path

Applies to MacWave 4.6 and later. Linux side: see the same subject under
`$ORIGIN` at the end of this document.

> ⚠️ **1.0 changed the "why".** Artifacts are still built with `@loader_path`
> (so the tree can be copied, archived, or checked out anywhere), but the client
> no longer needs to relocate anything at install time: the install root is fixed,
> `wave transfer` is gone, and `wave basedir --set` was removed. The relocation
> work now lives entirely in the build. The sections below describe the
> 4.6-era client behaviour and are kept as history.

---

## 1. The problem

A Mach-O records **paths**, not names:

```
$ otool -L ~/.local/macwave/bin/aria2c@1.37.0/aria2c
	/Users/you/.local/macwave/deps/openssl/openssl@3.0.15/lib/libssl.3.dylib
	/usr/lib/libSystem.B.dylib
```

The first line is an ordinary absolute path. Before 4.6 that was what every artifact
contained, so after unpacking MacWave had to rewrite it to the user's `base_dir` and
re-sign the file. Three consequences:

| Symptom | Cause |
|---|---|
| Install is slow and can fail | every Mach-O is rewritten with `install_name_tool`, then re-signed |
| The tree cannot be moved | every path names one specific directory |
| "Install" means "bytes differ per user" | sha256 only describes what was downloaded, not what ends up on disk |

`RELOCATION` is about removing all three. In 4.x that left the tree movable but the
install root still user-chosen; 1.0 goes further and fixes the root, so the whole
"relocate at install time" machinery is gone rather than generalised.

---

## 2. Three ways to write the reference

Same dependency, three encodings:

| | Encoding | Behaviour |
|---|---|---|
| A | `/Users/you/.local/macwave/deps/.../libssl.3.dylib` | works only at that exact path |
| B | `@loader_path/../../../deps/.../libssl.3.dylib` | resolved relative to the file that contains the load command |
| C | `@rpath/libssl.3.dylib` + `LC_RPATH=@loader_path/../../..` | resolved by searching the run-path stack |

**MacWave uses B.** Reason: MacWave keeps several versions of the same library on
disk at once (`deps/openssl@3.0.15` and `deps/openssl@3.2.0`). Under C both dylibs
would advertise the same name — `@rpath/libssl.3.dylib` — and dyld loads whichever
the run-path stack finds first. Two packages that need different versions would end
up sharing one, silently. Under B the two are different strings, so they stay
different libraries.

C is only better when you want a stable indirection (`deps/openssl/current` →
`openssl@3.2.0`) so an upgrade is a symlink flip. That directly contradicts
"the closure is pinned", so MacWave does not do it.

`LC_ID_DYLIB` still becomes `@rpath/<basename>`: it is the name *others* use when
linking against this library, and `@loader_path` would resolve relative to the
*loader*, which is the wrong meaning. Nothing in MacWave loads a library by its
id — every reference is explicit — so the id is advisory.

---

## 3. Who does what

| Stage | Tool | Action |
|---|---|---|
| Build (CI) | `scripts/prepare_bottle.py` → `scripts/relocate_rpath.py` | rewrite references to `@loader_path/...`, ids to `@rpath/...`, ad-hoc sign, then **mark the artifact as prebuilt** |
| Install (4.x) | `surfboard/transfer.sh` | prebuilt artifacts: **nothing at all**. Unmarked artifacts: rewrite to relative, re-sign. **Deleted in 1.0** — the client now only downloads and unpacks |
| Migrate an old tree | — | removed in 1.0: `wave transfer` is gone, and `apply_migrations` only moves the old directories into `Shore/` |
| Move the tree | — | impossible: the install root is fixed at `/opt/macwave`, and `wave basedir --set` was removed |

### 3.1 How the client knows an artifact is prebuilt

Two channels, because not every payload can carry a file:

| Form | Carrier | Who writes it |
|---|---|---|
| tree / archive payload | `_RELOCATED` file inside `Shore/<name>/<version>/` | `prepare_bottle.py`, after `relocate_rpath.py --check` passes |
| single-file payload | `relocated: "loader_path"` in the version record | whoever publishes the index record |

Both mark the same thing. In 4.x they meant `transfer.sh` returned immediately and the
install tail did not count the artifact in its "Checking Mach-O files" line. In 1.0 the
marker only exists so a later rebuild can skip work — nothing on the client reads it.

Trust: the payload marker is inside the bytes the index `sha256` covers, so it cannot be
added to someone else's artifact; the record field is as trustworthy as the record
itself, which is where the `sha256` comes from. Neither can be forged without also
changing the checksum.

Marking an **existing** bottle without republishing: run

```bash
python3 scripts/relocate_rpath.py <extracted-tree> --check     # must print OK
```

and add `relocated: "loader_path"` to the record. Rebuilding is only needed when the
check reports references it cannot map.

The build stage requires the staging tree to look like the runtime tree:

```
<stage>/Shore/<name>/<version>/...
<stage>/Shore/<dep>/<version>/lib/...
```

Relative paths are computed from that layout, so if staging differs from the installed
layout the numbers are wrong. This is the same constraint as MacPorts `destroot`.
`scripts/prepare_bottle.py` produces exactly this shape.

One judgement — "is this artifact position-independent?" — is implemented once, in
`scripts/relocate_rpath.py` (the read-only `--check` mode does not build a dependency
index). The 4.x client-side twin, `transfer.sh --check`, was deleted with `transfer.sh`.

---

## 4. Verifying by hand

```bash
# No absolute references left (the only allowed ones are Apple's)
otool -L bin/jq@1.8.2/jq | grep -c '^/Users\|^/opt'      # expect 0

# The signature survived: nothing was rewritten after signing
codesign --verify --verbose=2 bin/jq@1.8.2/jq            # expect "satisfies its Designated Requirement"

# Still works after moving the tree
mv /opt/macwave /tmp/mw && /tmp/mw/bin/jq --version

# Two versions of the same library stay separate
otool -L bin/A@1.0/A | grep openssl     # .../openssl@3.0.15/...
otool -L bin/B@1.0/B | grep openssl     # .../openssl@3.2.0/...
```

In 1.0 both `wave transfer` and `wave basedir --set` are gone, so there is no dry run to
offer: `scripts/relocate_rpath.py <stage-dir> --check` is the only inspection tool left,
and it runs at build time.

---

## 5. The Linux side is the same idea, different mechanism

`ELF` records only the library **name** in `DT_NEEDED` (`libcrypto.so.3`), so there is
nothing to rewrite. The search path is separate and can be relative:

```bash
patchelf --set-rpath '$ORIGIN/../../deps/openssl@3.0.15/lib' deps/foo/lib/libfoo.so
```

Two differences matter for maintenance:

| | ELF | Mach-O |
|---|---|---|
| What carries the path | `DT_RUNPATH` (a search list) | `LC_LOAD_DYLIB` (the path itself) |
| Cost of a change | none, no signature | must re-sign; needs `-headerpad` |
| Search path inherited? | **no** — every `.so` needs its own `$ORIGIN` | **yes** — the run-path stack accumulates along the load chain |
| Equivalent of `@executable_path` | none | exists |

Because `DT_NEEDED` holds only a name, LinuxWave today still has to run `patchelf` at
install time. That is the remaining thing to move into the build: while it stays there,
"the sha256 in the index" does not describe the file that ends up on disk, and `patchelf`
is a runtime requirement users can get wrong (the installer warns and skips relocation
when it is missing, which produces a broken install).

Related commands, side by side:

| Purpose | Linux | macOS |
|---|---|---|
| List dependencies | `readelf -d x \| grep NEEDED` | `otool -L x` |
| Show own name | `readelf -d x \| grep SONAME` | `otool -D x` |
| Show search path | `patchelf --print-rpath x` | `otool -l x \| grep -A2 LC_RPATH` |
| Set search path | `patchelf --set-rpath '$ORIGIN/../lib' x` | `install_name_tool -add_rpath @loader_path/../lib x` |
| Change a reference | `patchelf --replace-needed a.so b.so` | `install_name_tool -change a b x` |
| Change own name | `patchelf --set-soname` | `install_name_tool -id` |
| Trace loading | `LD_DEBUG=libs cmd` | `DYLD_PRINT_LIBRARIES=1 cmd` |
| After the change | — | `codesign --force --sign - x` |

---

## 6. Known limits

- **Relative layout is fixed.** The install root is hardcoded (`/opt/macwave`), and
  `Shore/` + `bin/` sit inside it; they cannot be split onto different disks. Move the tree whole.
- **No build-machine paths may survive.** Packing unpacks into `mktemp -d`, which is gone
  afterwards, so any reference to it is dead on the user's machine. `prepare_bottle.py`
  re-reads the finished archive and refuses if this run's `work`/`stage` path appears in it.
  Upstream build paths baked into static libs and debug info are **not** violations — see
  [`DATA-LAYER.md`](./DATA-LAYER.md).
- **Only Mach-O/ELF are rewritten.** Text files keep absolute paths: `.pc` files,
  `openssl.cnf`, `#!/abs/path` scripts, a bundled interpreter's `sys.prefix`. Those are
  handled at build time (placeholder, or read an environment variable), not here.
- **`@rpath`-based plugins** written by upstream may still carry absolute paths; the
  build-side tool reports anything it cannot map instead of guessing.
- **Old artifacts never gain this property by themselves.** `wave reinstall <pkg>`
  fetches the build-time relocated copy. `wave transfer` used to convert an already
  installed tree in place; it was removed in 1.0, so reinstall is the only route.
- **Payloads that come straight from upstream (conda repacks) are not prebuilt yet.**
  Their bytes must stay identical to upstream (`Deps/README.md`: "字节原样搬运"), so they
  carry `@rpath/<name>` + `LC_RPATH=@loader_path/../lib/`, which does not resolve once the
  libraries live under `Shore/<dep>/<version>/`. Moving them to build-time relocation means
  repacking every dep artifact (new sha256) and publishing them as new versions — a data
  migration, not a code change. **The client no longer rescues them at install time** (that
  runtime rewrite was removed with `transfer.sh`), so a dep artifact that was never relocated
  at build time stays broken: it must be repacked.
