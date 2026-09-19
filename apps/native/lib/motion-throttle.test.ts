import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";

const root = fileURLToPath(new URL("../", import.meta.url));

// Every infinitely-running animation must quantize its timing with steps()
// (or step-end). A value that only changes a few times per second avoids a
// full-window compositor commit on every animation frame; unquantized
// infinite animations hold several percent of CPU for as long as they are
// mounted. See #1037 and the policy comment in app/motion.css.
function* scan(dir: string): Generator<string> {
  for (const entry of readdirSync(dir)) {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) yield* scan(path);
    else if (/\.(tsx|css)$/.test(entry) && !entry.includes(".test.")) yield path;
  }
}

function cssBody(path: string): string {
  // Strip comments so prose mentioning the policy does not read as a declaration.
  return readFileSync(path, "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
}

function unquantized(line: string): boolean {
  return /\binfinite\b/.test(line) && !/\bsteps?\(/.test(line) && !/\bstep-(?:start|end)\b/.test(line);
}

describe("motion throttle", () => {
  it("quantizes every infinite animation", () => {
    const offenders: string[] = [];
    for (const dir of ["components", "app"]) {
      for (const path of scan(join(root, dir))) {
        const source = path.endsWith(".css") ? cssBody(path) : readFileSync(path, "utf8");
        source.split("\n").forEach((line, i) => {
          if (unquantized(line)) {
            offenders.push(`${path}:${i + 1}: ${line.trim()}`);
          }
        });
      }
    }
    assert.deepEqual(offenders, []);
  });

  it("keeps the global prefers-reduced-motion override", () => {
    const motion = readFileSync(join(root, "app", "motion.css"), "utf8");
    assert.match(motion, /@media \(prefers-reduced-motion: reduce\)/);
    assert.match(motion, /animation-iteration-count: 1 !important/);
  });
});
