import { describe, expect, it } from "vitest";
import { POLICY_AREAS, billCitation, billLabel, matchTopics, parseBillNumber, topicNamed } from "./bills.js";

describe("parseBillNumber", () => {
  it.each([
    ["hr 1013", { type: "hr", number: 1013, congress: null }],
    ["H.R.1013", { type: "hr", number: 1013, congress: null }],
    ["H.R. 1013", { type: "hr", number: 1013, congress: null }],
    ["HR-1013", { type: "hr", number: 1013, congress: null }],
    ["s 2", { type: "s", number: 2, congress: null }],
    ["S.2", { type: "s", number: 2, congress: null }],
    ["hjres 12", { type: "hjres", number: 12, congress: null }],
    ["H.J.Res. 12", { type: "hjres", number: 12, congress: null }],
    ["s.j.res.197", { type: "sjres", number: 197, congress: null }],
    ["H. Con. Res. 14", { type: "hconres", number: 14, congress: null }],
    ["sres 5", { type: "sres", number: 5, congress: null }],
    ["119-hr-2493", { type: "hr", number: 2493, congress: 119 }],
  ])("reads %s", (q, expected) => {
    expect(parseBillNumber(q)).toEqual(expected);
  });

  it.each(["hr", "s", "rural health", "Texas 35", "TX-35", "hr 1013 tax", "xyz 12", "1013", "118-pn-12"])(
    "leaves %s to the word search",
    (q) => {
      expect(parseBillNumber(q)).toBeNull();
    },
  );
});

describe("billCitation", () => {
  it("writes every type the way the chambers cite it", () => {
    expect(billCitation("hr", 1013)).toBe("H.R. 1013");
    expect(billCitation("sjres", 197)).toBe("S.J.Res. 197");
    expect(billCitation("hconres", 14)).toBe("H.Con.Res. 14");
  });
});

describe("topics", () => {
  it("are the 32 CRS policy areas", () => {
    expect(POLICY_AREAS).toHaveLength(32);
    expect(new Set(POLICY_AREAS).size).toBe(32);
  });

  it("are named case- and space-insensitively", () => {
    expect(topicNamed("health")).toBe("Health");
    expect(topicNamed("  arts,  culture, religion ")).toBe("Arts, Culture, Religion");
    expect(topicNamed("Private Legislation")).toBeNull();
    expect(topicNamed("Healthcare")).toBeNull();
  });

  it("match a query when every word starts a word of the name", () => {
    expect(matchTopics("health")).toEqual(["Health"]);
    // No topic holds both words, so any topic holding one: the mock's Health row for "rural health".
    expect(matchTopics("rural health")).toEqual(["Health"]);
    // Every word first, and only those: not every topic with "public" in it.
    expect(matchTopics("public lands")).toEqual(["Public Lands and Natural Resources"]);
    expect(matchTopics("public")).toEqual(["Economics and Public Finance", "Public Lands and Natural Resources", "Transportation and Public Works"]);
    // A stopword alone matches nothing, though most names hold "and"; with a real word it is ignored.
    expect(matchTopics("and")).toEqual([]);
    expect(matchTopics("the act")).toEqual([]);
    expect(matchTopics("health and")).toEqual(["Health"]);
    expect(matchTopics("rural broadband")).toEqual([]);
    expect(matchTopics("public lands")).toEqual(["Public Lands and Natural Resources"]);
    expect(matchTopics("immig")).toEqual(["Immigration"]);
    expect(matchTopics("tax")).toEqual(["Taxation"]);
    expect(matchTopics("of")).toEqual([]);
  });
});

