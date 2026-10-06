## test_cli_args.sage — command-line argument extraction across both backends.

import sys
import cli_args

var TESTS_RUN: Int = 0
var TESTS_PASSED: Int = 0

proc check(name: String, cond: Bool):
    TESTS_RUN = TESTS_RUN + 1
    if cond:
        TESTS_PASSED = TESTS_PASSED + 1
        print("    PASS  " + name)
    else:
        print("    FAIL  " + name)

## joined — Flatten an argument array so a whole shape can be asserted at once.
proc joined(args: Array[String]) -> String:
    var out: String = ""
    var i: Int = 0
    while i < len(args):
        if i > 0:
            out = out + "|"
        out = out + args[i]
        i = i + 1
    return out

## check_eq_argv — Compare extracted arguments as a joined string so the order
## and the count are both covered.
proc check_eq_argv(name: String, got: Array[String], expected: String):
    check(name + " (got '" + joined(got) + "')", joined(got) == expected)

proc main():
    ## The whole point of program_args() is that one source behaves identically
    ## whether it is interpreted or compiled, so every case below is a full argv
    ## as the launchers actually produce it, with the expected program arguments
    ## after extraction.

    ## A compiled binary: argv[0] is the binary itself.
    let compiled: Array[String] = ["./sagefs-scrub", "img.fs", "ref.img"]
    check_eq_argv("compiled binary",
                  cli_args.program_args(compiled), "img.fs|ref.img")

    ## The sagemake wrapper, `sage-c --runtime bytecode src.sage args`. The
    ## launcher leaves its own option value at argv[0] and the script path at
    ## argv[1], so both have to go.
    let wrapper: Array[String] = ["bytecode", "/src/tools/scrub_cli.sage",
                                  "img.fs", "ref.img"]
    check_eq_argv("sagemake wrapper",
                  cli_args.program_args(wrapper), "img.fs|ref.img")

    ## `sage -I src script.sage args`: the include directory arrives as a bare
    ## argument because the launcher eats -I but not its value.
    let incl: Array[String] = ["src", "src/mount.sage", "img.fs", "/mnt/point"]
    check_eq_argv("include directory",
                  cli_args.program_args(incl), "img.fs|/mnt/point")

    ## `sage script.sage args`, no -I.
    let plain: Array[String] = ["sage", "fsck.sage", "img.fs", "--repair"]
    check_eq_argv("plain interpreter",
                  cli_args.program_args(plain), "img.fs|--repair")

    ## A trailing .sage path is a launcher leftover wherever it appears, since
    ## no SageFS CLI takes a source file as an argument.
    let trailing: Array[String] = ["./bin", "img.fs", "helper.sage"]
    check_eq_argv("trailing source path",
                  cli_args.program_args(trailing), "img.fs")

    ## A real path that merely contains ".sage" as a substring is not a
    ## launcher token -- only the extension counts. Dropping these would silently
    ## ignore a legitimate volume path.
    let dotted: Array[String] = ["./bin", "/mnt/sage.data", "/mnt/data.sagefs"]
    check_eq_argv("path containing sage",
                  cli_args.program_args(dotted), "/mnt/sage.data|/mnt/data.sagefs")

    ## No arguments at all: argv[0] alone must yield an empty list, not a one
    ## element list holding the binary. This is what makes the usage messages
    ## reachable instead of the tool trying to open its own executable.
    let none_given: Array[String] = ["./bin"]
    check_eq_argv("no arguments",
                  cli_args.program_args(none_given), "")

    check("empty argv", len(cli_args.program_args([])) == 0)

    ## Flags are preserved verbatim; only launcher tokens are removed.
    check_eq_argv("flags preserved",
                  cli_args.program_args(["./bin", "img.fs", "--repair", "-v"]),
                  "img.fs|--repair|-v")

    ## The launcher-token predicate on its own, including the -I form the
    ## interpreter emits when the flag is separated from its value.
    check("token: src", cli_args.is_launcher_token("src"))
    check("token: .", cli_args.is_launcher_token("."))
    check("token: ./src", cli_args.is_launcher_token("./src"))
    check("token: -I", cli_args.is_launcher_token("-I"))
    check("token: script.sage", cli_args.is_launcher_token("a/b/c.sage"))
    check("not a token: image", not cli_args.is_launcher_token("img.fs"))
    check("not a token: mountpoint", not cli_args.is_launcher_token("/mnt/point"))
    check("not a token: short .sage-looking", not cli_args.is_launcher_token(".sagex"))
    check("not a token: empty", not cli_args.is_launcher_token(""))

    ## Argument order must survive untouched: a tool's positional arguments are
    ## positional precisely because order is the only thing that distinguishes
    ## them.
    let ordered: Array[String] = ["./bin", "first", "second", "third"]
    check_eq_argv("order preserved",
                  cli_args.program_args(ordered), "first|second|third")

    if TESTS_PASSED == TESTS_RUN:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")
        print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")

main()
