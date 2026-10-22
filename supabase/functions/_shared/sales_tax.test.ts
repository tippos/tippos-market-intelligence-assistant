import { assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { candidateEditions, checkSalesTaxRows, parseSalesTaxTable } from "./sales_tax.ts";

const FIXTURE = await Deno.readTextFile(
  new URL("./fixtures/tax-foundation-2026-midyear-table.html", import.meta.url),
);

Deno.test("parses Tax Foundation's midyear 2026 table", () => {
  const rows = parseSalesTaxTable(FIXTURE);
  assertEquals(rows.length, 51);
  assertEquals(rows.find((r) => r.state === "Tennessee"), {
    state: "Tennessee",
    state_rate: 7,
    local_rate: 2.61,
    combined_rate: 9.61,
  });
  assertEquals(rows.find((r) => r.state === "District of Columbia")?.combined_rate, 6);
  assertEquals(checkSalesTaxRows(rows), []);
});

Deno.test("refuses a table whose parts do not add up", () => {
  const rows = parseSalesTaxTable(FIXTURE).map((r) =>
    r.state === "Texas" ? { ...r, combined_rate: 9.2 } : r
  );
  assertEquals(checkSalesTaxRows(rows), ["Texas: 6.25 + 1.95 != 9.2"]);
});

Deno.test("refuses a page without the expected table", () => {
  assertThrows(() => parseSalesTaxTable("<p>moved</p>"));
  assertThrows(() => parseSalesTaxTable("<table><tr><th>Country</th></tr></table>"));
});

Deno.test("lists editions newest first and never one dated in the future", () => {
  const slugs = candidateEditions(new Date("2026-10-22T00:00:00Z")).map((e) => e.slug);
  assertEquals(slugs.slice(0, 3), [
    "2026-sales-tax-rates-midyear",
    "2026-sales-tax-rates",
    "2025-sales-tax-rates-midyear",
  ]);
});
