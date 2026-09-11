#!/usr/bin/env ruby
# frozen_string_literal: true

require 'csv'
require 'date'
require 'fileutils'
require 'json'
require 'net/http'
require 'uri'

work_dir, data_dir, public_data_dir = ARGV
abort 'Usage: rebuild-data.rb WORK_DIR DATA_DIR PUBLIC_DATA_DIR' unless public_data_dir

SOURCES = {
  boundaries: 'https://services7.arcgis.com/Zb4O2iaRvsbTmu4i/ArcGIS/rest/services/VA_ZipCodes/FeatureServer/0',
  zhvi: 'https://files.zillowstatic.com/research/public_csvs/zhvi/Zip_zhvi_uc_sfrcondo_tier_0.33_0.67_sm_sa_month.csv',
  forecast: 'https://files.zillowstatic.com/research/public_csvs/zhvf_growth/Zip_zhvf_growth_uc_sfrcondo_tier_0.33_0.67_sm_sa_month.csv',
  income: 'https://www.datahood.ai/assets/data/census_data_all_zipcode.csv',
  census_reporter: 'https://api.censusreporter.org/1.0/data/show/latest'
}.freeze

def zip_code(value)
  value.to_s[/\d{1,5}/]&.rjust(5, '0')
end

def number(value)
  return nil if value.nil? || value.to_s.strip.empty?
  Float(value)
rescue ArgumentError, TypeError
  nil
end

def date_column?(name)
  Date.iso8601(name.to_s)
  true
rescue Date::Error
  false
end

def first_present(*values)
  values.find { |value| !value.nil? && !value.to_s.strip.empty? }
end

def write_json(path, object)
  File.write(path, JSON.pretty_generate(object) + "\n")
end

def write_json_atomically(path, object)
  temporary_path = "#{path}.tmp"
  write_json(temporary_path, object)
  File.rename(temporary_path, path)
end

def fetch_json(url)
  uri = URI(url)
  3.times do |attempt|
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 90) do |http|
      http.get(uri.request_uri, 'User-Agent' => 'Virginia-Housing-Data-Refresh/1.0')
    end
    return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)
    raise "Census Reporter request failed: HTTP #{response.code}" if response.code.to_i.between?(400, 499)
    warn "Census Reporter attempt #{attempt + 1} failed: HTTP #{response.code}"
    sleep(attempt + 1)
  end
  raise 'Census Reporter request failed after three attempts.'
end

FileUtils.mkdir_p([data_dir, public_data_dir])
generated_on = Date.today.iso8601
boundaries = JSON.parse(File.read(File.join(work_dir, 'virginia-zip-boundaries.geojson')))
boundaries['features'].select! { |feature| feature.dig('properties', 'STATE') == 'VA' }
boundaries['features'].each { |feature| feature['properties']['ZIP_CODE'] = zip_code(feature.dig('properties', 'ZIP_CODE')) }
boundaries['features'].sort_by! { |feature| feature.dig('properties', 'ZIP_CODE') }
zip_codes = boundaries['features'].map { |feature| feature.dig('properties', 'ZIP_CODE') }.compact.uniq.sort
place_by_zip = boundaries['features'].to_h { |feature| [feature.dig('properties', 'ZIP_CODE'), feature.dig('properties', 'PO_NAME')] }
puts "Building records for #{zip_codes.length} Virginia ZIP codes..."

# 2024 ACS household income and location labels from the public Datahood bulk file.
census_by_zip = {}
CSV.foreach(File.join(work_dir, 'census-data-all-zipcode.csv'), headers: true, encoding: 'bom|utf-8') do |row|
  next unless row['state_code'] == 'VA'
  zip = zip_code(row['zipcode'])
  next unless zip_codes.include?(zip)
  census_by_zip[zip] = {
    city: row['city_name'], county_name: row['primary_county_name'],
    median_household_income: number(row['income_median_household_income_est'])
  }
end

# Preserve every published monthly ZHVI value for the price-history chart.
zhvi_rows = {}
CSV.foreach(File.join(work_dir, 'zillow-zhvi-va.csv'), headers: true, encoding: 'bom|utf-8') do |row|
  next unless row['StateName'] == 'VA'
  zip = zip_code(row['RegionName'])
  next unless zip_codes.include?(zip)
  monthly = row.headers.filter { |header| date_column?(header) }.to_h do |header|
    [header, number(row[header])]
  end.compact
  zhvi_rows[zip] = { region_name: row['RegionName'], city: row['City'], county_name: row['CountyName'], monthly_zhvi: monthly }
