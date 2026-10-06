## SageFS command-line argument extraction
##
## sys.args() does not have the same shape in both backends, and getting it wrong
## is silent rather than loud -- the tool runs, prints a plausible error, and
## points at the wrong file:
##
##   interpreted   [interpreter, script.sage, ...program args]
##   compiled      [binary,           ...program args]
##
## Two things follow. Index 0 is never a program argument in either backend, so
## it is always dropped. And the interpreter leaks its own include directory and
## script path into argv, which the compiled backend does not, so those have to
## be filtered out as well. Under `sage -I src src/mount.sage img mnt` argv is
## [sage, src, src/mount.sage, img, mnt]: dropping index 0 alone still leaves "src"
## in front of the volume.
##
## Earlier revisions of the tools got this wrong in both directions. mount.sage
## filtered the launcher leftovers but kept index 0, so once compiled binaries
## reported argv[0] it read the binary path as the device. scrub_cli.sage read
## args[0] as the image, which was right only while compiled code omitted
## argv[0] entirely, and wrong the moment that was fixed. dedup_cli.sage required
## two arguments to reach a single one. Each worked by accident under whatever
## launcher its author happened to test with.
##
## Every SageFS CLI should take its arguments from program_args() rather than
## indexing sys.args() directly, so that the two backends cannot diverge again.

## True for tokens the interpreter adds that are not program arguments: the
## include directory from -I, and the script path under interpreted execution.
proc is_launcher_token(a: String) -> Bool:
    if a == "src" or a == "." or a == "./src" or a == "-I":
        return true
    ## A source path is the script the interpreter was told to run. There is no
    ## file_exists() builtin in this runtime to tell a .sage script apart from a
    ## volume, and no SageFS CLI takes a .sage file as an argument.
    if len(a) >= 5:
        if a[len(a) - 5:len(a)] == ".sage":
            return true
    return false

## The program's own arguments, with no launcher tokens: argv[0] dropped, then
## interpreter leftovers filtered out. Works identically interpreted and compiled.
proc program_args(all: Array[String]) -> Array[String]:
    let args: Array[String] = []
    var i: Int = 1
    while i < len(all):
        let a: String = all[i]
        if not is_launcher_token(a):
            push(args, a)
        i = i + 1
    return args
