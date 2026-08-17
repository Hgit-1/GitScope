import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { foregroundForAccent } from "../App";

function luminance(hex: string): number {
  const values = [1, 3, 5].map((index) => Number.parseInt(hex.slice(index, index + 2), 16) / 255)
    .map((value) => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
  return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722;
}

function ratio(first: string, second: string): number {
  const [bright, dark] = [luminance(first), luminance(second)].sort((a, b) => b - a);
  return (bright + 0.05) / (dark + 0.05);
}

describe("theme contrast", () => {
  it("keeps all dark-mode text tokens above WCAG AA on background and solid surfaces", () => {
    const css = readFileSync(resolve(process.cwd(), "src/styles.css"), "utf8");
    const dark = css.match(/\.theme-dark\s*\{([^}]+)\}/)?.[1] || "";
    const token = (name: string) => dark.match(new RegExp(`--${name}:\\s*(#[0-9a-fA-F]{6})`))?.[1] || "";
    for (const foreground of [token("text"), token("text-soft"), token("text-muted")]) {
      expect(foreground).toMatch(/^#/);
      expect(ratio(foreground, token("bg"))).toBeGreaterThanOrEqual(4.5);
      expect(ratio(foreground, token("surface-solid"))).toBeGreaterThanOrEqual(4.5);
    }
  });

  it("chooses a readable foreground for both light and dark custom accents", () => {
    expect(ratio("#4ade80", foregroundForAccent("#4ade80"))).toBeGreaterThanOrEqual(4.5);
    expect(ratio("#17351f", foregroundForAccent("#17351f"))).toBeGreaterThanOrEqual(4.5);
  });
});
