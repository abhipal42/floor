// The landing page: renders every section from data.ts and wires its interactions. Plain DOM, no
// framework. Elements that animate (cards, rings, bars, the ball) are built once and then only
// their styles change, so CSS transitions run; lists that change length are rebuilt.

import {
  YOUR_THREE,
  contextNone,
  donorContext,
  drives,
  explainers,
  finals,
  flap,
  funding,
  hero,
  levels,
  live,
  mavericks,
  portfolio,
  portrait,
  scouting,
  ticker,
  type MemberId,
  type Tone,
} from "./data.js";
import {
  FLAP_ROWS,
  FLAP_TICKS,
  FLAP_WIDTH,
  cellLook,
  countText,
  deckPose,
  deckStep,
  driveBall,
  easeOutCubic,
  easeOutQuart,
  esc,
  fanPose,
  flapChar,
  flapSettle,
  formatMoney,
  formatPac,
  isMaxed,
  islandNext,
  padFlap,
  pct,
  rangeBar,
  readoutCite,
  ringDash,
  ringValues,
  seenLabel,
  splitText,
  tabKeyTarget,
  tierFor,
  yeaShare,
} from "./logic.js";

// ------------------------------------------------------------------ helpers

function el<T extends Element = HTMLElement>(selector: string, root: ParentNode = document): T {
  const found = root.querySelector<T>(selector);
  if (!found) throw new Error("missing element " + selector);
  return found;
}

function all<T extends Element = HTMLElement>(selector: string, root: ParentNode = document): T[] {
  return Array.from(root.querySelectorAll<T>(selector));
}

const motionQuery = window.matchMedia("(prefers-reduced-motion: reduce)");
const reduced = (): boolean => motionQuery.matches;

const tone = (t: Tone): string => "var(--" + t + ")";

/** Runs `fn` once, the first time `target` scrolls into view (at once without IntersectionObserver). */
function onVisible(target: Element, fn: () => void, threshold = 0.2): void {
  if (!("IntersectionObserver" in window)) {
    fn();
    return;
  }
  const io = new IntersectionObserver(
    (entries) => {
      if (entries.some((e) => e.isIntersecting)) {
        io.disconnect();
        fn();
      }
    },
    { threshold },
  );
  io.observe(target);
}

/** Animates progress 0→1 over `ms`, eased; with reduced motion, jumps straight to 1. Returns a cancel. */
function tween(ms: number, ease: (t: number) => number, frame: (p: number) => void): () => void {
  if (reduced()) {
    frame(1);
    return () => {};
  }
  const t0 = performance.now();
  let id = 0;
  const step = (now: number) => {
    const t = Math.min(1, (now - t0) / ms);
    frame(ease(t));
    if (t < 1) id = window.requestAnimationFrame(step);
  };
  frame(0);
  id = window.requestAnimationFrame(step);
  return () => window.cancelAnimationFrame(id);
}

/** Calls fn after the browser has painted the current styles, so a following change transitions. */
function afterPaint(fn: () => void): void {
  window.requestAnimationFrame(() => window.requestAnimationFrame(fn));
}

/**
 * Wires a role=tablist: click or arrow keys pick a tab, and the selected tab is the one in the tab
 * order (roving tabindex). Returns a setter for the selected index.
 */
function wireTabs(list: HTMLElement, onPick: (i: number) => void): (i: number) => void {
  const tabs = () => all<HTMLButtonElement>('[role="tab"]', list);
  const set = (i: number) => {
    tabs().forEach((t, k) => {
      t.setAttribute("aria-selected", String(k === i));
      t.tabIndex = k === i ? 0 : -1;
      t.classList.toggle("is-on", k === i);
    });
  };
  list.addEventListener("click", (e) => {
    const t = (e.target as Element).closest('[role="tab"]');
    const i = tabs().indexOf(t as HTMLButtonElement);
    if (i >= 0) {
      set(i);
      onPick(i);
    }
  });
  list.addEventListener("keydown", (e) => {
    const cur = tabs().findIndex((t) => t.getAttribute("aria-selected") === "true");
    const next = tabKeyTarget(e.key, Math.max(0, cur), tabs().length);
    if (next === null) return;
    e.preventDefault();
    tabs()[next]?.focus();
    set(next);
    onPick(next);
  });
  return set;
}

const AI_STAR =
  '<svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><path d="M7 0l1.6 4.4L13 6l-4.4 1.6L7 12l-1.6-4.4L1 6l4.4-1.6z" fill="currentColor"></path></svg>';

const scoutById = new Map(scouting.members.map((m) => [m.id, m]));
const label = (id: MemberId): string => scoutById.get(id as (typeof YOUR_THREE)[number])?.label ?? id;

function memberTabs(list: HTMLElement): void {
  list.innerHTML = YOUR_THREE.map(
    (id) =>
      '<button type="button" role="tab" class="ptab"><img src="' + portrait(id) + '" alt="" width="36" height="36">' + esc(label(id)) + "</button>",
  ).join("");
}

// ------------------------------------------------------------------ header

function header(): void {
  const head = el("#site-head");
  const setH = () => document.documentElement.style.setProperty("--head-h", head.offsetHeight + "px");
  setH();
  new ResizeObserver(setH).observe(head);
}

// ------------------------------------------------------------------ hero

function heroStats(): void {
  const box = el("#hero-stats");
  box.innerHTML = hero.stats
    .map((s) =>
      s.kind === "count"
        ? '<span class="stat"><span class="stat__n num" aria-hidden="true" data-count="' + s.value + '">0</span><span class="sr">' +
          s.value.toLocaleString("en-US") + '</span><span class="stat__l">' + esc(s.label) + "</span></span>"
        : '<span class="stat"><span class="stat__n stat__n--yea num">' + s.value + '</span><span class="stat__l">' + esc(s.label) + "</span></span>",
    )
    .join("");
  onVisible(box, () => {
    for (const n of all("[data-count]", box)) {
      const to = Number(n.dataset.count);
      tween(1400 + Math.random() * 400, easeOutQuart, (p) => (n.textContent = countText(to, p)));
    }
  });
  const hl = el("[data-reveal]");
  onVisible(hl, () => hl.classList.add("is-in"), 0.5);
}

