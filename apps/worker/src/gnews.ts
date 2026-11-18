import { decodeEntities, foldName } from "./social.js";

/*
 * Google News RSS search, shared by the members' news step (news.ts) and the jurisdictions'
 * headlines (local.ts).
 *
 * What is kept from an item: the headline, the publisher's name and site, the date and the Google
 * News link. Never the article's text, and nothing from the item's description (which only repeats
 * the headline). The feed's own terms say it is for "rendering Google News results within a personal
 * feed reader": HANDOFF ("News, polls and the Local tab") has what that means for Floor.
 *
 * No key: every URL here is safe to log.
 */

export const GNEWS = "https://news.google.com/rss/search";

export const gnewsUrl = (query: string) =>
  `${GNEWS}?q=${encodeURIComponent(query)}&hl=en-US&gl=US&ceid=US:en`;

export interface NewsItem {
  /** Google News's guid for the item (stable across fetches). */
  guid: string;
  /** The headline without the " - Publisher" suffix Google News adds. */
  title: string;
  source: string;
  sourceUrl: string | null;
  url: string;
  publishedAt: string;
}

const tag = (xml: string, name: string) => {
  const m = xml.match(new RegExp(`<${name}(?:\\s[^>]*)?>([\\s\\S]*?)</${name}>`));
  return m ? decodeEntities(m[1]!.replace(/^<!\[CDATA\[([\s\S]*)\]\]>$/, "$1").trim()) : null;
};

/** The items of a Google News RSS answer. Items without a link, guid, date or title are skipped. */
export function parseGoogleNews(xml: string): NewsItem[] {
  const out: NewsItem[] = [];
  for (const [item] of xml.matchAll(/<item>[\s\S]*?<\/item>/g)) {
    const rawTitle = tag(item, "title");
    const link = tag(item, "link");
    const guid = tag(item, "guid") ?? link;
    const date = tag(item, "pubDate");
    const sourceMatch = item.match(/<source(?:\s+url="([^"]*)")?[^>]*>([\s\S]*?)<\/source>/);
    const source = sourceMatch ? decodeEntities(sourceMatch[2]!.trim()) : null;
    if (!rawTitle || !link || !guid || !date || Number.isNaN(Date.parse(date))) continue;
    const suffix = source ? ` - ${source}` : null;
    const title = suffix && rawTitle.endsWith(suffix) ? rawTitle.slice(0, -suffix.length).trim() : rawTitle;
    out.push({
      guid,
      title,
      source: source ?? "",
      sourceUrl: sourceMatch?.[1] ? decodeEntities(sourceMatch[1]) : null,
      url: link,
      publishedAt: new Date(date).toISOString(),
    });
  }
  return out;
}

/** A publisher on a .gov domain: a member's own office, another office, an agency. */
export function isGov(sourceUrl: string | null): boolean {
  if (!sourceUrl) return false;
  try {
    return /(^|\.)[a-z0-9-]+\.gov$/i.test(new URL(sourceUrl).hostname);
  } catch {
    return false;
  }
}

/** Whether a headline names the member: their folded surname as whole words of the folded title. */
export function namesMember(title: string, lastName: string): boolean {
  const last = foldName(lastName);
  if (!last) return false;
  // A possessive goes first: foldName drops apostrophes, which would read "Schumer's" as "schumers".
  return ` ${foldName(title.replace(/['’]s\b/gi, ""))} `.includes(` ${last} `);
}

/** The Google News query for a member: their name in quotes and words for their office, 7 days. */
export function memberNewsQuery(m: { first_name: string; last_name: string; chamber: "house" | "senate" }): string {
  const words = m.chamber === "senate" ? "(senator OR sen OR congress)" : "(rep OR congressman OR congresswoman OR congress)";
  return `"${m.first_name} ${m.last_name}" ${words} when:7d`;
}
