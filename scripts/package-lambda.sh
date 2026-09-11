#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"

package_lambda() {
  local lambda_dir="$1"
  local zip_name="$2"
  cd "$lambda_dir"
  npm install --omit=dev
  rm -f "$zip_name"
  zip -qr "$zip_name" index.mjs package.json node_modules
}

package_lambda "$project_dir/lambda/visit-logger" function.zip
package_lambda "$project_dir/lambda/login-exporter" function.zip
