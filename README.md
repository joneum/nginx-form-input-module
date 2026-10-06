Name
====

nginx-form-input-module - read the fields of an `application/x-www-form-urlencoded`
request body into nginx variables.

[![Build & Test][build-test-badge]][build-test-link]
[![FreeBSD][freebsd-badge]][freebsd-link]
[![A/UBSan][sanitizers-badge]][sanitizers-link]
[![Valgrind][valgrind-badge]][valgrind-link]
[![CodeQL][codeql-badge]][codeql-link]
[![Lint][lint-badge]][lint-link]

[build-test-badge]: https://github.com/joneum/nginx-form-input-module/actions/workflows/build-test.yml/badge.svg
[build-test-link]: https://github.com/joneum/nginx-form-input-module/actions/workflows/build-test.yml
[freebsd-badge]: https://github.com/joneum/nginx-form-input-module/actions/workflows/freebsd.yml/badge.svg
[freebsd-link]: https://github.com/joneum/nginx-form-input-module/actions/workflows/freebsd.yml
[sanitizers-badge]: https://github.com/joneum/nginx-form-input-module/actions/workflows/sanitizers.yml/badge.svg
[sanitizers-link]: https://github.com/joneum/nginx-form-input-module/actions/workflows/sanitizers.yml
[valgrind-badge]: https://github.com/joneum/nginx-form-input-module/actions/workflows/valgrind.yml/badge.svg
[valgrind-link]: https://github.com/joneum/nginx-form-input-module/actions/workflows/valgrind.yml
[codeql-badge]: https://github.com/joneum/nginx-form-input-module/actions/workflows/codeql.yml/badge.svg
[codeql-link]: https://github.com/joneum/nginx-form-input-module/actions/workflows/codeql.yml
[lint-badge]: https://github.com/joneum/nginx-form-input-module/actions/workflows/lint.yml/badge.svg
[lint-link]: https://github.com/joneum/nginx-form-input-module/actions/workflows/lint.yml

Description
===========

nginx hands out the arguments of a query string as `$arg_name`, but it
has nothing for the body of a form submission.  This module closes that
gap: it parses the body of a POST or PUT request that carries a form and
assigns a field of that body to a variable.  Urlencoded bodies are read
out of the box, `multipart/form-data` where it is asked for.

The work happens in the rewrite phase, before a content handler sees the
request, so the value is available to everything that reads variables
afterwards, `if`, `map`, `proxy_set_header`, the access log, a Lua
handler, and so on.

Only the locations that name a directive are affected.  Everywhere else
the module stays out of the way and nginx streams request bodies as it
normally would.

Status
======

