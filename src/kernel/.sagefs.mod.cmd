savedcmd_sagefs.mod := printf '%s\n'   sagefs.o | awk '!x[$$0]++ { print("./"$$0) }' > sagefs.mod
