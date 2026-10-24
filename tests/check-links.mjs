// Verifies every external URL in index.html resolves. Needs network; run on demand:
//   node tests/check-links.mjs
// Sites that refuse automated requests (HTTP 403/429) report as "blocked", not as failures.
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const html = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "index.html"), "utf8");
const urls = [...new Set([...html.matchAll(/\bhref="(https:\/\/[^"]+)"/g)].map((m) => m[1]))].filter((u) => !u.includes("weeksitsolutions.com/#"));
let failed = 0;
for (const url of urls) {
  try {
    const res = await fetch(url, { redirect: "follow", headers: { "user-agent": "link-check" }, signal: AbortSignal.timeout(15000) });
    const blocked = [403, 429].includes(res.status);
    console.log(`${res.ok ? "OK     " : blocked ? "BLOCKED" : "FAIL   "} ${res.status} ${url}${res.url !== url ? ` -> ${res.url}` : ""}`);
    if (!res.ok && !blocked) failed++;
  } catch (err) {
    console.log(`FAIL    ${url} (${err.cause?.code ?? err.message})`);
    failed++;
  }
}
process.exit(failed ? 1 : 0);
