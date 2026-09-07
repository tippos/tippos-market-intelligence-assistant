# US tipping search demand — September 2026 reading

Source: one manual Google Trends comparison export, US, past 5 years
(2021-09-08 – 2026-09-08), Web Search, all categories, filed under
[evidence/market-intelligence/google-trends/2026-09-08-us-tipping-comparison](../evidence/market-intelligence/google-trends/2026-09-08-us-tipping-comparison/README.md).
Read that manifest first: every number below is a **relative index, never a
search count**, and the two regional files are a share between two terms rather
than a measure of a state's volume.

Compared against the live brand site at `origin/main` on 2026-09-08: 40 service
calculators under `/tip-calculator/*`, an `/answers` hub with one published
intent per service (`do-you-tip`), four category guides, `/tipping-statistics`,
`/how-much-should-i-tip-2026`, and the blog.

## What the export says

**1. Advice intent is overtaking tool intent.** Average interest across the
period is `tip calculator` 69 versus `how much to tip` 64, but the two are
moving in opposite directions: the calculator line falls from its early-2022
peak while the advice line rises and crosses above it late in the period. This
crossover is currently evidenced only by the 2026-09-08 screenshot — the
interest-over-time CSV was not exported, and it should be before the finding is
leaned on hard.

**2. The two "product" phrasings barely register.** `split tip` (avg 2) and
`tip with card` (avg 3) were dropped from both regional exports for
insufficient data. Nobody is searching for what tippos does; they search for the
tipping question that precedes it. Acquisition has to come through the question,
not the product category.

**3. Demand is concentrated in a handful of services, and one of them is
delivery.** Top related queries for `how much to tip`, by relative index:
delivery 100, hairdresser 72, movers 65, uber 62, tattoo 59, massage 50, valet
42, restaurant 40, haircut 37, tattoo artist 34, uber driver 32 (+110%),
delivery 29, at restaurant 26 (+100%), pedicure 24, doordash 24 (+160%), taxi
23, housekeeping 20, barber 19, groomer 19.

**4. Brand names carry the delivery demand.** `doordash` and
`how much to tip doordash` both index 24 at +160%, `instacart` 15, `uber eats`
11 (+30%), and `doordash tip calculator` is up 250% in the rising list. The
site's `/tip-calculator/food-delivery` page mentions these brands inside its
benchmark copy but has no URL, title or answer page in any of their names.

**5. Tax is the biggest uncovered adjacent intent.** From the `tip calculator`
related lists: `tax calculator` 70, `tip tax calculator` 69,
`tax and tip calculator` 23 (+50%), `sales tax calculator` 20 (+30%). The brand
site has no tax handling and no page containing the phrase.

**6. Phones are where the calculator demand went.** The rising list is dominated
by one cluster: `tip calculator iphone` 37 (+170%), `iphone tip calculator` 32
(+130%), `tip calculator on iphone` 10 (+150%), plus `tip calculator app` 24 and
`best tip calculator app` (+40%). People want a calculator on the phone they are
holding at the table.

**7. Fixed-percentage and chart phrasings are their own queries.**
`tip percentage calculator` 46, `tip percentage` 44, `20 tip calculator` 36
(+90%), `15 tip calculator` 19 (+40%), `tip chart calculator` 13,
`tip calculator chart` 13. None of these phrasings exist on the site.

**8. Geography splits by intent, not by volume.** In the two-term share,
`how much to tip` wins in Hawaii (66/34), DC (59), Washington (55), New Jersey
and New York (54), Alaska (53), California (52); the metro file is sharper —
Juneau 81/19, Honolulu 66/34, San Francisco 61/39, New York 59/41. `tip
calculator` wins in New Mexico (67), New Hampshire (64), South Dakota, Oklahoma,
Ohio and Arizona (62). Tourist and high-service markets ask the etiquette
question; interior markets reach for the tool. Separately,
`tip calculator california` and `tip calculator texas` are both rising 40%, and
`tip calculator nyc` 30% — state and city phrasings that pair naturally with
sales tax.

**9. Two content signals worth acting on.** `tip screen` is up 350% (the
tipflation backlash the blog already has a category for), and
`how much to tip in mexico` indexes 13 at +80% against zero international
coverage on the site.

## Recommended actions, in priority order

Each is a **net-new URL or a net-new feature**, not a rewrite of a live page —
the post-launch rule that existing URLs, canonicals and intent stay untouched
applies to all of them.

1. **Ship a tax-and-tip mode plus a `/tip-calculator/tax` page.** Highest-index
   uncovered intent (70/69/23/20) and the only one that also unlocks the rising
   state queries. State sales-tax rates make the state pages non-duplicative.
2. **Give delivery its brand pages.** `/tip-calculator/doordash`,
   `/tip-calculator/uber-eats`, `/tip-calculator/instacart` — delivery is the
   single largest related query (100) and the brand variants are the fastest
   risers in it (+160%, +250%).
3. **Add the rideshare brand pages.** `how much to tip uber` 62 (+40%) and
   `uber driver` 32 (+110%) currently land on a page called `taxi-rideshare`.
4. **Publish state pages behind the tax feature** — California, Texas, New York
   and New York City first, since those are the terms actually rising. Do not
   generate all 50 up front; one state page with no unique tax or custom content
   is thin.
5. **Make the phone story explicit**: a `/tip-calculator/iphone`-style page and
   an install-to-home-screen path. The entire rising cluster (+170%, +150%,
   +130%) is asking for an app, and tippos is a web app that can be one.
6. **Add percentage and chart pages** — 20%, 15%, a printable tip chart. Cheap
   to build from existing benchmark data, and they match four distinct query
   phrasings the site currently has no words for.
7. **Open the second answer intent.** `SeoIntent` already supports
   `holiday-tip`, `owner-operator`, `touch-up` and `high-ticket-example`, and
   the rising list is full of situational phrasings. One reviewed intent across
   the top services beats a new one-off page.
8. **Write the `tip screen` post** (+350%) and one international guide starting
   with Mexico (+80%), both linked from the relevant calculators.
9. **Aim the etiquette content at the coastal/tourist markets** and the tool
   content at the interior ones, in social targeting and in city-specific copy;
   the metro file gives the ranked list.

## Collection follow-ups

- Export **interest over time** for the same four terms so the crossover in
  finding 1 rests on a file, not a screenshot.
- Export **rising related queries for `how much to tip`**; only the top list
  exists today.
- Re-run this comparison quarterly. The two head terms moved far enough in five
  years that the ranking of these actions could change within a year.
