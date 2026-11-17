import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import { loadMigrations } from "@floor/db";
import { beforeEach, describe, expect, it } from "vitest";
import { POLICY_AREAS } from "../../api/src/bills.js";
import type { Complete, ModelCall } from "./analysis.js";
import type { Db } from "./db.js";
import type { FecGet } from "./fec.js";
import type { FetchText } from "./rollcalls.js";
import {
  TOPICS,
  cdxUrl,
  committeeSite,
  electionYear,
  findPlatformPage,
  lastCapture,
  normalizeSite,
  pageText,
  parsePromisesArgs,
  rawUrl,
  readCampaignSite,
  runPromises,
  snapshotCutoff,
  verifyPromises,
  type PromiseMember,
} from "./promises.js";

// Real responses, recorded 2026-11-16 and trimmed of scripts and styles (fixtures/said): the FEC's
// principal campaign committees, Wayback CDX answers and the archived pages themselves.
const here = dirname(fileURLToPath(import.meta.url));
const fixture = (name: string) => readFileSync(join(here, "../fixtures/said", name), "utf8");
const json = (name: string) => JSON.parse(fixture(name));

const SLOTKIN: PromiseMember = {
  bioguide_id: "S001208", first_name: "Elissa", last_name: "Slotkin", chamber: "senate", state: "MI",
  term_start: "2025-01-03", term_end: "2031-01-03", fec: ["H8MI08102", "S4MI00470"],
};
const GILLIBRAND: PromiseMember = {
  bioguide_id: "G000555", first_name: "Kirsten", last_name: "Gillibrand", chamber: "senate", state: "NY",
  term_start: "2025-01-03", term_end: "2031-01-03", fec: ["H6NY20167", "S0NY00410"],
};

const fec: FecGet = async (path) => {
  if (path === "/candidate/S4MI00470/committees/?designation=P&cycle=2024") return json("fec-slotkin-committees.json");
  if (path === "/candidate/S0NY00410/committees/?designation=P&cycle=2024") return json("fec-gillibrand-committees.json");
  return { results: [] };
};

const PAGES: Record<string, string> = {
  [cdxUrl("https://elissaslotkin.org/", "2024-11-05")]: fixture("wayback-cdx-slotkin.json"),
  "https://web.archive.org/web/20241104213328id_/https://elissaslotkin.org/": fixture("wayback-slotkin-home.html"),
  [cdxUrl("https://elissaslotkin.org/priorities/", "2024-11-05")]: fixture("wayback-cdx-slotkin-pri.json"),
  "https://web.archive.org/web/20241027183232id_/https://elissaslotkin.org/priorities/": fixture("wayback-slotkin-priorities.html"),
  [cdxUrl("https://www.kirstengillibrand.com/", "2024-11-05")]: fixture("wayback-cdx-gillibrand.json"),
  "https://web.archive.org/web/20241102220058id_/https://kirstengillibrand.com/": fixture("wayback-gillibrand-home.html"),
};
const wayback: FetchText = async (url) => (url in PAGES ? { status: 200, text: PAGES[url]! } : { status: 404, text: "" });

const REAL = "In the Senate, Elissa will work every day to bring critical supply chains and manufacturing back home.";
// What a model might write that the page does not say. It must never be stored.
const FABRICATED = "Elissa will cut every Michigan family's taxes in half in her first year in the Senate.";

/** A stand-in for Claude, returning fixed picks and recording what it was asked. */
function model(promises: { heading: string; quote: string; headline: string; topic: string }[]) {
  const calls: ModelCall[] = [];
  const complete: Complete = async (call) => {
    calls.push(call);
    return {
      data: { promises },
      model: "claude-sonnet-5-5",
      parts: [{ model: "claude-sonnet-5-5", usage: { input_tokens: 3000, output_tokens: 500, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 } }],
    };
  };
  return { complete, calls };
}

