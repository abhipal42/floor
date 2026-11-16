/**
 * Members-elect: who won a seat and has not taken office yet (`members_elect`), and the seats whose
 * race is not settled (`seats_pending`). Floor never calls a race; every row names who did and links
 * the source. Three loaders:
 *
 * - `elections`: `apps/worker/elections/<cycle>-senate.json`, the Senate races as the AP called them,
 *   kept in the repo so every call is reviewable in a diff. A seat the incumbent kept adds nothing.
 * - `members-elect-house`: the House Clerk's unofficial member-elect list (late December). House
 *   seats wait for it: Floor shows no House AP calls.
 * - `elect-disclosures`: the candidate reports (FilingType C) of House members-elect, from the same
 *   Clerk index the member disclosures use. The Senate's eFD candidate reports are not read (yet).
 *
 * The API stops serving all of it on `takes_office`, when congress-legislators takes over.
 */
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { Db } from "./db.js";
import { errorText, startRun } from "./db.js";
import { normName, storeParse, Throttle, fileCache, type Cache, type ListedFiling } from "./disclosures.js";

// ---------------------------------------------------------------------------------------------
// The Senate races file

export interface Race {
  state: string;
  special: boolean;
  incumbent: { name: string; party: string; running: boolean } | null;
  status: "called" | "uncalled" | "runoff";
  winner: { firstName: string; lastName: string; party: string; isIncumbent: boolean; fecCandidateId: string | null } | null;
  calledBy: "AP" | null;
  calledOn: string | null;
  runoffOn: string | null;
  sourceUrl: string;
  note: string | null;
}

export interface Elections {
  cycle: number;
  chamber: "senate";
  /** When the winners of the regular races take office: January 3 after the election. */
  takesOffice: string;
  races: Race[];
}

const RACE_KEYS = ["state", "special", "incumbent", "status", "winner", "calledBy", "calledOn", "runoffOn", "sourceUrl", "note"];
const WINNER_KEYS = ["firstName", "lastName", "party", "isIncumbent", "fecCandidateId"];
const INCUMBENT_KEYS = ["name", "party", "running"];
const DAY = /^\d{4}-\d{2}-\d{2}$/;

const isDay = (v: unknown): v is string =>
  typeof v === "string" && DAY.test(v) && new Date(`${v}T00:00:00Z`).toISOString().slice(0, 10) === v;

/**
 * Throws on anything the file must not hold. Race fields are strict (an unknown or missing key
 * fails), so a typo cannot silently drop a call; other top-level keys are notes and must be strings.
 */