The module is maintained and released here.  Every push and every pull
request is built against a range of nginx releases and run through the
whole test suite, built into the binary and again as loadable modules,
and once more inside a FreeBSD virtual machine, which is the platform
the module is packaged for.  A run under valgrind comes on top of that
on everything but a pull request.  The suite is part of this repository,
so none of it has to be taken on trust.  See
[Test Suite](#test-suite) and [Compatibility](#compatibility).

Synopsis
========

```nginx
location /login {
    set_form_input      $user;          # the "user" field of the body
    set_unescape_uri    $user;          # values arrive percent encoded

    proxy_set_header    X-User $user;
    proxy_pass          http://backend;
}
```

A field value is whatever the client sent, and decoding it makes more of
it, not less: `%0d%0a` becomes a real line break and that line break
becomes a second header.  [Limitations](#limitations) says what to do
about it, and it is worth reading before copying this.

```nginx
location /search {
    set_form_input      $q query;       # the "query" field, into $q
    set_unescape_uri    $q;

    if ($q = "") {
        return 400;
    }

    proxy_pass http://backend;
}
```

A form that can carry a file is sent as `multipart/form-data`, and that
has to be switched on.  Its values are literal, so nothing decodes them:

```nginx
location /profile {
    form_input_multipart on;

    set_form_input      $nick;      # no set_unescape_uri here
    proxy_set_header    X-Nick $nick;
    proxy_pass          http://backend;
}
```

The same caveat applies, and here the client does not even have to
encode anything: a `<textarea>` sends its line breaks as they are.

A field that a form sends more than once, `tag=a&tag=b&tag=c` from a set
of checkboxes for example, needs `set_form_input_multi` and
`array_join`:

```nginx
location /tags {
    set_form_input_multi $tags tag;
    array_join ',' $tags;               # $tags is a string from here on

    proxy_set_header X-Tags $tags;
    proxy_pass http://backend;
}
```

Installation
============

The module needs [ngx_devel_kit](https://github.com/openresty/ngx_devel_kit)
in every build, and it has to be named before this module on the
`./configure` line.  Grab the current nginx release from
[nginx.org](https://nginx.org/en/download.html) and build the two
together:

```bash
v=1.31.6   # whatever the current release is

wget "https://nginx.org/download/nginx-$v.tar.gz"
tar -xzf "nginx-$v.tar.gz"
cd "nginx-$v"

./configure --add-module=/path/to/ngx_devel_kit \
    --add-module=/path/to/nginx-form-input-module

make -j4
make install
```

Two further modules belong on the same line in most cases, and both need
ngx_devel_kit as well:

* [set-misc-nginx-module](https://github.com/openresty/set-misc-nginx-module)
brings `set_unescape_uri`.  Field values come out of the body as they
were sent, that is percent encoded, so without it a value like
`a+b%26c` never becomes `a b&c`.

* [array-var-nginx-module](https://github.com/openresty/array-var-nginx-module)
brings `array_join`.  It is not optional for `set_form_input_multi`:
nginx refuses to start when that directive is used in a build without
it, because nothing else can read the variable it produces.

Released tarballs of this module are on the
[tags page](https://github.com/joneum/nginx-form-input-module/tags).

Building as a dynamic module
----------------------------

Pass `--add-dynamic-module=PATH` instead of `--add-module=PATH` and load
the result from `nginx.conf` with
[load_module](https://nginx.org/en/docs/ngx_core_module.html#load_module).
ngx_devel_kit has to be loaded first:

```nginx
load_module modules/ndk_http_module.so;
load_module modules/ngx_http_form_input_module.so;
```

Directives
==========

set_form_input
--------------

**syntax:** *set_form_input $variable*

**syntax:** *set_form_input $variable field*

**default:** *no*

**context:** *location*

**phase:** *rewrite*

Reads a field out of the request body and assigns it to `$variable`.
When no field name is given, the name of the variable without the
leading `$` is used, so `set_form_input $data;` reads the field named
`data`.

Only POST and PUT requests carrying a content type of
`application/x-www-form-urlencoded` are looked at, and
`multipart/form-data` where
[form_input_multipart](#form_input_multipart) is on.  Parameters behind
the type do not matter, `; charset=UTF-8` is still that type, but a
longer type that merely begins with the same characters is not.
Everything else passes through and the variable stays empty.

An empty variable says less than it looks like: the field may be
missing, or the request may not have been one this module reads at all.
Nothing about that fails the request, so an empty value must not be read
as "the client sent nothing" and must not stand in for a check.
[form_input_multipart](#form_input_multipart) adds more ways for it to
come out empty.

If the field occurs more than once, the first occurrence wins.  Use
`set_form_input_multi` to get all of them.

Field names are matched without regard to case, so `set_form_input $v
data;` also reads a field sent as `DATA`.  This is what nginx itself
does for query arguments, `ngx_http_arg()` behind `$arg_name` matches
the same way, and it holds for both encodings here.  Together with the
rule above it means a client decides which spelling wins by sending it
first: out of `DATA=a&data=b` the variable receives `a`.

Whatever reads the body after nginx almost certainly does not work that
way.  A form library compares the name byte for byte, so out of the same
body it takes `b`.  A client that sends two spellings can therefore show
this module one value and the application another.  Where the variable
only travels along that costs nothing; where it decides something, match
on a name the application would also accept, and do not let the
difference stand in for a check.

The value is assigned exactly as it appears in the body, that is still
percent encoded and with `+` standing for a space.  See
[Limitations](#limitations) for how to decode it.

The directive belongs in a `location`.  Older versions of this module
also accepted it in a `server` or `http` block, where it had no effect
and left the variable empty without a warning.  nginx now refuses to
start on such a configuration.

set_form_input_multi
--------------------

**syntax:** *set_form_input_multi $variable*

**syntax:** *set_form_input_multi $variable field*

**default:** *no*

**context:** *location*

**phase:** *rewrite*

Behaves like `set_form_input`, but collects every occurrence of the
field instead of only the first one.  The note about `server` and `http`
blocks above applies here as well.

The variable does not hold a string afterwards.  It carries an array
that only the directives of
[array-var-nginx-module](https://github.com/openresty/array-var-nginx-module)
can read, `array_join` in particular.  Pass the variable through one of
them before anything else touches it.

It carries that array on every request, including the ones the module
does not look at, a GET or a different content type.  The array is empty
then and `array_join` makes an empty string of it, so a location using
these two directives answers such a request normally instead of failing
it.

Writing the variable straight into a response puts the raw bytes of the
array structure there, live heap addresses included, instead of the
field values.  That is a property of the calling convention array-var
defines, and array-var's own array variables behave the same way.  In a
build without array-var nothing could read the variable at all, so nginx
refuses to start when the directive is used there.

form_input_multipart
--------------------

**syntax:** *form_input_multipart on | off*

**default:** *form_input_multipart off*

**context:** *http, server, location*

Lets the two directives above read a `multipart/form-data` body as well,
the encoding a browser uses for a form that can carry files.  Without
it such a body is left alone and the variables stay empty.

It is off by default, because switching it on changes two things a
configuration has to know about.

**Values arrive literally.**  A urlencoded body carries them percent
encoded, which is why the documented pairing is `set_unescape_uri`.  A
multipart body does not: what the field held is what the variable gets.
Decoding it anyway corrupts it, `a+b` would turn into `a b` and `100%25`
into `100%`.  A location that accepts both encodings cannot decode
blindly.

**The whole body ends up in memory.**  The module reads it before the
rewrite phase ends, and multipart is what file uploads travel in.  nginx
may write a large body to a temporary file first, but the module then
reads that file back into a single allocation from the request pool, so
`client_max_body_size` is what bounds the memory one request can take.
Keep it small in a location that switches this on, or the uploads the
switch was meant to accept will be held in memory one by one.

Nothing bounds a single field either.  Whatever the part held is what
the variable gets, which is worth knowing when the value travels on in a
header through `proxy_set_header`.

Parts that name a file are skipped.  A part whose `Content-Disposition`
carries a `filename` parameter, or the `filename*` that RFC 5987 spells
a non-ASCII one with, is an upload rather than a form field, so its
content never reaches a variable, whatever the part is called.

A part is skipped as well when its headers do not hold together: a line
folded onto the one below it, which RFC 9112 deprecates and no form
sender produces, or a second `Content-Disposition`.  Either of those
could hide a `filename` from the rule above, so the part goes rather
than the rule.

A part is skipped for a third reason: a `Content-Transfer-Encoding`
naming anything but `7bit`, `8bit` or `binary`.  RFC 7578 tells senders
not to use one at all, but a form library that meets `base64` here
decodes it and this module does not, so handing the value out would put
two different answers in front of the same request.

Nothing here fails a request.  A body that does not hold together, a
content type that names no boundary, and one that names a boundary
longer than the 70 characters RFC 2046 allows all end the same way: the
variables stay empty and the request runs on.  The first two say so in
the error log at `info` level, a body without a single delimiter says
nothing at all.

Every one of these rules refuses rather than guesses, so where this
module is unsure it hands out nothing while the application behind it
may well read a field.  That is the safe direction for a value that
travels on, and the wrong one for a value that is meant to hold a
request back.  Do not build a gate out of it.

Limitations
===========

* Two encodings are parsed, `application/x-www-form-urlencoded` and,
where [form_input_multipart](#form_input_multipart) is on,
`multipart/form-data`.  Any other content type is left alone and the
variables stay empty.

* File uploads are out of scope.  A multipart part that names a file is
skipped rather than read into a variable.

* A field value is bytes out of the request and nothing in it is
escaped, checked or refused.  One that holds CR and LF turns into more
than one header line as soon as it reaches `proxy_set_header`, and nginx
does not stop that.  Measured against 1.31.6, a field holding
`bob<CR><LF>X-Injected: yes` arrives at the upstream as two headers, and
it does so with either encoding.  What multipart changes is how likely
it is: a `<textarea>` sends line breaks as they are, where a urlencoded
form percent encodes them.  Do not put a field value into a header
without deciding what a line break in it should mean.

* Field values of a urlencoded body are handed out exactly as they
appear, that is still percent encoded and with `+` for a space.  Use
`set_unescape_uri` from
[set-misc-nginx-module](https://github.com/openresty/set-misc-nginx-module)
to decode them.  Values of a multipart body are literal and must not go
through it.

* A location that names a directive reads the whole request body before
the rewrite phase finishes.  That is what the module is for, but it also
means `proxy_request_buffering off` no longer gets a location anything:
the body is already on hand before the upstream is contacted.

Request bodies that nginx writes to a temporary file, which happens as
soon as they exceed `client_body_buffer_size`, are read back from that
file since version 0.12.1.  Earlier versions silently discarded them,
which is why older documentation asked for `client_max_body_size` and
`client_body_buffer_size` to be set to the same value.  That is no
longer necessary.

Compatibility
=============

The module is kept working with the current nginx releases.  Before
anything is pushed the test suite is run against the current mainline
and stable releases, and against older ones down to 1.22, which is the
oldest release it is checked on.

One caveat, and it is not this module's doing: on the 1.30 stable line
array-var-nginx-module and set-misc-nginx-module terminate the worker
process on every request that passes through `array_join` or
`set_unescape_uri`.  That leaves `set_form_input_multi` and decoding
unusable there.  It showed first on 1.30.4 and 1.30.5 behaves the same
way.  Their own test suites fail on that line and pass on 1.31.6, in an
nginx built without this module just the same, which is why the 1.30
releases are not in the matrix.

Test Suite
==========

The tests are written for
[Test::Nginx::Socket](https://metacpan.org/dist/Test-Nginx), install it
from CPAN:

```bash
cpanm --notest Test::Nginx::Socket
```

They do not exercise this module on its own.  They need an nginx that
carries ngx_devel_kit,
[echo-nginx-module](https://github.com/openresty/echo-nginx-module) for
the output, set-misc-nginx-module and array-var-nginx-module, plus this
module.  `ci/build.sh` fetches those four at the versions the
continuous integration pins and builds that nginx:

```bash
ci/build.sh 1.31.6 /tmp/nginx-test
TEST_NGINX_BINARY=/tmp/nginx-test/sbin/nginx prove -r t/
```

The same script builds the two other shapes the workflow checks.
`ci/build.sh 1.31.6 /tmp/nginx-dyn dynamic` makes every module a
loadable object, and `ci/build.sh 1.31.6 /tmp/nginx-noav no-array-var`
leaves array-var out, which is the only way to reach the configuration
error that `set_form_input_multi` raises in such a build.

To assemble it by hand instead, ngx_devel_kit has to come before the
modules that use it:

```bash
./configure --prefix=/tmp/nginx-test \
    --add-module=/path/to/ngx_devel_kit \
    --add-module=/path/to/echo-nginx-module \
    --add-module=/path/to/nginx-form-input-module \
    --add-module=/path/to/set-misc-nginx-module \
    --add-module=/path/to/array-var-nginx-module
make && make install
```

`valgrind.suppress` in the repository root is picked up automatically
when the tests are run with `TEST_NGINX_USE_VALGRIND`.

License
=======

BSD 2-Clause, see [LICENSE](LICENSE).