function flapBoard(): void {
  const board = el("#flap");
  const rowClass = ["flap__row--meta", "flap__row--main", "flap__row--score"];
  let html = "";
  for (let r = 0; r < FLAP_ROWS; r++) {
    html += '<div class="flap__row ' + rowClass[r] + '">';
    for (let c = 0; c < FLAP_WIDTH; c++) html += '<span class="flap__cell"></span>';
    html += "</div>";
  }
  html +=
    '<div class="flap__foot"><span class="flap__count"></span><span class="flap__dots">' +
    flap.messages.map(() => '<span class="flap__dot"></span>').join("") +
    "</span></div>";
  board.innerHTML = html;
  const cells = all(".flap__cell", board);
  const count = el(".flap__count", board);
  const dots = all(".flap__dot", board);

  let m = 0;
  let tick = FLAP_TICKS + 1;
  let settle: number[] = [];
  let spin = 0;

  const paint = () => {
    const msg = flap.messages[m]!;
    msg.rows.forEach((line, r) => {
      const target = padFlap(line);
      for (let c = 0; c < FLAP_WIDTH; c++) {
        const cell = cells[r * FLAP_WIDTH + c]!;
        const ch = flapChar(target[c] ?? " ", r, c, tick, settle[r * FLAP_WIDTH + c]);
        if (cell.textContent !== ch) cell.textContent = ch;
      }
    });
  };

  const go = (next: number) => {
    m = next;
    const msg = flap.messages[m]!;
    board.style.setProperty("--tone", tone(msg.tone));
    board.setAttribute("aria-label", msg.rows.join(" · "));
    count.textContent = "FINALS BOARD · " + (m + 1) + " / " + flap.messages.length;
    dots.forEach((d, i) => d.classList.toggle("is-on", i === m));
    window.clearInterval(spin);
    if (reduced()) {
      tick = FLAP_TICKS + 1;
      paint();
      return;
    }
    settle = flapSettle();
    tick = 0;
    paint();
    spin = window.setInterval(() => {
      tick++;
      paint();
      if (tick > FLAP_TICKS) window.clearInterval(spin);
    }, 50);
  };

  go(0);
  window.setInterval(() => go((m + 1) % flap.messages.length), 4600);
}

function tickerBar(): void {
  const items = ticker.items
    .map(
      (k) =>
        '<span class="tk num"><span class="tk__c">' + esc(k.chamber) + '</span><span class="tk__t">' + esc(k.title) +
        '</span><span class="tk__s"><span class="yea">' + k.yea + '</span> – <span class="nay">' + k.nay +
        '</span></span><span class="tk__r">' + esc(k.result) + "</span></span>",
    )
    .join("");
  // Two copies side by side; the strip scrolls by half its width, so the loop is seamless.
  el("#ticker").innerHTML = '<div class="marq"><div class="marq__set">' + items + '</div><div class="marq__set" aria-hidden="true">' + items + "</div></div>";
}

// ------------------------------------------------------------------ 01 · deck

