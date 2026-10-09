# Changelog

Newest first.  Dates are release dates.

## v0.13.1 (2026-10-09)

### Changed

- The bounded apt call moved out of `.github/actions/setup` and into
  `ci/apt-get.sh`, and the lint workflow now uses it instead of carrying a
  second, unbounded copy.  Two things follow.  There is one implementation
  of the bound and the retries rather than two that can drift apart, and
  shellcheck actually sees it: the `shell` job checks every script under
  `ci/`, while a `run:` block inside a workflow is invisible to it.
- The lint workflow no longer installs shellcheck unconditionally.  The
  runner image ships it, so the step only acts if that ever stops being
  true -- and then through the same wrapper, because a stalled mirror must
  not hold this job either.
- The widened gate earned its keep on the spot: a comment in the new
  script began with `# shellcheck`, which shellcheck reads as a directive
  and then cannot parse -- SC1072 and SC1073, both errors.  The sentence is
  reworded.  That line sat in a `run:` block before the move and nothing
  would ever have looked at it.
- The repository moved from `joneum` to the `sysadmin-labs` organization.
  Badges and links in the README point to the new address; the old URLs
  redirect.

### Added

- A hostile-client test: `ci/hostile.sh` and a workflow of its own.  The
  suite can only send a finished request -- one write, a correct
  Content-Length, well formed -- and the shape of the buffer chain this
  module walks is decided entirely by how the body arrives.  The temp file
  path is not the gap; `t/bodyfile.t` covers that with seven cases, down to
  `client_body_in_file_only` with a tiny body.  The gap is a body that
  arrives over time and, above all, a **chunked** request body: there was
  not one chunked request anywhere in `t/`.  Chunked is the sharp case
  because the bytes on the wire are then not the body.  nginx has to strip
  the framing first, and anything that reaches past the assembled chain
  into the raw buffer gets chunk headers inside the field value.
- The oracle is not a hard coded string.  The same body is sent once in a
  single write and then again dripped seven bytes at a time, cut in the
  middle of a percent escape, chunked in small chunks, and chunked large
  enough to be spilled to a temp file; all four answers have to agree with
  the single write.  Beyond that: a client that announces a hundred
  thousand bytes and sends twenty, one that walks away in the middle of the
  body, an empty body with the directive in place, and two bodies that end
  in a broken percent escape.  The expected value is exact and needs no
  assumption about escaping, because the module hands the field over
  verbatim and leaves decoding to `set_unescape_uri` -- which `t/multipart.t`
  nails down by sending `a+b%20c&d=e` and expecting it back unchanged.
- Proven against a planted defect before it was written down.  With the
  chain check taken out of the module, so that the first buffer is used
  blindly, three oracles fire at once: the chunked value comes back as
  `[a%2<CR><LF>9<CR><LF>Bb%20c%25]`, the large chunked request gets no
  answer at all, and the error log carries `worker process exited on signal
  11 (core dumped)`.
- Recorded because it cost an iteration: the first draft had a case that
  claimed to make a value straddle the buffer that went to the file and the
  one still in memory.  The planted defect walked straight through it and
  the case stayed green, so it proved nothing and was dropped.  nginx
  flushes the whole body to the temp file, it does not leave a tail in
  memory, so that chain never occurs.
- What this cannot see: an over-read is only caught here when it changes
  the answer or kills the worker.  Catching it as such is the sanitizer
  job's work, and that one runs over the ordinary suite -- which is to say
  not over a chunked body.

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
