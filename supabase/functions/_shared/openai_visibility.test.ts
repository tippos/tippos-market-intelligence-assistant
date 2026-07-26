import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  extractCitations,
  extractOutputText,
  tipposMentions,
} from "./openai_visibility.ts";

Deno.test("extracts Responses API text blocks", () => {
  const response = {
    output: [{
      type: "message",
      content: [{ type: "output_text", text: "TIPPOS is one option." }],
    }],
  };
  assertEquals(extractOutputText(response), "TIPPOS is one option.");
  assertEquals(tipposMentions(extractOutputText(response)).length, 1);
});

Deno.test("deduplicates nested response citations", () => {
  const response = {
    output: [{
      content: [{
        annotations: [
          { type: "url_citation", url: "https://example.com/a", title: "A" },
          { type: "url_citation", url: "https://example.com/a", title: "A" },
        ],
      }],
    }],
  };
  assertEquals(extractCitations(response), [{
    order: 1,
    url: "https://example.com/a",
    title: "A",
  }]);
});

Deno.test("does not create a TIPPOS mention for unrelated text", () => {
  assertEquals(tipposMentions("Use a QR tipping service."), []);
});
