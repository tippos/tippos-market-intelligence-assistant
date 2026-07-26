from pathlib import Path

from reportlab.lib.colors import HexColor
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.platypus import KeepTogether, Paragraph, SimpleDocTemplate, Spacer


OUTPUT = Path("output/pdf/tippos-google-ads-api-design.pdf")
OUTPUT.parent.mkdir(parents=True, exist_ok=True)

styles = getSampleStyleSheet()
styles.add(ParagraphStyle(
    name="TitleTippos", parent=styles["Title"], fontName="Helvetica-Bold",
    fontSize=24, leading=29, textColor=HexColor("#111111"), spaceAfter=10,
))
styles.add(ParagraphStyle(
    name="SubTitleTippos", parent=styles["Normal"], fontName="Helvetica",
    fontSize=10, leading=14, textColor=HexColor("#5B5B5B"), spaceAfter=22,
))
styles.add(ParagraphStyle(
    name="HeadingTippos", parent=styles["Heading2"], fontName="Helvetica-Bold",
    fontSize=13, leading=17, textColor=HexColor("#242424"), spaceBefore=12, spaceAfter=5,
))
styles.add(ParagraphStyle(
    name="BodyTippos", parent=styles["BodyText"], fontName="Helvetica",
    fontSize=10, leading=14, textColor=HexColor("#2D2D2D"), spaceAfter=7,
))


def paragraph(text, style="BodyTippos"):
    return Paragraph(text, styles[style])


sections = [
    ("Purpose", "tippos is building an internal market-intelligence workflow for its own product and SEO decision-making. The workflow researches aggregate Google Search demand for tip-calculator and tipping-related topics in US English. It is not a public keyword tool, a customer-facing product, or an advertising-management service for other businesses."),
    ("Intended users and access", "Only authorized tippos employees and contractors who support product, SEO, or market research will use the internal workspace. External users, clients, advertisers, and the general public will not receive access to the API tool, developer token, credentials, or raw Google Ads API results."),
    ("API use", "The planned integration uses Google Ads API keyword-planning services for internal research. It generates candidate phrases from a small topic-specific seed set, labels those ideas as unmeasured candidates, and requests historical metrics only for an internally reviewed list. Requests are targeted to the United States, English, and Google Search. Returned aggregate metrics retain their month, geography, language, network, canonical keyword, and close-variant metadata."),
    ("Excluded activity", "The workflow does not create, modify, or optimize Google Ads campaigns, budgets, bids, ads, audiences, conversion tracking, or remarketing. It does not automate advertising for any third party."),
    ("Data handling and safeguards", "The integration records only aggregate keyword metrics returned by Google Ads API. It is not designed to collect personal data, user-level search histories, or Google Ads account performance data. API credentials are held as server-side secrets and are not exposed in the internal browser interface. Keyword ideas remain candidates rather than evidence until Google Ads returns historical metrics. Empty provider responses do not activate a source or become a success claim."),
    ("System design", "1. An authorized internal user starts a server-side research run.<br/>2. The server authenticates to Google Ads API with a service account and the tippos developer token.<br/>3. Discovery may retrieve candidate phrases but does not write measured metrics.<br/>4. Measurement requests historical metrics for an approved bounded list.<br/>5. Returned results are validated, deduplicated, and stored in the separate tippos Market Intelligence Supabase project.<br/>6. Internal users review aggregate research outputs to inform product and SEO decisions."),
    ("Operational controls", "Production use begins only after the developer token receives the required approved access and permissible use for keyword research. Requests are rate limited and retried conservatively. Research is refreshed monthly rather than used as real-time reporting. The implementation keeps an audit trail of source, collection time, and provider limitations."),
    ("Current rollout state", "The integration design and validation are prepared, but the Google Ads credential connection is not deployed. No Google Ads API keyword metrics have been imported into the market-intelligence database as of 2026-07-26."),
]

story = [
    paragraph("tippos Market Intelligence", "TitleTippos"),
    paragraph("Google Ads API Basic Access - Internal Tool Design", "SubTitleTippos"),
]
for heading, body in sections:
    story.append(KeepTogether([paragraph(heading, "HeadingTippos"), paragraph(body)]))

doc = SimpleDocTemplate(
    str(OUTPUT), pagesize=letter, rightMargin=0.72 * inch, leftMargin=0.72 * inch,
    topMargin=0.68 * inch, bottomMargin=0.68 * inch,
    title="tippos Google Ads API Design",
    author="tippos",
)
doc.build(story)
print(OUTPUT)
