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
## The exit status is the verdict, so `scrub image ref || echo bad` works. A
## trailing SCRUB VERDICT line is printed as well: it survives being piped
## through tee, where $? reports tee's status rather than this process's.
## Library callers should use Scrubber.scrub() -> ScrubResult.verdict instead.
##
## Arguments come from cli_args.program_args(), not from sys.args() directly:
## sys.args() has a different shape interpreted and compiled, and the previous
## version read args[0] as the image, which only worked while compiled code
## omitted argv[0]. The earlier attempt before that read args[1] while requiring
## two arguments, so it scrubbed the *second* path and refused to run with a
## single one -- the tool had never actually been exercised.

import sys
import scrub
import cli_args

proc main(args: Array):
    if len(args) < 1:
        print "Usage: scrub_cli.sage <image> [<known-good-image>]"
        print "SCRUB VERDICT: ERROR"
        sys.exit(scrub.SCRUB_ERROR)
    let image_path = args[0]
    ## Optional second positional: the known-good image to verify against.
    var reference: String = ""
    if len(args) > 1:
        reference = args[1]

    let s = scrub.Scrubber(image_path)
    if not s.ok():
        print "scrub: " + s.error()
        print "SCRUB VERDICT: ERROR"
        sys.exit(scrub.SCRUB_ERROR)

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
    let examined: String = str(r.blocks_examined) + "/" + str(r.total_blocks) + " (" + str(r.coverage_pct()) + "%)"
    print ""
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

    ## Both channels, on purpose: the exit status for scripts that do
    ## `scrub img ref || fail`, and this line for anyone who piped us through tee
    ## and is about to trust tee's status instead of ours.
    if r.verdict == scrub.SCRUB_OK:
        print "SCRUB VERDICT: OK"
    elif r.verdict == scrub.SCRUB_INCONCLUSIVE:
        print "SCRUB VERDICT: INCONCLUSIVE"
    elif r.verdict == scrub.SCRUB_DAMAGE:
        print "SCRUB VERDICT: DAMAGE"
    else:
        print "SCRUB VERDICT: ERROR"
    sys.exit(r.verdict)

main(cli_args.program_args(sys.args()))
