#!/usr/bin/env bash
# Checks that every submodule pointer recorded in the tree can actually be
# fetched from that submodule's remote.
#
# A pointer bump committed before the submodule commit is pushed looks fine
# locally, because the commit is right there in the local clone, and then every
# CI job dies at checkout with "did not contain <sha>". Run this before pushing
# a submodule bump.
#
# The test is a real fetch of that exact commit, not a listing of the remote's
# refs: a commit that no branch points at any more is still fetchable, so ref
# listings report false failures.
set -euo pipefail

cd "$(dirname "$0")/.."

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
git -C "$scratch" init -q

status=0

for name in $(
  git config -f .gitmodules --name-only --get-regexp '^submodule\..*\.path$' |
    sed 's/^submodule\.//; s/\.path$//'
); do
  path="$(git config -f .gitmodules "submodule.$name.path")"
  url="$(git config -f .gitmodules "submodule.$name.url")"
  commit="$(git ls-tree HEAD "$path" | awk '{print $3}')"

  if [ -z "$commit" ]; then
    echo "FAIL $path has no recorded commit" >&2
    status=1
    continue
  fi

  # Public submodules are readable over https, which works without the SSH key
  # that only the local machine has.
  case "$url" in
    git@github.com:*) fetch_url="https://github.com/${url#git@github.com:}" ;;
    *) fetch_url="$url" ;;
  esac

  if git -C "$scratch" fetch -q --depth 1 "$fetch_url" "$commit" 2>/dev/null; then
    echo "ok   $path $commit"
  else
    echo "FAIL $path records $commit, which $fetch_url will not serve" >&2
    status=1
  fi
done

exit "$status"