function deck(): void {
  const root = el("#deck");
  const cards = finals.cards;
  root.innerHTML =
    '<div class="deck__stack">' +
    cards
      .map(
        (c, k) =>
          '<article class="dk-card" data-k="' + k + '">' +
          '<div class="dk-top"><span class="dk-top__l"><span class="skew skew--ink">' + esc(c.chamber) + '</span><span class="dk-meta">' + esc(c.cite) + " · " + esc(c.date) +
          '</span></span><span class="dk-n">' + (k + 1) + " / " + cards.length + "</span></div>" +
          '<div class="dk-head"><h3>' + esc(c.title) + "</h3><p>" + esc(c.blurb) + "</p></div>" +
          '<div class="dk-score"><div class="dk-row"><span class="dk-side yea">YEA</span><span class="dk-big yea num" data-y>' + c.yea +
          '</span><span class="dk-res"><span class="skew dk-res__chip" data-res style="background:' + tone(c.passed ? "yea" : "nay") + '">' + c.result +
          '</span><span class="dk-final">FINAL</span></span><span class="dk-big nay num" data-n>' + c.nay + '</span><span class="dk-side nay dk-side--r">NAY</span></div>' +
          '<div class="dk-bar"><div class="dk-bar__y" data-w></div><div class="dk-bar__line" style="left:' + c.line + '%"></div></div>' +
          '<div class="dk-foot"><span class="num">' + esc(splitText(c.splits)) + '</span><span class="dk-need">' + esc(c.need) + "</span></div></div>" +
          '<div class="dk-twist" data-twist><span class="dk-twist__k">THE TWIST</span><span>' + esc(c.twist) + "</span></div>" +
          '<div class="dk-reps"><span class="eyebrow">YOUR THREE</span>' +
          c.reps
            .map(
              (r) =>
                '<span class="rep-chip"><img src="' + portrait(r.member) + '" alt="" width="26" height="26"><span class="rep-chip__who">' + esc(label(r.member)) +
                '</span><span class="rep-chip__pos ' + (r.pos === "Yea" ? "yea" : "nay") + '">' + r.pos.toUpperCase() + "</span></span>",
            )
            .join("") +
          "</div></article>",
      )
      .join("") +
    '</div><p class="sr" aria-live="polite" data-status></p>' +
    '<div class="deck__ctl"><button type="button" class="dk-btn dk-btn--back" data-prev>← Back</button>' +
    '<span class="deck__dots" role="img" data-dots>' + cards.map(() => '<span class="deck__dot"></span>').join("") + "</span>" +
    '<button type="button" class="dk-btn dk-btn--next" data-next>Next final →</button></div>';

  const arts = all("article", root);
  const dots = all(".deck__dot", root);
  const status = el("[data-status]", root);
  let front = 0;
  let leaving = -1;
  let p = 0;
  const seen = cards.map((_, k) => k === 0);
  let cancel = () => {};

  const paint = () => {
    arts.forEach((a, k) => {
      const c = cards[k]!;
      const pose = deckPose(k, front, leaving);
      a.style.transform = pose.transform;
      a.style.opacity = String(pose.opacity);
      a.style.zIndex = String(pose.z);
      a.setAttribute("aria-hidden", String(pose.hidden));
      const isFront = pose.depth === 0;
      const q = isFront ? p : 1;
      el("[data-y]", a).textContent = String(Math.round(c.yea * q));
      el("[data-n]", a).textContent = String(Math.round(c.nay * q));
      el("[data-w]", a).style.width = yeaShare(c.yea, c.nay, q);
      const resOp = isFront && p < 0.9 ? "0" : "1";
      el("[data-res]", a).style.opacity = resOp;
      el("[data-twist]", a).style.opacity = resOp;
    });
    dots.forEach((d, k) => {
      d.classList.toggle("is-on", k === front);
      d.classList.toggle("is-seen", k !== front && !!seen[k]);
    });
    el("[data-dots]", root).setAttribute("aria-label", seenLabel(seen));
  };

  const count = () => {
    cancel();
    cancel = tween(1000, easeOutCubic, (v) => {
      p = v;
      paint();
    });
  };

  const announce = () => {
    const c = cards[front]!;
    status.textContent = "Final " + (front + 1) + " of " + cards.length + ": " + c.title + ", " + c.yea + " to " + c.nay + ", " + c.result.toLowerCase() + ".";
  };

  const move = (dir: 1 | -1) => {
    if (leaving >= 0) return;
    const next = deckStep(front, dir);
    if (dir > 0 && !reduced()) {
      leaving = front;
      paint();
      window.setTimeout(() => {
        seen[next] = true;
        front = next;
        leaving = -1;
        announce();
        count();
      }, 360);
    } else {
      seen[next] = true;
      front = next;
      announce();
      count();
    }
  };

  el("[data-next]", root).addEventListener("click", () => move(1));
  el("[data-prev]", root).addEventListener("click", () => move(-1));
  paint();
  onVisible(root, count, 0.3);
}

// ------------------------------------------------------------------ 02 · levels + drive chart

function levelCards(): void {
  const n = levels.items.length;
  el("#levels").innerHTML = levels.items
    .map(
      (l, i) =>
        '<div class="level" style="--i:' + i + ";margin-bottom:" + (i === n - 1 ? "0" : "150px") + '">' +
        '<article class="level__card' + (i % 2 ? " level__card--alt" : "") + '">' +
        '<span class="level__n' + (l.boss ? " level__n--boss" : "") + '" aria-hidden="true">' + (i + 1) + "</span>" +
        '<div class="level__body"><span class="level__name-row"><h3 class="level__name"><span class="sr">Level ' + (i + 1) + ": </span>" + esc(l.name) + "</h3>" +
        (l.boss ? '<span class="skew skew--accent">BOSS · ' + esc(l.need) + "</span>" : '<span class="level__need">' + esc(l.need) + "</span>") +
        '</span><span class="level__text">' + esc(l.body) + "</span></div>" +
        '<div class="level__ex"><span class="eyebrow">REAL PLAY · ' + esc(l.example.when) + '</span><span class="level__ex-t">' + esc(l.example.title) +
        '</span><span class="level__ex-s num"><span class="yea">' + esc(l.example.yea) + '</span><span class="level__dash">–</span><span class="nay">' + esc(l.example.nay) +
        '</span><span class="level__res" style="color:' + tone(l.example.tone) + '">' + esc(l.example.result) + "</span></span></div>" +
        "</article></div>",
    )
    .join("");
}

function driveChart(): void {
  const tabs = el("#drive-tabs");
  tabs.innerHTML = drives.items.map((d) => '<button type="button" role="tab" class="btab">' + esc(d.label) + "</button>").join("");
  const panel = el("#drive-panel");
  panel.innerHTML =
    '<div class="drive__top"><span class="drive__id"><span class="drive__cite" data-cite></span><span class="drive__title" data-title></span></span><span class="drive__status" data-status></span></div>' +
    '<div class="field" aria-hidden="true"><div class="field__law"><span>LAW</span></div><div class="field__mid"></div><div class="field__fill ease" data-fill></div>' +
    '<div class="field__ball" data-ball><span></span></div></div>' +
    '<div class="field__labels"><span>INTRODUCED</span><span class="c" data-mid></span><span class="r">SIGNED</span></div>' +
    '<ol class="plays" data-plays></ol>';
  const fill = el("[data-fill]", panel);
  const ball = el("[data-ball]", panel);
  let cur = 0;
  let shown = false;
  const show = (i: number) => {
    cur = i;
    const d = drives.items[i]!;
    el("[data-cite]", panel).textContent = d.cite;
    el("[data-title]", panel).textContent = d.title;
    const st = el("[data-status]", panel);
    st.textContent = d.status;
    st.style.color = tone(d.tone);
    el("[data-mid]", panel).textContent = d.mid;
    el("[data-plays]", panel).innerHTML = d.plays
      .map(
        (p) =>
          '<li><span class="plays__w">' + esc(p.when) + '</span><span class="plays__what">' + esc(p.what) + '</span><span class="plays__s num" style="color:' +
          tone(p.tone) + '">' + esc(p.score) + "</span></li>",
      )
      .join("");
    fill.style.background = tone(d.tone);
    const g = shown ? driveBall(d.pos) : driveBall(0);
    ball.style.left = g.ball;
    fill.style.width = g.fill;
  };
  const set = wireTabs(tabs, show);
  set(0);
  show(0);
  // The ball starts on its own goal line and drives to where the bill is once the chart is seen.
  onVisible(panel, () => {
    shown = true;
    afterPaint(() => show(cur));
  }, 0.4);
}

