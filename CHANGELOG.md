# Changelog

Newest first.  Dates are release dates.

## Unreleased

### Added

- Every archive the build downloads is now verified against a sha256
  recorded in `.github/versions.env`: the nginx release and the actionlint
  release archive, through the new `ci/fetch-verify.sh`.  A changed archive,
  a truncated download or a build cache somebody else filled now fails the
  build instead of being compiled.  A file that fails the check is removed
  so the next run cannot pick it up, and a file that is already present is
  hashed again rather than trusted.
- The companion modules are pinned by commit as well as by tag, and the
  clone is refused if the tag no longer points at that commit.  A tag is a
  movable label, so pinning one alone does not say what was built.

### Changed

- The single version the deep checks build stays on mainline, which is the
  one place this module cannot follow the rest: its test suite needs
  array-var and set-misc, and those kill the worker process on 1.30.4 and
  1.30.5.  The shipped stable line therefore remains uncovered here until
  that is fixed upstream; the reason is written down in
  `.github/versions.env` so it is not mistaken for an oversight.

- Versions live in `.github/versions.env` and nowhere else.  Every workflow
  and `ci/build.sh` read them from there, so a release bump is one edit in
  one file instead of one per workflow, and the digest moves with the
  version it belongs to.  `ci/build.sh` refuses a version it has no digest
  for rather than building it unverified.
- `.github/scripts/pins.sh` hands the release list to `build-test` as a job
  output, because a matrix is read before any step of its own job can run.

### Removed

- nginx 1.22.0, 1.24.0 and 1.26.3 are out of the test matrix.  nginx keeps
  only the current stable and the current mainline alive; everything below
  1.30 is archive material upstream, and no FreeBSD port of this module uses
  it.  The floor is now 1.28.3, the last release of the previous stable line,
  kept so a newer nginx interface cannot creep in unnoticed.

### Known gap

- `Test::Nginx` still comes from CPAN unpinned, installed by `cpanm` in the
  shared setup action.  Pinning it means choosing a version for the suite,
  which is a separate decision.
- The digests prove what we build against, not where it came from.
  nginx.org publishes a detached signature next to each archive; verifying
  it would need the signing keys in the workflow.

## v0.13.0 (2026-09-13)

- First release from this repository.