const slotkinPicks = [
  { heading: "Making Things in America", quote: REAL, headline: "bring critical supply chains and manufacturing back home", topic: "Commerce" },
  { heading: "Making Things in America", quote: FABRICATED, headline: "cut every Michigan family's taxes in half", topic: "Taxation" },
];

describe("the race and the site", () => {
  it("dates the race that won the term, and the day a snapshot must precede", () => {
    expect(electionYear("2025-01-03")).toBe(2024);
    expect(snapshotCutoff("2025-01-03")).toBe("2024-11-05");
    expect(electionYear("2023-01-03")).toBe(2022);
    expect(snapshotCutoff("2023-01-03")).toBe("2022-11-08");
    // A special election's term: no election day held, so the start of the term.
    expect([electionYear("2025-04-02"), snapshotCutoff("2025-04-02")]).toEqual([2025, "2025-04-02"]);
  });

  it("takes the website from the member's own principal committee, normalised", async () => {
    expect(await committeeSite(fec, "S4MI00470", 2024)).toBe("https://elissaslotkin.org/");
    expect(await committeeSite(fec, "S0NY00410", 2024)).toBe("https://www.kirstengillibrand.com/");
    // A committee that does not name this candidate is someone else's.
    expect(await committeeSite(async () => json("fec-slotkin-committees.json"), "S0NY00410", 2024)).toBeNull();
    expect(normalizeSite("HTTPS://WWW.BECCABALINT.COM/")).toBe("https://www.beccabalint.com/");
    expect(normalizeSite("N/A")).toBeNull();
  });
});

