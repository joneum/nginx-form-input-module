# Changelog

Newest first.  Dates are release dates.

## Unreleased

### Added

- A reload test: `ci/reload.sh`, the per-module `ci/reload.conf` beside it,
  and a workflow of its own.  nginx is reloaded eight times in a row and
  after every one of them the module has to answer correctly, the worker
  generation has to be the new one and nothing of the old one left, the
  master's descriptor count has to be where it started, and no worker may
  have died by signal.  A module that allocates or opens something per cycle
  and never gives it back is invisible in normal use -- nothing fails,
  nothing is logged, and the process grows by one cycle's worth on every
  reload -- and a test suite cannot see it, because a suite starts nginx
  once.
- The probe asks the module, not the server.  A reload that left the module
  behind still answers 200, so the check is the value `let` computed, the
  field `set_form_input` read out of the body, the `Content-Encoding` header
  only this module can set, or the file that came through the cache.
- Deliberately no band on the master's resident size.  Measured here, a
  healthy series grows the master by about twenty-five pages per reload, the
  allocator keeping what it freed, while a leaked cycle pool is a handful of
  pages.  Any band wide enough not to flap is wider than the thing it would
  have to catch, so it could never fail for the right reason.  The descriptor
  count is sharp and needs no band.
- Proven against a planted leak before it was written down: one descriptor
  opened per configuration load inside the directive handler took the
  master's count from 10 to 18 over eight reloads and the check went red.

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

### Fixed

- A cleanup in `ci/build.sh` spelled `rm -rf "$DEPS/$name"`.  Both parts are
  always set, but an empty one would have taken the whole dependency
  directory with it, and two empty ones the root.  Written `${DEPS:?}` now,
  so the shell refuses instead.

### Changed

- Every job now carries a `timeout-minutes`, and the apt step in
  `.github/actions/setup` is bounded with `timeout` and retried.  A mirror
  that accepted the connection and then stopped answering held six jobs in
  that step until GitHub's own six hour ceiling killed them -- 360 and 361
  minutes for two of them.  The run produced no verdict at all and spent
  about 36 hours of runner time doing it.  A step inside a composite action
  cannot carry `timeout-minutes`, hence the explicit `timeout` there.  The
  bounds are measured rather than guessed: across the four repositories the
  slowest healthy job is CodeQL at 2.8 minutes and every other one stays
  under 2.5, so 15 minutes leaves five times the headroom, with 20 for
  CodeQL and 25 for the job that boots a virtual machine.

- `valgrind.suppress` carries two entries instead of 6, and both say what
  they hide.  Measured, not assumed: with an empty file the suite reports
  exactly two things and nothing else, the environment array nginx keeps in
  `ngx_set_environment` and the connection and event arrays it keeps in
  `ngx_event_process_init`.  No invalid read, no uninitialised value, no
  conditional jump -- so everything beyond those two suppressed something
  that never happens. 5 of them were raw `--gen-suppressions`
  output carrying `<insert_a_suppression_name_here>`, among them entries for
  glibc's dynamic loader and for `exp-sgcheck`, a valgrind tool no workflow
  here runs.  The file is now the same in all four module
  repositories.
- Both traces run through `ngx_single_process_cycle`, because Test::Nginx
  starts nginx with `master_process off`.  An entry for the master's own path
  could never be reached from this suite, which is why there is none: a
  suppression nobody can check is worse than no suppression.

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
