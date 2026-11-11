#!/usr/bin/env bash
set -euo pipefail

: "${BUILD_DIR:?Set BUILD_DIR to the build 6207 archive directory}"
: "${ACR_NAME:?Set ACR_NAME to the Azure Container Registry resource name}"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
inventory="$script_dir/../docs/build6207-images.json"
release=$(jq -er '.release' "$inventory")
source=$(jq -er '.source_repository' "$inventory")
images=$(jq -er '.images[] | [.image, .tag, .config_digest] | @tsv' "$inventory")
repository_prefix="fortiaigate-v803"

while IFS=$'\t' read -r image tag expected_digest; do
  archive="${BUILD_DIR}/FAIG_${image}-${release}-FORTINET.tar"
  if [[ ! -r "$archive" ]]; then
    printf 'Archive missing or unreadable: %s\n' "$archive" >&2
    exit 1
  fi
done <<< "$images"

docker buildx version >/dev/null
registry=$(az acr show --name "$ACR_NAME" --query loginServer --output tsv)
: "${registry:?Azure CLI did not return an ACR login server}"
printf 'Destination: %s/%s\n' "$registry" "$repository_prefix"
az acr login --name "$ACR_NAME"

while IFS=$'\t' read -r image tag expected_digest; do
  destination="${registry}/${repository_prefix}/${image}:${tag}"
  if manifest=$(docker buildx imagetools inspect --raw "$destination" 2>&1); then
    existing_digest=$(jq -er '.config.digest' <<< "$manifest")
    if [[ "$existing_digest" != "$expected_digest" ]]; then
      printf 'Tag conflict for %s: expected %s, found %s\n' \
        "$destination" "$expected_digest" "$existing_digest" >&2
      exit 1
    fi
    printf 'Already verified %s\n' "$destination"
    continue
  elif [[ "$manifest" != *"manifest unknown"* && "$manifest" != *"name unknown"* &&
          "$manifest" != *": not found" ]]; then
    printf '%s\n' "$manifest" >&2
    exit 1
  fi

  archive="${BUILD_DIR}/FAIG_${image}-${release}-FORTINET.tar"
  docker load --input "$archive"
  local_image="${source}/${image}:${tag}"
  loaded_digest=$(docker image inspect --format '{{.Id}}' "$local_image")
  if [[ "$loaded_digest" != "$expected_digest" ]]; then
    printf 'Loaded image mismatch for %s: expected %s, found %s\n' \
      "$local_image" "$expected_digest" "$loaded_digest" >&2
    exit 1
  fi

  docker tag "$local_image" "$destination"
  docker push "$destination"
  pushed_digest=$(docker buildx imagetools inspect --raw "$destination" | jq -er '.config.digest')
  if [[ "$pushed_digest" != "$expected_digest" ]]; then
    printf 'ACR verification failed for %s: expected %s, found %s\n' \
      "$destination" "$expected_digest" "$pushed_digest" >&2
    exit 1
  fi
  printf 'Verified %s\n' "$destination"
done <<< "$images"
