# Keep the last completed report in each marker window. The first can include
# submits recorded before the switch.
function flush() {
    if (!active) return
    if (reports < 2) {
        print "Incomplete GPU profile for " scene " / " dev > "/dev/stderr"
        failed = 1
    } else {
        printf "%s\t%s\t%s\t%s\t%s\n", scene, dev, total, submits, passes
    }
    active = 0
}
BEGIN { print "Scene\tDev\tms/submit\tSubmits\tGPU passes (ms/submit and label)" }
/\[QA\] profile / {
    flush()
    split(substr($0, index($0, "[QA] profile ") + 13), marker, /[[:space:]]+/)
    scene = marker[1]
    dev = marker[2]
    active = 1
    reports = 0
    windows++
}
/\[QA\] profile-end/ { flush() }
active && /\[GPU\] [0-9]+\.[0-9]+ ms\/submit over [0-9]+ / {
    report = substr($0, index($0, "[GPU] ") + 6)
    split(report, fields, /[[:space:]]+/)
    total = fields[1]
    submits = fields[4]
    passes = substr(report, index(report, "|") + 2)
    sub(/ \|[[:space:]]*$/, "", passes)
    reports++
}
END {
    flush()
    if (!windows) print "No GPU profile windows found" > "/dev/stderr"
    if (!windows || failed) exit 1
}
