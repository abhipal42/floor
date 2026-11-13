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
  sampleReps,
  scouting,
  ticker,
  type MemberId,
  type Tone,
} from "./data.js";
import { API_BASE } from "./config.js";
import {
  INITIAL,
  PRIVACY,
  STORE_KEY,
  canCancel,
  congressOn,
  foundFrom,
  gridLabel,
  httpOk,
  isSample,
  recordsError,
  memberUrl,
  nextState,
  parseFound,
  portraitUrl,
  repsOutcome,
  repsUrl,
  scoutFrom,
  seatShort,
  serializeFound,
  stripView,
  votesUrl,
  type ApiMember,
  type ApiMemberVote,
  type ApiReps,
  type FoundRow,
  type FoundScout,
  type LocEvent,
  type LocState,
  type Place,
} from "./locate.js";
import {
  FLAP_ROWS,
  FLAP_TICKS,
  FLAP_WIDTH,
  activeLevel,
  headFloats,
  scrollStep,
  stepLength,
  stickTop,
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

// ------------------------------------------------------------------ pinned sections
//
// A pinned section holds still while the reader scrolls, and each stretch of scroll moves it one
// step (the next final, the next level, the next member). It is plain sticky positioning over a
// tall run of empty space, so the scroll itself is never intercepted: the scrollbar stays honest,
// a fling or a keyboard jump passes straight through, and the reader's own clicks still work and
// move the scroll to match. A section pins only on screens wide and tall enough to show its whole
// stage, and never with reduced motion; otherwise it behaves as it always did.

interface Steps {
  /** What the progress pill calls one step: "Final", "Level". */
  noun: string;
  count: number;
  go: (i: number) => void;
  /** The step a reader's own click (a tab, a card, Next) moves the section to, if any. */
  picked?: (target: Element) => number | null;
}

interface Pin {
  update: () => void;
  layout: () => void;
  /** The pill's text while this section is pinned, or null when it isn't. */
  status: () => string | null;
  skip: () => void;
}

const pinQuery = window.matchMedia("(min-width: 900px) and (min-height: 640px)");
const pins: Pin[] = [];

function pin(stage: HTMLElement, s: Steps): void {
  const host = document.createElement("div");
  host.className = "pin";
  stage.before(host);
  host.append(stage);
  const run = document.createElement("div");
  run.className = "pin__run";
  run.setAttribute("aria-hidden", "true");
  host.append(run);

  let on = false;
  let cur = 0;
  let top = 0;
  let len = 0;
  let h = 0;
  const scrolled = () => top + h - run.getBoundingClientRect().top;

  const layout = () => {
    const was = on;
    stage.classList.remove("is-pinned");
    stage.style.top = "";
    host.style.paddingTop = "";
    host.style.paddingBottom = "";
    run.style.height = "0px";
    if (!pinQuery.matches || reduced()) {
      on = false;
      return;
    }
    // The stage's own vertical padding moves to the host, so only its content has to fit.
    const cs = getComputedStyle(stage);
    const padTop = cs.paddingTop;
    const padBottom = cs.paddingBottom;
    stage.classList.add("is-pinned");
    h = stage.offsetHeight;
    const head = el("#site-head").offsetHeight;
    on = h <= window.innerHeight - head - 24;
    if (!on) {
      stage.classList.remove("is-pinned");
      return;
    }
    host.style.paddingTop = padTop;
    host.style.paddingBottom = padBottom;
    top = stickTop(head, window.innerHeight, h);
    len = stepLength(window.innerHeight);
    stage.style.top = top + "px";
    run.style.height = len * s.count + "px";
    if (!was) {
      cur = 0;
      s.go(0);
    }
  };

  // Content can change height while pinned (a form opens, a longer point expands). Keep the stage
  // where it is if it still fits below that top, re-centre if not, and let go if it no longer fits.
  new ResizeObserver(() => {
    if (!on) return;
    const next = stage.offsetHeight;
    if (next === h) return;
    const head = el("#site-head").offsetHeight;
    if (next > window.innerHeight - head - 24) {
      layout();
      return;
    }
    h = next;
    if (top + h > window.innerHeight - 12) {
      top = stickTop(head, window.innerHeight, h);
      stage.style.top = top + "px";
    }
  }).observe(stage);

  const update = () => {
    if (!on) return;
    const i = scrollStep(scrolled(), len, s.count);
    if (i !== cur) {
      cur = i;
      s.go(i);
    }
  };

  // A reader's own click picks a step directly; move the scroll to that step so the two agree.
  stage.addEventListener(
    "click",
    (e) => {
      if (!on || !e.isTrusted || !s.picked) return;
      const i = s.picked(e.target as Element);
      if (i === null) return;
      cur = i;
      window.scrollBy({ top: i * len + 1 - scrolled(), behavior: "instant" as ScrollBehavior });
    },
    true,
  );

  pins.push({
    update,
    layout,
    status: () => {
      if (!on) return null;
      const sc = scrolled();
      if (sc < 0 || sc >= len * s.count) return null;
      if (s.count === 1) return s.noun;
      return s.noun + " " + (cur + 1) + " of " + s.count;
    },
    skip: () => window.scrollBy({ top: len * s.count - scrolled() + 2, behavior: "instant" as ScrollBehavior }),
  });
}

/** Starts every pinned section and the pill that shows progress and offers a way out. */
function pinAll(): void {
  const pill = document.createElement("div");
  pill.className = "pin-pill";
  pill.hidden = true;
  pill.innerHTML = '<span class="pin-pill__t" data-t></span><span class="pin-pill__hint">scroll to step through</span><button type="button" class="pin-pill__skip">Skip ↓</button>';
  document.body.append(pill);
  const text = el("[data-t]", pill);
  let live: Pin | null = null;
  el(".pin-pill__skip", pill).addEventListener("click", () => live?.skip());

  const update = () => {
    live = null;
    let t: string | null = null;
    for (const p of pins) {
      p.update();
      const st = p.status();
      if (st !== null) {
        live = p;
        t = st;
      }
    }
    pill.hidden = t === null;
    if (t !== null && text.textContent !== t) text.textContent = t;
  };
  let queued = false;
  const schedule = () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => {
      queued = false;
      update();
    });
  };
  const relayout = () => {
    pins.forEach((p) => p.layout());
    schedule();
  };
  window.addEventListener("scroll", schedule, { passive: true });
  window.addEventListener("resize", relayout);
  pinQuery.addEventListener("change", relayout);
  motionQuery.addEventListener("change", relayout);
  // Fonts change heights; measure once they are in.
  void document.fonts.ready.then(relayout);
  relayout();
}

