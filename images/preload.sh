#!/usr/bin/env bash
# Copy the benchmark images (linux/amd64 only) into ECR under bench/* and write images.json.
# The ECR repos are created by terraform/infra; apply it first.
# Uses the default AWS credential chain.
set -euo pipefail
cd "$(dirname "$0")"
REGION="${AWS_REGION:-us-east-1}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
ECR="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

# Keep ECR credentials out of the operator's ~/.docker/config.json.
DOCKER_CONFIG="$(mktemp -d)"; export DOCKER_CONFIG
trap 'rm -rf "$DOCKER_CONFIG"' EXIT
aws --region "$REGION" ecr get-login-password \
  | crane auth login "$ECR" -u AWS --password-stdin

grep -vE '^\s*(#|$)' images.txt | while read -r cls src repo; do
  digest="$(crane digest --platform linux/amd64 "$src")"
  echo "copy [$cls] $src@$digest -> $ECR/$repo:bench"
  crane copy --platform linux/amd64 "$src@$digest" "$ECR/$repo:bench"
done

python3 describe.py --registry "$ECR" --tag bench images.txt > images.json
jq -r '.images[] | "\(.class)\t\(.repo)\t\(.size / 1e6 | floor) MB\t\(.layers) layers\t\(.digest)"' images.json