describe("billLabel on real CRS titles", () => {
  it("prefers the short title", () => {
    expect(billLabel("To reauthorize the Improving Care in Rural America program.", "Improving Care in Rural America Reauthorization Act of 2025")).toBe(
      "Improving Care in Rural America Reauthorization Act of 2025",
    );
  });

  it.each([
    [
      // 119-sjres-196
      'A joint resolution providing for congressional disapproval under chapter 8 of title 5, United States Code, of the rule submitted by the Department of Education relating to "Reimagining and Improving Student Education-Federal Student Loan Program Final Regulations".',
      "Disapproving the Department of Education's rule: Reimagining and Improving Student Education-Federal Student Loan Program Final Regulations",
    ],
    [
      // 118-sjres-10: an agency whose name ends in s takes a bare apostrophe
      'A joint resolution providing for congressional disapproval under chapter 8 of title 5, United States Code, of the rule submitted by the Department of Veterans Affairs relating to "Reproductive Health Services".',
      "Disapproving the Department of Veterans Affairs' rule: Reproductive Health Services",
    ],
    [
      // 119-sjres-99: no "the" in front of the agency
      'A joint resolution providing for congressional disapproval under chapter 8 of title 5, United States Code, of the rule submitted by U.S. Citizenship and Immigration Services relating to "Removal of the Automatic Extension of Employment Authorization Documents".',
      "Disapproving U.S. Citizenship and Immigration Services' rule: Removal of the Automatic Extension of Employment Authorization Documents",
    ],
    [
      // 119-hjres-78: the House's spelling has no "A joint resolution"
      'Providing for congressional disapproval under chapter 8 of title 5, United States Code, of the rule submitted by the United States Fish and Wildlife Service relating to "Endangered and Threatened Wildlife and Plants; Endangered Species Status for the San Francisco Bay-Delta Distinct Population Segment of the Longfin Smelt".',
      "Disapproving the United States Fish and Wildlife Service's rule: Endangered and Threatened Wildlife and Plants; Endangered Species Status for the San…",
    ],
    [
      // 119-hjres-88: "Providing congressional disapproval", no "for"
      'Providing congressional disapproval under chapter 8 of title 5, United States Code, of the rule submitted by the Environmental Protection Agency relating to "California State Motor Vehicle and Engine Pollution Control Standards; Advanced Clean Cars II; Waiver of Preemption; Notice of Decision".',
      "Disapproving the Environmental Protection Agency's rule: California State Motor Vehicle and Engine Pollution Control Standards; Advanced Clean Cars II; Waiver…",
    ],
    [
      // 119-hjres-140: the rule's name is not quoted
      "Providing for congressional disapproval under chapter 8 of title 5, United States Code, of the rule submitted by the Bureau of Land Management relating to Public Land Order No. 7917 for Withdrawal of Federal Lands; Cook, Lake, and Saint Louis Counties, MN.",
      "Disapproving the Bureau of Land Management's rule: Public Land Order No. 7917 for Withdrawal of Federal Lands; Cook, Lake, and Saint Louis Counties, MN",
    ],
    [
      // 119-sjres-53
      "A joint resolution providing for congressional disapproval of the proposed foreign military sale to the Government of Qatar of certain defense articles and services.",
      "Disapproving the arms sale to Qatar",
    ],
    [
      // 119-sjres-54
      "A joint resolution providing for congressional disapproval of the proposed foreign military sale to the Government of the United Arab Emirates of certain defense articles and services.",
      "Disapproving the arms sale to United Arab Emirates",
    ],
    [
      // 119-sjres-41
      "A joint resolution providing for congressional disapproval of the proposed export of certain defense articles to Israel.",
      "Disapproving the arms export to Israel",
    ],
    [
      // 118-sjres-115
      "A joint resolution providing for congressional disapproval of the proposed license amendment for the export of certain defense articles, defense services, and technical data to Israel.",
      "Disapproving the arms export to Israel",
    ],
    [
      // A constructed title, not a stored one, to pin the verb: staging holds no transfer disapproval.
      "A joint resolution providing for congressional disapproval of the proposed transfer to the Government of Turkey of certain defense articles and services.",
      "Disapproving the arms transfer to Turkey",
    ],
    [
      // 118-hres-199: a House rule naming three measures, each in Floor's spelling
      "Providing for consideration of the bill (H.R. 140) to amend title 5, United States Code, to prohibit Federal employees from advocating for censorship of viewpoints in their official capacity, and for other purposes; providing for consideration of the joint resolution (H.J. Res. 27) providing for congressional disapproval under chapter 8 of title 5, United States Code, of the rule submitted by the Department of the Army, Corps of Engineers, Department of Defense and the Environmental Protection Agency relating to \"Revised Definition of 'Waters of the United States'\"; and providing for consideration of the bill (S. 619) to require the Director of National Intelligence to declassify information relating to the origin of COVID-19, and for other purposes.",
      "Rule for H.R. 140, H.J.Res. 27 and S. 619",
    ],
    [
      // 119-hres-1131
      "Providing for consideration of the bill (H.R. 8029) making appropriations for the Department of Homeland Security for the fiscal year ending September 30, 2026, and for other purposes.",
      "Rule for H.R. 8029",
    ],
    [
      // 119-sres-690
      "An executive resolution authorizing the en bloc consideration in Executive Session of certain nominations on the Executive Calendar.",
      "Confirming nominations en bloc",
    ],
    [
      // 119-sjres-83
      "A joint resolution to direct the removal of United States Armed Forces from hostilities that have not been authorized by Congress.",
      "To direct the removal of United States Armed Forces from hostilities that have not been authorized by Congress",
    ],
    [
      // 119-hr-6019
      "To repeal certain provisions relating to notification to Senate offices regarding legal process on disclosure of Senate data, and for other purposes.",
      "To repeal certain provisions relating to notification to Senate offices regarding legal process on disclosure of Senate data",
    ],
    [
      // 119-hres-1486: a plain resolution stays as written, without its full stop
      "Impeaching Donald John Trump, President of the United States, for high crimes and misdemeanors.",
      "Impeaching Donald John Trump, President of the United States, for high crimes and misdemeanors",
    ],
  ])("%s", (title, expected) => {
    const label = billLabel(title, null);
    expect(label).toBe(expected);
    expect(label.length).toBeLessThanOrEqual(160);
  });
});