/** Replays the swap-in transition on an element whose content was just replaced. */
function swapIn(target: HTMLElement): void {
  target.classList.remove("swap");
  void target.offsetWidth;
  target.classList.add("swap");
}

/**
 * Clicks the i-th tab of a tablist as if by hand, which runs its own selection code, then plays
 * the swap transition on the panel it fills.
 */
function tabStep(list: HTMLElement, panel: HTMLElement): Pick<Steps, "go" | "picked"> {
  const tabs = () => all<HTMLButtonElement>('[role="tab"]', list);
  return {
    go: (i) => {
      const tab = tabs()[i];
      if (!tab || tab.getAttribute("aria-selected") === "true") return;
      tab.click();
      swapIn(panel);
    },
    picked: (t) => {
      const tab = t.closest('[role="tab"]');
      const i = tab ? tabs().indexOf(tab as HTMLButtonElement) : -1;
      return i >= 0 ? i : null;
    },
  };
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

  // The bar draws in to a floating capsule once the reader scrolls. Only the inner bar changes:
  // the band's height, which pinned sections read, stays put (see .site-head in styles.css).
  let floating = false;
  let queued = false;
  const update = () => {
    queued = false;
    const next = headFloats(window.scrollY, floating);
    if (next === floating) return;
    floating = next;
    head.classList.toggle("is-floating", next);
  };
  window.addEventListener(
    "scroll",
    () => {
      if (queued) return;
      queued = true;
      requestAnimationFrame(update);
    },
    { passive: true },
  );
  update();
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
          '<div class="dk-reps"><span class="eyebrow" data-your-three>YOUR THREE</span>' +
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

  let wait = 0;
  const move = (dir: 1 | -1) => {
    if (leaving >= 0) return;
    const next = deckStep(front, dir);
    if (dir > 0 && !reduced()) {
      leaving = front;
      paint();
      wait = window.setTimeout(() => {
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

  // Pinned: each stretch of scroll deals the next final; one step forward keeps the deal animation.
  pin(el("#finals"), {
    noun: "Final",
    count: cards.length,
    go: (k) => {
      if (k === front && leaving < 0) return;
      if (k === deckStep(front, 1) && leaving < 0) {
        move(1);
        return;
      }
      window.clearTimeout(wait);
      leaving = -1;
      seen[k] = true;
      front = k;
      announce();
      count();
    },
    picked: (t) => (t.closest("[data-next]") ? deckStep(front, 1) : t.closest("[data-prev]") ? deckStep(front, -1) : null),
  });
}

// ------------------------------------------------------------------ 02 · levels + drive chart

// The section title and a six-stop map hold still beside one connected road of level cards; the
// stop and card for the level the reader has scrolled to light up, and earlier ones read as cleared.
function levelCards(): void {
  const track = el("#law-track");
  const road = el("#levels");
  const now = el("#law-now");
  track.innerHTML =
    '<span class="track__fill" aria-hidden="true"></span>' +
    levels.items
      .map(
        (l, i) =>
          '<li><button type="button" class="stop' + (l.boss ? " stop--boss" : "") + '" aria-label="Level ' + (i + 1) + ": " + esc(l.name) +
          (l.boss ? ", boss level" : "") + '"><span class="stop__dot">' + (i + 1) + '</span><span class="stop__name">' + esc(l.name) +
          (l.boss ? '<span class="stop__boss">BOSS</span>' : "") + "</span></button></li>",
      )
      .join("");
  road.innerHTML = '<div class="road__in">' + levels.items
    .map(
      (l, i) =>
        '<article class="leg' + (l.boss ? " leg--boss" : "") + '"><span class="leg__pin" aria-hidden="true"></span><div class="leg__card">' +
        '<div class="leg__top"><span class="leg__id"><span class="leg__n" aria-hidden="true">L' + (i + 1) + '</span><h3 class="leg__name"><span class="sr">Level ' +
        (i + 1) + ": </span>" + esc(l.name) + "</h3>" + (l.boss ? '<span class="skew skew--accent">BOSS</span>' : "") + "</span>" +
        '<span class="leg__need">' + esc(l.need) + '<span class="leg__cleared"> · CLEARED</span></span></div>' +
        '<p class="leg__text">' + esc(l.body) + "</p>" +
        '<div class="play"><span class="eyebrow play__k">REAL PLAY · ' + esc(l.example.when).toUpperCase() + '</span><span class="play__t">' + esc(l.example.title) +
        '</span><span class="play__s num"><span class="yea">' + esc(l.example.yea) + '</span><span class="play__dash">–</span><span class="nay">' + esc(l.example.nay) +
        '</span><span class="play__r" style="color:' + tone(l.example.tone) + '">' + esc(l.example.result) + "</span></span></div>" +
        "</div></article>",
    )
    .join("") + "</div>";

  const stops = all<HTMLButtonElement>(".stop", track);
  const legs = all(".leg", road);
  const fill = el(".track__fill", track);
  let on = -1;
  const law = el(".law");
  // Pinned (wide screens), the stage shows one card at a time and the pin drives the level;
  // otherwise the road scrolls past the sticky map and the level follows the reading line.
  const pinned = () => law.classList.contains("is-pinned");
  const lane = el(".road__in", road);
  // Pinned, the road is a window onto the connected lane, moved so the focused card sits centred.
  const centre = () => {
    if (!pinned() || on < 0) {
      lane.style.transform = "";
      return;
    }
    const leg = legs[on]!;
    const y = road.clientHeight / 2 - (leg.offsetTop + leg.offsetHeight / 2);
    lane.style.transform = "translateY(" + Math.round(y) + "px)";
  };

  const setLevel = (next: number) => {
    if (next === on) return;
    on = next;
    legs.forEach((leg, i) => {
      leg.classList.toggle("is-on", i === on);
      leg.classList.toggle("is-cleared", i < on);
    });
    stops.forEach((stop, i) => {
      stop.classList.toggle("is-on", i === on);
      stop.classList.toggle("is-cleared", i < on);
      if (i === on) stop.setAttribute("aria-current", "step");
      else stop.removeAttribute("aria-current");
    });
    const first = el(".stop__dot", stops[0]).getBoundingClientRect();
    const cur = el(".stop__dot", stops[on]).getBoundingClientRect();
    fill.style.setProperty("--fill-y", Math.max(0, cur.top - first.top) + "px");
    fill.style.setProperty("--fill-x", Math.max(0, cur.left - first.left) + "px");
    now.textContent = "Level " + (on + 1) + " · " + levels.items[on]!.name;
    centre();
  };

  const update = () => {
    if (pinned()) return;
    setLevel(activeLevel(legs.map((leg) => leg.getBoundingClientRect().top), window.innerHeight * 0.45));
  };

  stops.forEach((stop, i) =>
    stop.addEventListener("click", () => {
      if (pinned()) return;
      const head = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--head-h")) || 0;
      const y = legs[i]!.getBoundingClientRect().top + window.scrollY - head - window.innerHeight * 0.2;
      window.scrollTo({ top: y, behavior: reduced() ? "auto" : "smooth" });
    }),
  );

  let queued = false;
  const schedule = () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => {
      queued = false;
      update();
    });
  };
  window.addEventListener("scroll", schedule, { passive: true });
  window.addEventListener("resize", () => {
    if (pinned()) {
      centre();
      return;
    }
    lane.style.transform = "";
    on = -1;
    schedule();
  });
  update();

  // Pinned: the map and one level card hold still; each stretch of scroll clears a level.
  pin(law, {
    noun: "Level",
    count: levels.items.length,
    go: (i) => {
      setLevel(i);
      centre();
    },
    picked: (t) => {
      const stop = t.closest(".stop");
      const i = stop ? stops.indexOf(stop as HTMLButtonElement) : -1;
      return i >= 0 ? i : null;
    },
  });
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

  // Pinned: each stretch of scroll moves to the next point and lights the paragraph it came from.
  // The steps follow the first bill's points; another bill's extra points are a hover away.
  pin(root, {
    noun: "Point",
    count: explainers.bills[0]!.points.length,
    go: (i) => {
      hi = Math.min(i, explainers.bills[bill]!.points.length - 1);
      highlight();
    },
    picked: (t) => {
      const b = t.closest<HTMLElement>("[data-pt]");
      return b ? Number(b.dataset.pt) : null;
    },
  });
}

// ------------------------------------------------------------------ 04 · scouting

/** One scouting card, from the sample snapshot or built from the API (`scoutFrom`). */
interface ScoutCard {
  id: string;
  label: string;
  full: string;
  seat: string;
  chamber: "House" | "Senate";
  unity: number | null;
  withPartySub: string;
  played: number;
  playedSub: string;
  won: number;
  of: number;
  cross: number | null;
  note: string;
  grid: readonly FoundRow[];
  img: string;
  box: { k: string; t: string } | null;
  delegate: string;
  failed?: false;
}

/** A member whose own records didn't load while the others' did. */
interface FailedCard {
  failed: true;
  id: string;
  label: string;
  img: string;
}

const SAMPLE_CARDS: ScoutCard[] = scouting.members.map((m) => ({
  ...m,
  withPartySub: m.withParty.toLocaleString("en-US") + " of " + m.partyVotes.toLocaleString("en-US"),
  img: portrait(m.id),
  box: { k: "DID YOU KNOW", t: m.fact },
  delegate: "",
}));

function foundCard(f: FoundScout): ScoutCard {
  return { ...f, img: portraitUrl(f.id), box: f.latest ? { k: "LATEST CALL", t: f.latest } : null };
}

type ScoutMode =
  | { kind: "sample" }
  | { kind: "skeleton" }
  | { kind: "loading"; members: ApiMember[] }
  | { kind: "error"; members: ApiMember[] }
  | { kind: "found"; cards: (ScoutCard | FailedCard)[] };

function scout(onRetry: () => void): (mode: ScoutMode) => void {
  const tabs = el("#scout-tabs");
  const panel = el("#scout-panel");
  const kicker = el("#scout-kicker");
  let cards: (ScoutCard | FailedCard)[] = SAMPLE_CARDS;
  let who = 0;
  let hi = 39;
  let seen = false;

  const tabsFor = (list: { id: string; label: string; img: string }[]) => {
    tabs.innerHTML = list
      .map((m) => '<button type="button" role="tab" class="ptab"><img src="' + esc(m.img) + '" alt="" width="36" height="36">' + esc(m.label) + "</button>")
      .join("");
  };
  const memberList = (ms: ApiMember[]) => ms.map((m) => ({ id: m.bioguideId, label: m.lastName, img: portraitUrl(m.bioguideId) }));

  const readout = () => {
    const sc = cards[who]!;
    if (sc.failed || !sc.grid.length) return;
    const i = Math.min(hi, sc.grid.length - 1);
    const r = sc.grid[i]!;
    const look = cellLook(r[4]);
    all(".sq", panel).forEach((q, k) => q.classList.toggle("is-hi", k === i));
    el("[data-readout]", panel).innerHTML =
      '<span class="ro__pos" style="background:var(--' + look.chipBg + ");color:var(--" + look.chipFg + ')">' + esc(look.word) + "</span>" +
      '<span class="ro__what"><span class="ro__t">' + esc(readoutCite(r[2], r[3])) + " · " + esc(r[3]) + '</span><span class="ro__m">' + esc(sc.chamber) +
      (r[0] ? " roll " + esc(Number(r[0])) : "") + " · " + esc(r[1]) + " · " + esc(r[7].trim()) + "</span></span>" +
      '<span class="ro__s num"><span class="yea">' + esc(Number(r[5])) + '</span>–<span class="nay">' + esc(Number(r[6])) + "</span></span>";
  };

  const rings = (p: number) => {
    const sc = cards[who];
    if (!sc || sc.failed) return;
    // Showed up is out of 40 in the sample; ringValues scales by 2.5, so scale a shorter grid to match.
    const vals = ringValues({ unity: sc.unity ?? 0, played: (sc.played * 40) / Math.max(1, sc.grid.length), won: sc.won, of: Math.max(1, sc.of) });
    all<SVGCircleElement>("[data-ring]", panel).forEach((c, k) => {
      c.setAttribute("stroke-dasharray", ringDash(vals[k] ?? 0, p));
      // No party votes to count: draw no ring at all, not the dot a zero-length round cap leaves.
      c.style.opacity = k === 0 && sc.unity === null ? "0" : "";
    });
  };

  const show = (i: number) => {
    who = i;
    const sc = cards[i]!;
    if (sc.failed) {
      errorCard(recordsError(cards.length, sc.label));
      return;
    }
    const n = sc.grid.length;
    hi = n - 1;
    const ringDefs = [
      {
        label: "With party",
        big: sc.unity === null ? "—" : sc.unity.toFixed(1) + "%",
        sub: sc.withPartySub,
        color: "yea",
      },
      { label: "Showed up", big: sc.played + "/" + n, sub: sc.playedSub, color: "ink" },
      { label: "Winning side", big: sc.won + "/" + sc.of, sub: "last " + n + " calls", color: "nay" },
    ];
    const hasC = sc.grid.some((r) => r[4] === "C");
    panel.innerHTML =
      '<div class="sc-card card">' +
      '<div class="sc-id"><img src="' + esc(sc.img) + '" alt="' + esc(sc.full) + '" width="80" height="96"><div><span class="sc-name">' + esc(sc.full) + '</span><span class="sc-seat">' +
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
      '<div class="sc-cross"><span class="sc-cross__n"><span class="sc-cross__k">Crossovers since 2023</span><span class="sc-cross__v num">' + (sc.cross === null ? "—" : esc(Number(sc.cross))) + '</span></span><span class="sc-cross__note">' +
      esc(sc.note) + "</span></div></div>" +
      '<div class="sc-grid card">' +
      '<div class="sc-grid__head"><h3 class="h4">Last ' + n + ' calls</h3><span class="legend"><span><i class="lg lg--y"></i>Yea</span><span><i class="lg lg--n"></i>Nay</span><span><i class="lg lg--p"></i>Present</span><span><i class="lg lg--m"></i>Missed</span>' +
      (hasC ? '<span><i class="lg lg--c"></i>Speaker vote</span>' : "") + "</span></div>" +
      '<div class="squares" role="group" aria-label="' + esc(gridLabel(sc.grid)) + '">' +
      sc.grid
        .map((r, k) => {
          const look = cellLook(r[4]);
          return '<button type="button" class="sq sq--' + r[4] + '" data-sq="' + k + '" aria-label="' + esc(r[1] + ", " + r[2] + ", " + look.word) + '"></button>';
        })
        .join("") +
      "</div>" +
      (n ? '<div class="ro fade" data-readout aria-live="polite"></div>' : '<p class="fine">No recorded votes yet this Congress.</p>') +
      (sc.delegate ? '<div class="dyk dyk--delegate"><span class="dyk__k">DELEGATE</span><span class="dyk__t">' + esc(sc.delegate) + "</span></div>" : "") +
      (sc.box ? '<div class="dyk"><span class="dyk__k">' + esc(sc.box.k) + '</span><span class="dyk__t">' + esc(sc.box.t) + "</span></div>" : "") +
      "</div>";
    readout();
    rings(0);
    if (seen) afterPaint(() => rings(1));
  };

  const skeleton = (msg: string) => {
    panel.innerHTML =
      '<div class="sc-card card sc-skel" aria-hidden="true"><div class="sc-id"><span class="skel skel--img"></span><div><span class="skel skel--line"></span><span class="skel skel--line skel--short"></span></div></div></div>' +
      '<div class="sc-grid card"><div class="sc-grid__head"><h3 class="h4">Last 40 calls</h3></div><div class="squares" aria-hidden="true">' +
      '<span class="sq sq--M"></span>'.repeat(40) + '</div><p class="fine">' + esc(msg) + "</p></div>";
  };

  const errorCard = (copy: { title: string; body: string }) => {
    panel.innerHTML =
      '<div class="sc-err card"><h3 class="h4">' + esc(copy.title) + "</h3><p>" + esc(copy.body) + "</p>" +
      '<button type="button" class="sc-err__retry" data-retry>Try again</button></div>';
    el("[data-retry]", panel).addEventListener("click", () => {
      onRetry();
      panel.focus({ preventScroll: true });
    });
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

  // Tabs pick a card only while cards are showing; in the other modes they just name the members.
  let live = true;
  const set = wireTabs(tabs, (i) => {
    if (live) show(i);
  });
  onVisible(panel, () => {
    seen = true;
    afterPaint(() => rings(1));
  }, 0.3);

  // Pinned: the section holds still and each stretch of scroll moves to the next member.
  pin(el("#scout"), { noun: "Member", count: YOUR_THREE.length, ...tabStep(tabs, panel) });

  return (mode: ScoutMode) => {
    kicker.textContent = mode.kind === "sample" || mode.kind === "skeleton" ? "04 · YOUR REPS · SAMPLE · NY-8" : "04 · YOUR MEMBERS";
    live = mode.kind === "sample" || mode.kind === "found";
    if (mode.kind === "sample" || mode.kind === "found") {
      cards = mode.kind === "sample" ? SAMPLE_CARDS : mode.cards;
      tabsFor(cards.map((c) => ({ id: c.id, label: c.label, img: c.img })));
      set(0);
      show(0);
      return;
    }
    if (mode.kind === "skeleton") {
      tabs.innerHTML = "";
      skeleton("Finding your district…");
      return;
    }
    tabsFor(memberList(mode.members));
    set(0);
    if (mode.kind === "loading") skeleton("Loading their records…");
    else errorCard(recordsError(mode.members.length));
  };
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

  // Pinned: the cards hold still for one stretch of scroll, then the leaderboard scrolls up below
  // them, the way the drive chart follows the levels. The fan is not stepped through; hovering it
  // still picks a card.
  pin(el("#cards .players"), { noun: "The players", count: 1, go: () => {} });
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

  // Pinned: the heading and the funding panel hold still and each stretch of scroll moves to the
  // next member. The donor explainer below is a list to browse, so it scrolls freely.
  const stage = document.createElement("div");
  stage.className = "money__stage";
  const head = el("#money .sec-head");
  head.before(stage);
  stage.append(head, panel);
  pin(stage, { noun: "Member", count: funding.members.length, ...tabStep(tabs, panel) });
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

// ------------------------------------------------------------------ your members, from your location

/** GETs JSON; `status` is null when fetch itself threw (offline, or a response without CORS). */
async function getJson(url: string): Promise<{ status: number | null; body: unknown }> {
  try {
    const res = await fetch(url);
    let body: unknown = null;
    try {
      body = await res.json();
    } catch {
      body = null;
    }
    return { status: res.status, body };
  } catch {
    return { status: null, body: null };
  }
}

function storeGet(): string | null {
  try {
    return window.localStorage.getItem(STORE_KEY);
  } catch {
    return null;
  }
}

function storeSet(value: string | null): void {
  try {
    if (value === null) window.localStorage.removeItem(STORE_KEY);
    else window.localStorage.setItem(STORE_KEY, value);
  } catch {
    // Private windows and blocked storage: the page works, it just won't remember.
  }
}

const LOCATE_ICON =
  '<svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="3" fill="currentColor"></circle><circle cx="8" cy="8" r="6.2" fill="none" stroke="currentColor" stroke-width="1.6"></circle></svg>';

function chipHtml(m: ApiMember, img: string): string {
  return (
    '<span class="ychip"><img src="' + esc(img) + '" alt="" width="40" height="40"><span class="ychip__t"><span class="ychip__n">' + esc(m.lastName) +
    '</span><span class="ychip__s">' + esc(seatShort(m) + " · " + m.party) + "</span></span></span>"
  );
}

function yours(): void {
  const strip = el("#yours-strip");
  const kicker = el("#yours-kicker");
  const chips = el("#yours-chips");
  const note = el("#yours-note");
  const title = el("#yours-title");
  const locate = el<HTMLButtonElement>("#yours-locate");
  const form = el<HTMLFormElement>("#yours-addr");
  const input = el<HTMLInputElement>("#yours-input");
  const err = el("#yours-err");
  const toAddr = el<HTMLButtonElement>("#yours-to-addr");
  const back = el<HTMLButtonElement>("#yours-back");
  const cancel = el<HTMLButtonElement>("#yours-cancel");
  const status = el("#yours-status");
  el("#yours-privacy").textContent = PRIVACY;

  let state: LocState = INITIAL;
  let gen = 0;
  let scoutKey = "";
  let found: (ScoutCard | FailedCard)[] = [];
  const showScout = scout(() => dispatch({ type: "retry" }));

  const sampleChips = sampleReps.members.map((m) => chipHtml(m, portrait(m.bioguideId as MemberId))).join("");

  const announce = (s: LocState, prev: LocState) => {
    if (s.step === prev.step && s.records === prev.records && s.addrErr === prev.addrErr) return;
    const v = stripView(s);
    let msg = "";
    if (s.step === "found") {
      if (prev.step !== "found") msg = "Found " + (s.found?.label ?? "your district") + ": " + (s.found?.members.map((m) => m.firstName + " " + m.lastName).join(", ") ?? "") + ". " + v.note;
      else if (s.records === "error") msg = recordsError(s.found?.members.length ?? 0).title + ".";
      else if (s.records === "partial") {
        const failed = found.filter((c) => c.failed).map((c) => c.label);
        msg = "Loaded the records for " + (s.found?.label ?? "your district") + ", except " + failed.join(" and ") + ".";
      } else if (s.records === "ready") msg = "Loaded the records for " + (s.found?.label ?? "your district") + ".";
    } else if (s.step === "asking") msg = "Waiting for your browser's location prompt.";
    else if (s.step === "loading") msg = "Finding your district.";
    else if (s.step === "address" && s.addrErr) msg = "";
    else if (s.step !== "idle" && s.step !== "address") msg = v.kicker.toLowerCase() + ". " + v.title + " " + v.note;
    else if (s.step === "idle" && prev.step !== "idle") msg = "Showing the New York sample.";
    if (msg) status.textContent = msg.trim();
  };

  const render = (prev: LocState) => {
    const s = state;
    const v = stripView(s);
    strip.dataset.tone = v.tone;
    strip.dataset.step = s.step;
    kicker.textContent = v.kicker;
    chips.classList.toggle("is-dim", v.dim);
    if (v.chips === "skeleton") chips.innerHTML = '<span class="ychip ychip--skel"></span>'.repeat(3);
    else if (v.chips === "found" && s.found) chips.innerHTML = s.found.members.map((m) => chipHtml(m, portraitUrl(m.bioguideId))).join("");
    else chips.innerHTML = sampleChips;
    chips.setAttribute("aria-busy", String(v.chips === "skeleton"));
    note.hidden = !v.note;
    note.textContent = v.note;
    title.hidden = !v.title;
    title.textContent = v.title;
    locate.hidden = !v.locate;
    locate.innerHTML = LOCATE_ICON + "<span>" + esc(v.locate ?? "") + "</span>";
    // aria-disabled, not disabled: a disabled button drops the focus it holds while the browser asks.
    locate.setAttribute("aria-disabled", String(s.step === "asking"));
    form.hidden = !v.address;
    input.setAttribute("aria-invalid", String(s.addrErr));
    err.hidden = !s.addrErr;
    err.textContent = s.addrErr ? "Enter a street address — a ZIP alone can sit across two districts." : "";
    toAddr.hidden = !v.addressLink;
    toAddr.textContent = v.addressLink ?? "";
    back.hidden = !v.back;
    cancel.hidden = !canCancel(s);
    el(".yours__links").hidden = !v.addressLink && !v.back && cancel.hidden;
    // The address has done its job once a district is found; don't leave it sitting in the page.
    if (s.step === "found") input.value = "";

    // Everything that still shows New York says so once the strip shows someone else's members.
    const sample = isSample(s);
    for (const f of all("[data-sample-flag]")) f.hidden = sample;
    for (const e of all("[data-your-three]")) e.textContent = sample ? "YOUR THREE" : "NY-8 SAMPLE";

    const key =
      s.step === "loading" ? "skeleton" : sample ? "sample" : "found:" + (s.found?.members.map((m) => m.bioguideId).join(",") ?? "") + ":" + s.records;
    if (key !== scoutKey) {
      scoutKey = key;
      const members = s.found?.members ?? [];
      if (key === "skeleton") showScout({ kind: "skeleton" });
      else if (sample) showScout({ kind: "sample" });
      else if (s.records === "ready" || s.records === "partial") showScout({ kind: "found", cards: found });
      else showScout({ kind: s.records === "error" ? "error" : "loading", members });
    }

    announce(s, prev);
    // A control that just disappeared took focus with it: hand it to the strip, not the page top.
    const a = document.activeElement;
    if (!a || a === document.body || (a instanceof HTMLElement && a.closest("[hidden]"))) {
      if (prev.step !== s.step && s.step !== "idle") strip.focus({ preventScroll: true });
    }
  };

  const dispatch = (e: LocEvent) => {
    const prev = state;
    state = nextState(state, e);
    // Storage follows the screen: what a reload brings back is what the strip is showing. Leaving a
    // found district (to type another address, or back to the sample) clears it; Cancel back to it,
    // or a new district, writes it again. So a failed lookup after "Not your district?" never
    // resurrects the old district on reload.
    if (state.step === "found" && state.found) {
      if (prev.step !== "found" || prev.found !== state.found) storeSet(serializeFound(state.found));
    } else if (prev.step === "found" || e.type === "reset") storeSet(null);
    render(prev);
    if (state.step === "found" && state.records === "loading" && (prev.records !== "loading" || prev.step !== "found")) void loadRecords();
  };

  /** One member's card, or a failed placeholder: a bad response or a malformed vote fails that member only. */
  const loadMember = async (m: ApiMember): Promise<ScoutCard | FailedCard> => {
    const failed: FailedCard = { failed: true, id: m.bioguideId, label: m.lastName, img: portraitUrl(m.bioguideId) };
    try {
      const [detail, votes] = await Promise.all([getJson(memberUrl(API_BASE, m.bioguideId)), getJson(votesUrl(API_BASE, m.bioguideId))]);
      const loyalty = (detail.body as { partyLoyalty?: { votes: number; withParty: number; againstParty: number } } | null)?.partyLoyalty;
      const list = (votes.body as { votes?: ApiMemberVote[] } | null)?.votes;
      if (!httpOk(detail.status) || !httpOk(votes.status) || !loyalty || !Array.isArray(list)) return failed;
      if (![loyalty.votes, loyalty.withParty, loyalty.againstParty].every(Number.isFinite)) return failed;
      return foundCard(scoutFrom(m, loyalty, list));
    } catch {
      return failed;
    }
  };

  const loadRecords = async () => {
    const my = ++gen;
    const members = state.found?.members ?? [];
    const cards = await Promise.all(members.map(loadMember));
    if (my !== gen) return;
    found = cards;
    dispatch({ type: "records", loaded: cards.filter((c) => !c.failed).length, of: cards.length });
  };

  const lookup = async (place: Place) => {
    const my = ++gen;
    const res = await getJson(repsUrl(API_BASE, place));
    if (my !== gen) return;
    const outcome = repsOutcome(res.status, "address" in place ? "address" : "coords");
    const body = res.body as ApiReps | null;
    if (outcome === "ok" && body && Array.isArray(body.members) && body.district) dispatch({ type: "reps", outcome, found: foundFrom(body) });
    else dispatch({ type: "reps", outcome: outcome === "ok" ? "error" : outcome });
    // An address that needs fixing gets the cursor back, rather than leaving it on the strip.
    if (!form.hidden) input.focus();
  };

  cancel.addEventListener("click", () => {
    gen++;
    dispatch({ type: "cancel" });
    (state.step === "found" ? toAddr : locate).focus();
  });

  locate.addEventListener("click", () => {
    if (state.step === "asking") return;
    const geo = "geolocation" in navigator ? navigator.geolocation : null;
    dispatch({ type: "locate", supported: !!geo });
    if (!geo) {
      input.focus();
      return;
    }
    const my = ++gen;
    geo.getCurrentPosition(
      (pos) => {
        if (my !== gen) return;
        dispatch({ type: "geoFix" });
        void lookup({ lat: pos.coords.latitude, lng: pos.coords.longitude });
      },
      (e) => {
        if (my !== gen) return;
        dispatch({ type: "geoError", code: e.code });
        if (!form.hidden) input.focus();
      },
      { enableHighAccuracy: false, timeout: 20_000, maximumAge: 300_000 },
    );
  });
  toAddr.addEventListener("click", () => {
    gen++;
    dispatch({ type: "toAddress" });
    input.focus();
  });
  back.addEventListener("click", () => {
    gen++;
    input.value = "";
    dispatch({ type: "reset" });
    locate.focus();
  });
  input.addEventListener("input", () => dispatch({ type: "typed" }));
  form.addEventListener("submit", (e) => {
    e.preventDefault();
    const text = input.value;
    dispatch({ type: "submitAddress", text });
    if (state.step === "loading") void lookup({ address: text });
    else input.focus();
  });

  render(state);
  const saved = parseFound(storeGet(), congressOn(new Date()));
  if (!saved) storeSet(null);
  if (saved) dispatch({ type: "restore", found: saved });
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
players();
money();
context();
portfolioView();
phone();
signUp();
// Last: it owns the scouting report and relabels the sample sections above once it finds yours.
yours();
// After every section, the scouting report included, has registered its pin.
pinAll();
