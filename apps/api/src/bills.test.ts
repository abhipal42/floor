import { describe, expect, it } from "vitest";
import { POLICY_AREAS, billCitation, billLabel, matchTopics, parseBillNumber, ruleForBill, summaryLead, topicNamed } from "./bills.js";

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

// Every summary and title below is the production text, copied from `bills` on 2026-11-17.
describe("summaryLead", () => {
  it("drops the title line and keeps the first sentence (H.R. 2102)", () => {
    expect(
      summaryLead(
        "Major Richard Star Act\n\nThis bill allows a veteran with a combat-related disability to receive retirement pay, without reduction, " +
          "concurrently with their disability compensation. This includes veterans with a combat-related disability and fewer than 20 years " +
          "of creditable service. (Currently, veterans who receive combat-related special compensation and retirement pay are subject to an " +
          "offset in retirement pay for concurrent receipt of such benefits.)",
      ),
    ).toBe(
      "This bill allows a veteran with a combat-related disability to receive retirement pay, without reduction, concurrently with their " +
        "disability compensation.",
    );
  });

  it("skips the note on draft text as well as the title (H.R. 9612)", () => {
    expect(
      summaryLead(
        "The following analysis is based on draft bill text that was made available by the House of Representatives and may differ from " +
          "the bill text as introduced.\n\nAmerican Enrichment Deployment Act\n\nThis bill allows for the construction of a uranium " +
          "enrichment facility before a license is issued by the Nuclear Regulatory Commission (NRC).\n\nUnder current law, a license is " +
          "required from the NRC prior to the construction of a uranium enrichment facility.",
      ),
    ).toBe(
      "This bill allows for the construction of a uranium enrichment facility before a license is issued by the Nuclear Regulatory Commission (NRC).",
    );
  });

  it("does not end a sentence at an abbreviation (H.Con.Res. 110)", () => {
    expect(
      summaryLead(
        "This concurrent resolution directs the President to remove U.S. Armed Forces from hostilities against Iran unless explicitly " +
          "authorized by a declaration of war or a congressional authorization for use of military force against Iran.\n\nElements of the " +
          "U.S. Armed Forces needed to defend the United States, an ally, or a partner from imminent attack are not covered by this requirement.",
      ),
    ).toBe(
      "This concurrent resolution directs the President to remove U.S. Armed Forces from hostilities against Iran unless explicitly " +
        "authorized by a declaration of war or a congressional authorization for use of military force against Iran.",
    );
  });

  it("gives a short first sentence the next one too (H.R. 144)", () => {
    expect(
      summaryLead(
        "Tennessee Valley Authority Salary Transparency Act\n\nThis bill expands reporting requirements for the Tennessee Valley Authority " +
          "(TVA). TVA is a government corporation that provides electricity in Tennessee and in portions of several surrounding states. It " +
          "also provides flood control, navigation, and land management services for the Tennessee River system.",
      ),
    ).toBe(
      "This bill expands reporting requirements for the Tennessee Valley Authority (TVA). TVA is a government corporation that provides " +
        "electricity in Tennessee and in portions of several surrounding states.",
    );
  });

  it("reads a bullet list on as one sentence (H.Res. 1490)", () => {
    expect(
      summaryLead(
        "This resolution states that the House of Representatives\n• condemns and denounces socialism in all its forms, including the " +
          "Democratic Socialists of America, and opposes the implementation of socialist policies in the United States;\n• reaffirms its " +
          "support for free, fair, and secure elections and calls for enactment of the SAVE America Act;\n• reiterates that American " +
          "elections are for American citizens only; and\n• recommits itself to upholding the U.S. Constitution.",
      ),
    ).toBe(
      "This resolution states that the House of Representatives condemns and denounces socialism in all its forms, including the " +
        "Democratic Socialists of America, and opposes the implementation of socialist policies in the United States; reaffirms its " +
        "support for free, fair, and secure elections and calls for enactment of…",
    );
  });

  it("cuts a first sentence past the limit at a word, with an ellipsis (H.R. 7567)", () => {
    const lead = summaryLead(
      "Farm, Food, and National Security Act of 2026\n\nThis bill (commonly known as the farm bill) reauthorizes through FY2031 and " +
        "modifies Department of Agriculture programs that address\n• commodity support,\n• conservation,\n• trade and international food " +
        "aid,\n• nutrition assistance,\n• farm credit,\n• rural development,\n• research and extension activities,\n• forestry,\n• " +
        "energy,\n• horticulture,\n• crop insurance,\n• livestock and other animals, and\n• foreign investments in U.S. agricultural land.",
    );
    expect(lead!.length).toBeLessThanOrEqual(320);
    expect(lead).toMatch(/^This bill \(commonly known as the farm bill\) reauthorizes through FY2031 .* address commodity support, conservation, .*…$/);
  });

  it("keeps a one-sentence summary whole, and is null without one", () => {
    expect(summaryLead("This resolution censures Representative Al Green.")).toBe("This resolution censures Representative Al Green.");
    expect(summaryLead(null)).toBeNull();
    expect(summaryLead("")).toBeNull();
  });
});

describe("ruleForBill", () => {
  it.each([
    [
      "Providing for consideration of the bill (H.R. 2102) to amend title 10, United States Code, to provide for concurrent receipt of " +
        "veterans' disability compensation and retired pay for disability retirees with combat-related disabilities, and for other purposes.",
      "119-hr-2102",
    ],
    // Several bills: the first one named.
    [
      "Providing for consideration of the bill (H.R. 9576) to establish the National Fraud Enforcement Division of the Department of " +
        "Justice; providing for consideration of the bill (H.R. 10326) to enhance information-sharing capabilities",
      "119-hr-9576",
    ],
    [
      "Providing for consideration of the bill (S. 1383) to establish the Veterans Advisory Committee on Equal Access, and for other " +
        "purposes; providing for consideration of the bill (H.R. 2189) to modernize Federal firearms laws",
      "119-s-1383",
    ],
    [
      "Providing for consideration of the bill (H.R. 4690) to amend the Energy Conservation and Production Act to repeal certain Federal " +
        "building energy efficiency performance standards, and for other purposes; providing for consideration of the resolution (H. Res. " +
        "1182) expressing support for rural communities",
      "119-hr-4690",
    ],
    [
      "Providing for disposition of the Senate amendment to the bill (H.R. 7147) making further consolidated appropriations for the fiscal " +
        "year ending September 30, 2026, and for other purposes.",
      "119-hr-7147",
    ],
  ])("reads %s", (title, id) => {
    expect(ruleForBill(title, 119)).toBe(id);
  });

  it.each([
    // Not special rules: a concurrence, a resolution of its own, a rule-waiver, an impeachment referral.
    "Providing for the concurrence by the House in the Senate amendment to H.R. 6644, with amendment.",
    "Providing for the condemnation and denouncement of socialism in all its forms, and for other purposes.",
    "Providing that section 11 of House Resolution 1224 shall have no force or effect.",
    "Relating to the resolution (H. Res. 503) impeaching Joseph R. Biden, Jr., President of the United States, for high crimes and misdemeanors.",
  ])("is null for %s", (title) => {
    expect(ruleForBill(title, 119)).toBeNull();
  });
});