end

metadata_for = lambda do |zip, zillow_row = nil|
  census = census_by_zip[zip] || {}
  {
    city: first_present(zillow_row&.dig(:city), census[:city], place_by_zip[zip]),
    county_name: first_present(zillow_row&.dig(:county_name), census[:county_name])
  }
end

history_records = zip_codes.to_h do |zip|
  row = zhvi_rows[zip]
  labels = metadata_for.call(zip, row)
  monthly = row ? row[:monthly_zhvi] : {}
  [zip, {
    'zip_code' => zip, 'region_name' => row ? row[:region_name] : zip, 'city' => labels[:city],
    'county_name' => labels[:county_name], 'state' => 'VA', 'monthly_zhvi' => monthly,
    'data_status' => monthly.empty? ? 'not_published_by_zillow' : 'published'
  }]
end

history_document = {
  'dataset' => 'Zillow Home Value Index (ZHVI)',
  'description' => 'Monthly smoothed, seasonally adjusted, mid-tier typical home values for all homes (single-family residences and condo/co-ops).',
  'geography' => 'Virginia ZIP codes', 'source' => SOURCES[:zhvi], 'downloaded_on' => generated_on,
  'zip_codes_requested' => zip_codes.length,
  'zip_codes_with_data' => history_records.values.count { |record| record['data_status'] == 'published' },
  'zip_codes_without_data' => history_records.values.count { |record| record['data_status'] != 'published' },
  'zip_code_data' => history_records
}

# Keep every forecast horizon; the SPA picks the furthest horizon for the map.
forecast_rows = {}
forecast_dates = []
CSV.foreach(File.join(work_dir, 'zillow-zhvf-growth-va.csv'), headers: true, encoding: 'bom|utf-8') do |row|
  next unless row['StateName'] == 'VA'
  zip = zip_code(row['RegionName'])
  next unless zip_codes.include?(zip)
  horizons = row.headers.filter { |header| date_column?(header) }.to_h { |header| [header, number(row[header])] }.compact
  forecast_dates.concat(horizons.keys)
  forecast_rows[zip] = { region_name: row['RegionName'], city: row['City'], county_name: row['CountyName'], base_date: row['BaseDate'], horizons: horizons }
end

forecast_records = zip_codes.to_h do |zip|
  row = forecast_rows[zip]
  labels = metadata_for.call(zip, row)
  horizons = row ? row[:horizons] : {}
  [zip, {
    'zip_code' => zip, 'region_name' => row ? row[:region_name] : zip, 'city' => labels[:city],
    'county_name' => labels[:county_name], 'state' => 'VA', 'base_date' => row&.dig(:base_date),
    'forecast_growth_percent' => horizons, 'data_status' => horizons.empty? ? 'not_published_by_zillow' : 'published'
  }]
end

forecast_document = {
  'dataset' => 'Zillow Home Value Forecast (ZHVF) Growth',
  'description' => 'Zillow forecasted percentage change in the all-homes, mid-tier Zillow Home Value Index. Forecast horizons are measured from the listed base date.',
  'geography' => 'Virginia ZIP codes', 'source' => SOURCES[:forecast], 'downloaded_on' => generated_on,
  'forecast_base_date' => forecast_records.values.map { |record| record['base_date'] }.compact.uniq.sort,
  'forecast_horizon_end_dates' => forecast_dates.uniq.sort, 'units' => 'percent', 'zip_codes_requested' => zip_codes.length,
  'zip_codes_with_data' => forecast_records.values.count { |record| record['data_status'] == 'published' },
  'zip_codes_without_data' => forecast_records.values.count { |record| record['data_status'] != 'published' },
  'zip_code_data' => forecast_records
}

# Property tax is calculated from 2024 ACS medians. Census Reporter gives the
# values at the ZCTA geography, so ZIP codes without a matching ZCTA remain
# unavailable instead of receiving a misleading proxy rate.
tax_cache_path = File.join(work_dir, 'census-reporter-property-tax-cache.json')
tax_by_zip = if File.exist?(tax_cache_path)
               JSON.parse(File.read(tax_cache_path)).to_h do |zip, values|
                 [zip, { home_value: values['home_value'], taxes_paid: values['taxes_paid'] }]
               end
             else
               {}
             end
