#!/bin/sh
#
# Put the module behind a client that misbehaves.
#
# Every other check here hands the module a finished request body: one
# write, a correct Content-Length, well formed.  That is the only thing
# Test::Nginx can produce, and the shape of the buffer chain the module has
# to walk is decided entirely by how the body arrives.
#
# What the suite already covers: the body in a temp file, thoroughly --
# t/bodyfile.t has seven cases for it, down to client_body_in_file_only
# with a tiny body.  So that path is not what is missing here.
#
# What nothing covers: a body that arrives over time, and a chunked request
# body.  There is not one chunked request in t/.  Chunked is the sharp case,
# because the bytes on the wire are then not the body -- nginx has to strip
# the framing first, and a module that reaches past the assembled chain into
# the raw buffer gets the chunk headers mixed into the field value.
#
# So the oracle is not a hard coded string: the same body is sent once in a
# single write and then again dripped, cut, and chunked, and all the answers
# have to agree with the first one.  Proven against a planted defect -- with
# the chain check in the module removed, the chunked cases come back with
# chunk headers inside the value and this script fails.
#
# usage: ci/hostile.sh <nginx binary>
#
# A scriptable client is unavoidable: curl cannot be taught to lie about
# Content-Length, to send a body a byte at a time, or to walk away in the
# middle of one.  python3 does it in a few lines and is on every runner
# this repository uses.
#
# What this cannot see: an over-read past the end of a buffer is only
# caught here if it changes the answer.  Catching it as such needs the
# sanitizer build, which runs in its own workflow and over the ordinary
# suite.  The last two cases below exist to walk the percent-unescape code
# with input that ends in the middle of an escape; they assert that nginx
# answers and survives, not a particular value.

set -eu

NGINX=${1:?path to the nginx binary missing}
WORK=${CI_WORK:-$(cd "$(dirname "$0")/.." && pwd)/ci-work}/hostile
PORT=${HOSTILE_PORT:-18400}

command -v python3 > /dev/null || { echo "python3 is needed for the client" >&2; exit 2; }

rm -rf "$WORK"
mkdir -p "$WORK/conf" "$WORK/logs" "$WORK/body_temp"

fail=0
note() {
	echo "  $1" >&2
	fail=1
}

# --------------------------------------------------------------- the server
#
# client_body_buffer_size is deliberately small.  With it, a body of a
# couple of kilobytes is both split over several buffers and written to
# client_body_temp_path, which is exactly the path the ordinary suite never
# reaches.

ngx_user=
if [ "$(id -u)" = 0 ]; then
	ngx_user="user root $(id -gn);"
fi

cat > "$WORK/conf/nginx.conf" <<EOF
$ngx_user
worker_processes 1;
error_log $WORK/logs/error.log info;
pid $WORK/logs/nginx.pid;
events { worker_connections 64; }
http {
    access_log off;

    client_body_buffer_size 1k;
    client_body_temp_path $WORK/body_temp;
    client_max_body_size 1m;
    client_body_timeout 3s;

    server {
        listen 127.0.0.1:$PORT;

        location /field {
            set_form_input \$v field;
            echo "[\$v]";
        }
    }
}
EOF

echo "--- the configuration is read ---"
"$NGINX" -p "$WORK" -c conf/nginx.conf -t

"$NGINX" -p "$WORK" -c conf/nginx.conf

stop() {
	[ -s "$WORK/logs/nginx.pid" ] && kill "$(cat "$WORK/logs/nginx.pid")" 2> /dev/null
	return 0
}
trap stop EXIT
sleep 1

# --------------------------------------------------------------- the client
#
# One case per line on stdout: name, status, answer, separated by tabs.
# The judging stays in the shell below, so what is asserted is readable
# without reading the client.

cat > "$WORK/client.py" <<'CLIENT'
import socket
import sys
import time

PORT = int(sys.argv[1])

# The module hands the field value over exactly as it stands in the body and
# leaves decoding to set_unescape_uri, which t/multipart.t nails down: it
# sends "a+b%20c&d=e" and expects "[a+b%20c&d=e]".  So the expected answer
# here is computable without any assumption about escaping -- it is the
# bytes between "field=" and the end of the body.  The escapes are in it
# anyway, because they are what the field scan has to carry across a buffer
# boundary unchanged.
VALUE = "a%2Bb%20c%25d%2Fe"
BODY = ("field=" + VALUE).encode()

