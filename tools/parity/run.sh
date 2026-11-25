#!/bin/sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
commit=b242e7b65d2f72af36e30037954f3724ff7a57f2
ref=${FISK_REF:-$root/.cache/fisk}
bin=${KMERBUDGET_BIN:-$root/zig-out/bin/kmerbudget}
mask=1100110011001101

if [ ! -f "$ref/include/fisk/fisk.hpp" ]; then
    mkdir -p "$ref"
    curl -fsSL "https://codeload.github.com/lczech/fisk/tar.gz/$commit" |
        tar -xz -C "$ref" --strip-components=1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
c++ -std=c++20 -O2 -I "$ref/include" "$root/tools/parity/parity.cpp" -o "$work/parity"

sha() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1"
    else
        shasum -a 256 "$1"
    fi
}

printf '# fisk %s\n# mask %s\n' "$commit" "$mask"
status=0
for mb in 1 8 64; do
    "$bin" seed --mb "$mb" --n-rate 0 --out "$work/seed.fa"
    "$bin" scan "$work/seed.fa" --mask "$mask" --out "$work/ours.tsv" >/dev/null
    "$work/parity" "$work/seed.fa" "$mask" > "$work/fisk.tsv"
    if cmp -s "$work/ours.tsv" "$work/fisk.tsv"; then
        printf '%s MiB PASS %s\n' "$mb" "$(sha "$work/ours.tsv" | cut -d' ' -f1)"
    else
        printf '%s MiB FAIL\n' "$mb"
        status=1
    fi
done

"$bin" seed --mb 1 --n-rate 0.001 --out "$work/seed_n.fa"
"$bin" scan "$work/seed_n.fa" --mask "$mask" --out "$work/ours_n.tsv" >/dev/null
"$work/parity" "$work/seed_n.fa" "$mask" > "$work/fisk_n.tsv"
if cmp -s "$work/ours_n.tsv" "$work/fisk_n.tsv"; then
    printf '1 MiB with N PASS %s\n' "$(sha "$work/ours_n.tsv" | cut -d' ' -f1)"
else
    printf '1 MiB with N FAIL\n'
    status=1
fi
exit "$status"
