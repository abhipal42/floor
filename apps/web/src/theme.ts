// The reader's theme: System, Light or Dark. Pure, so it is tested here; main.ts applies it, and the
// inline script in index.html repeats `resolveTheme` before the first paint (theme.test.ts checks
// that the two agree).

export type ThemeChoice = "system" | "light" | "dark";
export type Theme = "light" | "dark";

/** The localStorage key. Changing it resets everyone's choice. */
export const THEME_KEY = "floor-theme";

/** The browser chrome colour for each theme: the page ground. */
export const THEME_COLOR: Record<Theme, string> = { light: "#ECEFEE", dark: "#07080A" };

const ORDER: ThemeChoice[] = ["system", "light", "dark"];

/** A stored value, or System for anything missing or unknown. */
export function parseChoice(stored: string | null | undefined): ThemeChoice {
  return stored === "light" || stored === "dark" ? stored : "system";
}

/** The theme to draw: the choice, or the system's when the choice is System. */
export function resolveTheme(choice: ThemeChoice, systemPrefersLight: boolean): Theme {
  if (choice === "system") return systemPrefersLight ? "light" : "dark";
  return choice;
}

/** What one click on the button switches to: System → Light → Dark → System. */
export function nextChoice(choice: ThemeChoice): ThemeChoice {
  return ORDER[(ORDER.indexOf(choice) + 1) % ORDER.length]!;
}

const NAME: Record<ThemeChoice, string> = { system: "System", light: "Light", dark: "Dark" };

/** The button's label: the current choice (and, for System, what it resolved to) and the next. */
export function themeLabel(choice: ThemeChoice, shown: Theme): string {
  const now = choice === "system" ? "System (" + NAME[shown].toLowerCase() + ")" : NAME[choice];
  return "Theme: " + now + ". Switch to " + NAME[nextChoice(choice)];
}
