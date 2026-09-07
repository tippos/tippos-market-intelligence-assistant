# Google Trends export — US tipping terms, 2021-09-08 to 2026-09-08

Manual export reviewed and filed on 2026-09-08. These files are the raw Google
Trends CSVs exactly as downloaded; nothing here has been edited, merged or
re-scaled. The written reading of them is
[docs/us-search-demand-2026-09.md](../../../../docs/us-search-demand-2026-09.md).

## Export parameters

| Field | Value |
|---|---|
| Comparison terms | `how much to tip`, `tip calculator`, `split tip`, `tip with card` (all "Search term") |
| Geography | United States |
| Period | Past 5 years (2021-09-08 – 2026-09-08) |
| Category | All categories |
| Search type | Web Search |

Average interest over the period, as reported by Trends: `how much to tip` 64,
`tip calculator` 69, `split tip` 2, `tip with card` 3.

## Files

| File | Dataset | SHA-256 |
|---|---|---|
| `interest-by-subregion_us-states.csv` | Interest by subregion, 51 US states + DC | `e61b325287467ab6ef92740070181c56c691943902a4c11d9983411b62986ff9` |
| `interest-by-metro_us-dma.csv` | Interest by metro, 208 US DMAs | `2c3eeda9807f4f23c7054b74cec3309816e929e6a445e3f672032c8f76a00003` |
| `related-queries_top_how-much-to-tip.csv` | Top related queries for `how much to tip` | `5ac399f0558ac6bb23a172154dc7baeb4dc9167b775b5f09fa1920383fc05c05` |
| `related-queries_top_tip-calculator.csv` | Top related queries for `tip calculator` | `e00fc1c4c686d70670b4b7dd003010970f55af4377ac721d640e0999c493445a` |
| `related-queries_rising_tip-calculator.csv` | Rising related queries for `tip calculator` | `56b68dec3257176266b0bbe1594fbd3de16adf4726c0d688c2126c812bbe2641` |

## How to read these numbers

- Every value is a **relative index, never a search count.** Trends gives no
  absolute volume, so nothing here may be reported as searches per month,
  market size, or competitor traffic.
- Both regional files are a **share between the two head terms only.** Hawaii's
  `66 / 34` means that of the combined interest in those two terms in Hawaii,
  66% went to `how much to tip` — it does not mean Hawaii searches more than
  another state.
- `split tip` and `tip with card` have **no column in either regional file.**
  Google dropped them for insufficient data at that granularity, which is
  itself the finding: at US scale those two phrasings are close to noise.
- Related-query files list queries also searched by people who searched the
  parent term, so calculator-adjacent queries (`google calculator`,
  `percent calculator`) appear for `tip calculator` and are not tipping demand.
- `increase percent` is Google's own change figure for the period. Treat the
  extremes as artifacts: `tip calculator 2022` at `4,000%` is a dated query
  rising off a near-zero base, not a real trend.

## Not exported

Filed so the next pass knows what is still missing, rather than inferring it:

- **Interest over time** (the `multiTimeline` CSV) for the 4-term comparison.
  The shape of the two head-term lines is currently known only from a
  screenshot taken on 2026-09-08: `tip calculator` declining from its early-2022
  peak while `how much to tip` rises and overtakes it late in the period. That
  crossover is the single most decision-relevant fact in this export and it is
  not yet backed by a file.
- **Rising related queries for `how much to tip`.** Only the top list was
  exported; the rising list for that term is the other half of the picture.
- Any export for `split tip` or `tip with card` on their own axis, which is the
  only way to see whether their small 2026 uptick is real.
