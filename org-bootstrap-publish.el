;;; org-bootstrap-publish.el --- Generate a Bootstrap 5 site from a single Org file -*- lexical-binding: t; -*-

;; Copyright (C) 2026 James Dyer

;; Author: James Dyer <captainflasmr@gmail.com>
;; Version: 0.4.1
;; Package-Requires: ((emacs "27.1"))
;; Keywords: org, html, hypermedia
;; URL: https://github.com/captainflasmr/org-bootstrap-publish

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Point `org-bootstrap-publish-source-file' at a single Org file where
;; each top-level heading is a post, run M-x org-bootstrap-publish, and
;; get a ready-to-upload `public/' folder.
;;
;; Output uses Bootstrap 5 with a hyde-style left sidebar and includes:
;;   - Index page with post cards, newest first.
;;   - One HTML page per post (rendered via `ox-html').
;;   - One HTML page per tag, plus an overall tags index.
;;   - Atom feed at index.xml (also mirrored to feed.xml).
;;   - Custom stylesheet copied into public/assets/.
;;
;; Recognised heading properties (compatible with ox-hugo):
;;   EXPORT_FILE_NAME                -> post slug ("index" → URL is /<section>/)
;;   EXPORT_HUGO_SECTION             -> post section (used as URL prefix)
;;   EXPORT_HUGO_LASTMOD             -> post date
;;   EXPORT_HUGO_TYPE                -> "gallery" renders a masonry grid of
;;                                      images read from static/<section>/
;;   EXPORT_HUGO_CUSTOM_FRONT_MATTER -> :thumbnail /path/to/image.jpg
;;
;; The `noexport' tag skips a heading.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'org)
(require 'org-element)
(require 'ox-html)
(require 'htmlize nil t)
(require 'subr-x)
(require 'xml)

;;;; Customization

(defgroup org-bootstrap-publish nil
  "Generate a Bootstrap 5 site from a single Org file."
  :group 'org
  :prefix "org-bootstrap-publish-")

(defcustom org-bootstrap-publish-source-file nil
  "Org file to publish.  Each top-level heading becomes a post.
For multi-source aggregator sites, set
`org-bootstrap-publish-source-files' to a list of files instead;
that takes precedence over this setting."
  :type '(choice (const :tag "Unset" nil) file))

(defcustom org-bootstrap-publish-source-files nil
  "List of Org files to aggregate into a single site.
When non-nil, every file is parsed and the combined post list is
sorted newest-first.  Useful for umbrella sites that pull together
content from several per-topic Org sources sitting in one directory.
Takes precedence over `org-bootstrap-publish-source-file' when set;
the single-file customisation continues to work for single-source
sites."
  :type '(choice (const :tag "Unset" nil)
                 (repeat file)))

(defcustom org-bootstrap-publish-output-dir
  (expand-file-name "public" default-directory)
  "Directory into which HTML is written."
  :type 'directory)

(defcustom org-bootstrap-publish-cache-dir
  (expand-file-name "org-bootstrap-publish/"
                    (or (getenv "XDG_CACHE_HOME") "~/.cache"))
  "Base directory for cross-build `ox-html' output cache.
Each output dir gets its own subdirectory inside this path,
keyed by a hash of the output dir's absolute path, so multiple
sites publishing through the same Emacs do not collide.

When non-nil, every unique post body is rendered through ox-html
once and cached on disk; subsequent builds reuse the cached HTML
for unchanged bodies, which is the dominant cost of a full
rebuild.  Stale entries are swept at the end of each build.

Set to nil to disable caching (renders every post from scratch
on every build).  Located outside the output dir so cache files
are not deployed."
  :type '(choice directory (const :tag "Disabled" nil)))

(defcustom org-bootstrap-publish-site-title "My Site"
  "Top-of-sidebar site title."
  :type 'string)

(defcustom org-bootstrap-publish-site-tagline ""
  "Short sub-title shown under the site title."
  :type 'string)

(defcustom org-bootstrap-publish-site-url "https://example.com/"
  "Canonical public URL, used in the Atom feed.  Include trailing slash."
  :type 'string)

(defcustom org-bootstrap-publish-site-path "/"
  "URL path prefix under which the site is served.
Use \"/\" for domain-root deployment (Cloudflare Pages, Netlify,
custom domain).  Use \"/repo-name/\" for subpath deployment.
Must start and end with a slash."
  :type 'string)

(defcustom org-bootstrap-publish-author (or user-full-name "Anonymous")
  "Author name used in templates and the feed."
  :type 'string)

(defcustom org-bootstrap-publish-posts-per-page 24
  "Maximum number of posts on the index page."
  :type 'integer)

(defcustom org-bootstrap-publish-preview-limit nil
  "When non-nil, only the N most-recent posts are written during a preview serve.
Full builds (`org-bootstrap-publish-publish') always ignore this;
only `org-bootstrap-publish-serve-preview' and the synchronous
preview path honour it.  Useful for fast local iteration when you
only need to see the latest posts."
  :type '(choice (const :tag "No limit" nil) (integer :tag "Number of posts")))

(defcustom org-bootstrap-publish-exclude-tags '("noexport")
  "Headings carrying any of these tags are skipped."
  :type '(repeat string))

(defcustom org-bootstrap-publish-menu-tags nil
  "Deprecated.  Use `org-bootstrap-publish-menu-links' instead.
Entries here are translated to `(LABEL \"/tags/TAG/\" :style list)'
form and merged into the sidebar after `-menu-links'.  Kept for
backwards compatibility — new configs should put everything in
`-menu-links' and use `:style' to drive the destination's layout."
  :type '(alist :key-type (string :tag "Label")
                :value-type (string :tag "Tag")))

(defcustom org-bootstrap-publish-menu-links nil
  "Sidebar nav entries.  Each entry is one of:

  (LABEL . URL)               ; short form
  (LABEL URL PROP VAL ...)    ; long form, plist tail

Each entry adds a link to URL between the main nav and the RSS
link.  URLs pass through verbatim, so they can be section
landings (`/blog/'), tag pages (`/tags/emacs/'), specific posts
(`/blog/about/'), or external addresses.  Alist order is
preserved.

Recognised plist keys (long form only):

  :style cards   ; render the destination as Bootstrap cards
  :style list    ; render the destination as a flat bullet list

`:style' takes effect when URL points to a generated section
landing or tag page; post URLs and external links ignore it.
Section landings default to `cards', tag pages default to `list',
matching the historical behaviour of each.

Example:

  (setq org-bootstrap-publish-menu-links
        \\='((\"Photos\" \"/photos/\"     :style cards)
          (\"Blog\"   \"/blog/\"       :style list)
          (\"Emacs\"  \"/tags/emacs/\" :style cards)
          (\"About\"  . \"/blog/about-me/\")))"
  :type '(repeat sexp))

(defcustom org-bootstrap-publish-publish-todo-states '("DONE")
  "TODO-keyword states whose headings are published.
Headings with any other TODO keyword are skipped (treated as drafts).
Headings with no TODO keyword are always published.  Set to nil to
publish every heading regardless of state."
  :type '(choice (const :tag "All states" nil)
                 (repeat string)))

(defcustom org-bootstrap-publish-static-dirs '("static")
  "Directories, relative to the source file, copied verbatim into the output."
  :type '(repeat string))

(defcustom org-bootstrap-publish-layout 'sidebar
  "Page layout style.
`sidebar' (default) puts the navigation in a vertical bar on the
left of every page.  `rightbar' is the same vertical bar mirrored
to the right edge.  `topbar' lays the same elements across the
top instead — site title, tagline, search box, theme toggle and
nav links sit in a horizontal strip above the content area, and
the copyright footer is hidden.  Implemented entirely via a
`site-layout-<name>' class on the outer wrapper, so user CSS can
register additional layouts without touching the generator."
  :type '(choice (const :tag "Sidebar (left)" sidebar)
                 (const :tag "Sidebar (right)" rightbar)
                 (const :tag "Topbar (above)" topbar)))

(defcustom org-bootstrap-publish-disqus-shortname nil
  "Disqus shortname for the comment thread embedded under each post.
nil disables the embed; any non-empty string enables it.  The
injected script skips `localhost'/`127.0.0.1' so the dev server
doesn't create stray threads under your account."
  :type '(choice (const :tag "Disabled" nil) string))

(defcustom org-bootstrap-publish-theme-overrides nil
  "Alist of (PROPERTY . VALUE) overriding CSS custom properties for the
default (`:root') theme only.  PROPERTY is a CSS variable name with or
without the leading `--' (e.g. `obp-sidebar-bg' or `--obp-sidebar-bg').
VALUE is any CSS value as a string (e.g. \"#123456\").  Overrides are
emitted against `:root' alone so that `[data-obp-theme=\"dark\"]' and
`[data-obp-theme=\"emacs\"]' can supply their own values via the
stylesheet -- useful for branding the default/light appearance while
letting alternative themes keep distinct colours."
  :type '(alist :key-type string :value-type string))

(defcustom org-bootstrap-publish-background-image nil
  "Optional URL or path for a `body' background image.
nil means no override -- the active theme's `--obp-body-bg' colour
shows through.  Any non-empty string is dropped straight into a
`background-image: url(...)' rule with `cover'/`fixed' sizing;
both site-relative paths (e.g. \"/assets/bg.jpg\") and absolute
URLs work."
  :type '(choice (const :tag "Disabled" nil) string))

(defcustom org-bootstrap-publish-background-blur nil
  "Optional CSS blur radius (in `px') applied to the body background image.
nil or 0 leaves the image rendered crisply.  A positive integer
adds `filter: blur(Npx)' to the fixed `body::before' overlay that
carries the image, so the blur hits only the image -- text and
cards in the content area stay sharp.  Useful for taming busy
banner photos behind the post column."
  :type '(choice (const :tag "No blur" nil) integer))

(defcustom org-bootstrap-publish-background-opacity nil
  "Optional opacity (0.0 -- 1.0) applied to the body background image.
nil means fully opaque (1.0) -- the image is drawn at full
strength.  Lower values fade the image toward the active theme's
`--obp-body-bg' colour, which sits behind it; e.g. 0.2 gives a
very subtle wash, 0.5 a clearly visible but muted image.  Stacks
with `org-bootstrap-publish-background-blur'.  Implemented as
`opacity' on the same `body::before' overlay, so foreground text
and cards are unaffected."
  :type '(choice (const :tag "Fully opaque" nil) number))

(defcustom org-bootstrap-publish-shortcodes nil
  "Alist of (NAME . FUNCTION) registering custom Hugo-style shortcodes.
NAME is a symbol matching the shortcode name in `{{< NAME ... >}}'.
FUNCTION receives a single plist argument carrying the parsed
`key=\"value\"' pairs (under keyword keys, e.g. `:src \"foo\"'),
or nil for argless shortcodes, and returns a string of raw HTML.
The result is wrapped in a `#+begin_export html' block before
ox-html runs, so it survives untouched into the final page.

Built-in shortcodes (`youtube', `video', `figure') run first; this
hook fires for any unrecognised name found anywhere in the body,
with or without a surrounding `#+begin_export md' wrapper.

For async and publish builds, FUNCTION must be a named function
symbol — defined in a file listed in
`org-bootstrap-publish-async-init-files' — because the handler is
replayed into a child `emacs --batch' process by name.  Anonymous
lambdas may not survive that transfer."
  :type '(alist :key-type symbol :value-type function))

(defcustom org-bootstrap-publish-bootstrap-css
  "https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css"
  "URL or relative path to Bootstrap 5 CSS."
  :type 'string)

(defcustom org-bootstrap-publish-bootstrap-js
  "https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js"
  "URL or relative path to Bootstrap 5 JS."
  :type 'string)

(defcustom org-bootstrap-publish-highlight-css
  "https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/styles/github-dark.min.css"
  "Optional URL for a highlight.js theme, or nil to disable."
  :type '(choice (const :tag "Disable" nil) string))

(defcustom org-bootstrap-publish-highlight-js
  "https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/highlight.min.js"
  "Optional URL for the highlight.js library, or nil to disable."
  :type '(choice (const :tag "Disable" nil) string))

(defcustom org-bootstrap-publish-htmlize-output-type 'inline-css
  "Output type for htmlize when exporting source blocks.
If nil, source blocks are exported as plain text inside <pre> tags
\(default behaviour), and you can rely on
`org-bootstrap-publish-highlight-js' for client-side highlighting.
If \\='inline-css, syntax highlighting is added as inline HTML styles.
This is useful for RSS readers.
If \\='css, styling is added via CSS classes."
  :type '(choice (const :tag "No htmlize (plain text)" nil)
                 (const :tag "Inline CSS" inline-css)
                 (const :tag "External CSS" css)))

(defcustom org-bootstrap-publish-cloudflare-project nil
  "Cloudflare Pages project name passed to `wrangler pages deploy'.
When set, `org-bootstrap-publish-publish' deploys the built site
to Cloudflare Pages via the wrangler CLI instead of pushing to a
git remote."
  :type '(choice (const :tag "Unset" nil) string))

(defcustom org-bootstrap-publish-cloudflare-branch "production"
  "Cloudflare Pages branch passed to `wrangler pages deploy'.
Defaults to \"production\" which maps to the production deployment."
  :type 'string)

(defcustom org-bootstrap-publish-wrangler-executable "wrangler"
  "Path to the wrangler CLI used by `org-bootstrap-publish-publish'."
  :type 'string)

(defcustom org-bootstrap-publish-date-format "%B %-d, %Y %H:%M"
  "Format string used for displaying the human-readable date and time.
Defaults to showing the month, day, year, and time
\(e.g. \"April 21, 2026 15:30\")."
  :type 'string)

(defconst org-bootstrap-publish--source-dir
  (file-name-directory
   (or load-file-name buffer-file-name default-directory))
  "Directory this library was loaded from, captured at load time.
Used for the default of `org-bootstrap-publish-asset-file' so that
re-evaluating that default (e.g. when `org-bootstrap-publish-use-site'
resets customs to their standard values) stays stable instead of
re-resolving against whatever buffer happens to be current.")

(defcustom org-bootstrap-publish-asset-file
  (expand-file-name "assets/style.css" org-bootstrap-publish--source-dir)
  "Path to the stylesheet copied into the output as assets/style.css."
  :type 'file)

;;;; Utilities

(defun org-bootstrap-publish--escape (s)
  "HTML-escape S for use in text or attributes."
  (if (null s) ""
    (xml-escape-string (format "%s" s))))

(defun org-bootstrap-publish--slugify (s)
  "Return S lowercased with non-alphanumerics collapsed to single dashes."
  (let ((x (downcase (or s ""))))
    (setq x (replace-regexp-in-string "[^a-z0-9]+" "-" x))
    (replace-regexp-in-string "\\(^-+\\|-+$\\)" "" x)))

(defun org-bootstrap-publish--parse-time (stamp)
  "Parse STAMP like \"<2026-04-21 15:30>\" to an Emacs time value, or nil."
  (when (and (stringp stamp) (not (string-empty-p stamp)))
    (ignore-errors (org-time-string-to-time stamp))))

(defun org-bootstrap-publish--iso (time)
  "Format TIME as an ISO-8601 / RFC-3339 timestamp, or nil if TIME is nil."
  (when time (format-time-string "%Y-%m-%dT%H:%M:%S%z" time)))

(defun org-bootstrap-publish--human-date (time)
  "Format TIME per `org-bootstrap-publish-date-format', or nil if TIME is nil."
  (when time (format-time-string org-bootstrap-publish-date-format time)))

(defun org-bootstrap-publish--mkdir (dir)
  "Create DIR (and any missing parents) unless it already exists."
  (unless (file-directory-p dir) (make-directory dir t)))

(defun org-bootstrap-publish--write (path content)
  "Write CONTENT to PATH as UTF-8, creating parent directories."
  (org-bootstrap-publish--mkdir (file-name-directory path))
  (with-temp-file path
    (set-buffer-file-coding-system 'utf-8)
    (insert content)))

;;;; Parsing

(defun org-bootstrap-publish--heading-props (heading)
  "Return an alist of (KEY . VALUE) node-properties under org HEADING."
  (let (result)
    (org-element-map (org-element-contents heading) 'node-property
      (lambda (np)
        (push (cons (org-element-property :key np)
                    (org-element-property :value np))
              result)))
    (nreverse result)))

(defun org-bootstrap-publish--strip-drawer (body)
  "Remove a leading :PROPERTIES:...:END: drawer from BODY."
  (replace-regexp-in-string
   "\\`[ \t]*:PROPERTIES:\n\\(?:.*\n\\)*?[ \t]*:END:[ \t]*\n?"
   "" body))

(defun org-bootstrap-publish--thumbnail (props)
  "Extract a :thumbnail path from PROPS' custom front-matter, or nil.
Accepts the property written with or without Org's accumulating
`+' suffix (EXPORT_HUGO_CUSTOM_FRONT_MATTER or ...+)."
  (let ((cfm (or (cdr (assoc "EXPORT_HUGO_CUSTOM_FRONT_MATTER+" props))
                 (cdr (assoc "EXPORT_HUGO_CUSTOM_FRONT_MATTER" props)))))
    (when (and cfm (string-match ":thumbnail[[:space:]]+\\([^[:space:]]+\\)" cfm))
      (match-string 1 cfm))))

(defun org-bootstrap-publish--slug (title props)
  "Post slug from PROPS' EXPORT_FILE_NAME, else a slugified TITLE."
  (downcase
   (or (cdr (assoc "EXPORT_FILE_NAME" props))
       (org-bootstrap-publish--slugify title))))

(defun org-bootstrap-publish--summary (body-org)
  "Return the lead of BODY-ORG: text before `#+hugo: more' or the first blank line."
  (cond
   ((string-match "^#\\+hugo:[ \t]+more[ \t]*$" body-org)
    (substring body-org 0 (match-beginning 0)))
   ((string-match "\n[ \t]*\n" body-org)
    (substring body-org 0 (match-beginning 0)))
   (t body-org)))

(defun org-bootstrap-publish--parse-posts (file)
  "Return a list of post plists from FILE, newest first."
  (let (posts)
    (with-temp-buffer
      (insert-file-contents file)
      (let ((default-directory (file-name-directory file)))
        (org-mode)
        (let ((tree (org-element-parse-buffer)))
          (org-element-map tree 'headline
            (lambda (h)
              (when (and (= 1 (org-element-property :level h))
                         (not (cl-intersection
                               (org-element-property :tags h)
                               org-bootstrap-publish-exclude-tags
                               :test #'string=))
                         (let ((kw (org-element-property :todo-keyword h)))
                           (or (null org-bootstrap-publish-publish-todo-states)
                               (null kw)
                               (member kw org-bootstrap-publish-publish-todo-states))))
                (let* ((title (org-element-property :raw-value h))
                       (tags  (copy-sequence (org-element-property :tags h)))
                       (b (org-element-property :contents-begin h))
                       (e (org-element-property :contents-end h))
                       (raw (and b e (buffer-substring-no-properties b e)))
                       (body (org-bootstrap-publish--strip-drawer (or raw "")))
                       (props (org-bootstrap-publish--heading-props h))
                       (date  (org-bootstrap-publish--parse-time
                               (cdr (assoc "EXPORT_HUGO_LASTMOD" props))))
                       (slug  (org-bootstrap-publish--slug title props))
                       (section (or (cdr (assoc "EXPORT_HUGO_SECTION" props))
                                    "posts"))
                       (type    (cdr (assoc "EXPORT_HUGO_TYPE" props)))
                       (thumb (org-bootstrap-publish--thumbnail props))
                       (summary (org-bootstrap-publish--summary body)))
                  (push (list :title title
                              :tags tags
                              :date date
                              :slug slug
                              :section section
                              :type type
                              :thumbnail thumb
                              :body body
                              :summary summary)
                        posts))))))))
    (sort posts
          (lambda (a b)
            (let ((da (plist-get a :date))
                  (db (plist-get b :date)))
              (cond ((and da db) (time-less-p db da))
                    (da t)
                    (db nil)
                    (t nil)))))))

;;;; Org -> HTML

(defun org-bootstrap-publish--rewrite-static-src (html)
  "Prefix local static/ image and link paths with the site path.
Also rewrites `file://...path/static/X' URLs (which ox-html emits
for org links like `[[~/foo/static/bar.jpg]]') to site-path URLs,
so legacy absolute file: paths still resolve on the deployed site."
  (let ((sp (replace-regexp-in-string "\\\\" "\\\\\\\\"
                                      org-bootstrap-publish-site-path)))
    (setq html
          (replace-regexp-in-string
           "\\(src\\|href\\)=\"file://[^\"]*?/\\(static/[^\"]+\\)\""
           (concat "\\1=\"" sp "\\2\"")
           html))
    (replace-regexp-in-string
     "\\(src\\|href\\)=\"static/"
     (concat "\\1=\"" sp "static/")
     html)))

(defun org-bootstrap-publish--bootstrapify (html)
  "Add Bootstrap classes to common elements in HTML."
  (setq html
        (replace-regexp-in-string
         "<img\\([^>]*?\\)\\(/?\\)>"
         (lambda (m)
           (let* ((attrs (match-string 1 m))
                  (tail  (match-string 2 m))
                  ;; Don't add a second loading= if the tag already has one.
                  (lazy  (if (string-match-p "\\bloading=" attrs)
                             "" " loading=\"lazy\"")))
             (if (string-match-p "\\bclass=\"" attrs)
                 (format "<img%s%s%s>"
                         lazy
                         (replace-regexp-in-string
                          "\\bclass=\"\\([^\"]*\\)\""
                          "class=\"img-fluid rounded \\1\""
                          attrs)
                         tail)
               (format "<img%s class=\"img-fluid rounded\"%s%s>" lazy attrs tail))))
         html))
  (setq html
        (replace-regexp-in-string
         "<table\\b" "<table class=\"table table-striped\""
         html t t))
  (setq html
        (replace-regexp-in-string
         "<blockquote>"
         "<blockquote class=\"blockquote ps-3 border-start\">"
         html t t))
  (when (and org-bootstrap-publish-highlight-js
             (not (and org-bootstrap-publish-htmlize-output-type
                       (featurep 'htmlize))))
    (setq html
          (replace-regexp-in-string
           "<pre class=\"src src-\\([^\"]+\\)\">\\(\\(?:.\\|\n\\)*?\\)</pre>"
           (lambda (m)
             (let* ((lang (match-string 1 m))
                    (code (match-string 2 m))
                    (hljs (or (cdr (assoc lang
                                          '(("emacs-lisp" . "lisp")
                                            ("elisp"      . "lisp")
                                            ("common-lisp". "lisp")
                                            ("sh"         . "bash")
                                            ("shell"      . "bash"))))
                              lang)))
               (format "<pre><code class=\"language-%s\">%s</code></pre>"
                       hljs code)))
           html nil t)))
  (org-bootstrap-publish--rewrite-static-src html))

(defun org-bootstrap-publish--shortcode-static-url (src)
  "Map a Hugo-style /foo path to /<site-path>static/foo, leave others alone."
  (cond
   ((string-prefix-p "static/" src) (org-bootstrap-publish--url src))
   ((string-prefix-p "/" src)
    (concat (org-bootstrap-publish--url "static") src))
   (t src)))

(defun org-bootstrap-publish--parse-shortcode-args (s)
  "Parse `key=\"value\"' pairs from S into a plist.
If no pairs are found and S has a non-empty trimmed value, falls
back to `(:value <trimmed-s>)' so positional shortcodes (e.g.
`{{< youtube ID >}}') still pass their arg through."
  (let ((args nil)
        (start 0))
    (while (string-match "\\([A-Za-z_][A-Za-z0-9_-]*\\)=\"\\([^\"]*\\)\""
                         s start)
      (push (intern (concat ":" (match-string 1 s))) args)
      (push (match-string 2 s) args)
      (setq start (match-end 0)))
    (if args
        (nreverse args)
      (let ((trimmed (string-trim s)))
        (and (not (string-empty-p trimmed))
             (list :value trimmed))))))

(defun org-bootstrap-publish--render-shortcode (name args)
  "Return raw HTML for shortcode NAME with parsed plist ARGS, or nil if unknown."
  (cond
   ((string= name "youtube")
    (let ((id (or (plist-get args :value) (plist-get args :id) "")))
      (concat "<div class=\"ratio ratio-16x9 my-3\">"
              "<iframe src=\"https://www.youtube.com/embed/" id "\" "
              "title=\"YouTube video\" frameborder=\"0\" "
              "allow=\"accelerometer; autoplay; clipboard-write; "
              "encrypted-media; gyroscope; picture-in-picture\" "
              "allowfullscreen></iframe></div>")))
   ((string= name "video")
    (let ((url (org-bootstrap-publish--shortcode-static-url
                (or (plist-get args :src) ""))))
      (concat "<video controls preload=\"metadata\" class=\"w-100 my-3\">"
              "<source src=\"" url "\" type=\"video/mp4\"></video>")))
   ((string= name "figure")
    (let* ((src (org-bootstrap-publish--shortcode-static-url
                 (or (plist-get args :src) "")))
           (caption (or (plist-get args :caption) "")))
      (concat "<figure class=\"figure my-3\">"
              "<img src=\"" src "\" loading=\"lazy\" class=\"figure-img img-fluid rounded\" alt=\""
              caption "\">"
              (if (string-empty-p caption) ""
                (concat "<figcaption class=\"figure-caption\">" caption
                        "</figcaption>"))
              "</figure>")))
   (t
    (let ((entry (assq (intern name) org-bootstrap-publish-shortcodes)))
      (when entry
        ;; A throwing user handler must not sink the whole build; warn
        ;; and drop the shortcode instead.
        (condition-case err
            (or (funcall (cdr entry) args) "")
          (error
           (message "org-bootstrap-publish: shortcode `%s' handler failed: %s"
                    name (error-message-string err))
           "")))))))

(defun org-bootstrap-publish--substitute-shortcodes (text)
  "Replace every `{{< NAME ARGS >}}' in TEXT with raw HTML.
Unknown shortcodes are left untouched."
  (replace-regexp-in-string
   "{{<[ \t]*\\([A-Za-z_][A-Za-z0-9_-]*\\)\\([^>]*?\\)[ \t]*>}}"
   (lambda (m)
     (save-match-data
       (string-match "{{<[ \t]*\\([A-Za-z_][A-Za-z0-9_-]*\\)\\([^>]*?\\)[ \t]*>}}"
                     m)
       (let* ((name (match-string 1 m))
              (args (org-bootstrap-publish--parse-shortcode-args
                     (or (match-string 2 m) "")))
              (html (org-bootstrap-publish--render-shortcode name args)))
         (or html m))))
   text t t))

(defun org-bootstrap-publish--rewrite-shortcodes (body)
  "Convert Hugo shortcodes in BODY to HTML export blocks.

Two phases:

1. Each `#+begin_export md ... #+end_export' block has its
   contents passed through the shortcode substituter; the wrapper
   itself is rewritten to `#+begin_export html', so any raw HTML
   that lived alongside shortcodes (e.g. `<br/>' between two
   crosswords) survives intact.

2. Standalone `{{< name args >}}' calls outside any export block
   are wrapped individually in `#+begin_export html'.

Built-in shortcodes (`youtube', `video', `figure') and any custom
entries in `org-bootstrap-publish-shortcodes' share the dispatch."
  (let ((case-fold-search nil))
    (setq body
          (replace-regexp-in-string
           "^[ \t]*#\\+begin_export[ \t]+md[ \t]*\n\\(\\(?:.\\|\n\\)*?\\)[ \t]*\n[ \t]*#\\+end_export[ \t]*$"
           (lambda (m)
             (save-match-data
               (string-match
                "^[ \t]*#\\+begin_export[ \t]+md[ \t]*\n\\(\\(?:.\\|\n\\)*?\\)[ \t]*\n[ \t]*#\\+end_export[ \t]*$"
                m)
               (let ((content (org-bootstrap-publish--substitute-shortcodes
                               (match-string 1 m))))
                 (concat "#+begin_export html\n" content "\n#+end_export"))))
           body t))
    (setq body
          (replace-regexp-in-string
           "{{<[ \t]*\\([A-Za-z_][A-Za-z0-9_-]*\\)\\([^>]*?\\)[ \t]*>}}"
           (lambda (m)
             (save-match-data
               (string-match
                "{{<[ \t]*\\([A-Za-z_][A-Za-z0-9_-]*\\)\\([^>]*?\\)[ \t]*>}}"
                m)
               (let* ((name (match-string 1 m))
                      (args (org-bootstrap-publish--parse-shortcode-args
                             (or (match-string 2 m) "")))
                      (html (org-bootstrap-publish--render-shortcode name args)))
                 (if html
                     (concat "#+begin_export html\n" html "\n#+end_export")
                   m))))
           body t t)))
  body)

(defconst org-bootstrap-publish--cache-version 14
  "Bump to invalidate every cached `--org->html' result.
Increment when the renderer's output changes for the same input
(e.g. shortcode rewriter, bootstrapifier, or ox-html settings).")

(defvar org-bootstrap-publish--emit-live-reload t
  "Non-nil emits the localhost live-reload poller script into each page.
The dev serve commands leave this on; the publish/deploy commands
turn it off so the deployed site doesn't carry the (host-guarded but
otherwise inert) poller.  Propagated to the async child build.")

(defvar org-bootstrap-publish--cache-current-dir nil
  "Resolved per-site cache directory bound by the entry point.
nil disables the cache for the current call.")

(defvar org-bootstrap-publish--cache-used nil
  "Hash table of cache keys touched during the current build.
Non-nil enables sweeping of stale entries.")

(defvar org-bootstrap-publish--cache-hits 0)
(defvar org-bootstrap-publish--cache-misses 0)

(defvar org-bootstrap-publish--card-memo nil
  "Per-build hash table memoizing post → card HTML.  nil disables.")

(defvar org-bootstrap-publish--feed-entry-memo nil
  "Per-build hash table memoizing post → atom <entry> block.  nil disables.")

(defun org-bootstrap-publish--cache-effective-dir (out)
  "Per-site cache directory under `org-bootstrap-publish-cache-dir', or nil."
  (when org-bootstrap-publish-cache-dir
    (expand-file-name
     (secure-hash 'sha1 (expand-file-name out))
     org-bootstrap-publish-cache-dir)))

(defun org-bootstrap-publish--cache-key (str)
  "Return the cache key (sha256) for STR, salted with renderer settings."
  (secure-hash 'sha256
               (format "v%d:%s:%s:%s"
                       org-bootstrap-publish--cache-version
                       org-bootstrap-publish-htmlize-output-type
                       (if (and org-bootstrap-publish-htmlize-output-type
                                (featurep 'htmlize))
                           "h" "n")
                       str)))

(defun org-bootstrap-publish--cache-path (key)
  "Absolute cache file path for KEY, or nil when caching is disabled."
  (and org-bootstrap-publish--cache-current-dir
       (expand-file-name (concat key ".html")
                         org-bootstrap-publish--cache-current-dir)))

(defun org-bootstrap-publish--cache-lookup (str)
  "Return cached HTML for STR, or nil on miss."
  (when org-bootstrap-publish--cache-current-dir
    (let* ((key  (org-bootstrap-publish--cache-key str))
           (path (org-bootstrap-publish--cache-path key)))
      (when org-bootstrap-publish--cache-used
        (puthash key t org-bootstrap-publish--cache-used))
      (when (file-exists-p path)
        (cl-incf org-bootstrap-publish--cache-hits)
        (with-temp-buffer
          (insert-file-contents path)
          (buffer-string))))))

(defun org-bootstrap-publish--cache-store (str html)
  "Write HTML for STR into the cache; return HTML."
  (when (and org-bootstrap-publish--cache-current-dir str)
    (cl-incf org-bootstrap-publish--cache-misses)
    (let* ((key  (org-bootstrap-publish--cache-key str))
           (path (org-bootstrap-publish--cache-path key)))
      (org-bootstrap-publish--mkdir org-bootstrap-publish--cache-current-dir)
      (with-temp-file path (insert html))))
  html)

(defun org-bootstrap-publish--cache-sweep ()
  "Delete cache files not touched during the current build.  Returns count."
  (if (not (and org-bootstrap-publish--cache-current-dir
                org-bootstrap-publish--cache-used
                (file-directory-p org-bootstrap-publish--cache-current-dir)))
      0
    (let ((removed 0))
      (dolist (f (directory-files
                  org-bootstrap-publish--cache-current-dir t "\\.html\\'"))
        (let ((key (file-name-base f)))
          (unless (gethash key org-bootstrap-publish--cache-used)
            (delete-file f)
            (cl-incf removed))))
      removed)))

(defun org-bootstrap-publish--org->html (body)
  "Render org BODY string to HTML via ox-html, body-only.
Results are cached under `org-bootstrap-publish--cache-current-dir'
when that variable is bound to a directory; cached entries persist
across builds and survive the sweep at the end of each build."
  (if (or (null body) (string-empty-p (string-trim body)))
      ""
    (or (org-bootstrap-publish--cache-lookup body)
        (org-bootstrap-publish--cache-store
         body
         (let ((org-export-with-toc nil)
               (org-export-with-section-numbers nil)
               (org-export-with-broken-links t)
               (org-export-with-sub-superscripts '{})
               (org-export-use-babel nil)
               (org-confirm-babel-evaluate nil)
               (org-html-htmlize-output-type org-bootstrap-publish-htmlize-output-type)
               (org-html-container-element "section")
               (inhibit-message t))
           (org-bootstrap-publish--bootstrapify
            (org-export-string-as
             (org-bootstrap-publish--rewrite-shortcodes body)
             'html t)))))))

;;;; Templates

(defun org-bootstrap-publish--url (&rest parts)
  "Join PARTS onto `org-bootstrap-publish-site-path' into a site URL."
  (apply #'concat org-bootstrap-publish-site-path parts))

(defun org-bootstrap-publish--post-path (post)
  "Relative URL path (no leading slash) to POST's directory.
A slug of \"index\" collapses into the section path, mirroring
Hugo's content-bundle convention (`section/index.md' → /section/)."
  (let* ((section (plist-get post :section))
         (slug    (plist-get post :slug))
         (bundle  (and slug (string= slug "index"))))
    (cond
     (bundle (concat section "/"))
     ((and section (not (string-empty-p section)))
      (concat section "/" slug "/"))
     (t (concat slug "/")))))

(defun org-bootstrap-publish--post-url (post)
  "Absolute site URL for POST."
  (org-bootstrap-publish--url (org-bootstrap-publish--post-path post)))

(defun org-bootstrap-publish--tag-path (tag)
  "Relative URL path (no leading slash) to TAG's directory."
  (concat "tags/" (org-bootstrap-publish--slugify tag) "/"))

(defun org-bootstrap-publish--tag-url (tag)
  "Absolute site URL for TAG's page."
  (org-bootstrap-publish--url (org-bootstrap-publish--tag-path tag)))

(defun org-bootstrap-publish--tag-pills (tags)
  "Return TAGS rendered as a row of linked Bootstrap pill badges."
  (mapconcat
   (lambda (tag)
      (format "<a class=\"badge rounded-pill obp-tag text-decoration-none\" href=\"%s\">%s</a>"
             (org-bootstrap-publish--tag-url tag)
             (org-bootstrap-publish--escape tag)))
   tags ""))

(defun org-bootstrap-publish--thumb-url (thumb)
  "Convert a hugo-style thumbnail path to the published static URL."
  (when thumb
    (let ((t2 (replace-regexp-in-string "^/" "" thumb)))
      (if (string-prefix-p "static/" t2)
          (org-bootstrap-publish--url t2)
        (org-bootstrap-publish--url "static/" t2)))))

(defun org-bootstrap-publish--theme-style-block ()
  "Return an inline `<style>' block applying user theme overrides.
Emits CSS variable overrides from `org-bootstrap-publish-theme-overrides'
against `:root' alone so the dark/emacs theme blocks in the stylesheet
can supply their own colours.  When
`org-bootstrap-publish-background-image' is set, also emits a
`body::before' rule painting it across the viewport plus a
`.content-inner' rule giving the whole content column a solid
`--obp-body-bg' block so post text and index cards stay readable
over the image, which shows in the gutters around the block.  The
`body' itself is painted with `--obp-sidebar-bg' so that, when
opacity is applied, the colour bleeding through the image stays
consistent with the sidebar.  The image URL is routed through
`org-bootstrap-publish--url' when it isn't already absolute so
relative paths resolve from any post URL.  Returns the empty
string when neither knob is configured."
  (let* ((overrides org-bootstrap-publish-theme-overrides)
         (bg        org-bootstrap-publish-background-image)
         (blur      org-bootstrap-publish-background-blur)
         (opacity   org-bootstrap-publish-background-opacity)
         (selector  ":root")
         (decls
          (mapconcat
           (lambda (pair)
             (let* ((raw (format "%s" (car pair)))
                    (name (if (string-prefix-p "--" raw) raw (concat "--" raw))))
               (format "  %s: %s;" name (cdr pair))))
overrides "\n"))
          (body-rule
           (and (stringp bg) (not (string-empty-p bg))
                 (let* ((bg-url (if (string-match-p "\\`\\(?:https?:\\|/\\|data:\\)" bg)
                                   bg
                                 (org-bootstrap-publish--url bg)))
                      (extras
                       (concat
                        (when (and (numberp blur) (> blur 0))
                          (format "  filter: blur(%dpx);\n  transform: scale(1.05);\n" blur))
                        (when (numberp opacity)
                          (format "  opacity: %s;\n" opacity)))))
                  (concat
                   "body {\n  background: var(--obp-sidebar-bg);\n}\n"
                   (format "body::before {\n  content: \"\";\n  position: fixed;\n  inset: 0;\n  background-image: url(%S);\n  background-size: cover;\n  background-position: center;\n%s  z-index: -1;\n}\n"
                           bg-url extras)
                    ".content-inner {\n  background: color-mix(in srgb, var(--obp-body-bg) 85%, var(--obp-sidebar-bg));\n  border: 3px solid var(--obp-sidebar-bg);\n  padding: 2rem 2.5rem;\n  border-radius: 6px;\n}\n"
                     ".content-inner-listing {\n  background: color-mix(in srgb, var(--obp-sidebar-bg) 50%, transparent) !important;\n  backdrop-filter: blur(8px);\n  color: var(--obp-sidebar-fg);\n  border-radius: 12px;\n}\n"
                    ".content-inner-listing .page-header h2 { color: var(--obp-sidebar-fg); }\n"
                    ".content-inner-listing .text-muted { color: var(--obp-sidebar-muted) !important; }\n"
                    ".content-inner-listing .post-list a { color: var(--obp-sidebar-fg); }\n"
                    ".content-inner-listing .post-list a:hover { color: var(--obp-accent); }\n"
                    ".content-inner-listing h3 { color: var(--obp-sidebar-fg); }\n")))))
    (if (and (string-empty-p decls) (not body-rule)) ""
      (concat
       "<style>\n"
       (unless (string-empty-p decls)
         (format "%s {\n%s\n}\n" selector decls))
       (or body-rule "")
       "</style>\n"))))

(defun org-bootstrap-publish--og-tags (title &optional post)
  "Return Open Graph / Twitter Card meta tags for TITLE.
With POST, emits article-type tags using its summary and thumbnail;
without, emits website-type tags using the site tagline."
  (let* ((site-url (string-trim-right org-bootstrap-publish-site-url "/"))
         (site     (org-bootstrap-publish--escape org-bootstrap-publish-site-title))
         (ptitle   (org-bootstrap-publish--escape title))
         (otype    (if post "article" "website"))
         (url      (if post
                       (concat site-url "/"
                               (org-bootstrap-publish--post-path post))
                     site-url))
         (desc     (if post
                       (let* ((raw (or (plist-get post :summary) ""))
                              (plain (replace-regexp-in-string
                                      "[ \t\n]+" " "
                                      (replace-regexp-in-string
                                       "[*/=~_]" "" raw))))
                         (org-bootstrap-publish--escape
                          (if (> (length plain) 200)
                              (substring plain 0 200)
                            plain)))
                     (org-bootstrap-publish--escape
                      org-bootstrap-publish-site-tagline)))
         (image    (if post
                       (let ((thumb (plist-get post :thumbnail)))
                         (when thumb
                           (concat site-url
                                   (org-bootstrap-publish--thumb-url thumb))))
                     nil)))
    (concat
     (format "<meta property=\"og:title\" content=\"%s\">\n" ptitle)
     (format "<meta property=\"og:type\" content=\"%s\">\n" otype)
     (format "<meta property=\"og:url\" content=\"%s\">\n" url)
     (format "<meta property=\"og:site_name\" content=\"%s\">\n" site)
     (unless (string-empty-p desc)
       (format "<meta property=\"og:description\" content=\"%s\">\n" desc))
     (when image
       (format "<meta property=\"og:image\" content=\"%s\">\n" image))
     "<meta name=\"twitter:card\" content=\"summary_large_image\">\n")))

(defun org-bootstrap-publish--page (title body &optional type post)
  "Wrap BODY in the full HTML page shell titled TITLE.
TYPE is the page kind (e.g. `listing' for index/tag/section pages);
POST, when given, is the post plist used for Open Graph tags."
  (let ((bs-css   org-bootstrap-publish-bootstrap-css)
        (bs-js    org-bootstrap-publish-bootstrap-js)
        (hl-css   org-bootstrap-publish-highlight-css)
        (hl-js    org-bootstrap-publish-highlight-js)
        (site     (org-bootstrap-publish--escape org-bootstrap-publish-site-title))
        (tagline  (org-bootstrap-publish--escape org-bootstrap-publish-site-tagline))
        (author   (org-bootstrap-publish--escape org-bootstrap-publish-author))
        (year     (format-time-string "%Y"))
        (ci-class (if (eq type 'listing) "content-inner content-inner-listing" "content-inner"))
        (og-tags  (org-bootstrap-publish--og-tags title post)))
    (concat
     "<!doctype html>\n"
     "<html lang=\"en\">\n"
     "<head>\n"
     "<meta charset=\"utf-8\">\n"
     "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
     (format "<title>%s</title>\n" (org-bootstrap-publish--escape title))
     og-tags
     (format "<link rel=\"stylesheet\" href=\"%s\">\n" bs-css)
     (when hl-css (format "<link rel=\"stylesheet\" href=\"%s\">\n" hl-css))
     (format "<link rel=\"stylesheet\" href=\"%s\">\n"
             (org-bootstrap-publish--url "assets/style.css"))
     (org-bootstrap-publish--theme-style-block)
     (format "<link rel=\"alternate\" type=\"application/atom+xml\" href=\"%s\" title=\"%s\">\n"
             (org-bootstrap-publish--url "index.xml") site)
     "<script>(function(){var t=null;try{t=localStorage.getItem('obp-theme');}catch(e){}if(!t){t=window.matchMedia&&window.matchMedia('(prefers-color-scheme: dark)').matches?'dark':'emacs';}document.documentElement.setAttribute('data-obp-theme',t);document.documentElement.setAttribute('data-bs-theme',t==='dark'?'dark':'light');})();</script>\n"
     "</head>\n"
     "<body>\n"
     (format "<div class=\"site site-layout-%s\">\n"
             (or org-bootstrap-publish-layout 'sidebar))
     "  <aside class=\"sidebar\">\n"
     "    <div class=\"sidebar-inner\">\n"
     (format "      <h1 class=\"site-title\"><a href=\"%s\">%s</a></h1>\n"
             (org-bootstrap-publish--url "index.html") site)
     (if (string-empty-p tagline) ""
       (format "      <p class=\"site-tagline\">%s</p>\n" tagline))
     (format "      <div class=\"search-widget\" data-index-url=\"%s\">\n"
             (org-bootstrap-publish--url "index.json"))
     "        <input type=\"search\" id=\"search-input\" placeholder=\"Search articles&hellip;\" autocomplete=\"off\" aria-label=\"Search articles\" aria-controls=\"search-results\" aria-expanded=\"false\">\n"
     "        <ul id=\"search-results\" class=\"search-results\" role=\"listbox\" hidden></ul>\n"
     "      </div>\n"
     "      <nav class=\"sidebar-nav\"><ul class=\"list-unstyled\">\n"
     (format "        <li><a href=\"%s\">Home</a></li>\n"
             (org-bootstrap-publish--url "index.html"))
     (format "        <li><a href=\"%s\">All posts</a></li>\n"
             (org-bootstrap-publish--url "posts.html"))
     (format "        <li><a href=\"%s\">Tags</a></li>\n"
             (org-bootstrap-publish--url "tags.html"))
     (mapconcat
      (lambda (entry)
        (format "        <li class=\"nav-link\"><a href=\"%s\">%s</a></li>\n"
                (org-bootstrap-publish--escape
                 (org-bootstrap-publish--menu-link-url entry))
                (org-bootstrap-publish--escape (car entry))))
      (org-bootstrap-publish--all-menu-entries) "")
     (format "        <li><a href=\"%s\">RSS</a></li>\n"
             (org-bootstrap-publish--url "index.xml"))
     "      </ul></nav>\n"
     "      <button type=\"button\" class=\"theme-toggle\" aria-label=\"Toggle colour theme\"><span class=\"theme-toggle-label\"></span></button>\n"
     (format "      <p class=\"sidebar-footer\">&copy; %s %s</p>\n" year author)
     "    </div>\n"
     "  </aside>\n"
     "  <main class=\"content\">\n"
      (format "    <div class=\"%s\">\n" ci-class)
     body
     "    </div>\n"
     "  </main>\n"
     "</div>\n"
     (format "<script src=\"%s\"></script>\n" bs-js)
     (when (and hl-js (not (and org-bootstrap-publish-htmlize-output-type
                                (featurep 'htmlize))))
       (concat (format "<script src=\"%s\"></script>\n" hl-js)
               "<script>hljs.highlightAll();</script>\n"))
     (format "<script src=\"%s\" defer></script>\n"
             (org-bootstrap-publish--url "assets/search.js"))
     "<script>document.addEventListener('click',function(e){var b=e.target.closest('.theme-toggle');if(!b)return;var order=['light','dark','emacs'];var cur=document.documentElement.getAttribute('data-obp-theme')||'light';var next=order[(order.indexOf(cur)+1)%order.length];document.documentElement.setAttribute('data-obp-theme',next);document.documentElement.setAttribute('data-bs-theme',next==='dark'?'dark':'light');try{localStorage.setItem('obp-theme',next);}catch(_){}});</script>\n"
     (when org-bootstrap-publish--emit-live-reload
       (format "<script>(function(){if(!/^(localhost|127\\.0\\.0\\.1|\\[::1\\])$/.test(location.hostname))return;var last=null;setInterval(function(){fetch('%s',{cache:'no-store'}).then(function(r){return r.ok?r.text():null;}).then(function(t){if(t==null)return;if(last===null){last=t;return;}if(t!==last){location.reload();}}).catch(function(){});},1000);})();</script>\n"
               (org-bootstrap-publish--url "reload-token")))
     "</body>\n"
     "</html>\n")))

(defun org-bootstrap-publish--card-build (post)
  "Build the index/listing card HTML for POST (uncached)."
  (let* ((url    (org-bootstrap-publish--post-url post))
         (title  (org-bootstrap-publish--escape (plist-get post :title)))
         (date-h (org-bootstrap-publish--human-date (plist-get post :date)))
         (thumb  (org-bootstrap-publish--thumb-url (plist-get post :thumbnail)))
         (tags   (plist-get post :tags))
         (summary-html
          (org-bootstrap-publish--org->html (plist-get post :summary))))
    (concat
     "<div class=\"col-12 col-md-6 col-lg-3 mb-3\">\n"
     "<article class=\"card h-100 post-card\">\n"
     (if thumb
         (format "<a href=\"%s\" class=\"post-card-thumb\"><img src=\"%s\" loading=\"lazy\" class=\"card-img-top\" alt=\"\"></a>\n"
                 url thumb)
       "")
     "<div class=\"card-body\">\n"
     (format "<h3 class=\"card-title h6\"><a href=\"%s\" class=\"text-decoration-none\">%s</a></h3>\n"
             url title)
     (if date-h (format "<p class=\"card-subtitle text-muted small mb-2\">%s</p>\n" date-h) "")
     (format "<div class=\"card-text post-summary\">%s</div>\n" summary-html)
     (if tags
         (format "<div class=\"post-tags mt-2\">%s</div>\n"
                 (org-bootstrap-publish--tag-pills tags))
       "")
     "</div>\n"
     "</article>\n"
     "</div>\n")))

(defun org-bootstrap-publish--card (post)
  "Card HTML for POST, memoized when `--card-memo' is bound."
  (if org-bootstrap-publish--card-memo
      (or (gethash post org-bootstrap-publish--card-memo)
          (puthash post (org-bootstrap-publish--card-build post)
                   org-bootstrap-publish--card-memo))
    (org-bootstrap-publish--card-build post)))

(defun org-bootstrap-publish--page-url (n &optional base)
  "URL for paginated listing page N (1-based).
BASE is a trailing-slash path like \"blog/\"; nil means the site root."
  (let ((base (or base "")))
    (if (<= n 1)
        (org-bootstrap-publish--url base)
      (org-bootstrap-publish--url base "page/" (number-to-string n) "/"))))

(defun org-bootstrap-publish--pagination-nav (page total &optional base)
  "Prev / page-N-of-M / Next nav for listing PAGE of TOTAL.
BASE is forwarded to `org-bootstrap-publish--page-url' so the same
nav works for the home index and per-section landings."
  (if (<= total 1)
      ""
    (let* ((prev (when (> page 1) (1- page)))
           (next (when (< page total) (1+ page))))
      (concat
       "<nav aria-label=\"Post pagination\" class=\"mt-4\">\n"
       "<ul class=\"pagination justify-content-center\">\n"
       (if prev
           (format "<li class=\"page-item\"><a class=\"page-link\" href=\"%s\">&laquo; Newer</a></li>\n"
                   (org-bootstrap-publish--page-url prev base))
         "<li class=\"page-item disabled\"><span class=\"page-link\">&laquo; Newer</span></li>\n")
       (format "<li class=\"page-item active\" aria-current=\"page\"><span class=\"page-link\">Page %d of %d</span></li>\n"
               page total)
       (if next
           (format "<li class=\"page-item\"><a class=\"page-link\" href=\"%s\">Older &raquo;</a></li>\n"
                   (org-bootstrap-publish--page-url next base))
         "<li class=\"page-item disabled\"><span class=\"page-link\">Older &raquo;</span></li>\n")
       "</ul>\n"
       "</nav>\n"))))

(defun org-bootstrap-publish--render-index (posts &optional page total)
  "Render index cards for PAGE (1-based) of TOTAL pages.
With no args, renders the first page only (legacy behaviour)."
  (let* ((page  (or page 1))
         (per   org-bootstrap-publish-posts-per-page)
         (total (or total (max 1 (ceiling (/ (float (length posts)) per)))))
         (start (* (1- page) per))
         (end   (min (+ start per) (length posts)))
         (slice (cl-subseq posts start end))
         (cards (mapconcat #'org-bootstrap-publish--card slice ""))
          (header (if (= page 1)
                      ""
                    (format "<h2>Latest posts &mdash; page %d of %d</h2>"
                            page total))))
    (concat
     (format "<header class=\"page-header mb-4\">%s</header>\n" header)
     "<div class=\"row\">\n"
     cards
     "</div>\n"
     (org-bootstrap-publish--pagination-nav page total))))

(defun org-bootstrap-publish--post-nav (newer older)
  "Render a prev/next nav block for a post page.
NEWER is the chronologically newer neighbour; OLDER is the older
one.  Either may be nil."
  (if (not (or newer older))
      ""
    (cl-flet ((cell (post label align-end)
                (if post
                    (format "<div class=\"col-6 post-nav-%s%s\"><a href=\"%s\"><span class=\"post-nav-label\">%s</span><span class=\"post-nav-title\">%s</span></a></div>\n"
                            (if align-end "next" "prev")
                            (if align-end " text-end" "")
                            (org-bootstrap-publish--post-url post)
                            label
                            (org-bootstrap-publish--escape
                             (plist-get post :title)))
                  "<div class=\"col-6\"></div>\n")))
      (concat
       "<nav class=\"post-nav\" aria-label=\"Post navigation\">\n"
       "<div class=\"row\">\n"
       (cell older "&laquo; Previous" nil)
       (cell newer "Next &raquo;"     t)
       "</div>\n"
       "</nav>\n"))))

(defun org-bootstrap-publish--disqus-snippet ()
  "Return the Disqus thread HTML snippet, or \"\" when not configured.
The injected script skips localhost so the dev server doesn't
create stray comment threads under your shortname."
  (if (or (null org-bootstrap-publish-disqus-shortname)
          (string-empty-p org-bootstrap-publish-disqus-shortname))
      ""
    (format
     (concat
      "<div id=\"disqus_thread\" class=\"mt-4\"></div>\n"
      "<script>(function(){"
      "if(/^(localhost|127\\.0\\.0\\.1|\\[::1\\])$/.test(location.hostname))return;"
      "var d=document.createElement('script');d.async=true;"
      "d.src='https://%s.disqus.com/embed.js';"
      "(document.head||document.body).appendChild(d);"
      "})();</script>\n")
     org-bootstrap-publish-disqus-shortname)))

(defun org-bootstrap-publish--render-post (post &optional newer older)
  "Render the full article HTML for POST, with NEWER/OLDER neighbour nav."
  (let* ((title  (org-bootstrap-publish--escape (plist-get post :title)))
         (date   (plist-get post :date))
         (tags   (plist-get post :tags))
         (body   (org-bootstrap-publish--org->html (plist-get post :body))))
    (concat
     "<article class=\"post\">\n"
     "<header class=\"post-header mb-4\">\n"
     (format "<h1>%s</h1>\n" title)
     "<p class=\"post-meta text-muted\">\n"
     (if date
         (format "<time datetime=\"%s\">%s</time>\n"
                 (org-bootstrap-publish--iso date)
                 (org-bootstrap-publish--human-date date))
       "")
     (if tags (concat " &middot; " (org-bootstrap-publish--tag-pills tags)) "")
     "</p>\n"
     "</header>\n"
     (format "<div class=\"post-body\">%s</div>\n" body)
     (org-bootstrap-publish--post-nav newer older)
     (org-bootstrap-publish--disqus-snippet)
     "</article>\n")))

(defun org-bootstrap-publish--gallery-images (source-file section)
  "Image filenames in SOURCE-FILE's static/SECTION dir, newest-first by name."
  (let* ((dir (expand-file-name (concat "static/" section)
                                (file-name-directory source-file)))
         (re  "\\.\\(?:gif\\|webp\\|jpe?g\\|tiff?\\|png\\|bmp\\)\\'"))
    (when (file-directory-p dir)
      (sort (directory-files dir nil re t)
            (lambda (a b) (string-greaterp a b))))))

(defun org-bootstrap-publish--render-gallery (post source-file &optional newer older)
  "Render a masonry gallery page for POST, pulling images from
static/<section>/ relative to SOURCE-FILE.
Includes a zero-dependency vanilla-JS image viewer overlay with
prev/next navigation and keyboard support."
  (let* ((title   (org-bootstrap-publish--escape (plist-get post :title)))
         (date    (plist-get post :date))
         (tags    (plist-get post :tags))
         (section (plist-get post :section))
         (body    (org-bootstrap-publish--org->html (plist-get post :body)))
         (images  (org-bootstrap-publish--gallery-images source-file section))
         (url-base (org-bootstrap-publish--url "static/" section "/")))
    (concat
     "<article class=\"post post-gallery\">\n"
     "<header class=\"post-header mb-4\">\n"
     (format "<h1>%s</h1>\n" title)
     "<p class=\"post-meta text-muted\">\n"
     (if date
         (format "<time datetime=\"%s\">%s</time>\n"
                 (org-bootstrap-publish--iso date)
                 (org-bootstrap-publish--human-date date))
       "")
     (if tags (concat " &middot; " (org-bootstrap-publish--tag-pills tags)) "")
     "</p>\n"
     "</header>\n"
     (format "<div class=\"post-body\">%s</div>\n" body)
     (if (null images)
         (format "<p class=\"text-muted\">No images found in <code>static/%s/</code>.</p>\n"
                 (org-bootstrap-publish--escape section))
       (concat
        "<div class=\"row row-img-fluid gallery-grid\">\n"
        (mapconcat
         (lambda (name)
           (let ((u (concat url-base name)))
             (format
              "<div class=\"col-6 col-md-3 col-xl-3 pb-1 px-2\"><a href=\"%s\"><img src=\"%s\" alt=\"\" loading=\"lazy\" class=\"img-fluid\"></a></div>\n"
              u u)))
         images "")
        "</div>\n"
         "<script src=\"https://cdn.jsdelivr.net/npm/masonry-layout@4.2.2/dist/masonry.pkgd.min.js\"></script>\n"
         "<script src=\"https://cdn.jsdelivr.net/npm/imagesloaded@5/imagesloaded.pkgd.min.js\"></script>\n"
         "<script>(function(){var g=document.querySelector('.gallery-grid');if(g&&typeof Masonry!=='undefined'){var m=new Masonry(g,{percentPosition:true});if(typeof imagesLoaded==='function'){imagesLoaded(g).on('progress',function(){m.layout();});}}})();</script>\n"
         "<script>(function(){var a=document.querySelectorAll('.gallery-grid a');if(!a.length)return;var imgs=[].map.call(a,function(l){return l.href});var c=0,img=new Image,pb,nb;var o=document.createElement('div');o.style.cssText='position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.9);z-index:1055;';img.style.cssText='position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);max-width:95vw;max-height:95vh;object-fit:contain;';o.appendChild(img);var x=document.createElement('button');x.innerHTML='\\u2715';x.style.cssText='position:absolute;top:10px;right:20px;font-size:2rem;color:#fff;background:none;border:none;cursor:pointer;z-index:1;line-height:1;';o.appendChild(x);pb=document.createElement('button');pb.innerHTML='\\u2039';pb.style.cssText='position:absolute;top:50%;left:10px;transform:translateY(-50%);font-size:3rem;color:#fff;background:none;border:none;cursor:pointer;padding:10px;';o.appendChild(pb);nb=document.createElement('button');nb.innerHTML='\\u203a';nb.style.cssText='position:absolute;top:50%;right:10px;transform:translateY(-50%);font-size:3rem;color:#fff;background:none;border:none;cursor:pointer;padding:10px;';o.appendChild(nb);o.style.display='none';document.body.appendChild(o);function s(idx){if(idx<0)idx=imgs.length-1;if(idx>=imgs.length)idx=0;c=idx;img.src=imgs[c];o.style.display='block';document.body.style.overflow='hidden';}function h(){o.style.display='none';document.body.style.overflow='';}a.forEach(function(l,idx){l.addEventListener('click',function(e){e.preventDefault();s(idx);});});o.addEventListener('click',function(e){if(e.target===o)h();});x.addEventListener('click',h);pb.addEventListener('click',function(e){e.stopPropagation();s(c-1);});nb.addEventListener('click',function(e){e.stopPropagation();s(c+1);});document.addEventListener('keydown',function(e){if(o.style.display!=='block')return;if(e.key==='Escape')h();if(e.key==='ArrowLeft')s(c-1);if(e.key==='ArrowRight')s(c+1);});})();</script>\n"))
     (org-bootstrap-publish--post-nav newer older)
     (org-bootstrap-publish--disqus-snippet)
     "</article>\n")))

(defun org-bootstrap-publish--tag-header (tag posts)
  "Header HTML for TAG's page, showing the POSTS count."
  (let ((tag-esc (org-bootstrap-publish--escape tag))
        (n       (length posts)))
    (concat
     (format "<header class=\"page-header mb-4\"><h2>Posts tagged <code>%s</code></h2>"
             tag-esc)
     (format "<p class=\"text-muted\">%d post%s</p></header>\n"
             n (if (= 1 n) "" "s")))))

(defun org-bootstrap-publish--render-tag-page-list (tag posts)
  "Render TAG's page as a flat bullet list of POSTS."
  (let ((items (mapconcat
                (lambda (p)
                  (let ((url (org-bootstrap-publish--post-url p))
                        (title (org-bootstrap-publish--escape (plist-get p :title)))
                        (date (plist-get p :date)))
                    (format "<li class=\"mb-2\"><a href=\"%s\">%s</a>%s</li>\n"
                            url title
                            (if date
                                (format " <span class=\"text-muted small\">&middot; %s</span>"
                                        (org-bootstrap-publish--human-date date))
                              ""))))
                posts "")))
    (concat
     (org-bootstrap-publish--tag-header tag posts)
     "<ul class=\"post-list list-unstyled\">\n"
     items
     "</ul>\n")))

(defun org-bootstrap-publish--render-tag-page-cards (tag posts)
  "Render TAG's page as a grid of POSTS cards."
  (concat
   (org-bootstrap-publish--tag-header tag posts)
   "<div class=\"row\">\n"
   (mapconcat #'org-bootstrap-publish--card posts "")
   "</div>\n"))

(defun org-bootstrap-publish--render-tag-page (tag posts)
  "Render TAG's page of POSTS as cards or a list per its configured style."
  (if (eq (org-bootstrap-publish--tag-style tag) 'cards)
      (org-bootstrap-publish--render-tag-page-cards tag posts)
    (org-bootstrap-publish--render-tag-page-list tag posts)))

(defun org-bootstrap-publish--render-archive (posts)
  "Render a flat, year-grouped archive of every post."
  (let ((groups nil)
        (order  nil))
    (dolist (p posts)
      (let* ((date (plist-get p :date))
             (year (if date (format-time-string "%Y" date) "Undated")))
        (unless (assoc year groups)
          (push (cons year nil) groups)
          (push year order))
        (push p (cdr (assoc year groups)))))
    (concat
     "<header class=\"page-header mb-4\">"
     (format "<h2>All posts <span class=\"text-muted fs-5\">(%d)</span></h2>"
             (length posts))
     "</header>\n"
     (mapconcat
      (lambda (year)
        (let ((year-posts (reverse (cdr (assoc year groups)))))
          (concat
           (format "<h3 class=\"mt-4 mb-2\">%s</h3>\n" year)
           "<ul class=\"post-list list-unstyled\">\n"
           (mapconcat
            (lambda (p)
              (let ((url (org-bootstrap-publish--post-url p))
                    (title (org-bootstrap-publish--escape (plist-get p :title)))
                    (date (plist-get p :date)))
                (format "<li class=\"mb-1\">%s<a href=\"%s\">%s</a></li>\n"
                        (if date
                            (format "<span class=\"text-muted small me-2 font-monospace\">%s</span>"
                                    (format-time-string "%m-%d" date))
                          "")
                        url title)))
            year-posts "")
           "</ul>\n")))
      (reverse order) ""))))

(defun org-bootstrap-publish--render-tags-index (tag-counts)
  "Render the all-tags cloud from TAG-COUNTS (an alist of (tag . count))."
  (let ((links
         (mapconcat
          (lambda (tc)
            (let* ((tag (car tc))
                   (n   (cdr tc)))
              (format "<a class=\"badge rounded-pill obp-tag text-decoration-none\" href=\"%s\">%s <span class=\"badge text-bg-secondary\">%d</span></a>"
                      (org-bootstrap-publish--tag-url tag)
                      (org-bootstrap-publish--escape tag) n)))
          tag-counts "\n")))
    (concat
     "<header class=\"page-header mb-4\"><h2>All tags</h2></header>\n"
     (format "<div class=\"tag-cloud\">%s</div>\n" links))))

;;;; Feed

(defun org-bootstrap-publish--feed (posts &optional title rel-path)
  "Render an Atom feed of POSTS.
Optional TITLE overrides the feed title (default: site title).
Optional REL-PATH is the feed's location relative to the site root
(default: \"\", the home feed at `index.xml').  Used to set the
`<link rel=\"self\">' and `<id>' so subscribers polling a tag feed
see stable identifiers."
  (let* ((n (min 20 (length posts)))
         (recent (cl-subseq posts 0 n))
         (url (or org-bootstrap-publish-site-url "https://example.com/"))
         (url (if (string-suffix-p "/" url) url (concat url "/")))
         (rel (or rel-path ""))
         (self (concat url rel "index.xml"))
         (alt (concat url rel))
         (feed-title (or title org-bootstrap-publish-site-title))
         (updated (or (org-bootstrap-publish--iso
                       (plist-get (car recent) :date))
                      (org-bootstrap-publish--iso (current-time))))
         (entries
          (mapconcat
           (lambda (p)
             (or (and org-bootstrap-publish--feed-entry-memo
                      (gethash p org-bootstrap-publish--feed-entry-memo))
                 (let* ((link (concat url (org-bootstrap-publish--post-path p)))
                        (date (org-bootstrap-publish--iso
                               (or (plist-get p :date) (current-time))))
                        (title (org-bootstrap-publish--escape (plist-get p :title)))
                        (content (org-bootstrap-publish--escape
                                  (org-bootstrap-publish--org->html
                                   (plist-get p :body)))))
                   (let ((entry
                          (format (concat "<entry>\n"
                                          "<title>%s</title>\n"
                                          "<link href=\"%s\"/>\n"
                                          "<id>%s</id>\n"
                                          "<updated>%s</updated>\n"
                                          "<content type=\"html\">%s</content>\n"
                                          "</entry>\n")
                                  title link link date content)))
                     (when org-bootstrap-publish--feed-entry-memo
                       (puthash p entry org-bootstrap-publish--feed-entry-memo))
                     entry))))
           recent "")))
    (concat
     "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
     "<feed xmlns=\"http://www.w3.org/2005/Atom\">\n"
     (format "<title>%s</title>\n"
             (org-bootstrap-publish--escape feed-title))
     (format "<link href=\"%s\"/>\n" alt)
     (format "<link rel=\"self\" href=\"%s\"/>\n" self)
     (format "<id>%s</id>\n" alt)
     (format "<updated>%s</updated>\n" updated)
     (format "<author><name>%s</name></author>\n"
             (org-bootstrap-publish--escape org-bootstrap-publish-author))
     entries
     "</feed>\n")))

;;;; Search index

(defun org-bootstrap-publish--index-json (posts)
  "Serialise POSTS as a JSON array for the client-side search widget."
  (let ((site (or org-bootstrap-publish-site-url "")))
    (json-encode
     (apply
      #'vector
      (mapcar
       (lambda (p)
         (let* ((summary (or (plist-get p :summary) ""))
                (plain   (replace-regexp-in-string
                          "[ \t\n]+" " "
                          (replace-regexp-in-string
                           "[*/=~_]" "" summary)))
                (trimmed (if (> (length plain) 200)
                             (substring plain 0 200)
                           plain))
                (date    (org-bootstrap-publish--human-date
                          (plist-get p :date))))
           `((title     . ,(plist-get p :title))
             (permalink . ,(concat site
                                   (org-bootstrap-publish--post-path p)))
             (summary   . ,trimmed)
             (tags      . ,(apply #'vector (plist-get p :tags)))
             (section   . ,(or (plist-get p :section) ""))
             (date      . ,(or date "")))))
       posts)))))

(defconst org-bootstrap-publish--search-js
  "(function () {
  var widget = document.querySelector('.search-widget');
  var input = document.getElementById('search-input');
  var results = document.getElementById('search-results');
  if (!widget || !input || !results) return;

  var indexUrl = widget.dataset.indexUrl;
  var index = null, loading = null, activeIdx = -1;

  function loadIndex() {
    if (index) return Promise.resolve(index);
    if (loading) return loading;
    loading = fetch(indexUrl, { credentials: 'same-origin' })
      .then(function (r) { return r.ok ? r.json() : []; })
      .then(function (d) { index = Array.isArray(d) ? d : []; return index; })
      .catch(function () { index = []; return index; });
    return loading;
  }
  function esc(s) {
    return (s == null ? '' : String(s)).replace(/[&<>\"']/g, function (c) {
      return ({ '&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;',\"'\":'&#39;' })[c];
    });
  }
  function render(matches) {
    activeIdx = -1;
    if (!matches.length) {
      results.innerHTML = '<li class=\"search-empty\">No matches</li>';
      results.hidden = false; input.setAttribute('aria-expanded','true'); return;
    }
    var shown = matches.slice(0, 12);
    results.innerHTML = shown.map(function (m) {
      var tags = (m.tags || []).join(', ');
      var meta = [m.section, tags, m.date].filter(Boolean).join(' \\u00b7 ');
      return '<li role=\"option\"><a href=\"' + esc(m.permalink) + '\">' +
        '<span class=\"search-title\">' + esc(m.title) + '</span>' +
        (meta ? '<span class=\"search-meta\">' + esc(meta) + '</span>' : '') +
        '</a></li>';
    }).join('');
    results.hidden = false; input.setAttribute('aria-expanded','true');
  }
  function hide() { results.hidden = true; input.setAttribute('aria-expanded','false'); activeIdx = -1; }
  function search(q) {
    q = q.trim().toLowerCase();
    if (!q) { hide(); results.innerHTML=''; return; }
    loadIndex().then(function (data) {
      var terms = q.split(/\\s+/).filter(Boolean);
      var matches = data.filter(function (e) {
        var hay = [e.title, e.summary, (e.tags||[]).join(' '), e.section].join(' ').toLowerCase();
        return terms.every(function (t) { return hay.indexOf(t) !== -1; });
      });
      render(matches);
    });
  }
  function setActive(next) {
    var items = results.querySelectorAll('li[role=\"option\"]');
    if (!items.length) return;
    if (activeIdx >= 0 && items[activeIdx]) items[activeIdx].classList.remove('active');
    activeIdx = (next + items.length) % items.length;
    items[activeIdx].classList.add('active');
    items[activeIdx].scrollIntoView({ block: 'nearest' });
  }
  var timer;
  input.addEventListener('input', function (e) {
    clearTimeout(timer); var val = e.target.value;
    timer = setTimeout(function () { search(val); }, 120);
  });
  input.addEventListener('focus', function () { if (input.value.trim()) search(input.value); });
  input.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') { input.value=''; hide(); input.blur(); return; }
    if (results.hidden) return;
    if (e.key === 'ArrowDown') { e.preventDefault(); setActive(activeIdx + 1); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); setActive(activeIdx - 1); }
    else if (e.key === 'Enter') {
      var items = results.querySelectorAll('li[role=\"option\"] a');
      if (activeIdx >= 0 && items[activeIdx]) { e.preventDefault(); window.location = items[activeIdx].href; }
    }
  });
  document.addEventListener('click', function (e) {
    if (!e.target.closest('.search-widget')) hide();
  });
})();
"
  "Client-side search widget.  Written to assets/search.js.")

;;;; Output

(defun org-bootstrap-publish--collect-tags (posts)
  "Return alist ((tag . count) ...) sorted by count desc, then name."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (p posts)
      (dolist (tag (plist-get p :tags))
        (puthash tag (1+ (gethash tag table 0)) table)))
    (let (result)
      (maphash (lambda (k v) (push (cons k v) result)) table)
      (sort result (lambda (a b)
                     (if (= (cdr a) (cdr b))
                         (string< (car a) (car b))
                       (> (cdr a) (cdr b))))))))

(defun org-bootstrap-publish--posts-with-tag (tag posts)
  "Return the subset of POSTS carrying TAG, preserving order."
  (cl-remove-if-not
   (lambda (p) (member tag (plist-get p :tags)))
   posts))

(defun org-bootstrap-publish--menu-link-url (entry)
  "URL for a `org-bootstrap-publish-menu-links' ENTRY (short or long form)."
  (let ((rest (cdr entry)))
    (if (consp rest) (car rest) rest)))

(defun org-bootstrap-publish--menu-link-plist (entry)
  "Plist tail for a long-form menu-links ENTRY, or nil for short form."
  (let ((rest (cdr entry)))
    (and (consp rest) (cdr rest))))

(defvar org-bootstrap-publish--menu-entries-cache nil
  "Per-build cache of `org-bootstrap-publish--all-menu-entries'.
The build entry points bind this to the precomputed entry list so the
sidebar nav and per-page style lookups don't rebuild it for every
page.  nil means compute on demand.")

(defun org-bootstrap-publish--all-menu-entries ()
  "Combined sidebar entries from `-menu-links' plus translated `-menu-tags'.
The result is cached in `org-bootstrap-publish--menu-entries-cache'
for the duration of a build when that variable is bound."
  (or org-bootstrap-publish--menu-entries-cache
      (append
       org-bootstrap-publish-menu-links
       (mapcar (lambda (e)
                 (list (car e)
                       (org-bootstrap-publish--tag-url (cdr e))
                       :style 'list))
               org-bootstrap-publish-menu-tags))))

(defun org-bootstrap-publish--menu-style-for-url (url present-default absent-default)
  "Layout style for URL.
Walks `--all-menu-entries' for an entry whose URL matches.  An
explicit `:style' on a matching entry wins; otherwise return
PRESENT-DEFAULT if URL is in the menu, ABSENT-DEFAULT if not."
  (let ((found nil) (style nil))
    (dolist (entry (org-bootstrap-publish--all-menu-entries))
      (let ((u  (org-bootstrap-publish--menu-link-url entry))
            (pl (org-bootstrap-publish--menu-link-plist entry)))
        (when (and u (string= u url))
          (setq found t)
          (when pl
            (let ((s (plist-get pl :style)))
              (when (memq s '(cards list))
                (setq style s)))))))
    (or style (if found present-default absent-default))))

(defun org-bootstrap-publish--section-style-for-root (root)
  "Layout style for section ROOT.  Always defaults to `cards'."
  (org-bootstrap-publish--menu-style-for-url
   (org-bootstrap-publish--url root "/") 'cards 'cards))

(defun org-bootstrap-publish--tag-style (tag)
  "Layout style for TAG's page.
Tags promoted into the sidebar via `-menu-links' default to
`cards'; tags not in the sidebar default to `list', matching the
historical bullet-list behaviour."
  (org-bootstrap-publish--menu-style-for-url
   (org-bootstrap-publish--tag-url tag) 'cards 'list))

(defun org-bootstrap-publish--section-root (post)
  "First path segment of POST's :section, or nil."
  (let ((s (plist-get post :section)))
    (and s (not (string-empty-p s))
         (car (split-string s "/")))))

(defun org-bootstrap-publish--all-section-roots (posts)
  "Distinct root section names from POSTS, sorted."
  (let (roots)
    (dolist (p posts)
      (let ((r (org-bootstrap-publish--section-root p)))
        (when (and r (not (member r roots)))
          (push r roots))))
    (sort roots #'string<)))

(defun org-bootstrap-publish--posts-in-section (root posts)
  "Return POSTS whose section is ROOT or a descendant (ROOT/foo)."
  (cl-remove-if-not
   (lambda (p)
     (let ((s (plist-get p :section)))
       (and s (or (string= s root)
                  (string-prefix-p (concat root "/") s)))))
   posts))

(defun org-bootstrap-publish--section-has-landing-p (root posts)
  "Non-nil if a post already owns /ROOT/ (section=ROOT, slug=index)."
  (cl-some
   (lambda (p)
     (and (string= (or (plist-get p :section) "") root)
          (string= (or (plist-get p :slug) "") "index")))
   posts))

(defun org-bootstrap-publish--section-header (root posts page total)
  "Header HTML for a section landing: ROOT, PAGE of TOTAL, POSTS count."
  (let ((root-esc (org-bootstrap-publish--escape root))
        (n        (length posts)))
    (concat
     (format "<header class=\"page-header mb-4\">%s"
             (if (= page 1)
                 (format "<h2>Section: <code>%s</code></h2>" root-esc)
               (format "<h2>Section: <code>%s</code> &mdash; page %d of %d</h2>"
                       root-esc page total)))
     (format "<p class=\"text-muted\">%d post%s</p></header>\n"
             n (if (= 1 n) "" "s")))))

(defun org-bootstrap-publish--render-section-page-cards (root posts page total)
  "Render section ROOT's card listing for PAGE of TOTAL over POSTS."
  (let* ((per   org-bootstrap-publish-posts-per-page)
         (start (* (1- page) per))
         (end   (min (+ start per) (length posts)))
         (slice (cl-subseq posts start end))
         (cards (mapconcat #'org-bootstrap-publish--card slice "")))
    (concat
     (org-bootstrap-publish--section-header root posts page total)
     "<div class=\"row\">\n"
     cards
     "</div>\n"
     (org-bootstrap-publish--pagination-nav page total (concat root "/")))))

(defun org-bootstrap-publish--render-section-page-list (root posts page total)
  "Render section ROOT's bullet-list listing for PAGE of TOTAL over POSTS."
  (let* ((per   org-bootstrap-publish-posts-per-page)
         (start (* (1- page) per))
         (end   (min (+ start per) (length posts)))
         (slice (cl-subseq posts start end))
         (items (mapconcat
                 (lambda (p)
                   (let ((url (org-bootstrap-publish--post-url p))
                         (title (org-bootstrap-publish--escape (plist-get p :title)))
                         (date (plist-get p :date)))
                     (format "<li class=\"mb-2\"><a href=\"%s\">%s</a>%s</li>\n"
                             url title
                             (if date
                                 (format " <span class=\"text-muted small\">&middot; %s</span>"
                                         (org-bootstrap-publish--human-date date))
                               ""))))
                 slice "")))
    (concat
     (org-bootstrap-publish--section-header root posts page total)
     "<ul class=\"post-list list-unstyled\">\n"
     items
     "</ul>\n"
     (org-bootstrap-publish--pagination-nav page total (concat root "/")))))

(defun org-bootstrap-publish--render-section-page (root posts &optional page total)
  "Render section ROOT's PAGE of TOTAL over POSTS, as cards or a list per style."
  (let* ((page  (or page 1))
         (per   org-bootstrap-publish-posts-per-page)
         (total (or total (max 1 (ceiling (/ (float (length posts)) per)))))
         (style (org-bootstrap-publish--section-style-for-root root)))
    (if (eq style 'list)
        (org-bootstrap-publish--render-section-page-list root posts page total)
      (org-bootstrap-publish--render-section-page-cards root posts page total))))

(defun org-bootstrap-publish--copy-static (source-file out-dir)
  "Copy each `org-bootstrap-publish-static-dirs' beside SOURCE-FILE into OUT-DIR."
  (dolist (name org-bootstrap-publish-static-dirs)
    (let ((src (expand-file-name name (file-name-directory source-file)))
          (dst (expand-file-name name out-dir)))
      (when (file-directory-p src)
        (org-bootstrap-publish--mkdir (file-name-directory dst))
        (copy-directory src dst nil t t)))))

(defun org-bootstrap-publish--copy-assets (out-dir)
  "Copy the stylesheet and write search.js into OUT-DIR/assets/."
  (let ((dst-dir (expand-file-name "assets" out-dir)))
    (org-bootstrap-publish--mkdir dst-dir)
    (when (and org-bootstrap-publish-asset-file
               (file-exists-p org-bootstrap-publish-asset-file))
      (copy-file org-bootstrap-publish-asset-file
                 (expand-file-name "style.css" dst-dir) t))
    (org-bootstrap-publish--write
     (expand-file-name "search.js" dst-dir)
     org-bootstrap-publish--search-js)))

;;;; Entry point

(defun org-bootstrap-publish--write-post (post out source-file &optional newer older)
  "Render POST (gallery or article) and write its page under OUT.
SOURCE-FILE locates gallery images; NEWER/OLDER are neighbour posts."
  (let* ((type (plist-get post :type))
         (body (cond
                ((and type (string= type "gallery"))
                 (org-bootstrap-publish--render-gallery
                  post source-file newer older))
                (t
                 (org-bootstrap-publish--render-post post newer older)))))
    (org-bootstrap-publish--write
     (expand-file-name
      (concat (org-bootstrap-publish--post-path post) "index.html") out)
     (org-bootstrap-publish--page
      (format "%s | %s"
              (plist-get post :title)
              org-bootstrap-publish-site-title)
      body nil post))))

(defun org-bootstrap-publish--neighbours (post posts)
  "Return (NEWER OLDER) for POST within the newest-first POSTS list."
  (let ((pos (cl-position post posts :test #'eq))
        (len (length posts)))
    (when pos
      (list (and (> pos 0) (nth (1- pos) posts))
            (and (< pos (1- len)) (nth (1+ pos) posts))))))

(defun org-bootstrap-publish--write-listings (posts tag-counts out &optional fast)
  "Write non-post pages (index, tag pages, archive, feeds, search index).
When FAST is non-nil, skip the expensive passes: per-tag HTML
pages, per-tag feeds, and the site feed.  These embed fully
exported post bodies and dominate rebuild time; they refresh on
the next full build."
  (let* ((per   org-bootstrap-publish-posts-per-page)
         (total (max 1 (ceiling (/ (float (length posts)) per)))))
    (dotimes (i total)
      (let* ((page (1+ i))
             (rel  (if (= page 1)
                       "index.html"
                     (concat "page/" (number-to-string page) "/index.html")))
             (title (if (= page 1)
                        org-bootstrap-publish-site-title
                      (format "Page %d | %s" page
                              org-bootstrap-publish-site-title))))
        (org-bootstrap-publish--write
         (expand-file-name rel out)
         (org-bootstrap-publish--page
          title
          (org-bootstrap-publish--render-index posts page total)
          'listing)))))
    (unless fast
      (dolist (tc tag-counts)
        (let* ((tag (car tc))
               (tag-path (org-bootstrap-publish--tag-path tag))
               (matching (org-bootstrap-publish--posts-with-tag tag posts)))
          (org-bootstrap-publish--write
           (expand-file-name (concat tag-path "index.html") out)
            (org-bootstrap-publish--page
             (format "%s | %s" tag org-bootstrap-publish-site-title)
             (org-bootstrap-publish--render-tag-page tag matching)
             'listing))
          (org-bootstrap-publish--write
           (expand-file-name (concat tag-path "index.xml") out)
           (org-bootstrap-publish--feed
            matching
            (format "%s on %s" tag org-bootstrap-publish-site-title)
            tag-path)))))
    (dolist (root (org-bootstrap-publish--all-section-roots posts))
      (unless (org-bootstrap-publish--section-has-landing-p root posts)
        (let* ((matching (org-bootstrap-publish--posts-in-section root posts))
               (per      org-bootstrap-publish-posts-per-page)
               (total    (max 1 (ceiling (/ (float (length matching)) per)))))
          (dotimes (i total)
            (let* ((page (1+ i))
                   (rel  (if (= page 1)
                             (concat root "/index.html")
                           (concat root "/page/" (number-to-string page) "/index.html")))
                   (title (if (= page 1)
                              (format "%s | %s" root org-bootstrap-publish-site-title)
                            (format "%s page %d | %s" root page
                                    org-bootstrap-publish-site-title))))
              (org-bootstrap-publish--write
               (expand-file-name rel out)
               (org-bootstrap-publish--page
                title
                (org-bootstrap-publish--render-section-page
                 root matching page total)
                'listing)))))))
    (org-bootstrap-publish--write
     (expand-file-name "posts.html" out)
     (org-bootstrap-publish--page
      (format "All posts | %s" org-bootstrap-publish-site-title)
      (org-bootstrap-publish--render-archive posts)
      'listing))
    (org-bootstrap-publish--write
     (expand-file-name "tags.html" out)
     (org-bootstrap-publish--page
      (format "Tags | %s" org-bootstrap-publish-site-title)
      (org-bootstrap-publish--render-tags-index tag-counts)
      'listing))
    (unless fast
      (let ((feed (org-bootstrap-publish--feed posts)))
        (org-bootstrap-publish--write
         (expand-file-name "index.xml" out) feed)
        (org-bootstrap-publish--write
         (expand-file-name "feed.xml" out) feed)))
    (org-bootstrap-publish--write
     (expand-file-name "index.json" out)
     (org-bootstrap-publish--index-json posts))
    (org-bootstrap-publish--write
     (expand-file-name "reload-token" out)
     (format "%.6f\n" (float-time))))

(defun org-bootstrap-publish--source-files ()
  "List of source files to publish, expanded to absolute paths.
Prefers `org-bootstrap-publish-source-files' (multi-source); falls
back to the singleton `org-bootstrap-publish-source-file'."
  (cond
   (org-bootstrap-publish-source-files
    (mapcar #'expand-file-name org-bootstrap-publish-source-files))
   (org-bootstrap-publish-source-file
    (list (expand-file-name org-bootstrap-publish-source-file)))))

(defun org-bootstrap-publish--parse-all (files)
  "Parse every file in FILES and return a single newest-first post list.
Each file's posts share the same shape as the single-file path; the
combined list is re-sorted by date so cross-file ordering is correct."
  (let (all)
    (dolist (f files)
      (setq all (append all (org-bootstrap-publish--parse-posts f))))
    (sort all
          (lambda (a b)
            (let ((da (plist-get a :date))
                  (db (plist-get b :date)))
              (cond ((and da db) (time-less-p db da))
                    (da t)
                    (db nil)
                    (t nil)))))))

(defconst org-bootstrap-publish--batch-face-colors
  '((default                          . ("#dcdcdc" . "#1e1e1e"))
    (font-lock-keyword-face           . "#569cd6")
    (font-lock-string-face            . "#ce9178")
    (font-lock-comment-face           . "#6a9955")
    (font-lock-comment-delimiter-face . "#6a9955")
    (font-lock-doc-face               . "#6a9955")
    (font-lock-function-name-face     . "#dcdcaa")
    (font-lock-variable-name-face     . "#9cdcfe")
    (font-lock-constant-face          . "#4ec9b0")
    (font-lock-builtin-face           . "#c586c0")
    (font-lock-type-face              . "#4ec9b0")
    (font-lock-warning-face           . "#f44747")
    (font-lock-preprocessor-face      . "#c586c0")
    (font-lock-negation-char-face     . "#f44747"))
  "Hardcoded colours for common font-lock faces in batch builds.
`emacs --batch' has no display, so themes never set face
foregrounds and `htmlize' produces colourless spans.  We force
explicit colours via `set-face-attribute' (which works without a
frame) so source blocks render with VS-Code-ish dark colours.")

(defun org-bootstrap-publish--ensure-batch-faces ()
  "Force explicit colours on font-lock faces when running in batch.
No-op when interactive or when a display is available."
  (when (and noninteractive (zerop (display-color-cells)))
    (dolist (entry org-bootstrap-publish--batch-face-colors)
      (let ((face (car entry))
            (val  (cdr entry)))
        (if (consp val)
            (set-face-attribute face nil :foreground (car val) :background (cdr val))
          (set-face-attribute face nil :foreground val))))))

;;;###autoload
(defun org-bootstrap-publish (&optional source-file output-dir preview)
  "Publish SOURCE-FILE to OUTPUT-DIR.
With no arguments, parse every file in
`org-bootstrap-publish-source-files' if set, otherwise the
singleton `org-bootstrap-publish-source-file' (or the current org
buffer).  Output goes to `org-bootstrap-publish-output-dir'.
When PREVIEW is non-nil, truncate the post list to
`org-bootstrap-publish-preview-limit' most-recent posts before
writing; this is used by `org-bootstrap-publish-serve-preview' for
fast local iteration.  Full publishes always pass nil for PREVIEW."
  (interactive)
  (org-bootstrap-publish--ensure-batch-faces)
  (let* ((files (cond
                 (source-file (list (expand-file-name source-file)))
                 ((org-bootstrap-publish--source-files))
                 ((and (derived-mode-p 'org-mode) buffer-file-name)
                  (list buffer-file-name))
                 (t (user-error "Set `org-bootstrap-publish-source-files' or `-source-file' first"))))
         (src (car files))
         (out (or output-dir org-bootstrap-publish-output-dir))
         (_   (org-bootstrap-publish--mkdir out))
         (org-bootstrap-publish--cache-current-dir
          (org-bootstrap-publish--cache-effective-dir out))
         (org-bootstrap-publish--cache-used
          (and org-bootstrap-publish--cache-current-dir
               (make-hash-table :test 'equal)))
         (org-bootstrap-publish--cache-hits 0)
         (org-bootstrap-publish--cache-misses 0)
         (org-bootstrap-publish--card-memo (make-hash-table :test 'eq))
         (org-bootstrap-publish--feed-entry-memo (make-hash-table :test 'eq))
         (org-bootstrap-publish--menu-entries-cache
          (org-bootstrap-publish--all-menu-entries))
         (all-posts (org-bootstrap-publish--parse-all files))
         (limit (and preview
                     (natnump org-bootstrap-publish-preview-limit)
                     org-bootstrap-publish-preview-limit))
         (posts (if limit
                   (let ((n (min limit (length all-posts))))
                     (message "org-bootstrap-publish: preview — using %d of %d posts" n (length all-posts))
                     (cl-subseq all-posts 0 n))
                 all-posts))
         (tag-counts (org-bootstrap-publish--collect-tags posts)))
    (message "org-bootstrap-publish: parsed %d posts from %d source%s"
             (length all-posts) (length files)
             (if (= 1 (length files)) "" "s"))
    (let ((i 0) (total (length posts))
          (newer nil) (cur posts))
      (while cur
        (cl-incf i)
        (when (zerop (mod i 50))
          (message "org-bootstrap-publish: rendering post %d/%d" i total))
        (let ((p (car cur)) (older (cadr cur)))
          (org-bootstrap-publish--write-post p out src newer older)
          (setq newer p cur (cdr cur)))))
    (org-bootstrap-publish--write-listings posts tag-counts out)
    (org-bootstrap-publish--copy-assets out)
    (org-bootstrap-publish--copy-static src out)
    (let ((swept (org-bootstrap-publish--cache-sweep)))
      (when org-bootstrap-publish--cache-current-dir
        (message "org-bootstrap-publish: cache %d hit%s, %d miss%s, %d swept (%s)"
                 org-bootstrap-publish--cache-hits
                 (if (= 1 org-bootstrap-publish--cache-hits) "" "s")
                 org-bootstrap-publish--cache-misses
                 (if (= 1 org-bootstrap-publish--cache-misses) "" "es")
                 swept org-bootstrap-publish--cache-current-dir)))
    (message "org-bootstrap-publish: wrote %d posts and %d tags to %s"
             (length posts) (length tag-counts) out)))

;;;; Async build

(defcustom org-bootstrap-publish-extra-load-path nil
  "Extra directories to add to `load-path' in async/batch builds.
The async child runs with `emacs --batch -Q', so packages installed
in your user directory (e.g. `htmlize') are not on the path.  Add
their directories here so the child can load them.  When nil, the
package tries to locate `htmlize' automatically from the parent
Emacs session."
  :type '(choice (const :tag "Auto-detect" nil)
                 (repeat directory)))

(defcustom org-bootstrap-publish-async-init-files nil
  "Extra Elisp files to load in async/batch builds.
The async child runs with `emacs --batch -Q' and does not load
user init, so custom shortcode handlers defined outside this package
are unavailable.  List the files containing those handlers here
\(e.g. `\"~/.emacs.d/obp-shortcodes.el\"').  Each file is loaded
with `load' after the package and custom values are set up."
  :type '(repeat file))

(defvar org-bootstrap-publish--async-process nil
  "Running async build subprocess, or nil.")

(defvar org-bootstrap-publish--async-buffer-name "*obp-build*"
  "Name of the buffer that captures stdout+stderr of the async build.")

(defconst org-bootstrap-publish--async-vars
  '(org-bootstrap-publish-site-title
    org-bootstrap-publish-site-tagline
    org-bootstrap-publish-site-url
    org-bootstrap-publish-site-path
    org-bootstrap-publish-author
    org-bootstrap-publish-date-format
    org-bootstrap-publish-posts-per-page
    org-bootstrap-publish-exclude-tags
    org-bootstrap-publish-static-dirs
    org-bootstrap-publish-bootstrap-css
    org-bootstrap-publish-bootstrap-js
    org-bootstrap-publish-highlight-css
    org-bootstrap-publish-highlight-js
    org-bootstrap-publish-publish-todo-states
    org-bootstrap-publish-asset-file
    org-bootstrap-publish-menu-tags
    org-bootstrap-publish-menu-links
    org-bootstrap-publish-source-files
    org-bootstrap-publish-cache-dir
    org-bootstrap-publish-disqus-shortname
    org-bootstrap-publish-layout
    org-bootstrap-publish-theme-overrides
    org-bootstrap-publish-background-image
    org-bootstrap-publish-background-blur
    org-bootstrap-publish-background-opacity
    org-bootstrap-publish-htmlize-output-type
    org-bootstrap-publish-shortcodes
    org-bootstrap-publish-preview-limit
    org-bootstrap-publish-async-init-files
    org-bootstrap-publish--emit-live-reload)
  "Customisation vars propagated to the async build subprocess.")

(defun org-bootstrap-publish--library-dir ()
  "Directory containing this library's `.el' file."
  (file-name-directory
   (or (symbol-file 'org-bootstrap-publish)
       (locate-library "org-bootstrap-publish")
       (user-error "Cannot locate org-bootstrap-publish on load-path"))))

(defun org-bootstrap-publish--async-eval-form (src out &optional preview)
  "Build the `--eval' string run inside the child Emacs.
Replays every custom in `org-bootstrap-publish--async-vars' then
invokes the synchronous entry point.  When the parent has a
multi-source list configured, that takes precedence; SRC is only
forwarded for single-source builds so the child uses the same file
the parent intended.  PREVIEW is forwarded as the third arg to
`org-bootstrap-publish' so the child honours
`org-bootstrap-publish-preview-limit'."
  (when (cl-some (lambda (entry) (not (symbolp (cdr entry))))
                 org-bootstrap-publish-shortcodes)
    (display-warning
     'org-bootstrap-publish
     "Async builds can only replay shortcode handlers that are named \
function symbols.  Anonymous lambdas in \
`org-bootstrap-publish-shortcodes' may not survive transfer to the \
child process; define them in a file listed in \
`org-bootstrap-publish-async-init-files' and reference them by symbol."
     :warning))
  (let ((forwarded (if org-bootstrap-publish-source-files nil src))
        (init-loads (and org-bootstrap-publish-async-init-files
                         (mapconcat
                          (lambda (f) (format "(load %S)" f))
                          org-bootstrap-publish-async-init-files " "))))
    (format "(progn %s %s (org-bootstrap-publish %S %S %s))"
            (mapconcat (lambda (v)
                         (format "(setq %s '%S)" v (symbol-value v)))
                       org-bootstrap-publish--async-vars
                       " ")
            (or init-loads "")
            forwarded out (if preview t nil))))

(defun org-bootstrap-publish--extra-load-dirs ()
  "Return list of extra load-path directories for async builds.
Uses `org-bootstrap-publish-extra-load-path' if set; otherwise
auto-detects the directory containing `htmlize'."
  (or org-bootstrap-publish-extra-load-path
      (let ((dir (or (and (featurep 'htmlize)
                          (locate-library "htmlize"))
                     ;; The load-time soft-require might have missed
                     ;; htmlize (e.g. package.el not yet initialised).
                     ;; Retry now — this is a no-op if already loaded.
                     (and (require 'htmlize nil t)
                          (locate-library "htmlize")))))
        (when dir (list (file-name-directory dir))))))

(defun org-bootstrap-publish--async-filter (proc string)
  "Append STRING to PROC's buffer and surface progress lines."
  (let ((buf (process-buffer proc)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (goto-char (point-max))
        (insert string))))
  (dolist (line (split-string string "\n" t))
    (when (string-match-p "\\`org-bootstrap-publish:" line)
      (message "%s" line))))

(defun org-bootstrap-publish--async-sentinel (proc _event)
  "Process sentinel for the async build PROC: report status, run callback."
  (when (memq (process-status proc) '(exit signal))
    (let ((rc (process-exit-status proc))
          (callback (process-get proc 'obp-callback))
          (t0       (process-get proc 'obp-start-time)))
      (setq org-bootstrap-publish--async-process nil)
      (cond
       ((zerop rc)
        (message "org-bootstrap-publish: build complete (%.1fs)"
                 (- (float-time) t0))
        (when callback (funcall callback nil)))
       (t
        (message "org-bootstrap-publish: build FAILED (exit %d) — see %s"
                 rc org-bootstrap-publish--async-buffer-name)
        (when callback (funcall callback (format "exit %d" rc))))))))

;;;###autoload
(defun org-bootstrap-publish-async (&optional source-file output-dir callback buffer preview)
  "Build the site asynchronously in a child `emacs --batch' subprocess.
SOURCE-FILE and OUTPUT-DIR default to the configured customs.
CALLBACK, if non-nil, is called on completion with nil on success
or an error string on failure.  BUFFER defaults to
`org-bootstrap-publish--async-buffer-name'.  Progress is streamed to
the echo area; full subprocess output lives in BUFFER.
When PREVIEW is non-nil, the child build honours
`org-bootstrap-publish-preview-limit', writing only the N most-recent
posts for faster local iteration."
  (interactive)
  (when (process-live-p org-bootstrap-publish--async-process)
    (user-error "An async build is already running"))
  (let* ((src (or source-file
                  (car (org-bootstrap-publish--source-files))
                  (and (derived-mode-p 'org-mode) buffer-file-name)
                  (user-error "Set `org-bootstrap-publish-source-files' or `-source-file' first")))
         (out (or output-dir
                  org-bootstrap-publish-output-dir
                  (user-error "Set `org-bootstrap-publish-output-dir' first")))
          (pkg-dir (org-bootstrap-publish--library-dir))
          (extra-dirs (org-bootstrap-publish--extra-load-dirs))
          (buf (get-buffer-create (or buffer org-bootstrap-publish--async-buffer-name)))
          (emacs (expand-file-name invocation-name invocation-directory))
          (eval-form (org-bootstrap-publish--async-eval-form
                      (expand-file-name src)
                      (expand-file-name out)
                      preview)))
     (with-current-buffer buf
       (erase-buffer)
       (insert (format "$ %s --batch -Q %s -l org-bootstrap-publish \\\n  --eval %s\n\n"
                       emacs
                       (mapconcat (lambda (d) (format "-L %s" d))
                                  (cons pkg-dir extra-dirs) " ")
                       eval-form)))
    (message "org-bootstrap-publish: starting %sbuild..."
             (if preview "preview " ""))
    (let* ((use-publish-buffer (and buffer
                                    (not (equal buffer org-bootstrap-publish--async-buffer-name))))
           (cmd (append (list emacs "--batch" "-Q")
                        (cl-mapcan (lambda (d) (list "-L" d))
                                   (cons pkg-dir extra-dirs))
                        (list "-l" "org-bootstrap-publish"
                              "--eval" eval-form)))
           (proc
            (make-process
             :name "obp-build"
             :buffer buf
             :command cmd
             :filter (if use-publish-buffer
                         #'org-bootstrap-publish--publish-filter
                       #'org-bootstrap-publish--async-filter)
             :sentinel #'org-bootstrap-publish--async-sentinel
             :connection-type 'pipe)))
      (process-put proc 'obp-callback callback)
      (process-put proc 'obp-start-time (float-time))
      (set-process-query-on-exit-flag proc nil)
      (setq org-bootstrap-publish--async-process proc))))

;;;###autoload
(defun org-bootstrap-publish-async-abort ()
  "Abort the currently running async build, if any."
  (interactive)
  (if (process-live-p org-bootstrap-publish--async-process)
      (progn (delete-process org-bootstrap-publish--async-process)
             (message "org-bootstrap-publish: async build aborted"))
    (message "org-bootstrap-publish: no async build running")))

;;;; Dev server

(defcustom org-bootstrap-publish-serve-port 8080
  "Port for `org-bootstrap-publish-serve'."
  :type 'integer)

(defcustom org-bootstrap-publish-serve-browser nil
  "Browser command for `org-bootstrap-publish-serve' and `serve-preview'.
When non-nil, used as the first argument to `start-process' to
open the preview URL.  Examples: \"firefox\", \"google-chrome\",
\"chromium\".  When nil, `browse-url' is used (which obeys
`browse-url-browser-function')."
  :type '(choice (const :tag "Default (browse-url)" nil)
                 (string :tag "Browser command")))

(defvar org-bootstrap-publish--server-process nil
  "Running HTTP server process, or nil.")

(defun org-bootstrap-publish--current-post-title ()
  "Title of the level-1 heading containing point, or nil."
  (condition-case nil
      (save-excursion
        (org-back-to-heading t)
        (while (> (org-current-level) 1)
          (org-up-heading-safe))
        (org-get-heading t t t t))
    (error nil)))

(defun org-bootstrap-publish--source-buffer-p ()
  "Non-nil if the current buffer is visiting any configured source file."
  (and buffer-file-name
       (let ((files (org-bootstrap-publish--source-files)))
         (cl-some (lambda (f) (file-equal-p buffer-file-name f)) files))))

(defun org-bootstrap-publish--install-save-hook ()
  "Install the rebuild-on-save hook if this buffer is the source file.
Suitable for `find-file-hook'."
  (when (org-bootstrap-publish--source-buffer-p)
    (add-hook 'after-save-hook
              #'org-bootstrap-publish-rebuild-current-post nil t)))

;;;###autoload
(defun org-bootstrap-publish-rebuild-current-post ()
  "Rebuild the post at point plus all listings.
Intended as an `after-save-hook' while editing the source file.
When `org-bootstrap-publish-preview-limit' is set, only the current
source file is parsed and the post list is truncated to the limit,
keeping the rebuild fast."
  (interactive)
  (let* ((all-files (or (org-bootstrap-publish--source-files)
                        (and (org-bootstrap-publish--source-buffer-p)
                             (list buffer-file-name))
                        (user-error "Set `org-bootstrap-publish-source-files' or `-source-file' first")))
         (preview-p (and org-bootstrap-publish-preview-limit
                         (natnump org-bootstrap-publish-preview-limit)))
         (files (if preview-p
                   (and (org-bootstrap-publish--source-buffer-p)
                        (list buffer-file-name))
                 all-files))
         (src   (car files))
         (out (or org-bootstrap-publish-output-dir
                  (user-error "Set `org-bootstrap-publish-output-dir' first")))
         (org-bootstrap-publish--cache-current-dir
          (org-bootstrap-publish--cache-effective-dir out))
         (org-bootstrap-publish--menu-entries-cache
          (org-bootstrap-publish--all-menu-entries))
         (title (and (org-bootstrap-publish--source-buffer-p)
                     (org-bootstrap-publish--current-post-title)))
         (all-posts (org-bootstrap-publish--parse-all files))
         (posts (if preview-p
                   (let ((n (min org-bootstrap-publish-preview-limit (length all-posts))))
                     (cl-subseq all-posts 0 n))
                 all-posts))
         (tag-counts (org-bootstrap-publish--collect-tags posts))
         (target (and title
                      (cl-find title posts
                               :key (lambda (p) (plist-get p :title))
                               :test #'string=)))
         (t0 (float-time)))
    (when target
      (let ((nb (org-bootstrap-publish--neighbours target posts)))
        (org-bootstrap-publish--write-post target out src (car nb) (cadr nb))))
    (org-bootstrap-publish--write-listings posts tag-counts out t)
    (org-bootstrap-publish--copy-assets out)
    (message "org-bootstrap-publish: rebuilt %s+ listings fast (%.2fs%s)"
             (if target (format "'%s' " title) "")
             (- (float-time) t0)
             (if preview-p " [preview]" ""))))

(defun org-bootstrap-publish--start-http-server (out port)
  "Spawn `python3 -m http.server' in OUT on PORT and record the process."
  (setq org-bootstrap-publish--server-process
        (start-process "obp-serve" "*obp-serve*"
                       "python3" "-m" "http.server"
                       "--directory" (expand-file-name out)
                       (number-to-string port)))
  (set-process-query-on-exit-flag
   org-bootstrap-publish--server-process nil))

;;;###autoload
(defun org-bootstrap-publish-serve (&optional port preview)
  "Build the site, serve it locally, and rebuild on save.
Kicks off an asynchronous full build via
`org-bootstrap-publish-async', then — once that finishes — runs
`python3 -m http.server' on PORT (default
`org-bootstrap-publish-serve-port'), opens the page in a browser,
and installs an `after-save-hook' on the source file's buffer so
saves trigger an incremental (synchronous, fast) rebuild.  Also
registers a `find-file-hook' so later visits of the source file
pick up the hook.  When PREVIEW is non-nil, only the
`org-bootstrap-publish-preview-limit' most-recent posts are built."
  (interactive (list (when current-prefix-arg
                       (read-number "Port: "
                                    org-bootstrap-publish-serve-port))))
  (let* ((port (or port org-bootstrap-publish-serve-port))
         (files (or (org-bootstrap-publish--source-files)
                    (and (derived-mode-p 'org-mode) buffer-file-name
                         (list buffer-file-name))
                    (user-error "Set `org-bootstrap-publish-source-files' or `-source-file' first")))
         (src (car files))
         (out (or org-bootstrap-publish-output-dir
                  (user-error "Set `org-bootstrap-publish-output-dir' first"))))
    ;; Dev serve: emit the live-reload poller (it drives rebuild-on-save).
    (setq org-bootstrap-publish--emit-live-reload t)
    (unless (or org-bootstrap-publish-source-file
                org-bootstrap-publish-source-files)
      (setq org-bootstrap-publish-source-file (expand-file-name src)))
    (when (process-live-p org-bootstrap-publish--server-process)
      (user-error "Server already running; call `org-bootstrap-publish-stop' first"))
    (unless (executable-find "python3")
      (user-error "python3 not found on PATH"))
    (org-bootstrap-publish-async
     src out
     (lambda (err)
       (if err
           (message "org-bootstrap-publish-serve: build failed (%s); server not started" err)
         (org-bootstrap-publish--start-http-server out port)
         (add-hook 'find-file-hook
                   #'org-bootstrap-publish--install-save-hook)
         (dolist (f files)
           (let ((buf (find-file-noselect f)))
             (with-current-buffer buf
               (add-hook 'after-save-hook
                         #'org-bootstrap-publish-rebuild-current-post nil t))))
          (if org-bootstrap-publish-serve-browser
              (start-process "obp-browse" nil org-bootstrap-publish-serve-browser
                             (format "http://localhost:%d/" port))
            (browse-url (format "http://localhost:%d/" port)))
         (message "org-bootstrap-publish-serve: serving %s on :%d%s; rebuild hook on %d source file%s (stop with M-x org-bootstrap-publish-stop)"
                  out port (if preview " (preview)" "")
                  (length files) (if (= 1 (length files)) "" "s"))))
     nil preview)))

;;;###autoload
(defun org-bootstrap-publish-serve-preview (&optional port)
  "Like `org-bootstrap-publish-serve', but only builds recent posts.
The number of posts built is controlled by
`org-bootstrap-publish-preview-limit' (default 10).  All other
behaviour — HTTP server, rebuild-on-save hook, browser launch — is
identical to a full serve.  Use this for fast local iteration when
you only care about the latest posts; run a full serve or publish
when you need the complete site."
  (interactive (list (when current-prefix-arg
                       (read-number "Port: "
                                    org-bootstrap-publish-serve-port))))
  (unless org-bootstrap-publish-preview-limit
    (setq org-bootstrap-publish-preview-limit 10))
  (org-bootstrap-publish-serve port t))

;;;###autoload
(defun org-bootstrap-publish-stop ()
  "Stop the dev HTTP server and disable rebuild-on-save.
Also aborts any running async build."
  (interactive)
  (when (process-live-p org-bootstrap-publish--async-process)
    (delete-process org-bootstrap-publish--async-process)
    (setq org-bootstrap-publish--async-process nil))
  (when (process-live-p org-bootstrap-publish--server-process)
    (delete-process org-bootstrap-publish--server-process))
  (setq org-bootstrap-publish--server-process nil)
  (remove-hook 'find-file-hook
               #'org-bootstrap-publish--install-save-hook)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (memq #'org-bootstrap-publish-rebuild-current-post
                  after-save-hook)
        (remove-hook 'after-save-hook
                     #'org-bootstrap-publish-rebuild-current-post t))))
  (message "org-bootstrap-publish: server stopped"))

;;;; Cloudflare Pages deploy

(defvar org-bootstrap-publish--publish-buffer-name "*obp-publish*"
  "Buffer for the publish command's async output.")

(defvar org-bootstrap-publish--deploy-process nil
  "Running wrangler deploy process, or nil.")

(defvar org-bootstrap-publish--publish-aborted nil
  "Non-nil when `org-bootstrap-publish-publish-abort' cancels a publish-all chain.")

(defun org-bootstrap-publish--publish-filter (proc string)
  "Append STRING to the publish buffer, stripping ANSI escapes.
Surfaces lines beginning with `org-bootstrap-publish:' in the echo
area.  Only moves point to the end if the window was already at the
bottom, so scrolling up to inspect output is not interrupted."
  (let ((buf (process-buffer proc))
        (clean (replace-regexp-in-string "\x1b\\[[?0-9;]*[A-Za-z]" "" string)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((win (get-buffer-window buf t))
              (at-bottom (eq (point) (point-max))))
          (save-excursion
            (goto-char (point-max))
            (insert clean))
          (when (and win at-bottom)
            (with-selected-window win
              (goto-char (point-max)))))))
    (dolist (line (split-string clean "\n" t))
      (when (string-match-p "\\`org-bootstrap-publish:" line)
        (message "%s" line)))))

(defun org-bootstrap-publish--wrangler-sentinel (proc _event)
  "Sentinel for async wrangler deploy."
  (setq org-bootstrap-publish--deploy-process nil)
  (when (memq (process-status proc) '(exit signal))
    (let ((buf (process-buffer proc))
          (exit (process-exit-status proc)))
      (with-current-buffer buf
        (goto-char (point-max))
        (if (zerop exit)
            (progn
              (insert "\n✔ deployed\n")
              (message "org-bootstrap-publish-publish: deployed ✓"))
          (insert (format "\n✘ wrangler exited with code %d\n" exit))
          (message "org-bootstrap-publish-publish: deploy failed (exit %d)" exit))))))

;;;###autoload
(defun org-bootstrap-publish-publish ()
  "Build the site asynchronously, then deploy to Cloudflare Pages via wrangler.
Runs `org-bootstrap-publish-async' to build, then spawns
`wrangler pages deploy' as an async process so Emacs stays
responsive throughout.

Requires `org-bootstrap-publish-cloudflare-project' to be set
and the wrangler CLI to be installed and authenticated.
Output is streamed to the *obp-publish* buffer."
  (interactive)
  (unless org-bootstrap-publish-cloudflare-project
    (user-error "Set `org-bootstrap-publish-cloudflare-project' first"))
  ;; Deploy build: omit the dev-only live-reload poller.
  (setq org-bootstrap-publish--emit-live-reload nil)
  (let ((output-dir (expand-file-name org-bootstrap-publish-output-dir))
        (project    org-bootstrap-publish-cloudflare-project)
        (branch     org-bootstrap-publish-cloudflare-branch)
        (wrangler   org-bootstrap-publish-wrangler-executable)
        (pub-buf    (get-buffer-create org-bootstrap-publish--publish-buffer-name)))
    (with-current-buffer pub-buf
      (erase-buffer)
      (insert (format "Publish → %s\n\n" project))
      (display-buffer pub-buf))
    (org-bootstrap-publish-async
     nil nil
     (lambda (err)
       (if err
           (with-current-buffer pub-buf
             (goto-char (point-max))
             (insert (format "\nBuild failed — %s\n" err)))
         (with-current-buffer pub-buf
           (goto-char (point-max))
           (insert (format "\nDeploying to %s ...\n" project)))
         (setq org-bootstrap-publish--deploy-process
               (make-process
                :name "obp-deploy"
                :buffer pub-buf
                :command (list wrangler
                               "pages" "deploy" output-dir
                               "--project-name" project
                               "--commit-dirty=true"
                               "--branch" branch)
                :filter #'org-bootstrap-publish--publish-filter
                :sentinel #'org-bootstrap-publish--wrangler-sentinel))))
     pub-buf)))

;;;###autoload
(defun org-bootstrap-publish-publish-abort ()
  "Abort the currently running publish (build or deploy) and stop any chain."
  (interactive)
  (setq org-bootstrap-publish--publish-aborted t)
  (cond
   ((process-live-p org-bootstrap-publish--deploy-process)
    (delete-process org-bootstrap-publish--deploy-process)
    (setq org-bootstrap-publish--deploy-process nil)
    (message "org-bootstrap-publish-publish: deploy aborted"))
   ((process-live-p org-bootstrap-publish--async-process)
    (delete-process org-bootstrap-publish--async-process)
    (setq org-bootstrap-publish--async-process nil)
    (message "org-bootstrap-publish-publish: build aborted"))
   (t
    (let ((procs (seq-filter
                  (lambda (p) (string-match-p "\\`obp-" (process-name p)))
                  (process-list))))
      (if procs
          (dolist (p procs)
            (delete-process p)
            (message "org-bootstrap-publish-publish: killed %s" (process-name p)))
        (message "org-bootstrap-publish-publish: nothing running"))))))

;;;; Site profiles

(defvar org-bootstrap-publish-sites nil
  "Alist of (NAME . PROFILE) for `org-bootstrap-publish-use-site'.
Each NAME is a symbol; each PROFILE is an alist of
\(SYMBOL . VALUE) pairs — the same shape accepted by
`org-bootstrap-publish-use-site'.  Consumers populate this
variable with their site definitions; the package itself leaves it
nil.")

(defun org-bootstrap-publish--managed-vars ()
  "Return list of all `org-bootstrap-publish-' defcustom symbols.
Auto-derived at runtime so adding a new defcustom to the package
automatically opts it into the profile-switching system."
  (let (vars)
    (mapatoms
     (lambda (sym)
       (when (and (custom-variable-p sym)
                  (string-prefix-p "org-bootstrap-publish-" (symbol-name sym))
                  (not (string-match-p "--" (symbol-name sym))))
         (push sym vars))))
    (nreverse vars)))

(defun org-bootstrap-publish-use-site (name-or-profile)
  "Reset every obp defcustom to its default, then apply a site profile.
NAME-OR-PROFILE is either a symbol (looked up in
`org-bootstrap-publish-sites') or an alist of (SYMBOL . VALUE) pairs.
Any symbol not in the profile keeps the package default."
  (interactive
   (list (intern (completing-read "Site: " org-bootstrap-publish-sites nil t))))
  (let ((profile (if (listp name-or-profile)
                     name-or-profile
                   (cdr (assq name-or-profile org-bootstrap-publish-sites)))))
    (unless profile (user-error "No such site: %s" name-or-profile))
    (dolist (sym (org-bootstrap-publish--managed-vars))
      (when-let ((std (get sym 'standard-value)))
        (set sym (eval (car std)))))
    (dolist (pair profile)
      (set (car pair) (cdr pair)))
    (message "obp: switched to %s"
             (or (alist-get 'org-bootstrap-publish-cloudflare-project profile)
                 (alist-get 'org-bootstrap-publish-site-title profile)
                 "profile"))))

;;;###autoload
(defun org-bootstrap-publish-serve-site (name)
  "Stop any running obp server, switch to site NAME, then serve it.
NAME is looked up in `org-bootstrap-publish-sites'."
  (interactive
   (list (intern (completing-read "Serve site: " org-bootstrap-publish-sites nil t))))
  (let ((profile (cdr (assq name org-bootstrap-publish-sites))))
    (unless profile (user-error "No such site: %s" name))
    (org-bootstrap-publish-stop)
    (org-bootstrap-publish-use-site profile)
    (org-bootstrap-publish-serve)))

;;;###autoload
(defun org-bootstrap-publish-serve-site-preview (name)
  "Stop any running obp server, switch to site NAME, then preview-serve it.
Like `org-bootstrap-publish-serve-site' but only builds the
`org-bootstrap-publish-preview-limit' most-recent posts."
  (interactive
   (list (intern (completing-read "Preview site: " org-bootstrap-publish-sites nil t))))
  (let ((profile (cdr (assq name org-bootstrap-publish-sites))))
    (unless profile (user-error "No such site: %s" name))
    (org-bootstrap-publish-stop)
    (org-bootstrap-publish-use-site profile)
    (org-bootstrap-publish-serve-preview)))

;;;###autoload
(defun org-bootstrap-publish-publish-all ()
  "Build and publish all sites in `org-bootstrap-publish-sites' sequentially.
Sites without a `org-bootstrap-publish-cloudflare-project' entry
are skipped.  Output streams to the *obp-publish* buffer."
  (interactive)
  (setq org-bootstrap-publish--publish-aborted nil)
  ;; Deploy builds: omit the dev-only live-reload poller.
  (setq org-bootstrap-publish--emit-live-reload nil)
  (let ((remaining (mapcar #'car org-bootstrap-publish-sites))
        (failed 0)
        (pub-buf (get-buffer-create org-bootstrap-publish--publish-buffer-name)))
    (with-current-buffer pub-buf
      (erase-buffer)
      (insert "Publish all\n\n")
      (display-buffer pub-buf))
    (cl-labels
        ((deploy-next (dir proj br)
           (with-current-buffer pub-buf
             (goto-char (point-max))
             (insert (format "\nDeploying %s ...\n" proj)))
           (setq org-bootstrap-publish--deploy-process
                 (make-process
                  :name (format "obp-deploy-%s" proj)
                  :buffer pub-buf
                  :command (list org-bootstrap-publish-wrangler-executable
                                "pages" "deploy" dir
                                "--project-name" proj
                                "--commit-dirty=true"
                                "--branch" br)
                  :filter #'org-bootstrap-publish--publish-filter
                  :sentinel
                  (lambda (proc _event)
                    (when (memq (process-status proc) '(exit signal))
                      (setq org-bootstrap-publish--deploy-process nil)
                      (with-current-buffer pub-buf
                        (goto-char (point-max))
                        (if (zerop (process-exit-status proc))
                            (insert (format "✔ %s deployed\n" proj))
                          (setq failed (1+ failed))
                          (insert (format "✘ %s failed (exit %d)\n"
                                          proj (process-exit-status proc)))))
                      (if org-bootstrap-publish--publish-aborted
                          (with-current-buffer pub-buf
                            (goto-char (point-max))
                            (insert "\n⚠ Publish all aborted\n")
                            (message "obp: publish all aborted"))
                        (publish-next)))))))
         (publish-next ()
           (cond
            (org-bootstrap-publish--publish-aborted
             (with-current-buffer pub-buf
               (goto-char (point-max))
               (insert "\n⚠ Publish all aborted\n")
               (message "obp: publish all aborted")))
            ((not remaining)
             (with-current-buffer pub-buf
               (goto-char (point-max))
               (insert (format "\nPublish all done%s\n"
                               (if (> failed 0)
                                   (format " — %d failed" failed)
                                 "")))
               (message "obp: publish all done")))
            (t
             (let* ((name (car remaining))
                    (profile (cdr (assq name org-bootstrap-publish-sites))))
               (setq remaining (cdr remaining))
               (if (not (alist-get 'org-bootstrap-publish-cloudflare-project profile))
                   (progn
                     (with-current-buffer pub-buf
                       (goto-char (point-max))
                       (insert (format "Skipping %s (no cloudflare project)\n" name)))
                     (publish-next))
                 (org-bootstrap-publish-use-site profile)
                 (with-current-buffer pub-buf
                   (goto-char (point-max))
                   (insert (format "\n--- %s ---\n" name)))
                 (org-bootstrap-publish-async
                  nil nil
                  (lambda (err)
                    (if org-bootstrap-publish--publish-aborted
                        (with-current-buffer pub-buf
                          (goto-char (point-max))
                          (insert "\n⚠ Publish all aborted\n")
                          (message "obp: publish all aborted"))
                      (if err
                          (progn
                            (setq failed (1+ failed))
                            (with-current-buffer pub-buf
                              (goto-char (point-max))
                              (insert (format "Build failed — %s\n" err)))
                            (publish-next))
                        (deploy-next
                         (expand-file-name org-bootstrap-publish-output-dir)
                         org-bootstrap-publish-cloudflare-project
                         org-bootstrap-publish-cloudflare-branch))))
                  pub-buf)))))))
      (publish-next))))

;;;###autoload
(defun org-bootstrap-publish-clean-site (name)
  "Deploy a placeholder page to wipe the Cloudflare site for NAME.
NAME is looked up in `org-bootstrap-publish-sites'."
  (interactive
   (list (intern (completing-read "Clean site: " org-bootstrap-publish-sites nil t))))
  (let* ((profile (cdr (assq name org-bootstrap-publish-sites)))
         (project (alist-get 'org-bootstrap-publish-cloudflare-project profile))
         (branch (or (alist-get 'org-bootstrap-publish-cloudflare-branch profile) "production"))
         (dir (make-temp-file "obp-clean-" t))
         (pub-buf (get-buffer-create org-bootstrap-publish--publish-buffer-name)))
    (unless project (user-error "No cloudflare project for site %s" name))
    (write-region "<!DOCTYPE html><html><body>Site cleaned — redeploy pending</body></html>"
                  nil (expand-file-name "index.html" dir))
    (with-current-buffer pub-buf
      (erase-buffer)
      (insert (format "Clean → %s\n\nDeploying placeholder ...\n" project))
      (display-buffer pub-buf))
    (make-process
     :name (format "obp-clean-%s" project)
     :buffer pub-buf
     :command (list org-bootstrap-publish-wrangler-executable
                    "pages" "deploy" dir
                    "--project-name" project
                    "--commit-dirty=true"
                    "--branch" branch)
     :filter #'org-bootstrap-publish--publish-filter
     :sentinel (lambda (proc _event)
                 (when (memq (process-status proc) '(exit signal))
                   (with-current-buffer pub-buf
                     (goto-char (point-max))
                     (if (zerop (process-exit-status proc))
                         (insert "\n✔ cleaned\n")
                       (insert (format "\n✘ clean failed (exit %d)\n"
                                       (process-exit-status proc)))))
                   ;; Clean up the throwaway placeholder dir.
                   (ignore-errors (delete-directory dir t)))))))

;;;###autoload
(defun org-bootstrap-publish-flush-site (name)
  "Purge the Cloudflare cache for site NAME.
NAME is looked up in `org-bootstrap-publish-sites'.  Requires
CLOUDFLARE_API_TOKEN and CLOUDFLARE_ZONE_<NAME> (uppercased) set
in the environment."
  (interactive
   (list (intern (completing-read "Flush site: " org-bootstrap-publish-sites nil t))))
  (let* ((profile (cdr (assq name org-bootstrap-publish-sites)))
         (project (alist-get 'org-bootstrap-publish-cloudflare-project profile))
         (zone-var (intern (format "CLOUDFLARE_ZONE_%s" (upcase (symbol-name name)))))
         (pub-buf (get-buffer-create org-bootstrap-publish--publish-buffer-name)))
    (unless project (user-error "No cloudflare project for site %s" name))
    (let ((zone-id (getenv (symbol-name zone-var)))
          (api-token (getenv "CLOUDFLARE_API_TOKEN")))
      (unless zone-id (user-error "%s not set" (symbol-name zone-var)))
      (unless api-token (user-error "CLOUDFLARE_API_TOKEN not set"))
      (with-current-buffer pub-buf
        (erase-buffer)
        (insert (format "Flush → %s\n\nPurging cache ...\n" project))
        (display-buffer pub-buf))
      (make-process
       :name (format "obp-flush-%s" project)
       :buffer pub-buf
       :command (list "curl" "-s" "-X" "POST"
                      (format "https://api.cloudflare.com/client/v4/zones/%s/purge_cache" zone-id)
                      "-H" (format "Authorization: Bearer %s" api-token)
                      "-H" "Content-Type: application/json"
                      "--data" "{\"purge_everything\":true}")
       :sentinel (lambda (proc _event)
                   (when (memq (process-status proc) '(exit signal))
                     (with-current-buffer pub-buf
                       (goto-char (point-max))
                       (if (zerop (process-exit-status proc))
                           (insert "\n✔ cache flushed\n")
                         (insert (format "\n✘ flush failed (exit %d)\n"
                                         (process-exit-status proc)))))))))))

(provide 'org-bootstrap-publish)

;;; org-bootstrap-publish.el ends here