// ------------------------------------------------------------------ 03 · explained

function explain(): void {
  const root = el("#explain");
  root.innerHTML =
    '<div role="tablist" aria-label="Bills" class="tabs" data-tabs>' +
    explainers.bills.map((b) => '<button type="button" role="tab" class="btab btab--two"><span class="btab__cite">' + esc(b.cite) + "</span><span>" + esc(b.label) + "</span></button>").join("") +
    '</div><div class="ex" role="tabpanel" aria-label="Bill explainer" data-panel></div>';
  const panel = el("[data-panel]", root);
  let bill = 0;
  let hi = 0;

  const highlight = () => {
    const b = explainers.bills[bill]!;
    const src = b.points[Math.min(hi, b.points.length - 1)]!.src;
    all(".ex-pt", panel).forEach((p, i) => {
      p.classList.toggle("is-on", i === hi);
      p.setAttribute("aria-pressed", String(i === hi));
    });
    all(".ex-para", panel).forEach((q, i) => q.classList.toggle("is-on", i + 1 === src));
  };

  const show = (i: number) => {
    bill = i;
    hi = 0;
    const b = explainers.bills[i]!;
    panel.innerHTML =
      '<div class="ex-main card">' +
      '<div class="ex-top"><span class="ai-tag">' + AI_STAR + 'FLOOR EXPLAINS · AI</span><span class="ex-meta">' + esc(b.sponsor) + " · " + esc(b.area) + "</span></div>" +
      '<p class="ex-tldr">' + esc(b.tldr) + "</p>" +
      '<div class="ex-pts"><span class="eyebrow">WHAT IT DOES · hover a point to see its source</span>' +
      b.points
        .map(
          (p, k) =>
            '<button type="button" class="ex-pt" data-pt="' + k + '" aria-describedby="ex-para-' + p.src + '"><span class="ex-pt__src" aria-label="Source paragraph ' + p.src + '">¶' + p.src +
            '</span><span class="ex-pt__txt"><span class="ex-pt__h">' + esc(p.head) + '</span><span class="ex-pt__b">' + esc(p.body) + "</span></span></button>",
        )
        .join("") +
      "</div>" +
      '<div class="ex-who"><span class="eyebrow">WHO IT TOUCHES</span>' + b.who.map((w) => '<span class="pill">' + esc(w) + "</span>").join("") + "</div>" +
      '<div class="callout"><span class="callout__k">WHAT IT DOESN\'T DO</span><span>' + esc(b.not) + "</span></div>" +
      '<div class="ex-foot"><span class="ex-stands"><span class="eyebrow">WHERE IT STANDS</span><span class="ex-stands__v" style="color:' + tone(b.tone) + '">' + esc(b.stands) +
      '</span></span><span class="ex-meta">AI summary of the CRS summary · every point cites it · may contain errors</span></div>' +
      "</div>" +
      '<div class="ex-src"><span class="eyebrow">THE SOURCE · Congressional Research Service summary, excerpted</span>' +
      b.paras.map((t, k) => '<p class="ex-para" id="ex-para-' + (k + 1) + '"><b>¶' + (k + 1) + "</b> " + esc(t) + "</p>").join("") +
      "</div>";
    highlight();
  };

  const pick = (e: Event) => {
    const b = (e.target as Element).closest<HTMLElement>("[data-pt]");
    if (!b) return;
    const k = Number(b.dataset.pt);
    if (k !== hi) {
      hi = k;
      highlight();
    }
  };
  panel.addEventListener("mouseover", pick);
  panel.addEventListener("focusin", pick);
  panel.addEventListener("click", pick);

  const set = wireTabs(el("[data-tabs]", root), show);
  set(0);
  show(0);
}

// ------------------------------------------------------------------ 04 · scouting

