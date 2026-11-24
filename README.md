# Virginia Housing by ZIP Code

An interactive Vue application for comparing Virginia ZIP codes by home affordability, historical Zillow home-value growth, and Zillow home-value forecasts.

**Live site:** [virginia-housing.marshall.mortgage](https://virginia-housing.marshall.mortgage/)

## What it does

- Displays an interactive, zoomable, and draggable map of Virginia ZIP-code areas.
- Shows city, county, ZIP code, and relevant metrics when a map area is hovered.
- Opens ZIP-specific details when a map area is selected.
- Provides four single-page-app views:
  - **Home affordability** — estimates the monthly cost of buying the typical home in each ZIP and expresses it as a share of annual median household income.
  - **Historical home-value growth** — colors ZIP codes by five-year compound annual Zillow Home Value Index (ZHVI) growth and shows the complete available monthly price history after selection.
  - **Projected home-value growth** — colors ZIP codes using Zillow’s furthest available ZIP-level Home Value Forecast (ZHVF) horizon.
  - **Data sources & methodology** — explains the data, calculation assumptions, geographic limitations, and attribution.
- Includes a responsive hamburger menu, a ZIP-level home-value chart with hover date/value tooltips, accessibility labels, search metadata, `robots.txt`, sitemap, and a Virginia favicon.
- Includes a mortgage-lending call to action linking to Marshall Hawkins’ Rate.com profile.

## Affordability calculation

The affordability map uses the latest available ZIP-level ZHVI value, median household income, and an estimated effective property-tax rate. Visitors can adjust:

- 30-year fixed loan interest rate (default: **7.5%**)
- Down payment (minimum: **3.5%**, default: **20%**)
- Annual homeowners-insurance rate (default: **0.60%**)

Each ZIP’s estimated monthly payment includes principal and interest, property tax, insurance, and illustrative PMI when the down payment is below 20%:

| Down payment | Illustrative annual PMI rate |
| --- | --- |
| 3.5% to under 5% | 0.90% |
| 5% to under 10% | 0.60% |
| 10% to under 15% | 0.45% |
| 15% to under 20% | 0.23% |

The map color represents the estimated total monthly payment divided by the ZIP’s median monthly household income. These are planning estimates, not a loan quote or underwriting decision.

## Data

The app builds data for 852 Virginia ZIP codes from public sources:

- Zillow Research ZIP-level [ZHVI](https://www.zillow.com/research/data/) for monthly home values.
- Zillow Research ZIP-level ZHVF growth data for forecasts.
- Virginia ZIP geometry from the Virginia ArcGIS Open Data service.
- 2024 American Community Survey 5-Year estimates for median household income.
- Census Reporter ACS tables B25077 and B25103 for the estimated effective property-tax rate.

See [DATA_SOURCES.md](DATA_SOURCES.md) for source URLs, methodology, Zillow attribution, calculation definitions, and limitations. ZIP codes and Census ZIP Code Tabulation Areas (ZCTAs) are not identical, so some ZIPs have no published income or property-tax estimate and are shown as no-data areas.

### Refresh data

The refresh script downloads the latest Zillow ZIP-level ZHVI and forecast CSV files on every run, then recreates the application JSON and browser-facing copies.

```bash
./scripts/rebuild-data.sh
```

Raw source files are cached under `data/source-cache/`; generated files are written to `data/` and the browser-facing subset is copied to `public/data/`.

## Local development

### Requirements

- Node.js and npm
- Ruby (for the data build)
- Terraform and AWS CLI (for AWS deployment and access-log exports)

### Install and run

```bash
npm install
npm run dev
```

Build a production bundle with:

```bash
npm run build
```

## AWS architecture

Terraform in `infrastructure/terraform/` provisions:

- A private S3 website bucket served only through CloudFront.
- CloudFront, an ACM certificate, and Route 53 A/AAAA alias records for the live domain.
- An API Gateway HTTP endpoint and Node.js 22 `visit-logger` Lambda.
- The `virginia_home_logins` DynamoDB table with on-demand billing, point-in-time recovery, and 90-day TTL expiration.
- A private S3 export bucket, Node.js 22 `login-exporter` Lambda, and an IP-restricted API Gateway endpoint for CSV exports of visit records.

On page load, the frontend sends a background request to `POST /api/visit`. The logger stores the timestamp, request IP, user agent, CloudFront location headers, and `button_click: false`. Selecting the mortgage call-to-action writes a separate event with `button_click: true`.

## Deployment

Set the Route 53 hosted-zone ID for `marshall.mortgage` and the public IP CIDR allowed to request login CSV exports. A `/32` restricts export access to one IPv4 address.

```bash
export TF_VAR_hosted_zone_id="Z123EXAMPLE"
export TF_VAR_login_export_allowed_ip_cidr="$(curl -4 https://checkip.amazonaws.com | tr -d '\n')/32"
```

Deploy the application, Lambdas, Terraform resources, and CloudFront invalidation using:

```bash
AWS_PROFILE=zipcodes ./scripts/deploy-website.sh
```

The deployment script builds the Vue app, packages both Lambdas, runs Terraform, synchronizes `dist/` to S3, and invalidates the CloudFront distribution.

## Downloading visit logs

The export endpoint is intentionally separate from the public website and is restricted at API Gateway to `TF_VAR_login_export_allowed_ip_cidr`. From an approved IP address:

```bash
AWS_PROFILE=zipcodes ./scripts/download-login-export.sh
```

The command writes `virginia_home_logins.csv` at the project root by default. Pass a destination path as the first argument to choose a different file.

## Project structure

```text
src/                         Vue UI, Leaflet map behavior, and styling
public/                      Static browser assets, SEO files, and generated map data
scripts/rebuild-data.sh      Download and rebuild data snapshots
scripts/deploy-website.sh    Build, provision, upload, and invalidate CloudFront
scripts/download-login-export.sh
                             Retrieve an IP-restricted CSV export
lambda/visit-logger/         Public site visit logger Lambda
lambda/login-exporter/       Private login-table CSV export Lambda
infrastructure/terraform/    AWS infrastructure configuration
DATA_SOURCES.md              Detailed data-source and methodology documentation
```

## Attribution and disclaimer

Home-value and forecast data are provided by Zillow Group. Zillow data is used subject to Zillow’s applicable terms and attribution requirements. This application is informational only; it does not provide financial, legal, tax, insurance, or lending advice. Home values, forecasts, taxes, insurance, income estimates, and payment calculations can change and may not reflect a particular property or borrower.