# The sharp one: chunked and larger than client_body_buffer_size, with the
# wanted field at the end.  nginx has to strip the chunk framing and spill
# the result to client_body_temp_path, so the assembled body differs from
# the bytes that arrived, and the answer depends on the end of it.
BIG = ("pad=" + "x" * 3000 + "&field=" + VALUE).encode()


def send(pieces, read=True, pause=0.004, half_close=False):
    """Open a connection, send the request in the given pieces, return
    (status, body).  pieces are sent with a pause between them."""
    buf = b""
    s = socket.create_connection(("127.0.0.1", PORT), timeout=20)
    try:
        for p in pieces:
            s.sendall(p)
            if len(pieces) > 1:
                time.sleep(pause)
        if half_close:
            # Let nginx see the end of input at once instead of waiting for
            # client_body_timeout.
            s.shutdown(socket.SHUT_WR)
        if not read:
            return (-1, "")
        while True:
            d = s.recv(4096)
            if not d:
                break
            buf += d
    except (OSError, socket.timeout):
        if not read:
            return (-1, "")
    finally:
        try:
            s.close()
        except OSError:
            pass
    if not buf:
        return (0, "")
    head, _, body = buf.partition(b"\r\n\r\n")
    lines = head.split(b"\r\n")
    first = lines[0].split(b" ")
    code = int(first[1]) if len(first) > 1 and first[1].isdigit() else 0
    if any(l.lower().startswith(b"transfer-encoding:") and b"chunked" in
           l.lower() for l in lines[1:]):
        body = dechunk(body)
    # The answer is one line of its own below, tab separated, so anything
    # that could break that is made visible instead of silently shifting a
    # field.
    text = body.decode("latin-1").strip()
    for bad, shown in (("\t", "<TAB>"), ("\r", "<CR>"), ("\n", "<LF>")):
        text = text.replace(bad, shown)
    return (code, text)


def dechunk(body):
    """The response arrives chunked whenever echo streams it, and the chunk
    framing is not part of the answer."""
    out = b""
    while True:
        line, sep, rest = body.partition(b"\r\n")
        if not sep:
            return out
        try:
            size = int(line.split(b";")[0], 16)
        except ValueError:
            return out
        if size == 0:
            return out
        out += rest[:size]
        body = rest[size:]
        if body.startswith(b"\r\n"):
            body = body[2:]


def request(body_len, extra=b"", path=b"/field"):
    return (b"POST " + path + b" HTTP/1.1\r\n"
            b"Host: 127.0.0.1\r\n"
            b"Connection: close\r\n"
            b"Content-Type: application/x-www-form-urlencoded\r\n"
            + (b"Content-Length: %d\r\n" % body_len if body_len is not None
               else b"")
            + extra + b"\r\n")


def chop(data, size):
    return [data[i:i + size] for i in range(0, len(data), size)]


def out(name, res):
    print("%s\t%d\t%s" % (name, res[0], res[1]), flush=True)


# The reference: one write, correct length, one buffer.  Everything that
# claims to be equivalent is compared against this.
out("atonce", send([request(len(BODY)) + BODY]))

# The same body, seven bytes at a time.
out("drip", send([request(len(BODY))] + chop(BODY, 7)))

# The same body again, but cut so that the escape %2B is split across two
# writes.  The chain walk has to put it back together before unescaping.
cut = BODY.index(b"%2B") + 2
out("splitesc", send([request(len(BODY)), BODY[:cut], BODY[cut:]]))

# Chunked, in small chunks, so nginx assembles the body itself and the
# bytes on the wire are not the body.
chunks = [b"%x\r\n%s\r\n" % (len(c), c) for c in chop(BODY, 9)]
out("chunked", send([request(None, b"Transfer-Encoding: chunked\r\n")]
                    + chunks + [b"0\r\n\r\n"]))

# Chunked and large enough to be written to client_body_temp_path, with the
# wanted field at the very end.
bigchunks = [b"%x\r\n%s\r\n" % (len(c), c) for c in chop(BIG, 211)]
out("bigchunked", send([request(None, b"Transfer-Encoding: chunked\r\n")]
                       + bigchunks + [b"0\r\n\r\n"]))

