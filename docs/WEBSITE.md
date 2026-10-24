# Website development

## Structure

One page, no framework, no build step. Everything the browser needs is served from the same origin.

| Path | Purpose |
|---|---|
| `index.html` | All content and metadata (title, description, canonical, Open Graph, JSON-LD, CSP `<meta>`) |
| `styles.css` | Design tokens (`:root`), fonts, layout and components |
| `script.js` | One enhancement: marks the nav link of the section in view with `aria-current`. The page works without it. |
| `favicon.svg` | Favicon and header mark |
| `robots.txt` | Allows all crawlers. There is no sitemap: a one-page site does not need one. |
| `assets/fonts/` | Self-hosted WOFF2 (Inter 400 and 600, JetBrains Mono 400, latin subset) and their SIL OFL licenses |
| `assets/og.png` | 1200×630 social preview, rendered from `design/og-card.html` |
| `design/` | Sources for generated assets. Not shipped in the image. |
| `tests/` | Dependency-free Node checks |

The Docker image ships exactly what `Dockerfile` copies: the root files above plus `assets/`. **A new file that is
not listed in the Dockerfile `COPY` lines is not deployed**; `tests/check-site.mjs` fails if the page references
a file the image does not ship.

## Local development

```bash
python -m http.server 8099       # serve the repository root
```

Paths in the page are root-relative (`/styles.css`), so open it through a server, not `file://`.
To regenerate the social image after editing `design/og-card.html`, render it at 1200×630 with any Chromium
(`--headless --window-size=1200,630 --screenshot=assets/og.png design/og-card.html`).

## Design tokens

All values live in `:root` in `styles.css`. Change a token, not the rule that uses it.

* **Colour**: `--bg`, `--surface`, `--rule` (hairlines), `--text`, `--text-muted`, `--accent` (links, primary button,
  focus ring), `--accent-on` (text on the accent). Dark only. Contrast ratios are asserted in `tests/check-site.mjs`.
* **Type**: Inter for text and headings, JetBrains Mono only for data (repository names, stack, URLs). Scale
  `--step--1` to `--step-3`; the heading size is fluid. `Inter Fallback` is a metric-matched Arial so the font swap
  does not shift the layout.
* **Space**: an 8 px scale, `--space-1` to `--space-7`. Container `--container` (65rem, 72rem from 90rem);
  reading width `--measure` (66ch).
* **Breakpoints**: 40rem (header and rows become horizontal) and 64rem (project rows get a side column).
  Everything below is a single column.
* **Motion**: only colour transitions and smooth anchor scrolling, the latter inside
  `prefers-reduced-motion: no-preference`. Nothing is hidden until a script runs.

## Editing content

* **Copy** is plain HTML in `index.html`. Keep statements verifiable: no clients, testimonials, metrics, years in
  business or certifications unless they are true and can be shown.
* **Add a project**: copy an `<li>` inside `ol.work`, give the `<article>` and its `<h3>` a new `id`/`aria-labelledby`
  pair, and fill in the description, three evidence-based points and the Stack, Status and Source rows. Read the
  repository first and only use what it states. Only feature **public** repositories; private repositories need
  explicit approval before they appear on the site.
* **Screenshots**: only real captures of the project, cropped but not edited, stored under `assets/`, with `width`,
  `height` and descriptive `alt`. A project without a real visual gets none rather than a mock-up.
* **Selected work vs. more repositories**: three projects are featured; other public repositories belong in the
  short "More public repositories" list. Choose featured projects on tests, CI, licensing, release hygiene and
  verified behaviour, not on commit count or recency.
* **Contact details** appear in the hero button, the contact section and the JSON-LD block. Change all three.
* Update `<title>`, `description`, `og:*` and the JSON-LD together; `tests/check-site.mjs` checks they agree.

## Accessibility conventions

* Landmarks: `header`, `nav`, `main`, `footer`; every `<section>` is named by its heading with `aria-labelledby`;
  one `h1`, no skipped levels.
* A skip link is the first tab stop. Focus is always visible (`:focus-visible`, 2 px accent outline).
* Interactive targets are at least 44 px high (`--target`); links inside sentences are exempt.
* Links keep their visible text as their accessible name (no `aria-label` overrides).
* Status is always written out ("Released, v1.6.0"); colour is never the only signal.
* The navigation is four visible links, so there is no menu script to fail.

## Content Security Policy

The page carries a strict CSP `<meta>` tag (`default-src 'none'` plus 'self' for scripts, styles, fonts, images and
fetches). There are no inline scripts, styles or event handlers, so the same policy can later be sent as a header by
the reverse proxy. Do not add third-party hosts without extending the policy deliberately. `connect-src 'self'`
is there because Lighthouse downloads `robots.txt` with an in-page fetch; without it the audit fails even though the
file is served correctly. Tools that inject scripts into the page are still blocked by `script-src`, so run them
through the DevTools protocol (as the checks described above do) instead of adding a script tag.

## Testing

```bash
node tests/check-site.mjs     # no dependencies; run before every commit
node tests/check-links.mjs    # external links; some sites refuse bots and report BLOCKED
```

Browser-level checks (axe-core, Lighthouse, keyboard and viewport tests) are run with throwaway tooling kept
outside the repository, so the site has no `package.json`. Reproduce them with `puppeteer-core`, `axe-core` and
`lighthouse` against a local server. Inject axe through the DevTools protocol (`page.evaluate(axeSource)`), not
with a script tag, because the CSP blocks injected scripts.

## Production boundary

Editing the site never changes production, and neither does pushing to `main`. Publication is a separate, deliberate
step: run the Deploy workflow and, after the build, approve the Production deployment, as described in
[DEPLOYMENT.md](DEPLOYMENT.md) (GitHub Actions -> GHCR -> Oracle). Changes to `Dockerfile`, `deploy/` and `.github/`
are infrastructure changes and are reviewed separately from content changes.