function scout(): void {
  const tabs = el("#scout-tabs");
  memberTabs(tabs);
  const panel = el("#scout-panel");
  let who = 0;
  let hi = 39;
  let seen = false;

  const readout = () => {
    const sc = scouting.members[who]!;
    const i = Math.min(hi, sc.grid.length - 1);
    const r = sc.grid[i]!;
    const look = cellLook(r[4]);
    all(".sq", panel).forEach((q, k) => q.classList.toggle("is-hi", k === i));
    el("[data-readout]", panel).innerHTML =
      '<span class="ro__pos" style="background:var(--' + look.chipBg + ");color:var(--" + look.chipFg + ')">' + look.word + "</span>" +
      '<span class="ro__what"><span class="ro__t">' + esc(readoutCite(r[2], r[3])) + " · " + esc(r[3]) + '</span><span class="ro__m">' + esc(sc.chamber) +
      " roll " + r[0] + " · " + esc(r[1]) + " · " + esc(r[7].trim()) + "</span></span>" +
      '<span class="ro__s num"><span class="yea">' + r[5] + '</span>–<span class="nay">' + r[6] + "</span></span>";
  };

  const rings = (p: number) => {
    const sc = scouting.members[who]!;
    const vals = ringValues(sc);
    all<SVGCircleElement>("[data-ring]", panel).forEach((c, k) => c.setAttribute("stroke-dasharray", ringDash(vals[k] ?? 0, p)));
  };

  const show = (i: number) => {
    who = i;
    hi = 39;
    const sc = scouting.members[i]!;
    const ringDefs = [
      { label: "With party", big: sc.unity.toFixed(1) + "%", sub: sc.withParty.toLocaleString("en-US") + " of " + sc.partyVotes.toLocaleString("en-US"), color: "yea" },
      { label: "Showed up", big: sc.played + "/40", sub: sc.playedSub, color: "ink" },
      { label: "Winning side", big: sc.won + "/" + sc.of, sub: "last 40 calls", color: "nay" },
    ];
    panel.innerHTML =
      '<div class="sc-card card">' +
      '<div class="sc-id"><img src="' + portrait(sc.id) + '" alt="' + esc(sc.full) + '" width="80" height="96"><div><span class="sc-name">' + esc(sc.full) + '</span><span class="sc-seat">' +
      esc(sc.seat) + "</span></div></div>" +
      '<div class="rings">' +
      ringDefs
        .map(
          (g) =>
            '<div class="ring"><div class="ring__fig"><svg width="92" height="92" viewBox="0 0 96 96" aria-hidden="true"><circle cx="48" cy="48" r="40" fill="none" class="ring__track" stroke-width="8"></circle>' +
            '<circle data-ring class="ease" cx="48" cy="48" r="40" fill="none" style="stroke:var(--' + g.color + ')" stroke-width="8" stroke-linecap="round" pathLength="100" stroke-dasharray="0 100" transform="rotate(-90 48 48)"></circle></svg>' +
            '<span class="ring__big num">' + esc(g.big) + '</span></div><span class="ring__label">' + esc(g.label) + '</span><span class="ring__sub num">' + esc(g.sub) + "</span></div>",
        )
        .join("") +
      "</div>" +
      '<div class="sc-cross"><span class="sc-cross__n"><span class="sc-cross__k">Crossovers since 2023</span><span class="sc-cross__v num">' + sc.cross + '</span></span><span class="sc-cross__note">' +
      esc(sc.note) + "</span></div></div>" +
      '<div class="sc-grid card">' +
      '<div class="sc-grid__head"><h3 class="h4">Last 40 calls</h3><span class="legend"><span><i class="lg lg--y"></i>Yea</span><span><i class="lg lg--n"></i>Nay</span><span><i class="lg lg--p"></i>Present</span><span><i class="lg lg--m"></i>Missed</span></span></div>' +
      '<div class="squares" role="group" aria-label="Last 40 roll calls, oldest first">' +
      sc.grid
        .map((r, k) => {
          const look = cellLook(r[4]);
          return '<button type="button" class="sq sq--' + r[4] + '" data-sq="' + k + '" aria-label="' + esc(r[1] + ", " + r[2] + ", " + look.word) + '"></button>';
        })
        .join("") +
      "</div>" +
      '<div class="ro fade" data-readout aria-live="polite"></div>' +
      '<div class="dyk"><span class="dyk__k">DID YOU KNOW</span><span class="dyk__t">' + esc(sc.fact) + "</span></div>" +
      "</div>";
    readout();
    rings(0);
    if (seen) afterPaint(() => rings(1));
  };

  const over = (e: Event) => {
    const q = (e.target as Element).closest<HTMLElement>("[data-sq]");
    if (!q) return;
    const k = Number(q.dataset.sq);
    if (k !== hi) {
      hi = k;
      readout();
    }
  };
  panel.addEventListener("mouseover", over);
  panel.addEventListener("focusin", over);
  panel.addEventListener("click", over);

  const set = wireTabs(tabs, show);
  set(0);
  show(0);
  onVisible(panel, () => {
    seen = true;
    afterPaint(() => rings(1));
  }, 0.3);
}

// ------------------------------------------------------------------ 05 · players

function players(): void {
  const fanBox = el("#fan");
  const byId = new Map(mavericks.members.map((m) => [m.id, m]));
  let sel: MemberId = mavericks.fanDefault;
  fanBox.innerHTML =
    '<div class="fan__stage">' +
    mavericks.fan
    .map((id) => {
      const m = byId.get(id)!;
      const t = tierFor(m.crossovers);
      return (
        '<button type="button" class="pcard pcard--' + t.frame + '" data-id="' + id + '" aria-label="' + esc(m.full + ", " + t.name.toLowerCase() + ", " + m.crossovers + " crossovers") + '">' +
        '<span class="pcard__in"><span class="pcard__photo"><img src="' + portrait(id) + '" alt="" width="216" height="188"><span class="shine"></span>' +
        '<span class="skew pcard__tier" style="background:var(--' + t.badge + ')">' + t.name + '</span><span class="pcard__badge">' + esc(m.badge) + "</span></span>" +
        '<span class="pcard__body"><span class="pcard__name">' + esc(m.full) + '</span><span class="pcard__pos">' + esc(m.pos) + "</span>" +
        '<span class="pcard__stats num"><span><b>' + pct(m.withParty, m.votes) + '</b><small>W/ PARTY</small></span><span class="r"><b class="accent">' + m.crossovers +
        "</b><small>CROSSOVERS</small></span></span></span></span></button>"
      );
    })
    .join("") +
    "</div>";
  const cards = all<HTMLButtonElement>(".pcard", fanBox);
  const selBox = el("#fan-sel");

  const paint = () => {
    cards.forEach((c, k) => {
      const on = c.dataset.id === sel;
      const pose = fanPose(k - 2, on);
      c.style.transform = pose.transform;
      c.style.zIndex = String(pose.z);
      c.setAttribute("aria-pressed", String(on));
    });
    const m = byId.get(sel)!;
    selBox.innerHTML =
      '<div class="fsel__top"><span class="fsel__name">' + esc(m.full) + '</span><span class="fsel__pos">' + esc(m.pos) + "</span></div>" +
      '<div class="fsel__stats num"><span><b>' + m.votes.toLocaleString("en-US") + "</b><small>counted votes</small></span><span><b>" + pct(m.withParty, m.votes) +
      '</b><small>with party</small></span><span><b class="accent">' + m.crossovers + "</b><small>crossovers</small></span></div>";
  };
  const pick = (e: Event) => {
    const c = (e.target as Element).closest<HTMLElement>(".pcard");
    if (c && c.dataset.id !== sel) {
      sel = c.dataset.id as MemberId;
      paint();
    }
  };
  fanBox.addEventListener("click", pick);
  fanBox.addEventListener("mouseover", pick);
  paint();

  // Leaderboard
  const rows = el("#board-rows");
  const chambers = [
    ["all", "Both"],
    ["house", "House"],
    ["senate", "Senate"],
  ] as const;
  const tabs = el("#board-tabs");
  tabs.innerHTML = chambers.map(([, l]) => '<button type="button" role="tab" class="seg__b">' + l + "</button>").join("");
  let ch: (typeof chambers)[number][0] = "all";
  let seen = false;
  const bars = () => all("[data-w]", rows).forEach((b) => (b.style.width = b.dataset.w ?? "0%"));
  const showRows = () => {
    rows.innerHTML = mavericks.members
      .filter((m) => ch === "all" || m.chamber === ch)
      .map(
        (m, i) =>
          '<tr class="row"><td class="c-rk num' + (i === 0 ? " accent" : "") + '">' + (i + 1) + '</td><td><span class="who"><img src="' + portrait(m.id) +
          '" alt="" width="36" height="36"><span>' + esc(m.full) + '</span></span></td><td class="c-seat">' + esc(m.pos) +
          '</td><td><span class="unity"><span class="unity__track"><span class="unity__bar ease" data-w="' + pct(m.withParty, m.votes) + '"></span></span><span class="unity__v num">' +
          pct(m.withParty, m.votes) + '</span></span></td><td class="c-x num">' + m.crossovers + "</td></tr>",
      )
      .join("");
    if (seen) afterPaint(bars);
  };
  const set = wireTabs(tabs, (i) => {
    ch = chambers[i]![0];
    showRows();
  });
  set(0);
  showRows();
  onVisible(rows, () => {
    seen = true;
    afterPaint(bars);
  }, 0.3);
}