export function checkElections(raw: unknown, file: string): Elections {
  const fail = (why: string): never => {
    throw new Error(`${file}: ${why}`);
  };
  const named = /^(\d{4})-senate\.json$/.exec(file);
  if (!named) fail("the file must be named <cycle>-senate.json");
  const cycle = Number(named![1]);
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) fail("the file must hold an object with races");
  const top = raw as Record<string, unknown>;
  for (const [k, v] of Object.entries(top)) if (k !== "races" && typeof v !== "string") fail(`top-level "${k}" must be a string note`);
  if (!Array.isArray(top["races"])) fail("races must be a list");
  const exactKeys = (o: unknown, keys: string[], what: string) => {
    if (typeof o !== "object" || o === null || Array.isArray(o)) fail(`${what} must be an object`);
    const have = Object.keys(o as object).sort();
    const want = [...keys].sort();
    const extra = have.filter((k) => !want.includes(k));
    const missing = want.filter((k) => !have.includes(k));
    if (extra.length) fail(`${what} has unknown ${extra.join(", ")}`);
    if (missing.length) fail(`${what} is missing ${missing.join(", ")}`);
  };
  const text = (v: unknown) => typeof v === "string" && v.trim().length > 0;
  const seen = new Set<string>();
  (top["races"] as unknown[]).forEach((r0, i) => {
    exactKeys(r0, RACE_KEYS, `race ${i + 1}`);
    const r = r0 as Race;
    const at = `race ${i + 1} (${String(r.state)})`;
    if (typeof r.state !== "string" || !/^[A-Z]{2}$/.test(r.state)) fail(`${at}: state must be a USPS code`);
    // One race per state: the ids ('elect-2026-mi-sen') name the state's seat, not the class.
    if (seen.has(r.state)) fail(`${at}: a second race in the same state`);
    seen.add(r.state);
    if (typeof r.special !== "boolean") fail(`${at}: special must be true or false`);
    if (r.incumbent !== null) {
      exactKeys(r.incumbent, INCUMBENT_KEYS, `${at} incumbent`);
      if (!text(r.incumbent.name) || !text(r.incumbent.party)) fail(`${at}: incumbent needs a name and party`);
      if (typeof r.incumbent.running !== "boolean") fail(`${at}: incumbent.running must be true or false`);
    }
    if (!["called", "uncalled", "runoff"].includes(r.status)) fail(`${at}: status must be called, uncalled or runoff`);
    if (typeof r.sourceUrl !== "string" || !r.sourceUrl.startsWith("https://")) fail(`${at}: sourceUrl must be an https link`);
    if (r.note !== null && typeof r.note !== "string") fail(`${at}: note must be text or null`);
    if (r.runoffOn !== null && !isDay(r.runoffOn)) fail(`${at}: runoffOn must be YYYY-MM-DD or null`);
    if (r.calledOn !== null && !isDay(r.calledOn)) fail(`${at}: calledOn must be YYYY-MM-DD or null`);
    if (r.calledBy !== null && r.calledBy !== "AP") fail(`${at}: calledBy must be "AP" or null`);
    if (r.status === "called") {
      if (r.calledBy !== "AP" || r.calledOn === null) fail(`${at}: a called race needs calledBy "AP" and calledOn`);
      if (r.runoffOn !== null) fail(`${at}: a called race has no runoff date`);
      exactKeys(r.winner, WINNER_KEYS, `${at} winner`);
      const w = r.winner!;
      if (!text(w.firstName) || !text(w.lastName) || !text(w.party)) fail(`${at}: winner needs a first name, last name and party`);
      if (typeof w.isIncumbent !== "boolean") fail(`${at}: winner.isIncumbent must be true or false`);
      if (w.isIncumbent && !r.incumbent?.running) fail(`${at}: the winner is the incumbent, but no incumbent is running`);
      if (w.fecCandidateId !== null && !(typeof w.fecCandidateId === "string" && new RegExp(`^S\\d${r.state}\\d{5}$`).test(w.fecCandidateId))) {
        fail(`${at}: fecCandidateId must be a Senate candidate ID in ${r.state} (S<digit>${r.state}<5 digits>) or null`);
      }
    } else {
      if (r.winner !== null) fail(`${at}: only a called race names a winner`);
      if (r.status === "runoff" && r.runoffOn === null) fail(`${at}: a runoff needs runoffOn`);
      if (r.status === "uncalled" && (r.calledBy !== null || r.calledOn !== null || r.runoffOn !== null)) {
        fail(`${at}: an uncalled race has no calledBy, calledOn or runoffOn`);
      }
    }
  });
  return { cycle, chamber: "senate", takesOffice: `${cycle + 1}-01-03`, races: top["races"] as Race[] };
}

export function readElections(dir: string): Elections[] {
  return readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .sort()
    .map((f) => checkElections(JSON.parse(readFileSync(join(dir, f), "utf8")), f));
}

/** 'elect-2026-mi-sen', 'elect-2026-ny-12', 'elect-2026-ak-al'. */
export const electId = (cycle: number, state: string, district: number | null) =>
  `elect-${cycle}-${state.toLowerCase()}-${district === null ? "sen" : district === 0 ? "al" : district}`;

interface SeatMember {
  bioguide_id: string;
  first_name: string;
  last_name: string;
  state: string;
  district: number | null;
  term_end: string;
}

/**
 * The senator a race's `incumbent` names, among the state's senators whose term ends with this
 * election (a regular term on January 3, an appointee's on the special election's day). The full
 * name must match, or the surname must end the name and pick out one senator; anything looser is
 * null, never a guess.
 */
