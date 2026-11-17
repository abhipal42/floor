import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import { EMPTY_SCHEDULE, NO_CONTACT, createApp, type Bill, type ScheduleRepository } from "./app.js";
import {
  appSiteAssociation,
  assetLinks,
  billIdFromPath,
  cardTitleSize,
  road,
  shareKicker,
  shareText,
  shareUrl,
  type FloorWeek,
} from "./share.js";

// A Thursday, Eastern: the week of Nov 16 is next week.
const NOW = new Date("2026-11-12T17:00:00Z");

// H.R. 5267 of the 119th Congress, as the locked design shows it. Fields the page reads only.
const bill: Bill = {
  id: "119-hr-5267",
  congress: 119,
  type: "hr",
  number: 5267,
  citation: "H.R. 5267",
  title: "To amend the National Labor Relations Act to clarify the standard for determining joint employer status, and for other purposes.",
  shortTitle: "American Franchise Act",
  label: "American Franchise Act",
  stage: "introduced",
  sponsor: null,
  introducedOn: "2025-09-10",
  originChamber: "house",
  policyArea: "Labor and Employment",
  summary: "This bill specifies the circumstances under which an employer is a joint employer.\nIt applies to franchises.",
  summaryStage: "Introduced in House",
  latestAction: { on: "2026-11-10", text: "Placed on the Union Calendar, Calendar No. 412." },
  cboEstimates: [],
  actions: [{ actedOn: "2025-09-10", chamber: "house", text: "Introduced in House" }],
  votes: [],
};

const week: FloorWeek = { chamber: "house", weekOf: "2026-11-16" };

describe("the share line and link", () => {
  it("reads as the locked design's line, neutral, with the bill's own name", () => {
    expect(shareText(bill, week)).toBe(
      "H.R. 5267, the American Franchise Act, is up for a House vote the week of Nov 16. What it does and how our members vote:",
    );
    expect(shareUrl(bill)).toBe("https://floor-web-seven.vercel.app/bill/119/hr/5267");
  });

  it("says where it stands when nothing is scheduled, and names no title it does not have", () => {
    expect(shareText({ ...bill, stage: "passed_house" }, null)).toBe(
      "H.R. 5267, the American Franchise Act, passed the House. What it does and where it stands:",
    );
    expect(shareText({ ...bill, shortTitle: null, stage: "law" }, null)).toBe("H.R. 5267 became law. What it does and where it stands:");
  });

  it("names a bill by its official title when that title is a name, as many bills without a short title are", () => {
    expect(shareText({ ...bill, shortTitle: null, title: "American Franchise Act" }, week)).toBe(
      "H.R. 5267, the American Franchise Act, is up for a House vote the week of Nov 16. What it does and how our members vote:",
    );
    expect(shareText({ ...bill, shortTitle: null, title: "To amend the National Trails System Act, and for other purposes." }, week)).toBe(
      "H.R. 5267 is up for a House vote the week of Nov 16. What it does and how our members vote:",
    );
    expect(shareText({ ...bill, shortTitle: null, title: "Providing for consideration of the bill (H.R. 5267)" }, null)).toBe(
      "H.R. 5267 was introduced in the House. What it does and where it stands:",
    );
  });

  it("kicks off with the floor week, else the stage", () => {
    expect(shareKicker(bill, week, NOW)).toBe("H.R. 5267 · ON THE FLOOR THE WEEK OF NOV 16");
    expect(shareKicker(bill, week, new Date("2026-11-17T15:00:00Z"))).toBe("H.R. 5267 · ON THE FLOOR THIS WEEK");
    expect(shareKicker({ ...bill, stage: "to_president" }, null, NOW)).toBe("H.R. 5267 · SENT TO THE PRESIDENT");
    expect(shareKicker({ ...bill, stage: null }, null, NOW)).toBe("H.R. 5267");
  });

  it("reads a link's parts as a bill id, and refuses anything else", () => {
    expect(billIdFromPath("119", "hr", "5267")).toBe("119-hr-5267");
    for (const [c, t, n] of [["119", "HR", "5267"], ["119", "pn", "1"], ["1", "hr", "1"], ["119", "hr", "0"], ["119", "hr", "1x"]]) {
      expect(billIdFromPath(c!, t!, n!)).toBeNull();
    }
  });
});

