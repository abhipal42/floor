import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { THEME_COLOR, THEME_KEY, nextChoice, parseChoice, resolveTheme, themeLabel } from "./theme.js";

const here = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(here, "../public/index.html"), "utf8").replace(/\r\n/g, "\n");
const css = readFileSync(join(here, "../public/styles.css"), "utf8").replace(/\r\n/g, "\n");

describe("theme choice", () => {
  it("reads a stored choice, and anything else as System", () => {
    expect(parseChoice("light")).toBe("light");
    expect(parseChoice("dark")).toBe("dark");
    expect(parseChoice("system")).toBe("system");
    expect(parseChoice(null)).toBe("system");
    expect(parseChoice("sepia")).toBe("system");
  });

  it("follows the system only when the choice is System", () => {
    expect(resolveTheme("system", true)).toBe("light");
    expect(resolveTheme("system", false)).toBe("dark");
    expect(resolveTheme("light", false)).toBe("light");
    expect(resolveTheme("dark", true)).toBe("dark");
  });

  it("steps System → Light → Dark → System", () => {
    expect(nextChoice("system")).toBe("light");
    expect(nextChoice("light")).toBe("dark");
    expect(nextChoice("dark")).toBe("system");
  });

  it("labels the button with the current choice and the next", () => {
    expect(themeLabel("system", "dark")).toBe("Theme: System (dark). Switch to Light");
    expect(themeLabel("light", "light")).toBe("Theme: Light. Switch to Dark");
    expect(themeLabel("dark", "dark")).toBe("Theme: Dark. Switch to System");
  });
});

describe("the page's own copy of the rule", () => {
  // index.html sets the theme before any module loads, so it repeats resolveTheme. Run that script
  // against a fake browser and check it lands where theme.ts does.
  const inline = html.match(/<script>(try\{[^<]*)<\/script>/)?.[1] ?? "";

  function runInline(stored: string | null, prefersLight: boolean) {
    const root = { dataset: {} as Record<string, string> };
    const meta = { content: THEME_COLOR.dark };
    new Function("localStorage", "matchMedia", "document", inline)(
      { getItem: (k: string) => (k === THEME_KEY ? stored : null) },
      () => ({ matches: prefersLight }),
      { documentElement: root, querySelector: () => meta },
    );
    return { theme: root.dataset.theme, color: meta.content };
  }

  it("runs before the stylesheet and the module", () => {
    expect(inline).not.toBe("");
    expect(html.indexOf(inline)).toBeLessThan(html.indexOf('href="styles.css"'));
    expect(html.indexOf(inline)).toBeLessThan(html.indexOf("js/main.js"));
  });

  it.each([
    [null, true],
    [null, false],
    ["light", false],
    ["dark", true],
    ["garbage", true],
  ] as const)("stored %s, system light %s", (stored, prefersLight) => {
    const want = resolveTheme(parseChoice(stored), prefersLight);
    expect(runInline(stored, prefersLight)).toEqual({ theme: want, color: THEME_COLOR[want] });
  });
});

describe("the light theme", () => {
  const block = (selector: string) => {
    const start = css.indexOf(selector + " {");
    return css.slice(start, css.indexOf("}", start));
  };
  const tokens = (text: string) => new Set([...text.matchAll(/(--[a-z0-9-]+):/g)].map((m) => m[1]));
  const lightBlock = block(':root[data-theme="light"]');
  const light = tokens(lightBlock);

  it("redefines every page colour the dark theme sets, except the lit displays' own", () => {
    const darkStart = css.indexOf(':root,\n:root[data-theme="light"]');
    const dark = tokens(css.slice(darkStart, css.indexOf("}", darkStart)));
    // Used only inside the board, ticker, field, phone and player-card frames, which keep them.
    const litOnly = new Set([
      "--black", "--ticker-bg", "--flap-top", "--flap-bottom", "--field-a", "--field-b", "--ball",
      "--phone-top", "--midline", "--shine", "--shine-0", "--shadow-phone", "--head-ease",
      "--gold-1", "--gold-2", "--silver-1", "--green-1", "--green-2",
    ]);
    expect(dark.size).toBeGreaterThan(40);
    expect([...dark].filter((t) => !light.has(t) && !litOnly.has(t))).toEqual([]);
  });

  const hex = (name: string) => {
    const m = lightBlock.match(new RegExp(name + ": (#[0-9a-f]{6});"));
    return parseInt(m![1].slice(1), 16);
  };
  const lum = (h: number) => {
    const c = [h >> 16, (h >> 8) & 255, h & 255].map((v) => {
      const s = v / 255;
      return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
    });
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  };
  const contrast = (a: number, b: number) => (Math.max(lum(a), lum(b)) + 0.05) / (Math.min(lum(a), lum(b)) + 0.05);

  it.each(["--ink", "--body", "--muted", "--para-dim", "--dim", "--yea", "--nay", "--accent", "--ai", "--live-text", "--error", "--teal"])(
    "%s reads at 4.5:1 on every light surface",
    (text) => {
      for (const surface of ["--ground", "--panel", "--panel-2", "--surface", "--surface-alt", "--surface-2", "--row-hover"]) {
        expect(contrast(hex(text), hex(surface)), text + " on " + surface).toBeGreaterThanOrEqual(4.5);
      }
    },
  );

  it.each(["--yea", "--nay", "--accent", "--ink", "--live-text"])("the ground reads as text on %s", (fill) => {
    expect(contrast(hex("--ground"), hex(fill))).toBeGreaterThanOrEqual(4.5);
  });
});