export function matchIncumbent(senators: SeatMember[], state: string, name: string): string | null {
  const inState = senators.filter((m) => m.state === state);
  const full = normName(name);
  const exact = inState.filter((m) => normName(`${m.first_name} ${m.last_name}`) === full);
  if (exact.length === 1) return exact[0]!.bioguide_id;
  const bySurname = inState.filter((m) => full.endsWith(normName(m.last_name)));
  return bySurname.length === 1 ? bySurname[0]!.bioguide_id : null;
}

const dayText = (d: unknown) => (d instanceof Date ? d.toISOString().slice(0, 10) : String(d).slice(0, 10));

/**
 * Replaces the cycle's AP rows with the file's: upserts what it holds and deletes what it no longer
 * does, so a call corrected in the file is corrected in the database. FEC totals already fetched for
 * an elect are kept across loads.
 */
export async function loadElections(
  db: Db,
  e: Elections,
  log: (msg: string) => void = () => {},
): Promise<{ elect: number; pending: number; unmatched: string[] }> {
  const { rows } = await db.query<SeatMember & { term_end: Date | string }>(
    `select bioguide_id, first_name, last_name, state, district, term_end from members
      where chamber = 'senate' and term_end between $1::date and $2::date`,
    [`${e.cycle}-01-01`, e.takesOffice],
  );
  const senators = rows.map((r) => ({ ...r, term_end: dayText(r.term_end) }));
  const unmatched: string[] = [];
  const incumbentOf = (r: Race) => {
    if (!r.incumbent) return null;
    const id = matchIncumbent(senators, r.state, r.incumbent.name);
    if (!id) {
      unmatched.push(`${r.state}: ${r.incumbent.name}`);
      log(`${r.state}: no senator whose term ends this cycle matches "${r.incumbent.name}"; stored with no incumbent`);
    }
    return id;
  };
  const elect = e.races
    .filter((r) => r.status === "called" && r.winner && !r.winner.isIncumbent)
    .map((r) => ({
      id: electId(e.cycle, r.state, null),
      cycle: e.cycle,
      first_name: r.winner!.firstName,
      last_name: r.winner!.lastName,
      party: r.winner!.party,
      state: r.state,
      replaces: incumbentOf(r),
      takes_office: e.takesOffice,
      on_certification: r.special,
      called_on: r.calledOn,
      source_url: r.sourceUrl,
      fec_candidate_id: r.winner!.fecCandidateId,
    }));
  const pending = e.races
    .filter((r) => r.status !== "called")
    .map((r) => ({
      id: electId(e.cycle, r.state, null),
      cycle: e.cycle,
      state: r.state,
      status: r.status,
      runoff_on: r.runoffOn,
      incumbent: incumbentOf(r),
      source_url: r.sourceUrl,
    }));
  await db.query(
    `with input as (
       select * from jsonb_to_recordset($2::jsonb) as x(id text, cycle smallint, first_name text, last_name text, party text,
         state text, replaces text, takes_office date, on_certification boolean, called_on date, source_url text, fec_candidate_id text)
     ), upserted as (
       insert into members_elect (id, cycle, bioguide_id, first_name, last_name, party, state, district, chamber, replaces,
                                  takes_office, on_certification, called_by, called_on, source_url, fec_candidate_id)
       select id, cycle, null, first_name, last_name, party, state, null, 'senate', replaces, takes_office, on_certification, 'AP', called_on,
              source_url, fec_candidate_id
         from input
       on conflict (id) do update set first_name = excluded.first_name, last_name = excluded.last_name, party = excluded.party,
         replaces = excluded.replaces, takes_office = excluded.takes_office, on_certification = excluded.on_certification, called_by = excluded.called_by,
         called_on = excluded.called_on, source_url = excluded.source_url, fec_candidate_id = excluded.fec_candidate_id
       returning 1
     )
     delete from members_elect
      where cycle = $1 and called_by = 'AP' and chamber = 'senate' and id not in (select id from input)`,
    [e.cycle, JSON.stringify(elect)],
  );
  await db.query(
    `with input as (
       select * from jsonb_to_recordset($2::jsonb) as x(id text, cycle smallint, state text, status text, runoff_on date,
         incumbent text, source_url text)
     ), upserted as (
       insert into seats_pending (id, cycle, state, district, chamber, status, runoff_on, incumbent, source_url)
       select id, cycle, state, null, 'senate', status, runoff_on, incumbent, source_url from input
       on conflict (id) do update set status = excluded.status, runoff_on = excluded.runoff_on,
         incumbent = excluded.incumbent, source_url = excluded.source_url
       returning 1
     )
     delete from seats_pending where cycle = $1 and chamber = 'senate' and id not in (select id from input)`,
    [e.cycle, JSON.stringify(pending)],
  );
  return { elect: elect.length, pending: pending.length, unmatched };
}