describe("road", () => {
  const states = (b: Partial<Bill>) => road({ ...bill, ...b }).map((s) => `${s.label}:${s.state}`);

  it("is five steps for a bill, settled at law", () => {
    expect(states({ stage: "introduced" })).toEqual([
      "Introduced:current", "Passed one chamber:todo", "Passed both:todo", "To the President:todo", "Law:todo",
    ]);
    expect(states({ stage: "passed_senate" })[1]).toBe("Passed one chamber:current");
    expect(states({ stage: "law" }).every((s) => s.endsWith(":done"))).toBe(true);
  });

  it("stops at the step a veto or a failure did not make", () => {
    expect(states({ stage: "vetoed" }).slice(3)).toEqual(["To the President:done", "Vetoed:stopped"]);
    expect(states({ stage: "failed" }).slice(0, 2)).toEqual(["Introduced:done", "Failed:stopped"]);
  });

  it("is shorter for a resolution", () => {
    expect(states({ type: "hres", stage: "adopted" })).toEqual(["Introduced:done", "Agreed to:done"]);
    expect(states({ type: "hconres", stage: "passed_house" })).toEqual(["Introduced:done", "Passed one chamber:current", "Agreed to by both:todo"]);
  });
});

describe("share routes", () => {
  const schedule: ScheduleRepository = { ...EMPTY_SCHEDULE, floorWeek: async (id) => (id === bill.id ? week : null) };
  const appWith = (share = {}) =>
    createApp({
      votes: { getVote: async () => null, recentVotes: async () => [], voteBreakdown: async () => ({ partyTotals: [], candidateTotals: [], positions: [], measure: null }) },
      members: {
        membersFor: async () => [],
        recentVotes: async () => [],
        getMember: async () => null,
        search: async () => [],
        partyLoyalty: async () => ({ votes: 0, withParty: 0, againstParty: 0 }),
        funding: async () => null,
        contact: async () => NO_CONTACT,
      },
      bills: {
        getBill: async (id) =>
          id === bill.id ? bill : id === "119-hr-1" ? { ...bill, id, number: 1, shortTitle: `<script>alert(1)</script> & "Act"` } : null,
        getAnalysis: async () => null,
      },
      nominations: { getNomination: async () => null },
      status: { lastRuns: async () => [] },
      live: { chambers: async () => [], liveVotes: async () => [] },
      locate: async () => null,
      schedule,
      now: () => NOW,
      share,
    });

  it("gives the app its share line and link", async () => {
    const res = await appWith().request("/v1/bills/119-hr-5267/share");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      url: "https://floor-web-seven.vercel.app/bill/119/hr/5267",
      text: "H.R. 5267, the American Franchise Act, is up for a House vote the week of Nov 16. What it does and how our members vote:",
      kicker: "H.R. 5267 · ON THE FLOOR THE WEEK OF NOV 16",
    });
    expect((await appWith().request("/v1/bills/119-hr-9/share")).status).toBe(404);
  });

  it("serves the page with its preview tags, summary, road and lookup", async () => {
    const res = await appWith().request("/bill/119/hr/5267");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toMatch(/^text\/html/);
    const html = await res.text();
    expect(html).toContain('<meta property="og:image" content="https://floor-web-seven.vercel.app/bill/119/hr/5267/card.png">');
    expect(html).toContain('<meta name="twitter:card" content="summary_large_image">');
    expect(html).toContain('<meta property="og:url" content="https://floor-web-seven.vercel.app/bill/119/hr/5267">');
    expect(html).toContain("<h1>American Franchise Act</h1>");
    expect(html).toContain("H.R. 5267 · ON THE FLOOR THE WEEK OF NOV 16");
    expect(html).toContain("<p>It applies to franchises.</p>");
    expect(html).toContain("Congressional Research Service summary (Introduced in House).");
    expect(html).toContain('<li class="current">Introduced</li>');
    expect(html).toContain("Placed on the Union Calendar, Calendar No. 412.");
    expect(html).toContain("Get Floor for iPhone");
    expect(html).toContain('data-api="https://floor-api.vercel.app"');
  });

  it("allows only its own script, by hash, and the API it looks members up on", async () => {
    const res = await appWith({ apiBase: "https://api.example.test" }).request("/bill/119/hr/5267");
    const csp = res.headers.get("content-security-policy")!;
    const html = await res.text();
    const script = /<script>([\s\S]*)<\/script>/.exec(html)![1]!;
    expect(csp).toContain(`script-src 'sha256-${createHash("sha256").update(script).digest("base64")}'`);
    expect(csp).toContain("connect-src https://api.example.test");
    expect(csp).toContain("default-src 'none'");
    // The script reads its data from attributes, so it holds none.
    expect(script).not.toContain("5267");
  });

  it("escapes what it prints", async () => {
    const html = await (await appWith().request("/bill/119/hr/1")).text();
    expect(html).not.toContain("<script>alert(1)");
    expect(html).toContain("&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;Act&quot;");
  });

  it("answers an unknown or malformed bill with a 404 page", async () => {
    for (const path of ["/bill/119/hr/9", "/bill/119/pn/1", "/bill/abc/hr/1"]) {
      const res = await appWith().request(path);
      expect(res.status).toBe(404);
      expect(await res.text()).toContain("No such bill");
    }
    expect((await appWith().request("/bill/119/hr/9/card.png")).status).toBe(404);
  });

  it("renders the preview card as a 1200×630 PNG", async () => {
    const res = await appWith().request("/bill/119/hr/5267/card.png");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("image/png");
    const png = Buffer.from(await res.arrayBuffer());
    expect(png.subarray(0, 8).toString("hex")).toBe("89504e470d0a1a0a");
    expect(png.readUInt32BE(16)).toBe(1200);
    expect(png.readUInt32BE(20)).toBe(630);
  }, 30_000);

  it("sizes the title to fit", () => {
    expect(cardTitleSize("American Franchise Act")).toBe(120);
    expect(cardTitleSize("x".repeat(100))).toBe(64);
  });

  it("serves the universal-link association for Ishan's team unless told another", async () => {
    const byDefault = await appWith().request("/.well-known/apple-app-site-association");
    expect(byDefault.status).toBe(200);
    expect(JSON.stringify(await byDefault.json())).toContain('"DCCFA8MX7A.app.floor.ios"');
    const res = await appWith({ appleTeamId: "ABCDE12345" }).request("/.well-known/apple-app-site-association");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toMatch(/^application\/json/);
    expect(await res.json()).toEqual({
      applinks: { details: [{ appIDs: ["ABCDE12345.app.floor.ios"], components: [{ "/": "/bill/*", comment: "A shared bill opens its bill screen" }] }] },
    });
    expect(appSiteAssociation({ appleTeamId: "not a team" })).toBeNull();
  });

  it("serves Android's asset links for the debug key unless told the release ones", async () => {
    const byDefault = await appWith().request("/.well-known/assetlinks.json");
    expect(byDefault.status).toBe(200);
    expect(byDefault.headers.get("content-type")).toMatch(/^application\/json/);
    expect(await byDefault.json()).toEqual([
      {
        relation: ["delegate_permission/common.handle_all_urls"],
        target: {
          namespace: "android_app",
          package_name: "app.floor.android",
          sha256_cert_fingerprints: [
            "AC:7D:DB:82:85:C7:84:3F:D5:44:FC:6D:EB:DF:E4:95:DF:A0:9B:BF:39:3F:61:15:6B:23:CA:62:F3:37:D5:46",
          ],
        },
      },
    ]);
    const release = "14:6D:E9:83:C5:73:06:50:D8:EE:B9:95:2F:34:FC:64:16:A0:83:42:E6:1D:BE:A8:8A:04:96:B2:3F:CF:44:E5";
    const res = await appWith({ androidCertSha256: [` ${release.toLowerCase()}`, "not a print"] }).request("/.well-known/assetlinks.json");
    const body = (await res.json()) as { target: { sha256_cert_fingerprints: string[] } }[];
    expect(body[0]?.target.sha256_cert_fingerprints).toEqual([release]);
    expect(assetLinks({ androidCertSha256: ["AC:7D"] })).toBeNull();
  });
});
