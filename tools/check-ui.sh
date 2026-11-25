#!/bin/sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
bin=${KMERBUDGET_BIN:-$root/zig-out/bin/kmerbudget}
port=${KMERBUDGET_PORT:-18099}
work=$(mktemp -d)
pid=
cleanup() {
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
    rm -rf "$work"
}
trap cleanup EXIT

"$bin" serve --port "$port" >"$work/server.log" 2>&1 &
pid=$!
tries=0
until curl -fsS "http://127.0.0.1:$port/" -o "$work/form.html"; do
    tries=$((tries + 1))
    if [ "$tries" -ge 50 ]; then
        cat "$work/server.log"
        exit 1
    fi
    sleep 0.1
done

case "$(cat "$work/form.html")" in
    *"<form"*) ;;
    *) echo "missing form"; exit 1 ;;
esac
case "$(cat "$work/form.html")" in
    *"<script"*) echo "script tag in page"; exit 1 ;;
    *) ;;
esac

curl -fsS -X POST "http://127.0.0.1:$port/scan" \
    --data-urlencode 'fasta=>demo
ACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT' \
    --data 'mask=1011010101' --data 'budget=1' -o "$work/result.html"
case "$(cat "$work/result.html")" in
    *"Result"*) ;;
    *) echo "scan result missing"; exit 1 ;;
esac
case "$(cat "$work/result.html")" in
    *"MB/s/core"*) ;;
    *) echo "throughput missing"; exit 1 ;;
esac
case "$(cat "$work/result.html")" in
    *"<script"*) echo "script tag in result"; exit 1 ;;
    *) ;;
esac

curl -fsS -X POST "http://127.0.0.1:$port/design" \
    --data-urlencode 'fasta=>demo
ACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT' \
    --data 'span=16' --data 'weight=8' --data 'error=0.02' -o "$work/design.html"
case "$(cat "$work/design.html")" in
    *"Designed mask"*) ;;
    *) echo "design result missing"; exit 1 ;;
esac

code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/not-found")
if [ "$code" != "404" ]; then
    echo "expected 404, got $code"
    exit 1
fi

seq 1 40 | xargs -P 8 -I{} curl -fsS -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:$port/" > "$work/codes"
while read -r code; do
    if [ "$code" != "200" ]; then
        echo "load request failed with $code"
        exit 1
    fi
done < "$work/codes"

echo "ui PASS"
