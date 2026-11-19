#!/usr/bin/env bash
# Mirror this repository into the backup repository: git refs + LFS, releases, and container images.
# Run from a full checkout (fetch-depth: 0). Required env:
#   SOURCE_REPO, BACKUP_REPO          owner/name
#   SOURCE_NAMESPACE, BACKUP_NAMESPACE ghcr.io namespaces (lowercase)
#   SOURCE_TOKEN                      reads this repo's releases (github.token is enough)
#   BACKUP_TOKEN                      classic PAT with repo + write:packages on the backup org;
#                                     its user must be allowed to push past the backup's main ruleset
#   SYNC_PARTS                        any of: git releases images (space separated)
set -euo pipefail

: "${SOURCE_REPO:?}" "${BACKUP_REPO:?}" "${SOURCE_NAMESPACE:?}" "${BACKUP_NAMESPACE:?}"
: "${SOURCE_TOKEN:?}" "${BACKUP_TOKEN:?}"
SYNC_PARTS="${SYNC_PARTS:-git releases images}"
IMAGES="${IMAGES:-opsknight opsknight-agent opsknight-pgbouncer}"
BACKUP_URL="https://x-access-token:${BACKUP_TOKEN}@github.com/${BACKUP_REPO}.git"

has() { [[ " $SYNC_PARTS " == *" $1 "* ]]; }

if has git; then
  echo "::group::git refs"
  # --prune removes backup branches/tags deleted here, so the backup stays an exact copy.
  git push --force --prune "$BACKUP_URL" \
    'refs/remotes/origin/*:refs/heads/*' '^refs/remotes/origin/HEAD' \
    'refs/tags/*:refs/tags/*'
  git lfs push --all "$BACKUP_URL"
  echo "::endgroup::"
fi

if has releases; then
  echo "::group::releases"
  existing="$(GH_TOKEN="$BACKUP_TOKEN" gh release list -R "$BACKUP_REPO" --limit 1000 --json tagName --jq '.[].tagName')"
  latest="$(GH_TOKEN="$SOURCE_TOKEN" gh release view -R "$SOURCE_REPO" --json tagName --jq .tagName 2>/dev/null || true)"
  # Oldest first so the backup's release order matches.
  for tag in $(GH_TOKEN="$SOURCE_TOKEN" gh release list -R "$SOURCE_REPO" --limit 1000 --exclude-drafts --json tagName --jq 'reverse|.[].tagName'); do
    grep -qxF "$tag" <<<"$existing" && continue
    dir="$(mktemp -d)"
    GH_TOKEN="$SOURCE_TOKEN" gh release view "$tag" -R "$SOURCE_REPO" --json name,body,isPrerelease > "$dir/meta.json"
    GH_TOKEN="$SOURCE_TOKEN" gh release download "$tag" -R "$SOURCE_REPO" -D "$dir/assets" 2>/dev/null || mkdir -p "$dir/assets"
    jq -r .body "$dir/meta.json" > "$dir/body.md"
    # shortcut: assets are copied as-is, so installers keep pointing at the source repo; rewrite them if the source ever goes away.
    GH_TOKEN="$BACKUP_TOKEN" gh release create "$tag" -R "$BACKUP_REPO" --verify-tag \
      --title "$(jq -r '.name // empty' "$dir/meta.json")" --notes-file "$dir/body.md" \
      --prerelease="$(jq -r .isPrerelease "$dir/meta.json")" --latest="$([[ "$tag" == "$latest" ]] && echo true || echo false)" \
      "$dir"/assets/*
    echo "created release $tag"
    rm -rf "$dir"
  done
  echo "::endgroup::"
fi

if has images; then
  echo "::group::images"
  # BACKUP_TOKEN's user owns both orgs, so one login reads the source and writes the backup.
  echo "$BACKUP_TOKEN" | docker login ghcr.io -u x-access-token --password-stdin >/dev/null
  for image in $IMAGES; do
    token="$(curl -fsS -u "x-access-token:${BACKUP_TOKEN}" "https://ghcr.io/token?scope=repository:${SOURCE_NAMESPACE}/${image}:pull" | jq -r .token)"
    tags="$(curl -fsS -H "Authorization: Bearer ${token}" "https://ghcr.io/v2/${SOURCE_NAMESPACE}/${image}/tags/list?n=10000" | jq -r '.tags[]? | select(startswith("sha-") | not)')"
    for tag in $tags; do
      src="ghcr.io/${SOURCE_NAMESPACE}/${image}:${tag}"
      dst="ghcr.io/${BACKUP_NAMESPACE}/${image}:${tag}"
      want="$(docker buildx imagetools inspect "$src" --format '{{.Manifest.Digest}}')"
      have="$(docker buildx imagetools inspect "$dst" --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
      [[ "$want" == "$have" ]] && continue
      # --prefer-index=false makes a byte-exact copy, so @sha256 pins match in both registries.
      docker buildx imagetools create --prefer-index=false -t "$dst" "$src"
      echo "copied $src ($want)"
    done
  done
  echo "::endgroup::"
fi
