#!/usr/bin/env bash
set -euo pipefail
review_source="$(cd "$(dirname "$0")" && pwd)/review.swift"
cd "${1:?Pass a completed QA output directory}"
shopt -s nullglob
images=(*.png)
frames=(*-frame-[0-9]*.png)
selected=()

# Representative scene, lighting A/B and dive frames. The full PNGs remain available for follow-up.
for scene in pond-morning underwater vista-sunset; do
    for path in *-"$scene".png; do
        selected+=("$path")
        break
    done
done
for path in lights-colour-on.png lights-colour-off.png lights-dyn-blaze-glowstone.png lights-dyn-blaze-glowstone-off.png; do
    if [[ -f $path ]]; then selected+=("$path"); fi
done
if (( ${#frames[@]} > 0 )); then
    selected+=("${frames[0]}")
    if (( ${#frames[@]} > 2 )); then selected+=("${frames[${#frames[@]} / 2]}"); fi
    if (( ${#frames[@]} > 1 )); then selected+=("${frames[${#frames[@]} - 1]}"); fi
fi
if (( ${#images[@]} > 0 && ${#selected[@]} == 0 )); then selected+=("${images[0]}"); fi
if (( ${#selected[@]} > 0 )); then
    swift -module-cache-path "${TMPDIR:-/tmp}/celestia-qa-swift-cache" "$review_source" review.jpg "${selected[@]}"
fi

{
    awk '
        /\[QA\] finished / { modes = modes (modes ? ", " : "") $NF }
        /\[QA\] shot .* settled / {
            sub(/.*\[QA\] shot /, "")
            scenes = scenes (scenes ? ", " : "") $1 " (" $3 " ticks)"
        }
        /\[QA\] frame [0-9]+ eye / {
            if (!firstFluid) firstFluid = $NF
            lastFluid = $NF
        }
        /\[QA\] lights colour-on / { colourOn = $NF }
        /\[QA\] lights colour-off / { colourOff = $NF }
        /\[QA\] lights dyn-hand-on / { torch = $(NF - 3) }
        /\[QA\] lights dyn-blaze-glowstone / { emitters = $(NF - 3) }
        /\[QA\] lights dyn-blaze-glowstone-off / { dynOff = $(NF - 3) }
        END {
            print "Completed: " modes
            if (scenes) print "Scenes: " scenes
            if (firstFluid) print "Descent camera fluid: " firstFluid " to " lastFluid
            if (colourOn != "") print "Colour slots: " colourOn " on, " colourOff " off"
            if (torch != "") print "Dynamic lights: " torch " held torch, " emitters " blaze and glowstone, " dynOff " off"
        }
    ' client.log
    if (( ${#selected[@]} > 0 )); then
        printf 'Images: %d PNGs, including %d descent frames. Start with review.jpg (%d selected).\n' \
            "${#images[@]}" "${#frames[@]}" "${#selected[@]}"
    fi
    if [[ -s profile.tsv ]]; then
        awk -F '\t' '
            NR == 1 { next }
            NR <= 13 { printf "%s %s: %s ms/submit\n", $1, $2, $3 }
            END { printf "Full pass breakdowns: profile.tsv (%d rows)\n", NR - 1 }
        ' profile.tsv
    fi
    if [[ -s perf.txt ]]; then
        awk '
            {
                if (!($2 in minLine)) {
                    scenes[++count] = $2
                    minLine[$2] = maxLine[$2] = $0
                    min[$2] = max[$2] = $(NF - 1)
                }
                if ($(NF - 1) + 0 < min[$2] + 0) { min[$2] = $(NF - 1); minLine[$2] = $0 }
                if ($(NF - 1) + 0 > max[$2] + 0) { max[$2] = $(NF - 1); maxLine[$2] = $0 }
            }
            END {
                print "Largest perf changes per scene:"
                for (i = 1; i <= count; i++) {
                    print minLine[scenes[i]]
                    if (maxLine[scenes[i]] != minLine[scenes[i]]) print maxLine[scenes[i]]
                }
                printf "Full comparisons: perf.txt (%d rows)\n", NR
            }
        ' perf.txt
    fi
} > summary.txt