// ------------------------------------------------------------------ 06 · money

function money(): void {
  const tabs = el("#money-tabs");
  memberTabs(tabs);
  const panel = el("#money-panel");
  let seen = false;
  const SEGS = [
    { key: "small", label: "Small-dollar donors", note: () => "gifts under $200, unitemized", color: "yea" },
    { key: "itemized", label: "Larger individual gifts", note: () => "$200 and up, itemized", color: "teal" },
    { key: "pac", label: "PACs", note: () => "other political committees", color: "accent" },
    { key: "other", label: "Transfers & other", note: (n: string) => n, color: "dim" },
  ] as const;

  const grow = () => all("[data-grow]", panel).forEach((s) => (s.style.flexGrow = s.dataset.grow ?? "1"));

  const show = (i: number) => {
    const f = funding.members[i]!;
    const segs = SEGS.map((s) => ({ ...s, v: f[s.key], note: s.note(f.otherNote), pct: pct(f[s.key], f.total) }));
    panel.innerHTML =
      '<div class="fund card">' +
      '<div class="fund__top"><span class="fund__total"><span class="fine">' + esc(f.period) + '</span><span class="fund__big num">' + formatMoney(f.total) +
      '</span><span class="fine">raised by the campaign committee</span></span><span class="fund__cash"><span class="fine">Cash on hand</span><span class="fund__cash-v num">' +
      formatMoney(f.cash) + '</span><span class="fine">' + esc(f.cashAsOf) + "</span></span></div>" +
      '<div class="fund__bar" role="img" aria-label="' + esc(segs.map((s) => s.label + " " + s.pct).join(", ")) + '">' +
      segs.map((s) => '<div class="fund__seg ease" data-grow="' + s.v + '" style="background:var(--' + s.color + ')"></div>').join("") +
      "</div><div class=\"fund__list\">" +
      segs
        .map(
          (s) =>
            '<div class="fund__row"><span class="sw" style="background:var(--' + s.color + ')"></span><span class="fund__lab"><span>' + esc(s.label) + "</span><small>" + esc(s.note) +
            '</small></span><span class="fund__amt num">' + formatMoney(s.v) + '</span><span class="fund__pct num">' + s.pct + "</span></div>",
        )
        .join("") +
      "</div></div>" +
      '<div class="pacs card"><div class="pacs__head"><h3 class="h4">Biggest PAC checks</h3><span class="fine">A PAC can give $5,000 per election — primary and general — so $10,000 is the cycle max.</span></div>' +
      (f.pacs.length
        ? '<div class="pacs__list">' +
          f.pacs
            .map(
              (c) =>
                '<div class="row pacs__row"><span class="pacs__name">' + esc(c.name) + '</span><span class="pill pill--sm">' + esc(c.kind) + "</span>" +
                (isMaxed(c.amount) ? '<span class="skew skew--accent skew--sm">MAXED</span>' : "") + '<span class="pacs__amt num">' + formatPac(c.amount) + "</span></div>",
            )
            .join("") +
          "</div>"
        : '<div class="pacs__none"><span>Coming soon for this member.</span><span class="fine">Floor reads the FEC\'s itemized receipts to list PAC checks. Jeffries\' list is in; the senators\' lists are next.</span></div>') +
      "</div>";
    if (seen) afterPaint(grow);
  };
  const set = wireTabs(tabs, show);
  set(0);
  show(0);
  onVisible(panel, () => {
    seen = true;
    afterPaint(grow);
  }, 0.3);
}