// ---------------------------------------------------------------------------------------------
// The House Clerk's member-elect list

export const clerkElectUrl = (congress: number) => `https://clerk.house.gov/xml/lists/unofficial-${congress}-member-elect-data.xml`;

/** The election year a Congress is chosen in: 2026 for the 120th. */
export const cycleOf = (congress: number) => 1786 + 2 * congress;

export interface ClerkMember {
  bioguideId: string;
  firstName: string;
  lastName: string;
  party: string;
  state: string;
  /** 0 at large, as `members` stores it. */
  district: number;
  electedOn: string | null;
}

const XML_ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };
const unescape = (s: string) => s.replace(/&(amp|lt|gt|quot|apos);/g, (_, e: string) => XML_ENTITIES[e]!).replace(/\s+/g, " ").trim();
/** The text of the first `<tag>…</tag>`; empty for `<tag/>` or a missing tag. */
const tag = (xml: string, name: string) => unescape(new RegExp(`<${name}(?:\\s[^>]*)?>([\\s\\S]*?)</${name}>`).exec(xml)?.[1] ?? "");

/** The Clerk writes American Samoa as AQ; everyone else, Floor included, as AS. */
const CLERK_STATES: Record<string, string> = { AQ: "AS" };

/** Reads the Clerk's member-elect XML: one entry per seat with a member-elect. */
export function parseClerkMembers(xml: string): { congress: number; members: ClerkMember[] } {
  const congress = Number(tag(xml, "congress-num"));
  if (!Number.isInteger(congress) || congress <= 0) throw new Error("member-elect XML has no congress-num");
  const members = [...xml.matchAll(/<member>([\s\S]*?)<\/member>/g)].map(([, m]) => {
    const sd = tag(m!, "statedistrict");
    const match = /^([A-Z]{2})(\d{2})$/.exec(sd);
    if (!match) throw new Error(`member-elect XML has a statedistrict "${sd}"`);
    const bioguideId = tag(m!, "bioguideID");
    if (!/^[A-Z]\d{6}$/.test(bioguideId)) throw new Error(`${sd} has no bioguide ID`);
    const elected = /<elected-date date="(\d{4})(\d{2})(\d{2})"/.exec(m!);
    return {
      bioguideId,
      firstName: tag(m!, "firstname"),
      lastName: tag(m!, "lastname"),
      party: tag(m!, "party"),
      state: CLERK_STATES[match[1]!] ?? match[1]!,
      district: Number(match[2]),
      electedOn: elected ? `${elected[1]}-${elected[2]}-${elected[3]}` : null,
    };
  });
  return { congress, members };
}

/**
 * Loads the Clerk's list for a Congress: a member-elect who already holds that exact seat was
 * re-elected and adds nothing; everyone else is a members_elect row replacing whoever holds the seat
 * now. Replaces the cycle's Clerk rows, so someone the Clerk drops is dropped here. Before the Clerk
 * publishes (the file 404s until late December), it stores nothing and says so.
 */
