// Static checks for the website. No dependencies: `node tests/check-site.mjs` from the repo root.
// Verifies what can be proven from source: references resolve, the Docker image ships every referenced
// file, metadata is consistent, nothing blocks a strict CSP, and the colour tokens meet WCAG AA.
import { existsSync, readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (p) => readFileSync(join(root, p), "utf8");
const html = read("index.html");
const css = read("styles.css");
const docker = read("Dockerfile");
const CANONICAL = "https://weeksitsolutions.com/";

let failed = 0;
const check = (name, ok, detail = "") => {
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${ok || !detail ? "" : `\n      ${detail}`}`);
  if (!ok) failed++;
};

// ---- references -------------------------------------------------------------------------------
const attr = (re) => [...html.matchAll(re)].map((m) => m[1]);
const localRefs = [...new Set([...attr(/\b(?:href|src)="(\/[^"#?]*)"/g), ...attr(/url\("(\/[^"#?]*)"\)/g), ...[...css.matchAll(/url\("(\/[^"#?]*)"\)/g)].map((m) => m[1])])]
  .filter((p) => p !== "/");
const missing = localRefs.filter((p) => !existsSync(join(root, p)));
check(`all ${localRefs.length} local references exist`, missing.length === 0, missing.join(", "));

// Files the image ships: parse COPY instructions that target /usr/share/nginx/html.
const shipped = [];
for (const line of docker.split("\n")) {
  const m = line.match(/^COPY\s+(.+?)\s+\/usr\/share\/nginx\/html(\/\S*)?\s*$/);
  if (!m) continue;
  const dest = m[2] ?? "/";
  for (const src of m[1].split(/\s+/)) shipped.push(src.endsWith("/") ? { dir: src, dest } : { file: src, dest });
}
const isShipped = (p) =>
  shipped.some((s) => (s.file ? `/${s.file}` === p : p.startsWith(`${s.dest}`.replace(/\/$/, "") + "/") && p.slice(s.dest.length).length > 0));
const notShipped = localRefs.filter((p) => !isShipped(p));
check("the Dockerfile ships every referenced file", notShipped.length === 0, notShipped.join(", "));
check("robots.txt is shipped", isShipped("/robots.txt"));

const ids = attr(/\bid="([^"]+)"/g);
check("ids are unique", new Set(ids).size === ids.length);
const badAnchors = attr(/\bhref="#([^"]+)"/g).filter((id) => !ids.includes(id));
check("in-page links resolve", badAnchors.length === 0, badAnchors.join(", "));

// ---- metadata ---------------------------------------------------------------------------------
const meta = (name, key = "name") => html.match(new RegExp(`<meta\\s+${key}="${name}"\\s+content="([^"]*)"`))?.[1];
const title = html.match(/<title>([^<]+)<\/title>/)?.[1] ?? "";
check("title names the company", /Weeks IT Solutions/.test(title) && title.length <= 70, title);
const desc = meta("description") ?? "";
check("meta description is 70-170 characters", desc.length >= 70 && desc.length <= 170, `${desc.length}`);
check("canonical is the apex https URL", html.includes(`<link rel="canonical" href="${CANONICAL}"`));
check("og:url matches canonical", meta("og:url", "property") === CANONICAL);
for (const p of ["og:title", "og:description", "og:image", "og:image:alt", "og:type", "og:site_name"])
  check(`${p} present`, !!meta(p, "property"));
check("twitter:card present", meta("twitter:card") === "summary_large_image");
const ogImage = meta("og:image", "property") ?? "";
check("og:image is an absolute apex URL", ogImage.startsWith("https://weeksitsolutions.com/"));
const ogPath = ogImage.replace("https://weeksitsolutions.com", "");
if (existsSync(join(root, ogPath))) {
  const png = readFileSync(join(root, ogPath));
  check("og image is a 1200x630 PNG", png.readUInt32BE(16) === 1200 && png.readUInt32BE(20) === 630);
} else check("og image exists", false, ogPath);
check("no hostname other than the apex in canonical metadata", !/https?:\/\/www\.weeksitsolutions\.com/.test(html));
let ld;
try {
  ld = JSON.parse(html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1]);
} catch {
  ld = null;
}
check("JSON-LD parses and only states verifiable facts", ld?.["@type"] === "Organization" && ld.url === CANONICAL && ld.email === "noah@weeksitsolutions.com");
check("html lang and viewport set", /<html lang="en">/.test(html) && /name="viewport"/.test(html));

