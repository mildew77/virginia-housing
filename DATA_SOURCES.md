# Virginia ZIP Home-Value Map — Data Sources

This project combines public ZIP, housing, income, and property-tax data. Unless otherwise noted, the files are snapshots downloaded on September 4, 2026.

## Geographic boundaries and ZIP list

### Virginia ZIP list

**File:** `virginia-zip-codes.json`

The project ZIP list was produced from the public **VA_ZipCodes** ArcGIS Feature Service. The service describes five-digit ZIP Code areas for Virginia and attributes the data to the U.S. Postal Service.

- Service: <https://services7.arcgis.com/Zb4O2iaRvsbTmu4i/ArcGIS/rest/services/VA_ZipCodes/FeatureServer/0>
- Geographic coverage: Virginia ZIP Code areas
- Records in the project list: 852 five-digit ZIP codes

### Map boundary geometry

**File:** `public/data/virginia-zip-boundaries.geojson`

The interactive map uses the same Virginia ZIP boundary service. Its geometry was generalized before inclusion to keep browser loading fast. Generalization changes visual detail only; ZIP identifiers and attributes are retained.

### City and county labels

ZIP city and county labels primarily come from Zillow’s ZIP-level data. Where Zillow did not supply a label, the project supplements place/county information with the [GeoNames United States postal-code dataset](https://download.geonames.org/export/zip/US.zip) and the Virginia ZIP boundary service.

## Zillow home values and price history

**Files:**

- `virginia-zillow-monthly-home-values.json`
- `public/data/virginia-zillow-monthly-home-values.json`
- `public/data/zip-metadata.json`

Monthly home values are from Zillow Research’s **Zillow Home Value Index (ZHVI)** ZIP-level download.

- Zillow Research data portal: <https://www.zillow.com/research/data/>
- ZIP-level source CSV: <https://files.zillowstatic.com/research/public_csvs/zhvi/Zip_zhvi_uc_sfrcondo_tier_0.33_0.67_sm_sa_month.csv>
- Measure: all homes (single-family residences and condo/co-ops), mid-tier, smoothed, seasonally adjusted ZHVI
- Meaning: Zillow’s estimate of a typical home value; it is not a median closed-sale price.

The map’s growth colors use the five-year annualized growth rate:

```text
(latest monthly ZHVI ÷ ZHVI from the same month five years earlier)^(1/5) − 1
```

The clicked-ZIP chart shows all available monthly ZHVI observations for that ZIP.

## Zillow projected home-value growth

**Files:**

- `virginia-zillow-home-value-forecast.json`
- `public/data/virginia-zillow-home-value-forecast.json`

Projected growth is from Zillow Research's ZIP-level **Zillow Home Value Forecast (ZHVF) Growth** download.

- ZIP-level source CSV: <https://files.zillowstatic.com/research/public_csvs/zhvf_growth/Zip_zhvf_growth_uc_sfrcondo_tier_0.33_0.67_sm_sa_month.csv>
- Measure: forecasted percentage change in the all-homes, mid-tier Zillow Home Value Index
- Base date in this snapshot: July 31, 2026
- Available forecast dates: August 31, 2026; October 31, 2026; and July 31, 2027

ZHVF is Zillow's model-based forecast, not a guarantee of future home values. The dataset's values are percentages: for example, `1.5` represents a projected 1.5% change from the base date to the stated forecast date.

According to Zillow, its forecast model is trained on past market behavior and incorporates housing indicators—including mortgage interest rates, property taxes, construction costs, vacancies, delinquency rates, and homes for sale—plus economic indicators such as household income, population growth, and unemployment. See [Zillow Home Value Forecasts](https://zillow.zendesk.com/hc/en-us/articles/203512180-Zillow-Home-Value-Forecasts) for Zillow's explanation.

## Median household income

**File:** `virginia-median-household-income.json`

Median household income estimates use the **2024 American Community Survey (ACS) 5-Year Estimates**, covering 2020–2024 and expressed in 2024 inflation-adjusted dollars.

- Underlying Census table: [B19013](https://data.census.gov/table/ACSDT5Y2024.B19013), Median Household Income in the Past 12 Months
- Census variable: [B19013_001E](https://api.census.gov/data/2024/acs/acs5/variables/B19013_001E.html)
- Bulk ZIP/ZCTA download used: <https://www.datahood.ai/assets/data/census_data_all_zipcode.csv>

The bulk download identifies its source as the Census Bureau’s 2024 ACS 5-Year release. The JSON preserves no-data records where the requested USPS ZIP has no corresponding Census estimate.

## Effective property-tax-rate estimate

**File:** `virginia-effective-property-tax-rate.json`

This file contains an **estimated effective property-tax rate**, calculated as:

```text
median real-estate taxes paid ÷ median owner-occupied home value
```

Both inputs are from the 2024 ACS 5-Year release (2020–2024), retrieved through the public [Census Reporter API](https://api.censusreporter.org/1.0/data/show/latest):

- [B25077](https://data.census.gov/table/ACSDT5Y2024.B25077): Median Value of Owner-Occupied Housing Units
- [B25103](https://data.census.gov/table/ACSDT5Y2024.B25103): Median Real Estate Taxes Paid

This is not a statutory tax rate. It is a ZIP/ZCTA-level tax-burden estimate and does not account for special districts, exemptions, assessment practices, or differences between assessed and market values. Virginia statutory real-estate rates are set locally by cities, counties, towns, and sometimes special districts; see [Virginia Tax local tax rates](https://www.tax.virginia.gov/local-tax-rates).

## Home-affordability calculator

**Files:**

- `virginia-home-affordability-data.json`
- `public/data/virginia-home-affordability-data.json`

This application-ready file combines the latest ZIP-level ZHVI value with the ACS median household income and estimated effective property-tax rate described above. The calculator estimates a 30-year fixed-rate payment using the user-entered interest rate and down payment, then adds monthly property tax and homeowner's insurance.

For down payments below 20%, the calculator also includes an **estimated PMI** charge based on this illustrative annual-rate grid: 3.5–5% down = 0.90%; 5–10% = 0.60%; 10–15% = 0.45%; and 15–20% = 0.23%. PMI is calculated from the starting loan amount. Actual PMI pricing is lender-, loan-, credit-, and property-specific; this grid is a modeling assumption, not sourced ZIP-level data or a lender quote.

## ZIP Codes and Census ZCTAs

USPS ZIP Codes and Census ZIP Code Tabulation Areas (ZCTAs) are not identical geographies. ACS income and tax data are published for ZCTAs, which are Census statistical approximations of ZIP Code service areas. PO-box-only, single-address, and other non-geographic ZIPs may not have a matching ZCTA or ACS estimate.

For background, see the Census Bureau’s [ZCTA guidance](https://www.census.gov/programs-surveys/geography/guidance/geo-areas/zctas.html).

## Production access logging

On a production page load, the site sends a single background request to its AWS Lambda access logger. The logger stores the access timestamp, IP address, user agent, and approximate country, region, city, postal-code, latitude/longitude, and time-zone information supplied by CloudFront in the `virginia_home_logins` DynamoDB table. DynamoDB TTL automatically removes records after 90 days.
