#!/usr/bin/env bash
# Download a CSV export from the IP-restricted login-export API.
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_dir="${project_dir}/infrastructure/terraform"
destination="${1:-${project_dir}/virginia_home_logins.csv}"

endpoint="$(terraform -chdir="${terraform_dir}" output -raw login_export_endpoint)"
response="$(curl --fail --silent --show-error --request POST "${endpoint}")"
download_url="$(node -e 'const input = JSON.parse(process.argv[1]); if (!input.download_url) process.exit(1); process.stdout.write(input.download_url)' "${response}")"
record_count="$(node -e 'const input = JSON.parse(process.argv[1]); process.stdout.write(String(input.record_count ?? "unknown"))' "${response}")"

curl --fail --location --silent --show-error --output "${destination}" "${download_url}"
echo "Downloaded ${record_count} records to ${destination}"
