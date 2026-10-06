#!/bin/sh
#
# Build an nginx that carries this module and the modules its test suite
# needs.  The continuous integration workflow runs this, and so can you:
#
#     ci/build.sh 1.31.6 /tmp/nginx-test
#     TEST_NGINX_BINARY=/tmp/nginx-test/sbin/nginx prove -r t/
#
# usage: ci/build.sh <nginx version> <install prefix> [mode]
#
#     static         every module built into the binary (the default)
#     dynamic        every module built as a loadable object
#     no-array-var   static, but without array-var-nginx-module, which is
#                    the only way to reach the configuration error that
#                    set_form_input_multi raises in such a build
#
# nginx and the companion modules land in $CI_WORK, ./ci-work by default,
# and are reused on a second run.  A warning from this module's own
# source fails the build.

set -eu

NGINX=${1:?nginx version missing}
PREFIX=${2:?install prefix missing}
MODE=${3:-static}

SRC=$(cd "$(dirname "$0")/.." && pwd)
WORK=${CI_WORK:-$SRC/ci-work}
DEPS=$WORK/deps
JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)

NDK_TAG=${NDK_TAG:-v0.3.5}
ECHO_TAG=${ECHO_TAG:-v0.65}
SETMISC_TAG=${SETMISC_TAG:-v0.34}
ARRAYVAR_TAG=${ARRAYVAR_TAG:-v0.06}

mkdir -p "$DEPS"

fetch_module() {
	name=$1
	tag=$2

	[ -d "$DEPS/$name" ] && return 0

	git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" \
		"https://github.com/openresty/$name.git" "$DEPS/$name"
}

fetch_module ngx_devel_kit "$NDK_TAG"
fetch_module echo-nginx-module "$ECHO_TAG"
fetch_module set-misc-nginx-module "$SETMISC_TAG"
fetch_module array-var-nginx-module "$ARRAYVAR_TAG"

tarball=$WORK/nginx-$NGINX.tar.gz
url=https://nginx.org/download/nginx-$NGINX.tar.gz

if [ ! -s "$tarball" ]; then
	# curl is a package on FreeBSD, fetch is in the base system
	if command -v curl > /dev/null 2>&1; then
		curl -sSfL -o "$tarball" "$url"
	else
		fetch -q -o "$tarball" "$url"
	fi
fi

rm -rf "$WORK/nginx-$NGINX"
tar xzf "$tarball" -C "$WORK"

case $MODE in
static)
	how=--add-module
	with_array_var=yes
	;;
dynamic)
	how=--add-dynamic-module
	with_array_var=yes
	;;
no-array-var)
	how=--add-module
	with_array_var=no
	;;
*)
	echo "ci/build.sh: unknown mode \"$MODE\"" >&2
	exit 2
	;;
esac

# ngx_devel_kit has to come before every module that uses it

set -- \
	"$how=$DEPS/ngx_devel_kit" \
	"$how=$DEPS/echo-nginx-module" \
	"$how=$SRC" \
	"$how=$DEPS/set-misc-nginx-module"

if [ "$with_array_var" = yes ]; then
	set -- "$@" "$how=$DEPS/array-var-nginx-module"
fi

cd "$WORK/nginx-$NGINX"

# the sanitizer workflow builds through this script as well, so that
# there is one build path and not two that drift apart
if [ -n "${CI_CC_OPT:-}" ]; then
	set -- "$@" --with-cc-opt="$CI_CC_OPT"
fi
if [ -n "${CI_LD_OPT:-}" ]; then
	set -- "$@" --with-ld-opt="$CI_LD_OPT"
fi

echo "--- configure ($MODE) ---"
./configure --prefix="$PREFIX" --with-debug --with-http_ssl_module "$@" \
	> "$WORK/configure-$NGINX.log" 2>&1 ||
	{ tail -30 "$WORK/configure-$NGINX.log"; exit 1; }

echo "--- make -j$JOBS ---"
make -j"$JOBS" > "$WORK/make-$NGINX.log" 2>&1 ||
	{ tail -40 "$WORK/make-$NGINX.log"; exit 1; }

if grep -E "ngx_http_form_input_module\.c.*warning" "$WORK/make-$NGINX.log"; then
	echo "ci/build.sh: the compiler warned about this module, see above" >&2
	exit 1
fi

make install > /dev/null
"$PREFIX/sbin/nginx" -v
