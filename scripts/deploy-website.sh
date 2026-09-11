#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
terraform_dir="$project_dir/infrastructure/terraform"
: "${TF_VAR_hosted_zone_id:?Set TF_VAR_hosted_zone_id to the Route 53 hosted zone ID for marshall.mortgage.}"
cd "$project_dir"
npm run build
"$project_dir/scripts/package-lambda.sh"
cd "$terraform_dir"
terraform init
terraform apply
bucket_name="$(terraform output -raw website_bucket_name)"
distribution_id="$(terraform output -raw cloudfront_distribution_id)"
cd "$project_dir"
aws s3 sync dist/ "s3://$bucket_name" --delete
aws cloudfront create-invalidation --distribution-id "$distribution_id" --paths '/*'