export async function ingestHouseMembersElect(
  db: Db,
  congress: number,
  opts: { fetchImpl?: typeof fetch; log?: (msg: string) => void } = {},
): Promise<{ published: boolean; listed: number; reElected: number; elect: number }> {
  const url = clerkElectUrl(congress);
  const res = await (opts.fetchImpl ?? fetch)(url, { headers: { "user-agent": "floor-ingest/0.1" } });
  if (res.status === 404) {
    opts.log?.(`The Clerk's member-elect list for the ${congress}th Congress is not published yet`);
    return { published: false, listed: 0, reElected: 0, elect: 0 };
  }
  if (!res.ok) throw new Error(`${url} returned HTTP ${res.status}`);
  const finish = await startRun(db, "members_elect_house");
  try {
    const parsed = parseClerkMembers(await res.text());
    if (parsed.congress !== congress) throw new Error(`${url} is for the ${parsed.congress}th Congress, not the ${congress}th`);
    const cycle = cycleOf(congress);
    const takesOffice = `${cycle + 1}-01-03`;
    const { rows } = await db.query<SeatMember & { term_end: Date | string }>(
      `select bioguide_id, first_name, last_name, state, district, term_end from members where chamber = 'house' and term_end >= $1::date`,
      [`${cycle}-01-01`],
    );
    const house = rows.map((r) => ({ ...r, term_end: dayText(r.term_end) }));
    const seatOf = (m: { state: string; district: number | null }) => `${m.state}-${m.district}`;
    let reElected = 0;
    const elect = parsed.members.flatMap((m) => {
      const seat = seatOf(m);
      if (house.some((h) => h.bioguide_id === m.bioguideId && seatOf(h) === seat)) {
        reElected++;
        return [];
      }
      // Whoever holds the seat in the Congress ending: the latest term there, up to the hand-over.
      const holder = house
        .filter((h) => seatOf(h) === seat && h.bioguide_id !== m.bioguideId && h.term_end <= takesOffice)
        .sort((a, b) => (a.term_end < b.term_end ? 1 : -1))[0];
      return [
        {
          id: electId(cycle, m.state, m.district),
          cycle,
          bioguide_id: m.bioguideId,
          first_name: m.firstName,
          last_name: m.lastName,
          party: m.party,
          state: m.state,
          district: m.district,
          replaces: holder?.bioguide_id ?? null,
          takes_office: takesOffice,
          called_on: m.electedOn,
          source_url: url,
        },
      ];
    });
    await db.query(
      `with input as (
         select * from jsonb_to_recordset($2::jsonb) as x(id text, cycle smallint, bioguide_id text, first_name text, last_name text,
           party text, state text, district smallint, replaces text, takes_office date, called_on date, source_url text)
       ), upserted as (
         insert into members_elect (id, cycle, bioguide_id, first_name, last_name, party, state, district, chamber, replaces,
                                    takes_office, called_by, called_on, source_url)
         select id, cycle, bioguide_id, first_name, last_name, party, state, district, 'house', replaces, takes_office,
                'House Clerk', called_on, source_url
           from input
         on conflict (id) do update set bioguide_id = excluded.bioguide_id, first_name = excluded.first_name,
           last_name = excluded.last_name, party = excluded.party, replaces = excluded.replaces,
           takes_office = excluded.takes_office, called_by = excluded.called_by, called_on = excluded.called_on,
           source_url = excluded.source_url
         returning 1
       )
       delete from members_elect where cycle = $1 and called_by = 'House Clerk' and id not in (select id from input)`,
      [cycle, JSON.stringify(elect)],
    );
    await finish(elect.length);
    return { published: true, listed: parsed.members.length, reElected, elect: elect.length };
  } catch (err) {
    await finish(0, errorText(err));
    throw err;
  }
}

// ---------------------------------------------------------------------------------------------
// Candidate reports of House members-elect

interface ElectSeat {
  id: string;
  first_name: string;
  last_name: string;
  state: string;
  district: number;
}

/**
 * The candidate report a House member-elect filed, or null. The index row must name their seat
 * (state and district) and carry their exact surname, and only one filer there may: two filers of
 * that surname for one seat is a guess, and is skipped. The latest report of that filer wins.
 */