# A USPS ZIP is not always an ACS ZCTA. When a mixed batch includes a ZIP that
# Census Reporter does not recognize, split it until the unavailable ZIP can be
# recorded explicitly instead of aborting the entire refresh.
fetch_tax_batch = nil
fetch_tax_batch = lambda do |batch|
  geo_ids = batch.map { |zip| "86000US#{zip}" }.join(',')
  url = "#{SOURCES[:census_reporter]}?table_ids=B25077,B25103&geo_ids=#{URI.encode_www_form_component(geo_ids)}"
  begin
    payload = fetch_json(url)
    batch.each do |zip|
      estimate = payload.dig('data', "86000US#{zip}")
      tax_by_zip[zip] = {
        home_value: number(estimate&.dig('B25077', 'estimate', 'B25077001')),
        taxes_paid: number(estimate&.dig('B25103', 'estimate', 'B25103001'))
      }
    end
  rescue RuntimeError
    if batch.length == 1
      tax_by_zip[batch.first] = { home_value: nil, taxes_paid: nil }
    else
      midpoint = (batch.length / 2.0).ceil
      fetch_tax_batch.call(batch.take(midpoint))
      fetch_tax_batch.call(batch.drop(midpoint))
    end
  end
  write_json_atomically(tax_cache_path, tax_by_zip)
end

# Census Reporter accepts moderate request batches; successful results are
# checkpointed, making the script safe to rerun after a network interruption.
zip_codes.each_slice(30).with_index do |batch, index|
  batch = batch.reject { |zip| tax_by_zip.key?(zip) }
  next if batch.empty?
  puts "Fetching property-tax batch #{index + 1}..."
  fetch_tax_batch.call(batch)
end

income_records = zip_codes.to_h do |zip|
  labels = metadata_for.call(zip, zhvi_rows[zip])
  income = census_by_zip.dig(zip, :median_household_income)
  [zip, {
    'zip_code' => zip, 'city' => labels[:city], 'county_name' => labels[:county_name], 'state' => 'VA',
    'median_household_income' => income&.round,
    'data_status' => income&.positive? ? 'available' : 'unavailable'
  }]
end

income_document = {
  'dataset' => 'Median household income by ZIP Code Tabulation Area',
  'dataset_vintage' => '2024 ACS 5-Year Estimates', 'coverage_period' => '2020-2024', 'currency_year' => 2024,
  'geography' => 'Virginia ZIP codes', 'source' => SOURCES[:income],
  'source_note' => 'Datahood bulk file sourced from the American Community Survey 2024 5-Year Estimates; field income_median_household_income_est corresponds to ACS table B19013.',
  'downloaded_on' => generated_on, 'zip_codes_requested' => zip_codes.length,
  'zip_codes_with_data' => income_records.values.count { |record| record['data_status'] == 'available' },
  'zip_codes_without_data' => income_records.values.count { |record| record['data_status'] != 'available' },
  'zip_code_data' => income_records
}

tax_records = zip_codes.to_h do |zip|
  labels = metadata_for.call(zip, zhvi_rows[zip])
  values = tax_by_zip[zip] || {}
  rate = values[:home_value]&.positive? && values[:taxes_paid] ? values[:taxes_paid] / values[:home_value] : nil
  [zip, {
    'zip_code' => zip, 'city' => labels[:city], 'county_name' => labels[:county_name], 'state' => 'VA',
    'median_owner_occupied_home_value' => values[:home_value]&.round,
    'median_real_estate_taxes_paid' => values[:taxes_paid]&.round,
    'estimated_effective_property_tax_rate' => rate,
    'estimated_effective_property_tax_percent' => rate && rate * 100,
    'data_status' => rate ? 'available' : 'unavailable'
  }]
end

tax_document = {
  'dataset' => 'Estimated effective property tax rate by ZIP Code Tabulation Area',
  'dataset_vintage' => '2024 ACS 5-Year Estimates', 'coverage_period' => '2020-2024', 'geography' => 'Virginia ZIP codes',
  'calculation' => 'median real-estate taxes paid / median owner occupied home value',
  'important_note' => 'This is an estimate based on ACS medians, not a jurisdictional statutory tax rate. ZIP codes can cross local tax jurisdictions.',
  'source' => SOURCES[:census_reporter], 'source_tables' => ['B25077', 'B25103'], 'downloaded_on' => generated_on,
  'zip_codes_requested' => zip_codes.length,
  'zip_codes_with_data' => tax_records.values.count { |record| record['data_status'] == 'available' },
  'zip_codes_without_data' => tax_records.values.count { |record| record['data_status'] != 'available' },
  'zip_code_data' => tax_records
}

