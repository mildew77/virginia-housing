#!/usr/bin/env bash
# Rebuild the Virginia ZIP housing-data snapshots used by the application.
# Sources are documented in DATA_SOURCES.md. Generated files go to data/ and
# browser-facing copies are placed in public/data/.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${script_dir}/.." && pwd)"
data_dir="${project_dir}/data"
public_data_dir="${project_dir}/public/data"
# Keeping raw source files makes reruns fast and makes the generated records
# auditable. Delete data/source-cache/ to force a fresh download.
work_dir="${data_dir}/source-cache"
mkdir -p "${data_dir}" "${public_data_dir}" "${work_dir}"

download() {
  local url="$1" destination="$2"
  if [[ -s "${destination}" ]]; then
    echo "Using cached $(basename "${destination}")..."
    return
  fi
  echo "Downloading $(basename "${destination}")..."
  curl --fail --location --retry 3 --retry-delay 2 --output "${destination}" "${url}"
}

download 'https://services7.arcgis.com/Zb4O2iaRvsbTmu4i/ArcGIS/rest/services/VA_ZipCodes/FeatureServer/0/query?where=1%3D1&outFields=ZIP_CODE%2CPO_NAME%2CSTATE&returnGeometry=true&geometryPrecision=5&maxAllowableOffset=0.0001&f=geojson' "${work_dir}/virginia-zip-boundaries.geojson"
download 'https://files.zillowstatic.com/research/public_csvs/zhvi/Zip_zhvi_uc_sfrcondo_tier_0.33_0.67_sm_sa_month.csv' "${work_dir}/zillow-zhvi.csv"
download 'https://files.zillowstatic.com/research/public_csvs/zhvf_growth/Zip_zhvf_growth_uc_sfrcondo_tier_0.33_0.67_sm_sa_month.csv' "${work_dir}/zillow-zhvf-growth.csv"
download 'https://www.datahood.ai/assets/data/census_data_all_zipcode.csv' "${work_dir}/census-data-all-zipcode.csv"

# Zillow's national CSVs are large. Extracting Virginia rows before Ruby parses
# them makes a refresh substantially faster while retaining the original CSVs
# as the auditable source cache.
for source in zillow-zhvi zillow-zhvf-growth; do
  state_file="${work_dir}/${source}-va.csv"
  if [[ ! -s "${state_file}" ]]; then
    awk -F',' 'NR == 1 || $5 == "VA"' "${work_dir}/${source}.csv" > "${state_file}"
  fi
done

ruby "${script_dir}/rebuild-data.rb" "${work_dir}" "${data_dir}" "${public_data_dir}"
echo "Finished. Rebuilt JSON records are in ${data_dir}."
