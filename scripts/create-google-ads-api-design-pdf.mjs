import { mkdirSync, writeFileSync } from "node:fs";

const out = "output/pdf/tippos-google-ads-api-design.pdf";
const lines = [
  "tippos Market Intelligence",
  "Google Ads API Basic Access - Internal Tool Design",
  "",
  "Purpose",
  "tippos is building an internal market-intelligence workflow for its own product",
  "and SEO decision-making. It researches aggregate Google Search demand for",
  "tip-calculator and tipping-related topics in US English.",
  "",
  "Intended users and access",
  "Only authorized tippos employees and contractors use this internal workspace.",
  "External users, clients, advertisers, and the public do not receive API access,",
  "credentials, or raw Google Ads API results.",
  "",
  "API use",
  "The planned integration uses Google Ads keyword-planning services to generate",
  "candidate phrases and request historical metrics only for an internally reviewed",
  "list. Requests target the United States, English, and Google Search.",
  "",
  "Excluded activity",
  "The workflow does not create or optimize campaigns, budgets, bids, ads, audiences,",
  "conversion tracking, or remarketing. It does not manage advertising for third parties.",
  "",
  "Data handling and safeguards",
  "The integration records aggregate keyword metrics only. It is not designed to collect",
  "personal data, user-level search histories, or Google Ads performance data. API",
  "credentials are server-side secrets and are not exposed in the browser interface.",
  "Keyword ideas are candidates, not evidence, until Google Ads returns historical metrics.",
  "",
  "System design",
  "1. An authorized internal user starts a server-side research run.",
  "2. The server authenticates with a service account and tippos developer token.",
  "3. Discovery creates candidates only; measurement requests approved historical metrics.",
  "4. Returned results are validated and stored in the separate Market Intelligence",
  "   Supabase project for internal product and SEO review.",
  "",
  "Operational controls",
  "Production use begins only after approved access and keyword-research permission.",
  "Requests are rate limited, results are refreshed monthly, and provider limitations",
  "and collection time are retained for auditability.",
  "",
  "Current rollout state (2026-07-26)",
  "The design is prepared, but the credential connection is not deployed and no Google",
  "Ads API keyword metrics have been imported into the market-intelligence database.",
];

const esc = (s) => s.replace(/\\/g, "\\\\").replace(/\(/g, "\\(").replace(/\)/g, "\\)");
let content = "BT\n/F1 10 Tf\n50 750 Td\n";
lines.forEach((line, i) => {
  const font = i === 0 ? 18 : (line && ![4, 9, 14, 19, 23, 30, 36, 41].includes(i) ? 12 : 10);
  if (i === 0) content += "/F1 18 Tf\n";
  else if ([3, 8, 13, 18, 22, 29, 35, 40].includes(i)) content += "/F1 12 Tf\n";
  else content += "/F1 10 Tf\n";
  content += `(${esc(line)}) Tj\n0 -${i === 0 ? 28 : 14} Td\n`;
});
content += "ET";
const objects = [
  "<< /Type /Catalog /Pages 2 0 R >>",
  "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
  "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
  "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
  `<< /Length ${Buffer.byteLength(content, "ascii")} >>\nstream\n${content}\nendstream`,
];
let pdf = "%PDF-1.4\n";
const offsets = [0];
objects.forEach((obj, index) => { offsets.push(Buffer.byteLength(pdf, "ascii")); pdf += `${index + 1} 0 obj\n${obj}\nendobj\n`; });
const start = Buffer.byteLength(pdf, "ascii");
pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
offsets.slice(1).forEach((offset) => { pdf += `${String(offset).padStart(10, "0")} 00000 n \n`; });
pdf += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R /Title (tippos Google Ads API Design) >>\nstartxref\n${start}\n%%EOF\n`;
mkdirSync("output/pdf", { recursive: true });
writeFileSync(out, pdf, "ascii");
console.log(out);
