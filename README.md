# Weeks IT Solutions website

Source for <https://weeksitsolutions.com>: a single static page (HTML, CSS and a small vanilla JavaScript file)
served by nginx in a container.

```bash
python -m http.server 8099      # then open http://127.0.0.1:8099/
node tests/check-site.mjs       # static checks: references, metadata, CSP-readiness, contrast
node tests/check-links.mjs      # external links (needs network)
```

Site structure, design tokens, content editing and the production boundary are documented in
[docs/WEBSITE.md](docs/WEBSITE.md).

Production releases go **GitHub Actions -> GHCR -> Oracle** through the manually triggered, approval-gated Deploy
workflow. Nothing deploys on push, and nothing should be built or copied onto the server by hand. The procedure,
rollback and host layout are in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).
