#!/usr/bin/env bash
set -euo pipefail

if (( $# < 2 || $# > 3 )); then
  printf 'Usage: %s TERRAFORM_ROOT IMAGE_TAG [linux/amd64|linux/arm64]\n' "$0" >&2
  exit 64
fi

terraform_root=$1
tag=$2
platform=${3:-linux/amd64}
[[ $platform == linux/amd64 || $platform == linux/arm64 ]] || exit 64
[[ $tag =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]] || exit 64
repository=$(terraform -chdir="$terraform_root" output -raw ecr_repository_url)
region=$(terraform -chdir="$terraform_root" output -raw region)
aws --region "$region" ecr get-login-password |
  docker login --username AWS --password-stdin "${repository%%/*}" >&2

sample_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
docker buildx build --platform "$platform" --tag "$repository:$tag" --push "$sample_dir" >&2
digest=$(aws --region "$region" ecr describe-images --repository-name "${repository#*/}" \
  --image-ids "imageTag=$tag" --query 'imageDetails[0].imageDigest' --output text)
if ! [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
  printf 'ECR did not return a digest for image tag %s.\n' "$tag" >&2
  exit 69
fi
printf '%s@%s\n' "$repository" "$digest"
