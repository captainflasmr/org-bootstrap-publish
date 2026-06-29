# org-bootstrap-publish — Agent Notes

Single-file Emacs Lisp package (`org-bootstrap-publish.el`, ~2400 lines) that generates a Bootstrap 5 static site from Org-mode files. Includes built-in site-profile infrastructure. No build system, no external dependencies, no test suite.

## Loading / verifying

Drop the directory on `load-path` and require:

```elisp
(add-to-list 'load-path "~/source/repos/org-bootstrap-publish")
(require 'org-bootstrap-publish)
```

Quick smoke-test from shell:

```bash
emacs --batch -L . -l org-bootstrap-publish --eval "(message \"loaded ok\")"
```

## Project structure

- `org-bootstrap-publish.el` — sole code file; everything lives here
- `assets/style.css` — stylesheet copied into every build as `public/assets/style.css`
- `workflows/pages.yml` — **template for consumer repos**, not a CI workflow run on this repo
- `README.org`, `TRANSITION.org`, `CHANGELOG.org` — docs

## Key commands

| Command | What it does |
|---------|--------------|
| `M-x org-bootstrap-publish` | Synchronous full build |
| `M-x org-bootstrap-publish-async` | Async build in child `emacs --batch -Q` |
| `M-x org-bootstrap-publish-serve` | Async build + `python3 -m http.server` + live-reload on save |
| `M-x org-bootstrap-publish-rebuild-current-post` | Fast incremental rebuild (skips tag pages & feeds) |
| `M-x org-bootstrap-publish-publish` | Build locally, deploy to Cloudflare Pages via `wrangler` |
| `M-x org-bootstrap-publish-publish-all` | Build + deploy every site in `org-bootstrap-publish-sites` |
| `M-x org-bootstrap-publish-serve-site` | Stop server, switch to named site, serve it |
| `M-x org-bootstrap-publish-use-site` | Switch active defcustoms to a named site profile |
| `M-x org-bootstrap-publish-switch` | Pick a site from `org-bootstrap-publish-sites` and activate it |
| `M-x org-bootstrap-publish-menu` | Transient menu: switch site, publish, serve, build, clean, flush |
| `M-x org-bootstrap-publish-clean-site` | Deploy blank placeholder to wipe a Cloudflare site |
| `M-x org-bootstrap-publish-flush-site` | Purge Cloudflare cache for a named site |

## Site profiles

The package provides infrastructure for switching between named site configurations:

- **`org-bootstrap-publish-sites`** — alist of `(NAME . PROFILE)` where each PROFILE is an alist of `(SYMBOL . VALUE)` pairs for any `org-bootstrap-publish-*` defcustom. Consumers populate this; the package defaults it to nil.
- **`org-bootstrap-publish-use-site`** — resets every obp defcustom to its default, then applies a profile. The list of managed variables is auto-derived from all `org-bootstrap-publish-*` defcustoms via `org-bootstrap-publish--managed-vars` — no manual list to maintain.
- **`org-bootstrap-publish-switch`** — interactively pick and activate a site profile from the list.
- **`org-bootstrap-publish-serve-site`** — stop server, switch profile, serve.
- **`org-bootstrap-publish-publish-all`** — sequential build+deploy of all sites with a `cloudflare-project` entry.
- **`org-bootstrap-publish-clean-site`** / **`org-bootstrap-publish-flush-site`** — deploy a blank page or purge Cloudflare cache for a named site.

Consumer files (e.g. `obp-sites.el`) need only: custom shortcode functions, the site profile data fed into `org-bootstrap-publish-sites`, and any transient menus / keybindings. All profile-switching, publishing, and Cloudflare logic lives in the package.

## Important gotchas

- **Async builds do NOT load user init.** Custom shortcode handlers defined outside this package will be skipped in async / batch builds. Use the synchronous `M-x org-bootstrap-publish` when developing custom shortcodes.
- **Cache invalidation:** The cross-build HTML cache (`org-bootstrap-publish-cache-dir`) keys on a hash of the Org body. If you change the renderer (HTML templates, Bootstrap classes, shortcode rewriter, etc.), bump `org-bootstrap-publish--cache-version` in the source so stale cached entries are invalidated.
- **Multi-source precedence:** When both `org-bootstrap-publish-source-file` and `org-bootstrap-publish-source-files` are set, the plural variable wins.
- **Save-hook fast mode:** The rebuild-on-save hook skips per-tag HTML, per-tag feeds, and the site feed to stay fast (~0.5 s). These refresh on the next full build.
- **No test suite.** There are no unit tests, ERT tests, or integration tests in this repo. Verification is manual: build a site and inspect the output.

## Style / conventions

- Standard Emacs Lisp conventions; `lexical-binding: t` throughout.
- Uses `cl-lib`, `org-element`, `ox-html`, `subr-x`.
- Private helpers use the `--` prefix (e.g., `org-bootstrap-publish--org->html`).
- HTML templates are string-concatenation inside elisp, not external template files.

## Deploy workflow template

`workflows/pages.yml` is meant to be copied into a *site* repo's `.github/workflows/`, not executed here. It checks out this package as a submodule-like path (`.obp`), runs Emacs in batch mode to build the site, then deploys to Cloudflare Pages via `wrangler`. Set `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` as repository secrets.