describe("the Wayback Machine", () => {
  it("asks CDX for captures through the day before the election, and refuses a later one", () => {
    expect(cdxUrl("https://elissaslotkin.org/", "2024-11-05")).toContain("&to=20241104&");
    const rows = json("wayback-cdx-slotkin.json");
    expect(lastCapture(rows, "2024-11-05")).toEqual({ timestamp: "20241104213328", original: "https://elissaslotkin.org/" });
    expect(lastCapture([...rows, ["20241105120000", "https://elissaslotkin.org/", "200", "text/html"]], "2024-11-05")!.timestamp).toBe("20241104213328");
    expect(lastCapture([rows[0]], "2024-11-05")).toBeNull();
    // An older race's site: jasoncrow.org's last capture before the 2024 election (CDX, 2026-11-16).
    expect(cdxUrl("https://jasoncrow.org/", "2024-11-05")).toContain("&from=20230101&");
    expect(lastCapture([rows[0], ["20211205114837", "http://jasoncrow.org/", "200", "text/html"]], "2024-11-05")).toBeNull();
    expect(rawUrl({ timestamp: "20241027183232", original: "https://elissaslotkin.org/priorities/" })).toBe(
      "https://web.archive.org/web/20241027183232id_/https://elissaslotkin.org/priorities/",
    );
  });

  it("finds the priorities page among the home page's links, and none on a donate-only page", () => {
    expect(findPlatformPage(fixture("wayback-slotkin-home.html"), "https://elissaslotkin.org/")).toBe("https://elissaslotkin.org/priorities/");
    // Its only same-site links are about, privacy and terms.
    expect(findPlatformPage(fixture("wayback-gillibrand-home.html"), "https://kirstengillibrand.com/")).toBeNull();
  });

  it("reads the page as text with its headings on their own lines", () => {
    const text = pageText(fixture("wayback-slotkin-priorities.html")).split("\n");
    for (const h of ["Protecting our Rights and Democracy", "Keeping our Communities and Kids Safe", "Making Things in America", "Defending and Expanding Michigan’s Middle Class"]) {
      expect(text).toContain(h);
    }
    expect(text.join(" ")).toContain(REAL);
    expect(text.join(" ")).not.toMatch(/<|function\(|&amp;/);
  });
});

describe("verifyPromises", () => {
  const text = pageText(fixture("wayback-slotkin-priorities.html"));

  it("keeps the real quote and drops the fabricated one", () => {
    expect(verifyPromises(text, slotkinPicks)).toEqual([
      { heading: "Making Things in America", quote: REAL, headline: "bring critical supply chains and manufacturing back home", topic: "Commerce" },
    ]);
  });

  it("matches across typography, and drops a headline that is not inside its quote, a made-up heading and topic", () => {
    const straight = "Defending and Expanding Michigan's Middle Class";
    const [p] = verifyPromises(text, [
      { heading: straight, quote: `${REAL.replace("Senate,", "Senate,\n ")}`, headline: "critical supply chains", topic: "Manufacturing" },
    ]);
    expect(p).toEqual({ heading: straight, quote: REAL, headline: "critical supply chains", topic: null });
    expect(verifyPromises(text, [{ ...slotkinPicks[0]!, headline: "ban corporate PACs" }])).toEqual([]);
    expect(verifyPromises(text, [{ ...slotkinPicks[0]!, heading: "Lower Costs" }])[0]!.heading).toBeNull();
    // A heading must be a line of the page, not a few words from inside a sentence.
    expect(verifyPromises(text, [{ ...slotkinPicks[0]!, heading: "critical supply chains" }])[0]!.heading).toBeNull();
    expect(verifyPromises(text, [{ ...slotkinPicks[0]!, quote: "Elissa believes", headline: "Elissa" }])).toEqual([]);
    expect(verifyPromises(text, [slotkinPicks[0]!, slotkinPicks[0]!])).toHaveLength(1);
  });

  it("uses Floor's 32 topics exactly", () => {
    expect([...TOPICS]).toEqual([...POLICY_AREAS]);
  });
});

describe("readCampaignSite", () => {
  it("reads Slotkin's 2024 priorities page and keeps only verbatim lines", async () => {
    const m = model(slotkinPicks);
    const r = await readCampaignSite(SLOTKIN, { fec, fetchText: wayback, complete: m.complete });
    expect(r).toMatchObject({
      election_year: 2024,
      site_url: "https://elissaslotkin.org/",
      snapshot_url: "https://web.archive.org/web/20241027183232/https://elissaslotkin.org/priorities/",
      snapshot_at: "2024-10-27T18:32:32Z",
      page_url: "https://elissaslotkin.org/priorities/",
      status: "promises",
    });
    expect(r.promises.map((p) => p.quote)).toEqual([REAL]);
    expect(m.calls).toHaveLength(1);
    expect(m.calls[0]!.user).toContain("Election: 2024");
    expect(m.calls[0]!.user).toContain(REAL);
  });

  it("says no_platform for Gillibrand's donate-only home page, without calling the model", async () => {
    const m = model([]);
    const r = await readCampaignSite(GILLIBRAND, { fec, fetchText: wayback, complete: m.complete });
    expect(r).toMatchObject({
      status: "no_platform",
      site_url: "https://www.kirstengillibrand.com/",
      snapshot_url: "https://web.archive.org/web/20241102220058/https://kirstengillibrand.com/",
      page_url: null,
      promises: [],
    });
    expect(m.calls).toHaveLength(0);
  });

  it("says no_site with no FEC ID or committee website, and no_snapshot with no capture", async () => {
    const m = model([]);
    const deps = { fec, fetchText: wayback, complete: m.complete };
    expect((await readCampaignSite({ ...SLOTKIN, fec: [] }, deps)).status).toBe("no_site");
    expect((await readCampaignSite({ ...SLOTKIN, fec: ["S4MI99999"] }, deps)).status).toBe("no_site");
    const empty: FetchText = async () => ({ status: 200, text: "" });
    expect(await readCampaignSite(SLOTKIN, { ...deps, fetchText: empty })).toMatchObject({ status: "no_snapshot", site_url: "https://elissaslotkin.org/" });
  });
});

describe("runPromises (PGlite)", () => {
  let pg: PGlite;
  beforeEach(async () => {
    pg = new PGlite();
    await pg.exec(`create schema auth; create table auth.users (id uuid primary key);
      create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;`);
    for (const mig of loadMigrations()) await pg.exec(mig.sql);
    await pg.exec(`insert into members (bioguide_id, first_name, last_name, party, state, district, chamber, term_start, term_end, ids) values
      ('S001208', 'Elissa', 'Slotkin', 'D', 'MI', null, 'senate', '2025-01-03', '2099-01-03', '{"fec":["H8MI08102","S4MI00470"]}'),
      ('G000555', 'Kirsten', 'Gillibrand', 'D', 'NY', null, 'senate', '2025-01-03', '2099-01-03', '{"fec":["H6NY20167","S0NY00410"]}'),
      ('X000002', 'Failing', 'Member', 'R', 'TX', 2, 'house', '2025-01-03', '2099-01-03', '{"fec":["H4TX02000"]}')`);
  });

  const failingFec: FecGet = async (path) => {
    if (path.startsWith("/candidate/H4TX02000/")) throw new Error("OpenFEC /candidate/H4TX02000/committees/ returned HTTP 500");
    return fec(path);
  };

  it("stores each member's status and verified promises, a failure as failed, within the budget", async () => {
    const m = model(slotkinPicks);
    const r = await runPromises(pg as unknown as Db, { fec: failingFec, fetchText: wayback, complete: m.complete }, { budget: 10 });
    expect(r).toMatchObject({ ran: true, checked: 3, byStatus: { promises: 1, no_platform: 1, no_site: 0, no_snapshot: 0, failed: 1 } });
    const sites = await pg.query("select member_id, election_year, status, page_url from campaign_sites order by 1");
    expect(sites.rows).toEqual([
      { member_id: "G000555", election_year: 2024, status: "no_platform", page_url: null },
      { member_id: "S001208", election_year: 2024, status: "promises", page_url: "https://elissaslotkin.org/priorities/" },
      { member_id: "X000002", election_year: 2024, status: "failed", page_url: null },
    ]);
    const promises = await pg.query("select member_id, position, heading, quote, headline, topic from campaign_promises");
    expect(promises.rows).toEqual([
      { member_id: "S001208", position: 1, heading: "Making Things in America", quote: REAL, headline: "bring critical supply chains and manufacturing back home", topic: "Commerce" },
    ]);

    // Nothing left to check: everyone has a row and the failure is too recent to retry.
    expect((await runPromises(pg as unknown as Db, { fec, fetchText: wayback, complete: m.complete })).checked).toBe(0);
    // A recheck on demand replaces the member's promises rather than adding to them.
    const again = await runPromises(pg as unknown as Db, { fec, fetchText: wayback, complete: m.complete }, { members: ["S001208"] });
    expect(again.checked).toBe(1);
    expect((await pg.query("select count(*)::int as n from campaign_promises")).rows).toEqual([{ n: 1 }]);
  });

  it("stops at the budget", async () => {
    const m = model(slotkinPicks);
    const r = await runPromises(pg as unknown as Db, { fec, fetchText: wayback, complete: m.complete }, { budget: 1 });
    expect(r.checked).toBe(1);
    expect((await pg.query("select count(*)::int as n from campaign_sites")).rows).toEqual([{ n: 1 }]);
  });
});

describe("parsePromisesArgs", () => {
  it("reads the budget, a recheck and members, and refuses anything else", () => {
    expect(parsePromisesArgs([])).toEqual({ budget: 25, recheck: false, members: [] });
    expect(parsePromisesArgs(["--budget", "40", "--recheck", "--member", "S001208"])).toEqual({ budget: 40, recheck: true, members: ["S001208"] });
    expect(() => parsePromisesArgs(["--budget", "0"])).toThrow(/positive/);
    expect(() => parsePromisesArgs(["--member", "slotkin"])).toThrow(/Bioguide/);
    expect(() => parsePromisesArgs(["--all"])).toThrow(/unknown/);
  });
});
