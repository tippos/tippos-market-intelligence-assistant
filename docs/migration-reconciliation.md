# Market Intelligence migration reconciliation

## Current status

The standalone Supabase project `irprsggvvfxakctlotga` is an internal, pre-launch
marketing-intelligence system. It contains no tippos payment or customer data.

Reconciliation and deployment completed on 2026-07-24:

- All 22 checked-in migration versions match the hosted migration history.
- The historical SERP version `20260723021447` was repaired once as `applied`;
  its SQL was not re-run after the later cleanup.
- The four forward migrations were applied in order:
  - `20260724111500_google_ads_keyword_planner`
  - `20260724190745_reconcile_market_intelligence_remote_schema`
  - `20260724191056_preserve_remote_reference_evidence`
  - `20260724210000_market_intelligence_strategy_access_guard`
- `supabase db push --dry-run` now reports that the remote database is up to date.
- All five Market Intelligence Edge Functions are active.
- The private strategy-assistant Storage object matches the checked-in hardened HTML.

## Historical SERP exception

`20260723021447_ingest_2026_tipping_serp_research.sql` had been executed before
the later production-data cleanup, but its version was absent from migration
history. A pre-change fingerprint confirmed the intended post-cleanup state:
one keyword, one topic link, four domains, three brands, one snapshot, four
items, one raw observation, eight evidence rows, and zero keyword variants.

The exact command applied was:

```powershell
supabase migration repair 20260723021447 --status applied --linked
```

This changed migration tracking only. Do not run this migration again on the
current project. On a new blank database it remains in its timestamp order
before `20260723174230_remove_fabricated_market_intelligence_data`, so the later
cleanup removes its unmeasured keyword variants.

## Preserved data

Before the change, a compact data fingerprint and the hosted Storage object were
backed up outside the repository. Post-change verification confirmed:

| Data | Before | After |
|---|---:|---:|
| `strategy_history` | 13 rows, MD5 `30ab85ada88f038cb52edc1b20c65859` | unchanged |
| `languages` | 23 rows, MD5 `dc150f36c41baba949d48ee5e673c294` | unchanged |
| `market_evidence` | 50 rows | 50 rows |
| `raw_observations` | 3 rows, MD5 `c5f255cbe377b9328f6c5add9f030cc1` | unchanged |
| `keywords` | 11 rows | unchanged |
| SERP snapshots/items | 1 / 4 rows | unchanged |

The evidence hash changed only because five known UTF-8 double-encoded publisher
or title values were corrected with exact byte predicates. The resulting values
include `Presidência da República`, `março`, and `Banco de España`.

The reproducible migration snapshot contains 23 languages and 50 reviewed
`market_evidence` rows. It deliberately excludes the 13 runtime
`strategy_history` rows.

## Runtime state

Five scheduled jobs are active:

| Job | Schedule (UTC) |
|---|---|
| `tippos-mi-cleanup-weekly` | `15 3 * * 0` |
| `tippos-mi-score-previous-month` | `0 4 1 * *` |
| `tippos-mi-gsc-keywords-daily` | `30 8 * * *` |
| `tippos-mi-google-ads-monthly` | `15 9 2 * *` |
| `tippos-mi-strategy-access-cleanup` | `35 3 * * *` |

All five Edge Functions are active. `market-intelligence-google-ads-sync` has
JWT verification enabled, but the required Google Ads secrets are not present
and its source remains `disabled_pending_credentials`. Do not describe it as
collecting live demand data until a successful authenticated import creates
verified rows.

The private strategy assistant has its access-code digest, rate-limit salt, and
allowed origin configured as hosted secrets. A live authenticated history
request returned HTTP 200 with all 13 existing strategy records and the exact
configured CORS origin. The resulting audit row contains only a 64-character
client hash, action, outcome, and timestamp; no raw client address is stored.
The plaintext internal access code is retained outside the repository.

The strategy access table has RLS enabled and no direct table grants to
`anon`, `authenticated`, or `service_role`. Its two `SECURITY DEFINER` RPCs are
granted only to `service_role`, perform an internal role check, and the
reservation path uses an advisory transaction lock.

## Storage object

Database migrations preserve the bucket metadata, not object bytes. The old
hosted `index.html` was backed up before replacement:

- Previous object: 11,767 bytes, MD5 `b31a0fb26de862563c258970757da242`.
- Current hosted and checked-in object: 15,877 bytes, MD5
  `0ce960237ff9b1eb1af4004f5200a2a9`.

The current object is an exact byte match with
`tools/tippos-us-strategy-assistant.html`, contains `noindex` directives, and
still requires the private strategy access code.

## Verification record

The applied state passed:

- `npm run check`
- `npm test` — 23 passed
- Deno format and type checks for all five Edge Function entrypoints
- `supabase migration list` — all 22 versions matched
- `supabase db push --dry-run` — remote database up to date
- `supabase db lint --linked --schema market_intelligence` — no schema errors
- five active cron jobs and five active Edge Functions
- current `tippos.app` AI-visibility domains with retired domains absent
- observation-only language scoring with zero score rows when no measured
  search or AI observations exist
- an unauthorized `authenticated` call to
  `mi_get_language_recommendations()` failed with
  `market_intelligence_forbidden`
- a `service_role` call succeeded; candidate languages without evidence
  returned null score and recommendation fields rather than fabricated values
- a live strategy-assistant history request succeeded with 13 records, correct
  CORS, and a hashed-only access audit row
- an unauthenticated Google Ads sync request failed at the JWT gateway

## Known advisor findings

The remaining findings are expected for this internal, low-data system:

- `rls_enabled_no_policy` applies to `market_evidence`, `strategy_history`, and
  `strategy_access_attempts`. They are intentionally server-only, so no client
  policy is the deny-by-default design. See the
  [advisor remediation](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy).
- `authenticated_security_definer_function_executable` applies to
  `mi_get_language_recommendations()`. Execution is intentional for assigned
  internal viewers; an unassigned authenticated test user was verified to fail
  the internal role check. See the
  [advisor remediation](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable).
- `unused_index` findings are informational before representative workload
  exists. Do not remove indexes without query-plan evidence. See the
  [advisor remediation](https://supabase.com/docs/guides/database/database-linter?lint=0005_unused_index).

## Future migration workflow

1. Create every new migration with `supabase migration new <name>`.
2. Keep new versions later than the current hosted history; do not retimestamp
   or duplicate an applied migration.
3. Run `npm run check`, `npm test`, Deno checks, and linked database lint.
4. Capture a compact fingerprint for any table the migration mutates.
5. Run `supabase db push --dry-run`, review the exact list, then apply it.
6. Re-run migration list, dry-run, data checks, function privileges, cron
   inventory, and both advisor classes.
7. Treat database migrations, Edge Functions, secrets, and Storage objects as
   separate deployment surfaces.

A blank replay with `supabase db reset` remains recommended when a
Docker-compatible runtime or disposable branch is available. It is a
reproducibility check, not a blocker for this internal pre-launch database.