// ---- structure and accessibility --------------------------------------------------------------
check("exactly one h1", (html.match(/<h1[\s>]/g) ?? []).length === 1);
const levels = [...html.matchAll(/<h([1-6])[\s>]/g)].map((m) => Number(m[1]));
check("heading levels never skip", levels.every((l, i) => i === 0 || l <= levels[i - 1] + 1), levels.join(""));
check("skip link targets main", /class="skip-link" href="#main"/.test(html) && /<main id="main">/.test(html));
check("landmarks: header, nav, main, footer", ["<header", "<nav", "<main", "<footer"].every((t) => html.includes(t)));
check("every img has alt", [...html.matchAll(/<img\b[^>]*>/g)].every((m) => /\balt="/.test(m[0])));
check("exactly three featured projects, each linking to a github.com/nullps1 repository", (html.match(/<article class="project"/g) ?? []).length === 3 && (html.match(/<dd><a href="https:\/\/github\.com\/nullps1\/[A-Za-z0-9._-]+" rel="noopener noreferrer">github\.com\/nullps1\//g) ?? []).length === 3);
check("every img declares width and height (no layout shift)", [...html.matchAll(/<img\b[^>]*>/g)].every((m) => /\bwidth="\d+"/.test(m[0]) && /\bheight="\d+"/.test(m[0])));
check("no aria-label that could contradict visible link text", !/<a\b[^>]*aria-label=/.test(html));
check("sections are named by their headings", [...html.matchAll(/<section\b[^>]*>/g)].every((m) => /aria-labelledby=/.test(m[0])));
const labelled = [...html.matchAll(/aria-labelledby="([^"]+)"/g)].map((m) => m[1]);
check("aria-labelledby targets exist", labelled.every((id) => ids.includes(id)));

// ---- CSP friendliness and dependencies ----------------------------------------------------------
check("no inline event handlers", !/\son[a-z]+="/i.test(html));
check("no inline style attributes", !/\sstyle="/i.test(html));
check("no inline <style> or executable inline <script>", !/<style\b/i.test(html) && !/<script(?![^>]*(?:src=|type="application\/ld\+json"))[^>]*>/i.test(html));
const external = [...html.matchAll(/\b(?:src|href)="(https?:\/\/[^"]+)"/g)].map((m) => m[1]);
const nonLinkExternal = [...html.matchAll(/<(?:script|link|img|iframe)\b[^>]*\b(?:src|href)="(https?:\/\/[^"]+)"/g)]
  .map((m) => m[1])
  .filter((u) => !/rel="canonical"/.test(html.slice(html.indexOf(u) - 60, html.indexOf(u))));
check("no third-party scripts, styles, fonts or images", nonLinkExternal.filter((u) => u !== CANONICAL).length === 0, nonLinkExternal.join(", "));
check("CSP meta tag present and strict", /Content-Security-Policy[\s\S]*default-src 'none'[\s\S]*script-src 'self'/.test(html));
check("every external anchor has rel noopener", [...html.matchAll(/<a\b[^>]*href="https?:[^>]*>/g)].every((m) => /rel="[^"]*noopener/.test(m[0])));
console.log(`      ${external.length} external URLs in the page (verify with: node tests/check-links.mjs)`);

// ---- colour tokens ----------------------------------------------------------------------------
const token = (n) => css.match(new RegExp(`--${n}:\\s*(#[0-9a-fA-F]{6})`))?.[1];
const lum = (hex) => {
  const c = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
};
const ratio = (a, b) => {
  const [x, y] = [lum(a), lum(b)].sort((m, n) => n - m);
  return (x + 0.05) / (y + 0.05);
};
const pairs = [
  ["text", "bg", 4.5], ["text-muted", "bg", 4.5], ["text-muted", "surface", 4.5], ["text", "surface", 4.5],
  ["accent", "bg", 4.5], ["accent", "surface", 4.5], ["accent-on", "accent", 4.5], ["focus", "bg", 3],
];
for (const [fg, bg, min] of pairs) {
  const r = ratio(token(fg), token(bg));
  check(`contrast ${fg} on ${bg}: ${r.toFixed(2)}:1 (needs ${min}:1)`, r >= min);
}

check("stylesheet honours prefers-reduced-motion", /prefers-reduced-motion/.test(css));
check("stylesheet defines a visible focus style", /:focus-visible/.test(css));

console.log(failed ? `\n${failed} check(s) failed` : "\nall checks passed");
process.exit(failed ? 1 : 0);
