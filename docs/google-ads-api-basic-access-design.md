# tippos Market Intelligence - Google Ads API Design

## Purpose

tippos is building an internal market-intelligence workflow for its own product and SEO decision-making. The workflow will research aggregate Google Search demand for tip-calculator and tipping-related topics in US English. It is not a public keyword tool, a customer-facing product, or an advertising-management service for other businesses.

## Intended users and access

Only authorized tippos employees and contractors who support product, SEO, or market research will use the internal workspace. External users, clients, advertisers, and the general public will not receive access to the API tool, developer token, credentials, or raw Google Ads API results.

## API use

The planned integration uses Google Ads API keyword-planning services for internal research:

- Generate keyword ideas from a small, topic-specific seed set.
- Treat ideas as unmeasured candidates, subject to internal review.
- Request historical keyword metrics only for the reviewed list, targeted to the United States, English, and Google Search.
- Store returned aggregate metrics with their month, geography, language, network, canonical keyword, and close-variant metadata.

The workflow does not create, modify, or optimize Google Ads campaigns, budgets, bids, ads, audiences, conversion tracking, or remarketing. It does not automate advertising for any third party.

## Data handling and safeguards

The integration records only aggregate keyword metrics returned by Google Ads API. It is not designed to collect personal data, user-level search histories, or Google Ads account performance data. API credentials are held as server-side secrets and are not exposed in the internal browser interface.

Keyword ideas are clearly labelled as candidates rather than evidence. A keyword becomes measured market evidence only when Google Ads returns historical metrics for it. Empty provider responses do not activate a source or become a success claim. Results retain provider limitations, including approximate volume, monthly refresh timing, and close-variant aggregation.

## System design

1. An authorized internal user starts a server-side research run.
2. The server authenticates to Google Ads API with a service account and the tippos developer token.
3. A discovery stage may retrieve candidate phrases; it does not write measured metrics.
4. A measurement stage requests historical metrics for an approved, bounded list.
5. Returned results are validated, deduplicated, and stored in the separate tippos Market Intelligence Supabase project.
6. Internal users review aggregate research outputs to inform product and SEO decisions.

## Operational controls

- No external-user access and no third-party advertiser management.
- Production use begins only after the developer token has the required approved access and permissible use for keyword research.
- Requests are rate limited and retried conservatively.
- Research is refreshed monthly rather than used as real-time reporting.
- The implementation maintains an audit trail of source, collection time, and provider limitations.

## Current rollout state

The integration design and validation are prepared, but the Google Ads credential connection is not deployed. No Google Ads API keyword metrics have been imported into the market-intelligence database as of this document.