affordability_records = zip_codes.to_h do |zip|
  history = history_records[zip]
  latest_date, latest_value = history['monthly_zhvi'].to_a.last
  income = income_records[zip]['median_household_income']
  rate = tax_records[zip]['estimated_effective_property_tax_rate']
  complete = latest_value && income && rate
  [zip, {
    'zip_code' => zip, 'city' => history['city'], 'county_name' => history['county_name'],
    'home_value' => complete ? latest_value : nil, 'home_value_date' => complete ? latest_date : nil,
    'median_household_income' => complete ? income : nil, 'effective_property_tax_rate' => complete ? rate : nil,
    'data_status' => complete ? 'available' : 'unavailable'
  }]
end

affordability_document = {
  'dataset' => 'Virginia ZIP home affordability inputs',
  'description' => 'Latest Zillow Home Value Index, ACS median household income, and ACS-derived effective property tax rate used for the home-affordability calculator.',
  'downloaded_on' => generated_on, 'zip_codes_requested' => zip_codes.length,
  'zip_codes_with_complete_inputs' => affordability_records.values.count { |record| record['data_status'] == 'available' },
  'zip_codes_without_complete_inputs' => affordability_records.values.count { |record| record['data_status'] != 'available' },
  'zip_code_data' => affordability_records
}

# The map displays a five-year compound annual rate. A separate one-year rate
# remains available for compatibility with the historical-record metadata.
metadata_records = history_records.to_h do |zip, record|
  monthly = record['monthly_zhvi'].sort.to_h
  latest_date = monthly.keys.last
  latest_value = latest_date && monthly[latest_date]
  one_year_date = latest_date && (Date.parse(latest_date) << 12).iso8601
  five_year_date = latest_date && (Date.parse(latest_date) << 60).iso8601
  one_year_value = monthly[one_year_date]
  five_year_value = monthly[five_year_date]
  one_year_rate = latest_value && one_year_value ? latest_value / one_year_value - 1 : nil
  five_year_rate = latest_value && five_year_value ? (latest_value / five_year_value)**(1.0 / 5) - 1 : nil
  [zip, {
    'zip_code' => zip, 'city' => record['city'], 'county_name' => record['county_name'],
    'annualized_growth_rate' => one_year_rate, 'growth_period_end' => latest_date,
    'data_status' => five_year_rate ? 'available' : 'unavailable',
    'five_year_average_annual_growth_rate' => five_year_rate,
    'five_year_growth_period_start' => five_year_rate ? five_year_date : nil
  }]
end

metadata_document = {
  'metric' => 'Annualized Zillow Home Value Index growth rate',
  'calculation' => 'The map rate is the compound annual growth rate between the latest published value and the value from the same month five years earlier.',
  'zip_codes' => metadata_records,
  'map_metric' => 'Five-year average annual home-value growth',
  'map_calculation' => '(latest ZHVI / ZHVI five years earlier)^(1/5) - 1'
}

outputs = {
  'virginia-zip-codes.json' => { 'state' => 'VA', 'zip_codes' => zip_codes },
  'virginia-zillow-monthly-home-values.json' => history_document,
  'virginia-zillow-home-value-forecast.json' => forecast_document,
  'virginia-median-household-income.json' => income_document,
  'virginia-effective-property-tax-rate.json' => tax_document,
  'virginia-home-affordability-data.json' => affordability_document,
  'zip-metadata.json' => metadata_document,
  'virginia-zip-boundaries.geojson' => boundaries
}
outputs.each { |filename, document| write_json(File.join(data_dir, filename), document) }

%w[
  virginia-zillow-monthly-home-values.json
  virginia-zillow-home-value-forecast.json
  virginia-home-affordability-data.json
  zip-metadata.json
  virginia-zip-boundaries.geojson
].each do |filename|
  FileUtils.cp(File.join(data_dir, filename), File.join(public_data_dir, filename))
end

puts "Created #{outputs.length} data files and updated public/data/."