# Announces far more than it sends and then closes.  nginx must not hand
# the module a short body as if it were the whole one.
out("lie", send([request(100000) + BODY[:20]], half_close=True))

# Walks away in the middle of the body without waiting for an answer.
out("walkaway", send([request(4096) + b"field=abc"], read=False))

# No body at all, with the directive in place.
out("empty", send([request(0)]))

# Ends in the middle of a percent escape, and contains one that is not
# hex.  Nothing decodes them, but both end the body in a shape the field
# scan has to cope with.
out("cutesc", send([request(11) + b"field=abc%4"]))
out("badesc", send([request(12) + b"field=abc%zz"]))

print("expected\t0\t[%s]" % VALUE, flush=True)
CLIENT

python3 "$WORK/client.py" "$PORT" > "$WORK/cases" 2> "$WORK/client.err" || {
	echo "the client itself failed:" >&2
	cat "$WORK/client.err" >&2
	exit 1
}

case_status() { awk -F'\t' -v n="$1" '$1 == n { print $2 }' "$WORK/cases"; }
case_body() { awk -F'\t' -v n="$1" '$1 == n { print $3 }' "$WORK/cases"; }

want=$(case_body expected)
ref=$(case_body atonce)

echo "--- the easy case still works, and is the reference ---"
if [ "$(case_status atonce)" = 200 ] && [ "$ref" = "$want" ]; then
	echo "  one write, one buffer: $ref"
else
	note "HTTP $(case_status atonce) and \"$ref\", expected 200 and \"$want\""
	note "without a working reference the comparisons below mean nothing"
fi

for c in drip splitesc chunked bigchunked; do
	case $c in
	drip) what="a body that arrives seven bytes at a time" ;;
	splitesc) what="a body cut in the middle of a percent escape" ;;
	chunked) what="a chunked body in small chunks" ;;
	bigchunked) what="a chunked body large enough for a temp file" ;;
	esac
	echo "--- $what ---"
	if [ "$(case_status $c)" != 200 ]; then
		note "HTTP $(case_status $c), expected 200"
	elif [ "$(case_body $c)" = "$ref" ]; then
		echo "  same answer as the single write: $(case_body $c)"
	else
		note "answered \"$(case_body $c)\", the single write answered \"$ref\""
	fi
done

echo "--- a client that promises more than it sends ---"
# What matters is not which status nginx picks -- it may also just close --
# but that a truncated body is never parsed and handed over as a whole one.
if [ "$(case_status lie)" = 200 ]; then
	note "HTTP 200 with \"$(case_body lie)\" from a body that never arrived"
else
	echo "  HTTP $(case_status lie), and nothing was parsed"
fi

echo "--- an empty body with the directive in place ---"
if [ "$(case_status empty)" = 200 ] && [ "$(case_body empty)" = "[]" ]; then
	echo "  answered without a stall, and the variable is empty"
else
	note "HTTP $(case_status empty) and \"$(case_body empty)\", expected 200 and \"[]\""
fi

for c in cutesc badesc; do
	case $c in
	cutesc) what="a body that stops in the middle of an escape" ;;
	badesc) what="an escape that is not hexadecimal" ;;
	esac
	echo "--- $what ---"
	if [ "$(case_status $c)" = 200 ]; then
		echo "  answered: $(case_body $c)"
	else
		note "HTTP $(case_status $c), expected an answer"
	fi
done

echo "--- a client that walks away in the middle of the body ---"
# Nothing to compare: the client never reads an answer.  Its oracle is the
# survival check below and an error log without an alert.
if [ "$(case_status walkaway)" = "-1" ]; then
	echo "  sent and dropped"
else
	note "the client did not get as far as walking away"
fi

echo "--- the worker survived all of it ---"
if [ -s "$WORK/logs/nginx.pid" ] &&
	kill -0 "$(cat "$WORK/logs/nginx.pid")" 2> /dev/null; then
	echo "  yes"
else
	note "the master is gone"
fi

if grep -qE '\[alert\]|\[crit\]|\[emerg\]|exited on signal' "$WORK/logs/error.log" 2> /dev/null; then
	echo "--- the error log complains ---" >&2
	grep -E '\[alert\]|\[crit\]|\[emerg\]|exited on signal' "$WORK/logs/error.log" | head -5 >&2
	fail=1
fi

[ "$fail" -eq 0 ]