function context(): void {
  const root = el("#context");
  const donors = donorContext.donors;
  const who = label(donorContext.member).toUpperCase();
  root.innerHTML =
    '<div class="cx-banner"><span class="cx-banner__k">CONTEXT, NOT CAUSE</span><span>Floor explains who a donor is and what they lobby for, and puts any related votes beside it. A contribution doesn\'t show why a member votes the way they do — and Floor never says it does.</span></div>' +
    '<div class="cx"><div class="cx-list card"><div class="cx-list__head">' + who + " · 2026 CYCLE · TAP A DONOR</div>" +
    donors
      .map(
        (d, i) =>
          '<button type="button" class="cx-row" data-i="' + i + '"><span class="cx-row__name">' + esc(d.name) + '</span><span class="pill pill--sm">' + esc(d.kind) +
          '</span><span class="cx-row__amt num">' + formatPac(d.amount) + "</span></button>",
      )
      .join("") +
    '</div><div class="cx-detail card cx-in" data-detail aria-live="polite"></div></div>';
  const detail = el("[data-detail]", root);
  const rowsEls = all(".cx-row", root);
  const show = (i: number) => {
    const d = donors[i]!;
    rowsEls.forEach((r, k) => {
      r.classList.toggle("is-on", k === i);
      r.setAttribute("aria-pressed", String(k === i));
    });
    const v = d.vote;
    detail.innerHTML =
      '<div class="cx-top"><span class="cx-id"><span class="cx-name">' + esc(d.name) + '</span><span class="fine">' + esc(d.kind) + " · " + esc(d.how) +
      '</span></span><span class="cx-amt num">' + formatPac(d.amount) + "</span></div>" +
      '<span class="ai-tag">' + AI_STAR + "FLOOR EXPLAINS · AI</span>" +
      '<div class="cx-facts"><div class="cx-fact"><span class="eyebrow">WHO THEY ARE</span><span>' + esc(d.who) + '</span></div><div class="cx-fact"><span class="eyebrow">WHAT THEY LOBBY ON</span><span>' +
      esc(d.lobby) + "</span></div></div>" +
      '<div class="cx-votes"><span class="eyebrow">ON HIS RECORD · RELATED VOTES</span>' +
      (v
        ? '<div class="cx-vote"><span class="cx-vote__pos ' + (v.pos === "NAY" ? "chip-nay" : "chip-yea") + '">' + v.pos + '</span><span class="cx-vote__what"><span class="cx-vote__t">' + esc(v.title) +
          '</span><span class="fine">' + esc(v.meta) + '</span></span><span class="cx-vote__s num">' + esc(v.score) + '</span></div><span class="cx-why">' + esc(v.why) + "</span>"
        : '<span class="cx-none">' + esc(d.none ?? contextNone) + "</span>") +
      '</div><span class="fine cx-foot">Amounts: FEC itemized receipts, Jan 2025 – Oct 14, 2026. Descriptions are AI-written from public sources and may contain errors.</span>';
  };
  root.addEventListener("click", (e) => {
    const r = (e.target as Element).closest<HTMLElement>(".cx-row");
    if (r) show(Number(r.dataset.i));
  });
  show(donorContext.defaultIndex);
}

// ------------------------------------------------------------------ 07 · portfolio