export function matchCandidateReport(elect: ElectSeat, filings: ListedFiling[]): ListedFiling | null {
  const seat = `${elect.state}${String(elect.district).padStart(2, "0")}`;
  const last = normName(elect.last_name);
  const theirs = filings.filter((f) => f.stateDistrict?.toUpperCase() === seat && normName(f.last) === last);
  const filers = new Set(theirs.map((f) => normName(`${f.first} ${f.last}`)));
  if (filers.size !== 1) return null;
  return [...theirs].sort((a, b) => `${b.filedOn ?? ""}${b.id}`.localeCompare(`${a.filedOn ?? ""}${a.id}`))[0]!;
}

/**
 * Lists the House candidate reports for every House member-elect still to take office, stores the
 * matching one under the elect (no member), and reads it with the House parser.
 */
export async function ingestElectDisclosures(
  db: Db,
  opts: { years: number[]; budget: number; cache?: Cache; fetchImpl?: typeof fetch; throttle?: Throttle; log?: (msg: string) => void },
): Promise<{ elects: number; matched: number; parsed: number; paper: number; failed: number; requests: number }> {
  const log = opts.log ?? (() => {});
  const result = { elects: 0, matched: 0, parsed: 0, paper: 0, failed: 0, requests: 0 };
  const { rows: elects } = await db.query<ElectSeat>(
    `select id, first_name, last_name, state, district from members_elect
      where chamber = 'house' and district is not null and takes_office > current_date order by id`,
  );
  result.elects = elects.length;
  // Nothing to look for: no download at all (the Clerk's list arrives in late December).
  if (elects.length === 0) return result;
  const finish = await startRun(db, "elect_disclosures");
  try {
    const { houseSource, CANDIDATE_KINDS } = await import("./disclosures-house.js");
    const throttle = opts.throttle ?? new Throttle(1500, opts.budget);
    const source = houseSource({
      years: opts.years,
      ptrSince: "0000-01-01",
      cache: opts.cache ?? fileCache(),
      throttle,
      fetchImpl: opts.fetchImpl,
      kinds: CANDIDATE_KINDS,
    });
    const listed = await source.list();
    for (const e of elects) {
      const f = matchCandidateReport(e, listed);
      if (!f) {
        log(`${e.id}: no candidate report for ${e.first_name} ${e.last_name} at that seat`);
        continue;
      }
      result.matched++;
      const { rows } = await db.query<{ parse_status: string }>(
        `with others as (update disclosure_filings set elect_id = null where elect_id = $1 and id <> $2)
         insert into disclosure_filings (id, chamber, member_id, filer_name, filer_state_district, kind, amendment, report_year,
                                         filed_on, source_url, parse_status, elect_id)
         values ($2, 'house', null, $3, $4, 'annual', false, $5, $6, $7, 'pending', $1)
         on conflict (id) do update set elect_id = excluded.elect_id, filer_name = excluded.filer_name,
           filer_state_district = excluded.filer_state_district, filed_on = excluded.filed_on, listed_at = now()
         returning parse_status`,
        [e.id, f.id, f.filerName, f.stateDistrict, f.reportYear, f.filedOn, f.sourceUrl],
      );
      if (!["pending", "failed"].includes(rows[0]?.parse_status ?? "") || throttle.exhausted) continue;
      try {
        const parsed = await source.parse({ id: f.id, kind: "annual", sourceUrl: f.sourceUrl });
        await storeParse(db, f.id, parsed);
        if (parsed.format === "paper") result.paper++;
        else result.parsed++;
      } catch (err) {
        result.failed++;
        log(`${f.id}: ${errorText(err)}`);
        await storeParse(db, f.id, { error: errorText(err) });
      }
    }
    result.requests = throttle.requests;
    await finish(result.parsed + result.paper, undefined, result.failed);
    return result;
  } catch (err) {
    await finish(result.parsed + result.paper, errorText(err), result.failed);
    throw err;
  }
}
