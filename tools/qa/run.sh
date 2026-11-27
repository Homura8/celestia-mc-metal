#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: tools/qa/run.sh <shots,profile,perf,lights,frames,packs> [Gradle options]
Set QA_LABEL to name the output folder or QA_VERBOSE=1 to stream client logs.
See docs/QA.md for presets, filters, profiling and the Iris/Photon reference.
USAGE
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
if [[ $# == 0 ]]; then usage >&2; exit 2; fi
modes=$1
shift
if [[ ! $modes =~ ^(shots|profile|perf|lights|frames|packs)(,(shots|profile|perf|lights|frames|packs))*$ ]]; then
    usage >&2
    exit 2
fi
label=${QA_LABEL:-${modes//,/-}-$(date +%Y%m%d-%H%M%S)}
if [[ ! $label =~ ^[[:alnum:]][[:alnum:]_.-]*$ || $label == run || $label == world || $label == reference || $label == probe ]]; then
    echo "Invalid QA_LABEL: $label" >&2
    exit 2
fi

cd "$(dirname "$0")/../.."
qa_root="$PWD/build/qa"
run="$qa_root/run"
world="$qa_root/world/CelestiaQA"
out="$qa_root/$label"
mkdir -p "$qa_root"
if ! mkdir "$qa_root/.lock"; then
    echo "The QA run directory is locked. Check for an active QA run before removing $qa_root/.lock." >&2
    exit 1
fi
trap 'rmdir "$qa_root/.lock" 2>/dev/null || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$out"
mkdir -p "$qa_root/world"

gradle_args=()
if [[ -n ${QA_REFERENCE_DIR:-} ]]; then
    reference=$(cd "$QA_REFERENCE_DIR" && pwd -P)
    [[ -d $reference/mods && -d $reference/shaderpacks && -f $reference/config/iris.properties ]] || {
        echo "QA_REFERENCE_DIR needs mods/, shaderpacks/ and config/iris.properties" >&2
        exit 2
    }
    # Use a fresh Iris configuration for each comparison without touching the supplied files.
    run="$qa_root/reference/run"
    mkdir -p "$run/config"
    rm -rf "$run/shaderpacks"
    cp -R "$reference/shaderpacks" "$run/shaderpacks"
    cp "$reference/config/iris.properties" "$run/config/iris.properties"
    gradle_args+=("-PqaReferenceMods=$reference/mods")
else
    # Leave the Metal binary archive and Fabric's processed mods on disk.
    mkdir -p "$run/config"
    cp tools/qa/template/config/celestia-metal.json "$run/config/celestia-metal.json"
    # The example world pack, fresh each run (with no saved options), for the packs mode and manual switching.
    mkdir -p "$run/shaderpacks"
    rm -rf "$run/shaderpacks/celestia-example-world" "$run/shaderpacks/user_celestia-example-world".celestia*.json
    cp -R examples/shaderpacks/celestia-example-world "$run/shaderpacks/"
fi

mkdir -p "$run/saves"
cp tools/qa/template/options.txt "$run/options.txt"
rm -rf "$run/screenshots" "$run/saves/CelestiaQA"
if [[ -f $world/level.dat ]]; then cp -cR "$world" "$run/saves/CelestiaQA"; fi
if [[ ,$modes, == *,profile,* ]]; then gradle_args+=(-PqaProfile=120); fi

echo "QA output: $out"
launch=(./gradlew --console=plain qaClient ${gradle_args[@]+"${gradle_args[@]}"} "$@" "-PqaDir=$run" "-PqaModes=$modes")
if [[ ${QA_VERBOSE:-0} == 1 ]]; then
    "${launch[@]}" 2>&1 | tee "$out/client.log"
elif ! "${launch[@]}" > "$out/client.log" 2>&1; then
    tail -25 "$out/client.log" >&2
    exit 1
fi
if ! grep -q '\[QA\] done[[:space:]]*$' "$out/client.log"; then
    grep '\[QA\] failed' "$out/client.log" >&2 || true
    echo "Client exited before QA completed. See $out/client.log." >&2
    exit 1
fi

if [[ ! -f $world/level.dat ]]; then
    snapshot=$(mktemp -d "$qa_root/world/.snapshot.XXXXXX")
    cp -cR "$run/saves/CelestiaQA" "$snapshot/CelestiaQA"
    mv "$snapshot/CelestiaQA" "$world"
    rmdir "$snapshot"
fi

if [[ ,$modes, == *,profile,* ]]; then
    awk -f tools/qa/profile.awk "$out/client.log" > "$out/profile.tsv"
fi
if [[ ,$modes, == *,perf,* ]]; then
    sed -n 's/^.*\(\[PERF\].*\)$/\1/p' "$out/client.log" > "$out/perf.txt"
    test -s "$out/perf.txt"
fi
shopt -s nullglob
shots=("$run/screenshots/"*.png)
expected=$(awk '/\[QA\] saved [0-9]+ screenshots/ { print $(NF - 1) }' "$out/client.log")
if [[ ${#shots[@]} != "$expected" ]]; then
    echo "Expected $expected screenshots, found ${#shots[@]}. See $out/client.log." >&2
    exit 1
fi
if (( ${#shots[@]} > 0 )); then
    sips -Z 1100 "${shots[@]}" --out "$out" > "$out/resize.log"
    rm "$out/resize.log"
fi
bash tools/qa/review.sh "$out"
cat "$out/summary.txt"
echo "QA complete: $out"