function portfolioView(): void {
  const root = el("#pf");
  const P = portfolio;
  root.innerHTML =
    '<div role="tablist" aria-label="View" class="seg seg--lg" data-tabs><button type="button" role="tab" class="seg__b">Your rep</button><button type="button" role="tab" class="seg__b">Biggest traders</button></div>' +
    '<div role="tabpanel" aria-label="Portfolio" data-panel></div>' +
    '<span class="fine">Source: financial disclosure reports and periodic transaction reports filed with the Clerk of the House. Values are the ranges members report, not exact amounts.</span>';
  const panel = el("[data-panel]", root);
  let seen = false;
  const grow = () => all("[data-w]", panel).forEach((b) => (b.style.width = b.dataset.w ?? "0"));
  const side = (s: "P" | "S") => (s === "P" ? { word: "BUY", cls: "buy" } : { word: "SELL", cls: "sell" });

  const repView = () => {
    const name = scoutById.get(P.member)!.full;
    return (
      '<div class="pf-grid pf-in">' +
      '<div class="pf-main card"><div class="pf-id"><img src="' + portrait(P.member) + '" alt="' + esc(name) + '" width="56" height="56"><span><span class="pf-name">' + esc(name) +
      '</span><span class="fine">Annual financial disclosures, House Clerk</span></span></div>' +
      '<div class="pf-years"><span class="eyebrow">REPORTED ASSETS · DISCLOSURES GIVE RANGES, SO WE SHOW RANGES</span>' +
      P.years
        .map((y) => {
          const b = rangeBar(y.low, y.high, P.scaleMax, 1);
          return (
            '<div class="yr"><span class="yr__y">' + y.year + '</span><span class="yr__track"><span class="yr__bar pf-bar" data-w="' + b.width + '" style="left:' + b.left +
            ";background:var(--" + (y.tone === "yea" ? "yea" : "dim-2") + ')"></span></span><span class="yr__l num">' + esc(y.label) + "</span></div>"
          );
        })
        .join("") +
      '<div class="yr yr--axis" aria-hidden="true"><span></span><span class="yr__ticks"><span>$0</span><span>$600K</span><span>$1.2M</span></span><span></span></div></div>' +
      '<div class="pf-stats">' + P.stats.map((k) => '<div class="pf-stat"><span class="pf-stat__b" style="color:' + tone(k.tone) + '">' + esc(k.big) + "</span><span>" + esc(k.label) + "</span></div>").join("") + "</div>" +
      '<div class="callout callout--ai"><span class="ai-tag ai-tag--sm">' + AI_STAR + "AI</span><span>" + esc(P.aiNote) + "</span></div>" +
      "</div>" +
      '<div class="pf-trades card"><div class="pf-trades__head"><span class="h5">Trades · 2025</span><span class="fine">' + P.trades.length + " reported</span></div>" +
      P.trades
        .map((t) => {
          const s = side(t.side);
          return (
            '<div class="row pf-trade"><span class="side side--' + s.cls + '">' + s.word + '</span><span class="pf-trade__a"><span>' + esc(t.asset) + "</span><small>" + esc(t.who) + " · " + esc(t.date) +
            '</small></span><span class="pf-trade__r">' + esc(P.tradeRange) + "</span></div>"
          );
        })
        .join("") +
      '<div class="pf-trades__foot">STOCK Act transaction reports filed in 2026: <b>' + P.ptrs2026 + "</b></div></div></div>"
    );
  };

  const tradersView = () => {
    const top = P.board[0]!.reports;
    return (
      '<div class="pf-grid pf-in">' +
      '<div class="pf-board card"><div class="pf-board__head"><span class="h5">Most active · House · 2026</span><span class="fine">Periodic transaction reports filed so far this year. One report can list many trades.</span></div>' +
      P.board
        .map(
          (b, i) =>
            '<div class="row pf-brow"><span class="pf-brow__n' + (i === 0 ? " accent" : "") + '">' + (i + 1) + '</span><span class="pf-brow__name">' + esc(b.name) + " <span>" + esc(b.seat) +
            '</span></span><span class="pf-brow__track"><span class="pf-bar" data-w="' + (100 * b.reports) / top + '%"></span></span><span class="pf-brow__c">' + b.reports + "</span></div>",
        )
        .join("") +
      "</div>" +
      '<div class="pf-report card"><div class="pf-report__head"><span><span class="h5">One report, up close</span><span class="fine">' + esc(P.report.filer) +
      '</span></span><span class="pf-report__bs"><span class="yea">' + P.report.buys + ' BUYS</span><span class="nay">' + P.report.sells + " SELLS</span></span></div>" +
      '<div class="tape">' +
      P.report.tape
        .map((t) => {
          const s = side(t.side);
          return (
            '<div class="tape__t tape__t--' + s.cls + '"><span class="tape__top"><span class="tape__tk">' + esc(t.ticker) + '</span><span class="tape__side">' + s.word + "</span></span>" +
            '<span class="tape__name">' + esc(t.name) + '</span><span class="fine">' + esc(t.date) + " · " + esc(P.tradeRange) + "</span></div>"
          );
        })
        .join("") +
      "</div>" +
      '<div class="pf-report__foot"><span class="pf-lag"><span class="pf-lag__v">' + esc(P.report.lag) + '</span><span class="fine">from trade to filing · the STOCK Act allows up to 45</span></span>' +
      '<span class="pf-ai"><b>AI ·</b> ' + esc(P.report.aiNote) + "</span></div></div></div>"
    );
  };

  const show = (i: number) => {
    panel.innerHTML = i === 0 ? repView() : tradersView();
    if (seen) grow();
  };
  const set = wireTabs(el("[data-tabs]", root), show);
  set(0);
  show(0);
  onVisible(panel, () => {
    seen = true;
    afterPaint(grow);
  }, 0.3);
}

// ------------------------------------------------------------------ 08 · live

function phone(): void {
  const root = el("#phone");
  const v = live.vote;
  root.innerHTML =
    '<div class="island-row"><div class="island" role="status" aria-live="polite" data-island></div></div>' +
    '<div class="lock"><span class="lock__d">' + esc(live.lockDate) + '</span><span class="lock__t num">' + esc(live.lockTime) + "</span></div>" +
    '<div class="phone__ctl"><button type="button" class="phone__btn" data-next></button></div>';
  const island = el("[data-island]", root);
  const btn = el("[data-next]", root);
  const content: Record<string, string> = {
    idle: '<span class="island__idle"></span>',
    open:
      '<div class="island__c fade"><span class="live-dot pulse"></span><span class="island__mid"><span class="island__k">' + esc(v.chamber) + '</span><span class="island__t">' + esc(v.title) +
      '</span></span><span class="island__need">' + esc(v.needs) + "</span></div>",
    rep:
      '<div class="island__c fade"><img src="' + portrait(v.rep) + '" alt="" width="40" height="40"><span class="island__mid"><span class="island__k island__k--muted">YOUR REP JUST VOTED</span><span class="island__rep">' +
      esc(v.repLabel) + '</span></span><span class="island__pos ' + (v.repPos === "NAY" ? "nay" : "yea") + '">' + v.repPos + "</span></div>",
    final:
      '<div class="island__c island__c--final fade"><span class="island__score yea">' + v.yea + '</span><span class="island__res"><span class="island__chip">' + esc(v.result) +
      '</span><span class="island__fin">' + esc(v.final) + '</span></span><span class="island__score nay">' + v.nay + "</span></div>",
  };
  let step = 0;
  const show = () => {
    const s = live.steps[step]!;
    island.style.width = s.width;
    island.style.height = s.height;
    island.style.borderRadius = s.radius;
    island.innerHTML = content[s.mode] ?? "";
    btn.textContent = s.next;
  };
  const auto = window.setInterval(() => {
    step = islandNext(step);
    show();
  }, 2600);
  btn.addEventListener("click", () => {
    window.clearInterval(auto);
    step = islandNext(step);
    show();
  });
  show();
}

// ------------------------------------------------------------------ sign-up

function signUp(): void {
  const form = el<HTMLFormElement>("#get-form");
  const msg = el("#get-msg");
  form.addEventListener("submit", (e) => {
    e.preventDefault();
    msg.textContent = "Beta sign-up opens soon";
  });
}

// ------------------------------------------------------------------ boot

header();
heroStats();
flapBoard();
tickerBar();
deck();
levelCards();
driveChart();
explain();
scout();
players();
money();
context();
portfolioView();
phone();
signUp();
