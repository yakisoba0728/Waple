#!/bin/bash
set -euo pipefail

mode="$1"
ref="refs/tags/$2"
commit="$3"
git check-ref-format "$ref"

remote_git() {
  git -c credential.helper= -c 'credential.helper=!gh auth git-credential' "$@"
}

verify_tag() {
  local refs status target
  if refs=$(remote_git ls-remote --exit-code --tags origin "$ref" "$ref^{}"); then
    target=$(awk -v ref="$ref" '
      $2 == ref { direct = $1 }
      $2 == ref "^{}" { peeled = $1 }
      END { print (peeled == "" ? direct : peeled) }
    ' <<< "$refs")
    if [[ "$target" != "$commit" ]]; then
      echo "::error::Tag $ref points to ${target:-<missing SHA>}, expected $commit." >&2
      return 1
    fi
    return 0
  else
    status=$?
  fi

  if [[ "$status" == 2 ]]; then
    return 2 # git ls-remote --exit-code gives 2 only for an absent ref
  fi
  echo "::error::Could not check $ref (git exit $status)." >&2
  return 1
}

if verify_tag; then
  exit 0
else
  status=$?
fi
[[ "$status" == 2 ]] || exit "$status"

case "$mode" in
  preflight) exit 0 ;;
  create)
    remote_git push origin "$commit:$ref"
    verify_tag
    ;;
  require)
    echo "::error::Release tag $ref disappeared before publication." >&2
    exit 1
    ;;
  *) exit 2 ;;
esac
