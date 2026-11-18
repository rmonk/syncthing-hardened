#!/bin/sh
# Raise the modules listed in $1 to @latest, but only those the module in the
# current directory already requires. Runs inside the Go build stages.
set -eu
list="$1"
present="$(go list -m -f '{{.Path}}' all)"
mods=""
for m in $(grep -vE '^\s*(#|$)' "$list"); do
  if printf '%s\n' "$present" | grep -qx "$m"; then mods="$mods $m@latest"; fi
done
if [ -n "$mods" ]; then
  echo "go-bump:$mods"
  # shellcheck disable=SC2086
  go get $mods
fi
go mod tidy
