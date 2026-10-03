## scrub_cli.sage — command-line front end for scrub.sage.
##
## Usage:
##   scrub_cli.sage <image>
##   scrub_cli.sage <image> <known-good-image>
##
## The reference is positional rather than a --ref flag: a compiled Sage binary
## runs its own argument parser before sys.args() is populated, and an
## unrecognised flag is consumed by it -- so "--ref" arrives as the image path
## and the tool reports it cannot open a file called "--ref".
##
## The process exit status is always 0 and cannot be set from here: sys.exit()
## does not exist in this runtime, and sys_module.exit() is not reachable from
## user code. Scripts must read the trailing SCRUB VERDICT line instead of
## trusting $?. The library API (Scrubber.scrub() -> ScrubResult.verdict) is
## unaffected and is what tests and callers should use.
##
## sys.args() does NOT include the program name, so the image is args[0]. The
## previous version read args[1] while requiring two or more arguments, which
## meant it scrubbed the *second* path and refused to run at all with a single
## one -- the tool had never actually been exercised.

import sys
import scrub

proc main(args: Array):
    if len(args) < 1:
        print "Usage: scrub_cli.sage <image> [<known-good-image>]"
    let image_path = args[0]
    ## Optional second positional: the known-good image to verify against.
    var reference: String = ""
    if len(args) > 1:
        reference = args[1]

    let s = scrub.Scrubber(image_path)
    if not s.ok():
        print "scrub: " + s.error()

    let info = s.info()
    print "Scrubbing '" + image_path + "'"
    print "  format:       v" + str(info["version_major"]) + "." + str(info["version_minor"])
    print "  block size:   " + str(info["block_size"])
    print "  total blocks: " + str(info["total_blocks"])
    print "  checksum:     " + info["checksum_algo"]
    print "  image bytes:  " + str(info["image_bytes"])
    if reference != "":
        print "  reference:    " + reference

    let r = s.scrub(reference)
    print ""
    let examined: String = str(r.blocks_examined) + "/" + str(r.total_blocks) + " (" + str(r.coverage_pct()) + "%)"
    print "  Blocks examined: " + examined
    print "  Mismatches:      " + str(r.mismatches)
    print "  Unreadable:      " + str(r.unreadable)
    for m in r.messages:
        print "  - " + m

    if r.verdict == scrub.SCRUB_OK:
        print "  Status: OK -- every examined block matches the reference"
    elif r.verdict == scrub.SCRUB_INCONCLUSIVE:
        print "  Status: INCONCLUSIVE -- nothing was verified; this is not a pass"
    elif r.verdict == scrub.SCRUB_DAMAGE:
        print "  Status: FAILED -- damage found; run fsck"
    else:
        print "  Status: ERROR -- could not scrub"

    ## Single line for scripts and CI to match on.
    if r.verdict == scrub.SCRUB_OK:
        print "SCRUB VERDICT: OK"
    elif r.verdict == scrub.SCRUB_INCONCLUSIVE:
        print "SCRUB VERDICT: INCONCLUSIVE"
    elif r.verdict == scrub.SCRUB_DAMAGE:
        print "SCRUB VERDICT: DAMAGE"
    else:
        print "SCRUB VERDICT: ERROR"

main(sys.args())
