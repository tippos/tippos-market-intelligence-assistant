import { readFileSync, readdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { isDeepStrictEqual } from "node:util";

const migrationsDirectory = "supabase/migrations";
const evidenceDirectory = "evidence/market-intelligence";
const migrationFiles = readdirSync(migrationsDirectory)
  .filter((file) => file.endsWith(".sql"))
  .sort();
const evidenceFiles = readdirSync(evidenceDirectory)
  .filter((file) => file.endsWith(".json"))
  .sort();

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function occurrences(text, needle) {
  return text.split(needle).length - 1;
}

const migrationFileByVersion = new Map();
for (const file of migrationFiles) {
  const match = file.match(/^(\d{14})_.+\.sql$/);
  assert(match, `invalid migration filename: ${file}`);
  assert(
    !migrationFileByVersion.has(match[1]),
    `duplicate migration version: ${match[1]}`,
  );
  migrationFileByVersion.set(match[1], file);
}

function readMigration(version) {
  const file = migrationFileByVersion.get(version);
  assert(file, `migration ${version} is missing`);
  return readFileSync(join(migrationsDirectory, file), "utf8");
}

const canonicalRemoteVersions = [
  "20260722232550",
  "20260722232623",
  "20260722232637",
  "20260722232651",
  "20260722233938",
  "20260722234609",
  "20260723002801",
  "20260723003014",
  "20260723004844",
  "20260723005039",
  "20260723012429",
  "20260723012627",
  "20260723014638",
  "20260723020832",
  "20260723021041",
  "20260723174230",
  "20260723175827",
];
const reconciledAdditionalVersions = [
  "20260723021447",
  "20260724111500",
  "20260724190745",
  "20260724191056",
  "20260724210000",
  "20260725200649",
  "20260809014500",
];
const obsoleteRetimestampedVersions = [
  "20260723004822",
  "20260723020631",
  "20260723020908",
  "20260723100000",
  "20260723100001",
  "20260723100002",
  "20260723100003",
  "20260723100004",
  "20260723100005",
  "20260723100006",
  "20260723100007",
  "20260723100008",
  "20260723173224",
  "20260723175648",
];
const canonicalRemoteBodyHashes = new Map([
  ["20260722232550", "318bcfe619b21d401c41b4f16e76c3c8"],
  ["20260722232623", "dab05f147283eafc8e45657a9a2b1dfc"],
  ["20260722232637", "d95549fbbf4f89f1bfe1c3ca3681aa56"],
  ["20260722232651", "76297c460eba379cbc83d9aba4e1e56d"],
  ["20260722233938", "1df8abbb92c5edbc509940dccf3aa700"],
  ["20260722234609", "86162c2e3e194d9c7fdcf4749b57466a"],
  ["20260723002801", "0a13711771cd0f4104c70449bc970cb6"],
  ["20260723003014", "d9aab7c8361af0402d2d7e2f5ae3f36b"],
  ["20260723004844", "8adafe1f89867d6f1a519e404303c4de"],
  ["20260723005039", "8adafe1f89867d6f1a519e404303c4de"],
  ["20260723020832", "0e3747b4bf2df7a1a6ad4f5ce9b8d31a"],
  ["20260723021041", "e9c69725a0be1e9f5f4a25ccc97827f0"],
  ["20260723174230", "91f1da76a3566084f4b6775c18054c7e"],
  ["20260723175827", "63ddd33f19a970b282713faf470c2d05"],
]);

for (const version of canonicalRemoteVersions) {
  assert(
    migrationFileByVersion.has(version),
    `canonical remote migration ${version} is missing`,
  );
}
for (const version of obsoleteRetimestampedVersions) {
  assert(
    !migrationFileByVersion.has(version),
    `obsolete retimestamped migration ${version} is present`,
  );
}
for (const [version, expectedHash] of canonicalRemoteBodyHashes) {
  const compactBody = readMigration(version).replace(/\s+/g, "");
  const actualHash = createHash("md5").update(compactBody).digest("hex");
  assert(
    actualHash === expectedHash,
    `canonical remote migration ${version} body hash differs:
expected ${expectedHash}
actual   ${actualHash}`,
  );
}

const expectedVersions = [
  ...canonicalRemoteVersions,
  ...reconciledAdditionalVersions,
].sort();
const actualVersions = [...migrationFileByVersion.keys()].sort();
assert(
  isDeepStrictEqual(actualVersions, expectedVersions),
  `migration lineage differs from the canonical history plus reconciled additions:
expected ${expectedVersions.join(", ")}
actual   ${actualVersions.join(", ")}`,
);

const core = readMigration("20260722232550");
const seed = readMigration("20260722232623");
const ai = readMigration("20260722232637");
const cleanup = readMigration("20260723174230");
const historicalSerp = readMigration("20260723021447");
const googleAds = readMigration("20260724111500");
const convergence = readMigration("20260724190745");
const referenceEvidence = readMigration("20260724191056");
const strategyGuard = readMigration("20260724210000");
const searchMetricActivationGuard = readMigration("20260725200649");
const googleTrendsManualImports = readMigration("20260809014500");
const strategy = readFileSync(
  "supabase/functions/market-intelligence-us-strategy/index.ts",
  "utf8",
);
const runtimeAuth = readFileSync(
  "supabase/functions/_shared/market_intelligence_runtime.ts",
  "utf8",
);
const ingest = readFileSync(
  "supabase/functions/market-intelligence-ingest/index.ts",
  "utf8",
);
const strategyTool = readFileSync(
  "tools/tippos-us-strategy-assistant.html",
  "utf8",
);
const hostedStrategyTool = readFileSync(
  "supabase/functions/market-intelligence-us-strategy/strategy-assistant.html",
  "utf8",
);
const supabaseConfig = readFileSync("supabase/config.toml", "utf8");
const googleAdsCollector = readFileSync(
  "supabase/functions/market-intelligence-google-ads-sync/index.ts",
  "utf8",
);
const googleAdsDiscovery = readFileSync(
  "supabase/functions/market-intelligence-google-ads-discover/index.ts",
  "utf8",
);
const googleAdsPlanner = readFileSync(
  "supabase/functions/_shared/google_ads_keyword_planner.ts",
  "utf8",
);
const languages = JSON.parse(
  readFileSync(
    join(evidenceDirectory, "languages-baseline-2026-07-24.json"),
    "utf8",
  ),
);
const marketEvidence = JSON.parse(
  readFileSync(
    join(evidenceDirectory, "market-evidence-baseline-2026-07-24.json"),
    "utf8",
  ),
);

const tableCount = core.split("CREATE TABLE market_intelligence.").length - 1;
assert(tableCount >= 28, "market-intelligence tables are missing");
assert(seed.length > 0, "canonical seed migration is empty");
assert(core.includes("ENABLE ROW LEVEL SECURITY"), "RLS activation is missing");
assert(core.includes("auth.jwt()"), "service-role ingestion guard is missing");
assert(
  core.includes("security_invoker = true"),
  "security-invoker views are missing",
);
assert(
  ai.includes("full_text_not_allowed_for_retention_mode"),
  "AI retention guard is missing",
);

assert(
  "20260723021447" < "20260723174230",
  "historical SERP migration must precede the production cleanup",
);
assert(
  historicalSerp.includes("INSERT INTO market_intelligence.keyword_variants"),
  "historical SERP keyword variants are missing",
);
assert(
  cleanup.includes("DELETE FROM market_intelligence.keyword_variants"),
  "cleanup must remove historical keyword variants",
);
assert(
  cleanup.includes("sources_production_data_only"),
  "production-source constraint is missing",
);
assert(
  cleanup.includes("language_scores_require_real_observations"),
  "score trigger is missing",
);

for (const domain of [
  "tippos.app",
  "www.tippos.app",
  "discover.tippos.app",
  "app.tippos.app",
]) {
  assert(
    convergence.includes(`'${domain}'`),
    `current AI visibility domain ${domain} is missing`,
  );
}
assert(
  !convergence.includes("'tippos.com'") &&
    !convergence.includes("'tippos.lovable.app'"),
  "retired tippos domains remain in the convergence migration",
);
assert(
  convergence.includes(
    "coalesce(s.observed_days, 0) > 0 OR coalesce(a.ai_runs, 0) > 0",
  ),
  "unobserved scoring is enabled",
);
assert(
  convergence.includes("coalesce(s.competition_opportunity, 0)") &&
    convergence.includes("coalesce(s.source_confidence, 0)") &&
    !convergence.includes("coalesce(s.competition_opportunity, 50)") &&
    !convergence.includes("coalesce(s.source_confidence, 0.3)"),
  "unobserved scoring still uses neutral fallback estimates",
);

assert(
  Array.isArray(languages) && languages.length === 23,
  "language baseline must contain exactly 23 rows",
);
assert(
  new Set(languages.map((language) => language.code)).size === languages.length,
  "language baseline contains duplicate codes",
);
assert(
  languages.every(
    (language) =>
      typeof language.code === "string" &&
      /^[a-z]{2,3}$/.test(language.code),
  ),
  "language baseline contains an invalid code",
);
assert(
  Array.isArray(marketEvidence) && marketEvidence.length === 50,
  "market evidence baseline must contain exactly 50 rows",
);
assert(
  new Set(marketEvidence.map((item) => item.evidence_key)).size ===
    marketEvidence.length,
  "market evidence baseline contains duplicate evidence keys",
);
assert(
  marketEvidence.every(
    (item) =>
      typeof item.evidence_key === "string" && item.evidence_key.length > 0,
  ),
  "market evidence baseline contains an invalid evidence key",
);
assert(
  marketEvidence.every(
    (item) =>
      typeof item.source_url === "string" &&
      item.source_url.startsWith("https://"),
  ),
  "market evidence baseline contains a non-HTTPS source",
);
assert(
  marketEvidence.every((item) => item.data_nature === "third_party"),
  "market evidence baseline contains non-third-party data",
);
assert(
  marketEvidence.every(
    (item) =>
      item.source_key === "codex_public_research" &&
      languages.some((language) => language.code === item.language_code),
  ),
  "market evidence baseline contains an unexpected source or language",
);

function extractTaggedJson(sql, tag) {
  const match = sql.match(
    new RegExp(`\\$${tag}\\$\\s*([\\s\\S]*?)\\s*\\$${tag}\\$::jsonb`),
  );
  assert(match, `tagged JSON payload ${tag} is missing`);
  try {
    return JSON.parse(match[1]);
  } catch (error) {
    throw new Error(`tagged JSON payload ${tag} is invalid: ${error.message}`);
  }
}

const embeddedLanguages = extractTaggedJson(
  referenceEvidence,
  "tippos_mi_languages",
);
const embeddedEvidence = extractTaggedJson(
  referenceEvidence,
  "tippos_mi_evidence",
);
assert(
  isDeepStrictEqual(embeddedLanguages, languages),
  "embedded language payload differs from its evidence artifact",
);
assert(
  isDeepStrictEqual(embeddedEvidence, marketEvidence),
  "embedded market evidence payload differs from its evidence artifact",
);
assert(
  referenceEvidence.includes("ON CONFLICT (code) DO NOTHING;") &&
    referenceEvidence.includes(
      "ON CONFLICT (evidence_key) DO NOTHING;",
    ),
  "reference snapshots must preserve reviewed rows with DO NOTHING",
);

const expectedUtf8Predicates = [
  [
    "publisher",
    "507265736964c383c2aa6e63696120646120526570c383c2ba626c696361",
  ],
  [
    "source_title",
    "4c65692031332e343139206465203133206465206d6172c383c2a76f2064652032303137",
  ],
  ["publisher", "42616e636f2064652045737061c383c2b161"],
];
for (const [column, fingerprint] of expectedUtf8Predicates) {
  assert(
    occurrences(
      referenceEvidence,
      `encode(convert_to(${column}, 'UTF8'), 'hex')
    = '${fingerprint}'`,
    ) === 1,
    `exact UTF-8 repair predicate for ${column} / ${fingerprint} is missing`,
  );
}
assert(
  occurrences(
    referenceEvidence,
    "encode(convert_to(publisher, 'UTF8'), 'hex')",
  ) === 2 &&
    occurrences(
      referenceEvidence,
      "encode(convert_to(source_title, 'UTF8'), 'hex')",
    ) === 1,
  "UTF-8 repairs must use exact byte predicates",
);
assert(
  referenceEvidence.includes("publisher = 'Presidência da República'") &&
    referenceEvidence.includes(
      "source_title = 'Lei 13.419 de 13 de março de 2017'",
    ) &&
    referenceEvidence.includes("publisher = 'Banco de España'"),
  "UTF-8 repairs must set the reviewed strings",
);

const textArtifacts = [
  ...migrationFiles.map((file) => join(migrationsDirectory, file)),
  ...evidenceFiles.map((file) => join(evidenceDirectory, file)),
];
const likelyMojibake =
  /(?:\u00c2|\u00c3|[\u00d0\u00d1\u00d7\u00d8\u00d9\u00e0\u00e1\u00e4\u00ed][\u0080-\u00bf]|\u00e2[\u20ac\u2122\u0153\u017e\u201c\u201d\u2013\u2014\u2026]|\u00e6[\u0080-\u00bf\u2014\u0153])/u;
for (const path of textArtifacts) {
  const content = readFileSync(path, "utf8");
  assert(!content.includes("tokens truncated"), `${path} is truncated`);
  assert(!content.includes("\ufffd"), `${path} contains U+FFFD`);
  assert(!likelyMojibake.test(content), `${path} contains likely mojibake`);
}

assert(
  strategy.includes("mi_get_growth_campaign_snapshot"),
  "strategy assistant growth snapshot is missing",
);
assert(
  strategy.includes("growth_snapshot_unavailable"),
  "website growth integration must remain optional",
);
assert(
  strategy.includes("mi_reserve_strategy_access_attempt") &&
    strategy.includes("mi_finalize_strategy_access_attempt"),
  "strategy access rate limit and audit are missing",
);
assert(
  strategyGuard.includes("strategy_access_attempts_client_window_idx") &&
    strategyGuard.includes("strategy_access_attempts_request_window_idx") &&
    strategyGuard.includes("pg_advisory_xact_lock") &&
    strategyGuard.includes("RETURNING id INTO v_attempt_id") &&
    strategyGuard.includes("'rate_limited'") &&
    strategyGuard.includes("ENABLE ROW LEVEL SECURITY") &&
    strategyGuard.includes("interval '30 days'"),
  "strategy access database guard must reserve and audit atomically",
);
assert(
  strategyGuard.includes("client_hash") &&
    !strategyGuard.includes("client_ip") &&
    !strategyGuard.includes("ip_address"),
  "strategy access audit must not retain raw client addresses",
);
assert(
  strategyTool === hostedStrategyTool,
  "strategy assistant copies have drifted",
);
assert(
  strategyTool.includes(
    '<meta name="robots" content="noindex, nofollow, noarchive, nosnippet">',
  ),
  "private strategy assistant indexing guard is missing",
);
assert(
  strategyTool.includes("async function unlockWithCode") &&
    /await loadHistory\(value\)[\s\S]*sessionStorage\.setItem/.test(
      strategyTool,
    ) &&
    strategyTool.includes("function lockWorkspace"),
  "strategy assistant must verify access before unlocking and relock on failure",
);
assert(
  strategyTool.includes("function safeHttpUrl") &&
    strategyTool.includes('link.rel = "noopener noreferrer"'),
  "strategy assistant source links are not hardened",
);
assert(
  !strategy.includes('"Access-Control-Allow-Origin": "*"'),
  "strategy assistant CORS must not allow every origin",
);
assert(
  runtimeAuth.includes("export function hasIngestAccess") &&
    ingest.includes("hasIngestAccess") &&
    !strategy.includes("hasIngestAccess"),
  "custom ingest key must remain scoped to the ingest boundary",
);
assert(
  /\[functions\.market-intelligence-ingest\]\s+verify_jwt = false/.test(
    supabaseConfig,
  ) &&
    /\[functions\.market-intelligence-openai\]\s+verify_jwt = false/.test(
      supabaseConfig,
    ),
  "secret-key functions must authenticate inside the handler",
);
assert(
  googleAds.includes("'google_ads_keyword_planner'"),
  "Google Ads source registration is missing",
);
assert(
  googleTrendsManualImports.includes("'relative_interest_index_0_100'") &&
    googleTrendsManualImports.includes("'search_counts', false") &&
    googleTrendsManualImports.includes("'manual_export_required', true"),
  "Google Trends imports must remain relative manual evidence, never search-volume estimates",
);
assert(
  googleTrendsManualImports.includes("trends_imports_source_id_idx") &&
    googleTrendsManualImports.includes("trends_imports_query_country_period_idx") &&
    googleTrendsManualImports.includes("relative_interest BETWEEN 0 AND 100"),
  "Google Trends tables must preserve foreign-key lookup indexes and bounded relative interest",
);
assert(
  googleAds.includes("'third_party'"),
  "Google Ads estimates must remain third-party evidence",
);
assert(
  googleAds.includes("'approximate_monthly_searches'"),
  "Google Ads metric limitation is missing",
);
assert(
  googleAdsCollector.includes(":generateKeywordHistoricalMetrics"),
  "Google Ads collector must use historical metrics",
);
assert(
  !googleAdsCollector.includes(":generateKeywordIdeas"),
  "Google Ads collector must not substitute keyword ideas",
);
assert(
  googleAdsDiscovery.includes(":generateKeywordIdeas") &&
    !googleAdsDiscovery.includes(":generateKeywordHistoricalMetrics") &&
    !googleAdsDiscovery.includes("mi_import_search_metrics") &&
    !googleAdsDiscovery.includes("adminClient"),
  "Google Ads discovery must remain separate from measured ingestion",
);
assert(
  googleAdsDiscovery.includes('"candidate_only_not_measured"') &&
    googleAdsDiscovery.includes("review_required: true") &&
    googleAdsDiscovery.includes("evidence_landed: false"),
  "Google Ads keyword ideas must be labeled as unmeasured candidates",
);
assert(
  googleAdsPlanner.includes('"tip calculator per person"'),
  "per-person demand seed is missing",
);
assert(
  googleAdsPlanner.includes('"tip calculator split bill"'),
  "split-bill demand seed is missing",
);
assert(
  googleAdsPlanner.includes("GOOGLE_ADS_MAX_REVIEWED_KEYWORDS = 1_000") &&
    googleAdsCollector.includes("createObservationBatches") &&
    googleAdsCollector.includes("createObservationBatchKey"),
  "Google Ads collector must safely support the reviewed 1,000-keyword set",
);
assert(
  searchMetricActivationGuard.includes("IF NOT p_dry_run AND v_loaded > 0 THEN") &&
    searchMetricActivationGuard.includes("'evidence_landed'") &&
    searchMetricActivationGuard.includes("rows_loaded = v_loaded"),
  "empty or dry-run search imports must not advance source success state",
);
assert(
  googleAdsCollector.includes("GOOGLE_ADS_CLIENT_EMAIL") &&
    googleAdsDiscovery.includes("GOOGLE_ADS_CLIENT_EMAIL"),
  "dedicated Google Ads credentials are missing",
);
assert(
  !googleAdsCollector.includes("GSC_CLIENT_EMAIL") &&
    !googleAdsDiscovery.includes("GSC_CLIENT_EMAIL"),
  "Google Ads collector must not couple to GSC credentials",
);
assert(
  /\[functions\.market-intelligence-google-ads-sync\]\s+verify_jwt = true/.test(
      supabaseConfig,
    ) &&
    /\[functions\.market-intelligence-google-ads-discover\]\s+verify_jwt = true/
      .test(supabaseConfig),
  "Google Ads functions must retain gateway JWT verification",
);

console.log(
  JSON.stringify(
    {
      ok: true,
      tableCount,
      canonicalRemoteMigrations: canonicalRemoteVersions.length,
      reconciledAdditionalMigrations: reconciledAdditionalVersions.length,
      referenceLanguages: languages.length,
      referenceEvidence: marketEvidence.length,
      observationGuards: true,
      optionalWebsiteGrowthIntegration: true,
      googleAdsHistoricalDemand: true,
      googleAdsReviewedKeywordDiscovery: true,
      strategyAccessGuard: true,
    },
    null,
    2,
  ),
);
