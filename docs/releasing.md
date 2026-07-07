# Release runbook

Exact, ordered steps. The repo doubles as the Homebrew tap, so a release is:
tag → pin tarball sha in the formula on main → GitHub release. Users get it
via `brew upgrade dalinkstone/devflow/devflow` or by re-running install.sh
(which always pulls `main`).

Versioning: semver-ish — patch for fixes, minor for features. The single
source of truth is `DEVFLOW_VERSION` in `bin/devflow`.

## Preflight (must all be green)

```bash
make lint && make test && make test-docker
git status --short          # clean tree, on main, synced with origin
```

## Steps

```bash
# 1. bump version
#    edit bin/devflow: DEVFLOW_VERSION="X.Y.Z"

# 2. commit + tag + push
git add -A
git commit -m "vX.Y.Z: <summary>"
git tag vX.Y.Z
git push origin main vX.Y.Z

# 3. pin the formula sha — compute from GitHub's OWN tarball (never from
#    local `git archive`; byte-identity is not guaranteed)
SHA=$(curl -fsSL https://github.com/dalinkstone/devflow/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256 | cut -d' ' -f1)
#    edit Formula/devflow.rb: url → vX.Y.Z tarball, sha256 → $SHA
git add Formula/devflow.rb
git commit -m "formula: pin vX.Y.Z tarball sha256"
git push origin main

# 4. GitHub release (notes: what changed + upgrade line)
gh release create vX.Y.Z --repo dalinkstone/devflow \
  --title "devflow vX.Y.Z" --notes "…"

# 5. verify the real user paths
brew update && brew upgrade dalinkstone/devflow/devflow && devflow version
curl -fsSL https://raw.githubusercontent.com/dalinkstone/devflow/main/install.sh | head -3

# 6. confirm CI green for the pushed commits
gh run list --repo dalinkstone/devflow --limit 2
```

Note the ordering in steps 2–3: the tag must exist on GitHub **before** you
can hash its tarball, so the formula pin is always a follow-up commit on
main. Tap users read the formula from main; the sha refers to the tagged
tarball. This is intentional — don't try to fold it into one commit.

## CI

`.github/workflows/ci.yml`, three jobs on push/PR:

| Job | Covers |
|---|---|
| lint-and-test (ubuntu-latest) | shellcheck + hermetic suite |
| lint-and-test (macos-latest) | same under **bash 3.2** + BSD tools (brew-installs shellcheck first) |
| provision-in-docker | the real provisioner incl. harness npm installs, on amd64 |

A release is not done until the release commits are green.

## Rollback

- Bad formula pin: fix sha/url on main, push (tap users get it on next
  `brew update`).
- Bad release: `gh release delete vX.Y.Z --yes`, `git push --delete origin
  vX.Y.Z`, fix forward with a new patch version. Never retag an existing
  published version.

## Distribution surfaces (what must keep working)

1. `curl -fsSL https://raw.githubusercontent.com/dalinkstone/devflow/main/install.sh | bash`
   (installs devflow + `dv`, plus daytona/jq/gh if missing)
2. `brew tap dalinkstone/devflow https://github.com/dalinkstone/devflow` +
   `brew install dalinkstone/devflow/devflow` (formula test: `devflow version`)
3. `make install` from a checkout
