export type OpenAIResponse = Record<string, unknown>;

export function extractOutputText(response: OpenAIResponse): string {
  const direct = response.output_text;
  if (typeof direct === "string") return direct.trim();
  const output = Array.isArray(response.output) ? response.output : [];
  const parts: string[] = [];
  for (const item of output) {
    if (!item || typeof item !== "object") continue;
    const content = Array.isArray((item as Record<string, unknown>).content)
      ? (item as Record<string, unknown>).content as Array<
        Record<string, unknown>
      >
      : [];
    for (const block of content) {
      if (typeof block.text === "string") parts.push(block.text);
    }
  }
  return parts.join("\n").trim();
}

export function extractCitations(
  response: OpenAIResponse,
): Array<{ order: number; url: string; title?: string }> {
  const found = new Map<
    string,
    { order: number; url: string; title?: string }
  >();
  const visit = (value: unknown) => {
    if (!value || typeof value !== "object") return;
    if (Array.isArray(value)) {
      value.forEach(visit);
      return;
    }
    const object = value as Record<string, unknown>;
    const candidate = object.url;
    if (
      typeof candidate === "string" && /^https?:\/\//i.test(candidate) &&
      !found.has(candidate)
    ) {
      found.set(candidate, {
        order: found.size + 1,
        url: candidate,
        title: typeof object.title === "string" ? object.title : undefined,
      });
    }
    Object.values(object).forEach(visit);
  };
  visit(response.output);
  return [...found.values()];
}

export function tipposMentions(text: string): Array<Record<string, unknown>> {
  const match = /\btippos\b/i.exec(text);
  if (!match) return [];
  const prefix = text.slice(0, match.index);
  const position = (prefix.match(/\b[A-Z][A-Za-z0-9-]*\b/g) ?? []).length + 1;
  const start = Math.max(0, match.index - 100);
  const end = Math.min(text.length, match.index + match[0].length + 160);
  return [{
    brand_key: "tippos",
    display_name: "tippos",
    position: Math.max(1, position),
    context_summary: text.slice(start, end).replace(/\s+/g, " ").trim(),
    confidence: 0.95,
  }];
}
