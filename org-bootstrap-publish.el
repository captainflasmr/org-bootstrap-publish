;;; org-bootstrap-publish.el --- Generate a Bootstrap 5 site from a single Org file -*- lexical-binding: t; -*-

;; Copyright (C) 2026 James Dyer

;; Author: James Dyer <captainflasmr@gmail.com>
;; Version: 0.1.0
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
;;   EXPORT_FILE_NAME                -> post slug
;;   EXPORT_HUGO_SECTION             -> post section (used as URL prefix)
;;   EXPORT_HUGO_LASTMOD             -> post date
;;   EXPORT_HUGO_CUSTOM_FRONT_MATTER -> :thumbnail /path/to/image.jpg
;;
;; The `noexport' tag skips a heading.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'org)
(require 'org-element)
(require 'ox-html)
(require 'subr-x)
(require 'xml)

;;;; Customization

(defgroup org-bootstrap-publish nil
  "Generate a Bootstrap 5 site from a single Org file."
  :group 'org
  :prefix "org-bootstrap-publish-")

(defcustom org-bootstrap-publish-source-file nil
  "Org file to publish.  Each top-level heading becomes a post."
  :type '(choice (const :tag "Unset" nil) file))

(defcustom org-bootstrap-publish-output-dir
  (expand-file-name "public" default-directory)
  "Directory into which HTML is written."
  :type 'directory)

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
custom domain on GitHub Pages).  Use \"/repo-name/\" for a GitHub
Pages project site.  Must start and end with a slash."
  :type 'string)

(defcustom org-bootstrap-publish-author (or user-full-name "Anonymous")
  "Author name used in templates and the feed."
  :type 'string)

(defcustom org-bootstrap-publish-posts-per-page 24
  "Maximum number of posts on the index page."
  :type 'integer)

(defcustom org-bootstrap-publish-exclude-tags '("noexport")
  "Headings carrying any of these tags are skipped."
  :type '(repeat string))

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

(defcustom org-bootstrap-publish-deploy-dir nil
  "Local git checkout that `org-bootstrap-publish-publish' builds into.
This is just a regular clone of the repo that serves your site
(usually the branch GitHub Pages is configured to deploy from).
No `git worktree' or anything fancy required -- a plain
`git clone' is fine."
  :type '(choice (const :tag "Unset" nil) directory))

(defcustom org-bootstrap-publish-deploy-remote "origin"
  "Git remote used by `org-bootstrap-publish-publish'."
  :type 'string)

(defcustom org-bootstrap-publish-deploy-branch "main"
  "Git branch used by `org-bootstrap-publish-publish'."
  :type 'string)

(defcustom org-bootstrap-publish-publish-preserve '("CNAME" ".nojekyll")
  "Entries preserved in the deploy directory across publishes.
`.git' is always preserved."
  :type '(repeat string))

(defcustom org-bootstrap-publish-asset-file
  (expand-file-name "assets/style.css"
                    (file-name-directory
                     (or load-file-name buffer-file-name default-directory)))
  "Path to the stylesheet copied into the output as assets/style.css."
  :type 'file)

;;;; Utilities

(defun org-bootstrap-publish--escape (s)
  "HTML-escape S for use in text or attributes."
  (if (null s) ""
    (xml-escape-string (format "%s" s))))

(defun org-bootstrap-publish--slugify (s)
  (let ((x (downcase (or s ""))))
    (setq x (replace-regexp-in-string "[^a-z0-9]+" "-" x))
    (replace-regexp-in-string "\\(^-+\\|-+$\\)" "" x)))

(defun org-bootstrap-publish--parse-time (stamp)
  "Parse STAMP like \"<2026-04-21 15:30>\" to an Emacs time value, or nil."
  (when (and (stringp stamp) (not (string-empty-p stamp)))
    (ignore-errors (org-time-string-to-time stamp))))

(defun org-bootstrap-publish--iso (time)
  (when time (format-time-string "%Y-%m-%dT%H:%M:%S%z" time)))

(defun org-bootstrap-publish--human-date (time)
  (when time (format-time-string "%B %-d, %Y" time)))

(defun org-bootstrap-publish--mkdir (dir)
  (unless (file-directory-p dir) (make-directory dir t)))

(defun org-bootstrap-publish--write (path content)
  (org-bootstrap-publish--mkdir (file-name-directory path))
  (with-temp-file path
    (set-buffer-file-coding-system 'utf-8)
    (insert content)))

;;;; Parsing

(defun org-bootstrap-publish--heading-props (heading)
  (let (result)
    (org-element-map (org-element-contents heading) 'node-property
      (lambda (np)
        (push (cons (org-element-property :key np)
                    (org-element-property :value np))
              result)))
    (nreverse result)))

(defun org-bootstrap-publish--strip-drawer (body)
  (replace-regexp-in-string
   "\\`[ \t]*:PROPERTIES:\n\\(?:.*\n\\)*?[ \t]*:END:[ \t]*\n?"
   "" body))

(defun org-bootstrap-publish--thumbnail (props)
  (let ((cfm (cdr (assoc "EXPORT_HUGO_CUSTOM_FRONT_MATTER+" props))))
    (when (and cfm (string-match ":thumbnail[[:space:]]+\\([^[:space:]]+\\)" cfm))
      (match-string 1 cfm))))

(defun org-bootstrap-publish--slug (title props)
  (downcase
   (or (cdr (assoc "EXPORT_FILE_NAME" props))
       (org-bootstrap-publish--slugify title))))

(defun org-bootstrap-publish--summary (body-org)
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
                       (thumb (org-bootstrap-publish--thumbnail props))
                       (summary (org-bootstrap-publish--summary body)))
                  (push (list :title title
                              :tags tags
                              :date date
                              :slug slug
                              :section section
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
  "Prefix local static/ image and link paths with the site path."
  (let ((sp (replace-regexp-in-string "\\\\" "\\\\\\\\"
                                      org-bootstrap-publish-site-path)))
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
           (let ((attrs (match-string 1 m))
                 (tail  (match-string 2 m)))
             (if (string-match-p "\\bclass=\"" attrs)
                 (format "<img%s%s>"
                         (replace-regexp-in-string
                          "\\bclass=\"\\([^\"]*\\)\""
                          "class=\"img-fluid rounded \\1\""
                          attrs)
                         tail)
               (format "<img class=\"img-fluid rounded\"%s%s>" attrs tail))))
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
  (when org-bootstrap-publish-highlight-js
    (setq html
          (replace-regexp-in-string
           "<pre class=\"src src-\\([^\"]+\\)\">\\(\\(?:.\\|\n\\)*?\\)</pre>"
           (lambda (m)
             (let ((lang (match-string 1 m))
                   (code (match-string 2 m)))
               (format "<pre><code class=\"language-%s\">%s</code></pre>"
                       lang code)))
           html nil t)))
  (org-bootstrap-publish--rewrite-static-src html))

(defun org-bootstrap-publish--org->html (body)
  "Render org BODY string to HTML via ox-html, body-only."
  (if (or (null body) (string-empty-p (string-trim body)))
      ""
    (let ((org-export-with-toc nil)
          (org-export-with-section-numbers nil)
          (org-export-with-broken-links t)
          (org-export-with-sub-superscripts '{})
          (org-html-htmlize-output-type nil)
          (org-html-container-element "section")
          (inhibit-message t))
      (org-bootstrap-publish--bootstrapify
       (org-export-string-as body 'html t)))))

;;;; Templates

(defun org-bootstrap-publish--url (&rest parts)
  (apply #'concat org-bootstrap-publish-site-path parts))

(defun org-bootstrap-publish--post-path (post)
  "Relative URL path (no leading slash) to POST's directory."
  (let ((section (plist-get post :section))
        (slug (plist-get post :slug)))
    (if (and section (not (string-empty-p section)))
        (concat section "/" slug "/")
      (concat slug "/"))))

(defun org-bootstrap-publish--post-url (post)
  (org-bootstrap-publish--url (org-bootstrap-publish--post-path post)))

(defun org-bootstrap-publish--tag-path (tag)
  "Relative URL path (no leading slash) to TAG's directory."
  (concat "tags/" (org-bootstrap-publish--slugify tag) "/"))

(defun org-bootstrap-publish--tag-url (tag)
  (org-bootstrap-publish--url (org-bootstrap-publish--tag-path tag)))

(defun org-bootstrap-publish--tag-pills (tags)
  (mapconcat
   (lambda (tag)
     (format "<a class=\"badge rounded-pill text-bg-secondary text-decoration-none me-1\" href=\"%s\">#%s</a>"
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

(defun org-bootstrap-publish--page (title body)
  (let ((bs-css   org-bootstrap-publish-bootstrap-css)
        (bs-js    org-bootstrap-publish-bootstrap-js)
        (hl-css   org-bootstrap-publish-highlight-css)
        (hl-js    org-bootstrap-publish-highlight-js)
        (site     (org-bootstrap-publish--escape org-bootstrap-publish-site-title))
        (tagline  (org-bootstrap-publish--escape org-bootstrap-publish-site-tagline))
        (author   (org-bootstrap-publish--escape org-bootstrap-publish-author))
        (year     (format-time-string "%Y")))
    (concat
     "<!doctype html>\n"
     "<html lang=\"en\">\n"
     "<head>\n"
     "<meta charset=\"utf-8\">\n"
     "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
     (format "<title>%s</title>\n" (org-bootstrap-publish--escape title))
     (format "<link rel=\"stylesheet\" href=\"%s\">\n" bs-css)
     (when hl-css (format "<link rel=\"stylesheet\" href=\"%s\">\n" hl-css))
     (format "<link rel=\"stylesheet\" href=\"%s\">\n"
             (org-bootstrap-publish--url "assets/style.css"))
     (format "<link rel=\"alternate\" type=\"application/atom+xml\" href=\"%s\" title=\"%s\">\n"
             (org-bootstrap-publish--url "index.xml") site)
     "</head>\n"
     "<body>\n"
     "<div class=\"site\">\n"
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
     (format "        <li><a href=\"%s\">RSS</a></li>\n"
             (org-bootstrap-publish--url "index.xml"))
     "      </ul></nav>\n"
     (format "      <p class=\"sidebar-footer\">&copy; %s %s</p>\n" year author)
     "    </div>\n"
     "  </aside>\n"
     "  <main class=\"content\">\n"
     "    <div class=\"content-inner\">\n"
     body
     "    </div>\n"
     "  </main>\n"
     "</div>\n"
     (format "<script src=\"%s\"></script>\n" bs-js)
     (when hl-js
       (concat (format "<script src=\"%s\"></script>\n" hl-js)
               "<script>hljs.highlightAll();</script>\n"))
     (format "<script src=\"%s\" defer></script>\n"
             (org-bootstrap-publish--url "assets/search.js"))
     "</body>\n"
     "</html>\n")))

(defun org-bootstrap-publish--card (post)
  (let* ((url    (org-bootstrap-publish--post-url post))
         (title  (org-bootstrap-publish--escape (plist-get post :title)))
         (date-h (org-bootstrap-publish--human-date (plist-get post :date)))
         (thumb  (org-bootstrap-publish--thumb-url (plist-get post :thumbnail)))
         (tags   (plist-get post :tags))
         (summary-html
          (org-bootstrap-publish--org->html (plist-get post :summary))))
    (concat
     "<div class=\"col-md-6 col-lg-4 mb-4\">\n"
     "<article class=\"card h-100 post-card\">\n"
     (if thumb
         (format "<a href=\"%s\" class=\"post-card-thumb\"><img src=\"%s\" class=\"card-img-top\" alt=\"\"></a>\n"
                 url thumb)
       "")
     "<div class=\"card-body\">\n"
     (format "<h3 class=\"card-title h5\"><a href=\"%s\" class=\"text-decoration-none\">%s</a></h3>\n"
             url title)
     (if date-h (format "<p class=\"card-subtitle text-muted small mb-2\">%s</p>\n" date-h) "")
     (format "<div class=\"card-text post-summary\">%s</div>\n" summary-html)
     (if tags
         (format "<div class=\"post-tags mt-3\">%s</div>\n"
                 (org-bootstrap-publish--tag-pills tags))
       "")
     "</div>\n"
     "</article>\n"
     "</div>\n")))

(defun org-bootstrap-publish--render-index (posts)
  (let* ((n (min org-bootstrap-publish-posts-per-page (length posts)))
         (recent (cl-subseq posts 0 n))
         (cards  (mapconcat #'org-bootstrap-publish--card recent "")))
    (concat
     "<header class=\"page-header mb-4\"><h2>Latest posts</h2></header>\n"
     "<div class=\"row\">\n"
     cards
     "</div>\n"
     (if (> (length posts) n)
         (format "<p class=\"text-center mt-3\"><a href=\"tags.html\">Browse all %d posts by tag &rarr;</a></p>\n"
                 (length posts))
       ""))))

(defun org-bootstrap-publish--render-post (post)
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
     "</article>\n")))

(defun org-bootstrap-publish--render-tag-page (tag posts)
  (let* ((tag-esc (org-bootstrap-publish--escape tag))
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
                 posts "")))
    (concat
     (format "<header class=\"page-header mb-4\"><h2>Posts tagged <code>#%s</code></h2>"
             tag-esc)
     (format "<p class=\"text-muted\">%d post%s</p></header>\n"
             (length posts) (if (= 1 (length posts)) "" "s"))
     "<ul class=\"post-list list-unstyled\">\n"
     items
     "</ul>\n")))

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
  (let ((links
         (mapconcat
          (lambda (tc)
            (let* ((tag (car tc))
                   (n   (cdr tc)))
              (format "<a class=\"badge rounded-pill text-bg-light text-decoration-none me-2 mb-2 p-2\" href=\"%s\">#%s <span class=\"badge text-bg-secondary\">%d</span></a>"
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
             (let* ((link (concat url (org-bootstrap-publish--post-path p)))
                    (date (org-bootstrap-publish--iso
                           (or (plist-get p :date) (current-time))))
                    (title (org-bootstrap-publish--escape (plist-get p :title)))
                    (content (org-bootstrap-publish--escape
                              (org-bootstrap-publish--org->html
                               (plist-get p :body)))))
               (format (concat "<entry>\n"
                               "<title>%s</title>\n"
                               "<link href=\"%s\"/>\n"
                               "<id>%s</id>\n"
                               "<updated>%s</updated>\n"
                               "<content type=\"html\">%s</content>\n"
                               "</entry>\n")
                       title link link date content)))
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
  (cl-remove-if-not
   (lambda (p) (member tag (plist-get p :tags)))
   posts))

(defun org-bootstrap-publish--copy-static (source-file out-dir)
  (dolist (name org-bootstrap-publish-static-dirs)
    (let ((src (expand-file-name name (file-name-directory source-file)))
          (dst (expand-file-name name out-dir)))
      (when (file-directory-p src)
        (copy-directory src dst nil t t)))))

(defun org-bootstrap-publish--copy-assets (out-dir)
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

(defun org-bootstrap-publish--write-post (post out)
  (org-bootstrap-publish--write
   (expand-file-name
    (concat (org-bootstrap-publish--post-path post) "index.html") out)
   (org-bootstrap-publish--page
    (format "%s | %s"
            (plist-get post :title)
            org-bootstrap-publish-site-title)
    (org-bootstrap-publish--render-post post))))

(defun org-bootstrap-publish--write-listings (posts tag-counts out)
  (org-bootstrap-publish--write
   (expand-file-name "index.html" out)
   (org-bootstrap-publish--page
    org-bootstrap-publish-site-title
    (org-bootstrap-publish--render-index posts)))
  (dolist (tc tag-counts)
    (let* ((tag (car tc))
           (tag-path (org-bootstrap-publish--tag-path tag))
           (matching (org-bootstrap-publish--posts-with-tag tag posts)))
      (org-bootstrap-publish--write
       (expand-file-name (concat tag-path "index.html") out)
       (org-bootstrap-publish--page
        (format "#%s | %s" tag org-bootstrap-publish-site-title)
        (org-bootstrap-publish--render-tag-page tag matching)))
      (org-bootstrap-publish--write
       (expand-file-name (concat tag-path "index.xml") out)
       (org-bootstrap-publish--feed
        matching
        (format "%s on %s" tag org-bootstrap-publish-site-title)
        tag-path))))
  (org-bootstrap-publish--write
   (expand-file-name "posts.html" out)
   (org-bootstrap-publish--page
    (format "All posts | %s" org-bootstrap-publish-site-title)
    (org-bootstrap-publish--render-archive posts)))
  (org-bootstrap-publish--write
   (expand-file-name "tags.html" out)
   (org-bootstrap-publish--page
    (format "Tags | %s" org-bootstrap-publish-site-title)
    (org-bootstrap-publish--render-tags-index tag-counts)))
  (let ((feed (org-bootstrap-publish--feed posts)))
    (org-bootstrap-publish--write
     (expand-file-name "index.xml" out) feed)
    (org-bootstrap-publish--write
     (expand-file-name "feed.xml" out) feed))
  (org-bootstrap-publish--write
   (expand-file-name "index.json" out)
   (org-bootstrap-publish--index-json posts)))

;;;###autoload
(defun org-bootstrap-publish (&optional source-file output-dir)
  "Publish SOURCE-FILE to OUTPUT-DIR.
With no arguments, use `org-bootstrap-publish-source-file' (or the
current org buffer) and `org-bootstrap-publish-output-dir'."
  (interactive)
  (let* ((src (or source-file
                  (and (derived-mode-p 'org-mode) buffer-file-name)
                  org-bootstrap-publish-source-file
                  (user-error "Set `org-bootstrap-publish-source-file' or call from an org buffer")))
         (out (or output-dir org-bootstrap-publish-output-dir))
         (_   (org-bootstrap-publish--mkdir out))
         (posts (org-bootstrap-publish--parse-posts src))
         (tag-counts (org-bootstrap-publish--collect-tags posts)))
    (message "org-bootstrap-publish: parsed %d posts" (length posts))
    (let ((i 0) (total (length posts)))
      (dolist (p posts)
        (cl-incf i)
        (when (zerop (mod i 20))
          (message "org-bootstrap-publish: rendering post %d/%d" i total))
        (org-bootstrap-publish--write-post p out)))
    (org-bootstrap-publish--write-listings posts tag-counts out)
    (org-bootstrap-publish--copy-assets out)
    (org-bootstrap-publish--copy-static src out)
    (message "org-bootstrap-publish: wrote %d posts and %d tags to %s"
             (length posts) (length tag-counts) out)))

;;;; Dev server

(defcustom org-bootstrap-publish-serve-port 8080
  "Port for `org-bootstrap-publish-serve'."
  :type 'integer)

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
  "Non-nil if the current buffer is visiting the configured source file."
  (and buffer-file-name
       org-bootstrap-publish-source-file
       (file-equal-p
        buffer-file-name
        (expand-file-name org-bootstrap-publish-source-file))))

(defun org-bootstrap-publish--install-save-hook ()
  "Install the rebuild-on-save hook if this buffer is the source file.
Suitable for `find-file-hook'."
  (when (org-bootstrap-publish--source-buffer-p)
    (add-hook 'after-save-hook
              #'org-bootstrap-publish-rebuild-current-post nil t)))

;;;###autoload
(defun org-bootstrap-publish-rebuild-current-post ()
  "Rebuild the post at point plus all listings.
Intended as an `after-save-hook' while editing the source file."
  (interactive)
  (let* ((src (or (and (org-bootstrap-publish--source-buffer-p)
                       buffer-file-name)
                  org-bootstrap-publish-source-file
                  (user-error "Set `org-bootstrap-publish-source-file' first")))
         (out (or org-bootstrap-publish-output-dir
                  (user-error "Set `org-bootstrap-publish-output-dir' first")))
         (title (and (org-bootstrap-publish--source-buffer-p)
                     (org-bootstrap-publish--current-post-title)))
         (posts (org-bootstrap-publish--parse-posts src))
         (tag-counts (org-bootstrap-publish--collect-tags posts))
         (target (and title
                      (cl-find title posts
                               :key (lambda (p) (plist-get p :title))
                               :test #'string=)))
         (t0 (float-time)))
    (when target
      (org-bootstrap-publish--write-post target out))
    (org-bootstrap-publish--write-listings posts tag-counts out)
    (message "org-bootstrap-publish: rebuilt %s+ listings (%.2fs)"
             (if target (format "'%s' " title) "")
             (- (float-time) t0))))

;;;###autoload
(defun org-bootstrap-publish-serve (&optional port)
  "Build the site, serve it locally, and rebuild on save.
Runs `python3 -m http.server' in the output directory on PORT
(default `org-bootstrap-publish-serve-port'), opens the page in a
browser, and installs an `after-save-hook' on the source file's
buffer (visiting it if necessary) so saves trigger an incremental
rebuild.  Also registers a `find-file-hook' so later visits of the
source file pick up the hook."
  (interactive (list (when current-prefix-arg
                       (read-number "Port: "
                                    org-bootstrap-publish-serve-port))))
  (let* ((port (or port org-bootstrap-publish-serve-port))
         (src (or org-bootstrap-publish-source-file
                  (and (derived-mode-p 'org-mode) buffer-file-name)
                  (user-error "Set `org-bootstrap-publish-source-file' first")))
         (out (or org-bootstrap-publish-output-dir
                  (user-error "Set `org-bootstrap-publish-output-dir' first"))))
    (unless org-bootstrap-publish-source-file
      (setq org-bootstrap-publish-source-file (expand-file-name src)))
    (when (process-live-p org-bootstrap-publish--server-process)
      (user-error "Server already running; call `org-bootstrap-publish-stop' first"))
    (unless (executable-find "python3")
      (user-error "python3 not found on PATH"))
    (org-bootstrap-publish src out)
    (setq org-bootstrap-publish--server-process
          (start-process "obp-serve" "*obp-serve*"
                         "python3" "-m" "http.server"
                         "--directory" (expand-file-name out)
                         (number-to-string port)))
    (set-process-query-on-exit-flag
     org-bootstrap-publish--server-process nil)
    (add-hook 'find-file-hook
              #'org-bootstrap-publish--install-save-hook)
    (let ((buf (find-file-noselect src)))
      (with-current-buffer buf
        (add-hook 'after-save-hook
                  #'org-bootstrap-publish-rebuild-current-post nil t))
      (browse-url (format "http://localhost:%d/" port))
      (message "org-bootstrap-publish-serve: serving %s on :%d; rebuild hook on %s (stop with M-x org-bootstrap-publish-stop)"
               out port (buffer-name buf)))))

;;;###autoload
(defun org-bootstrap-publish-stop ()
  "Stop the dev HTTP server and disable rebuild-on-save."
  (interactive)
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

;;;; Git publish

(defun org-bootstrap-publish--git (dir &rest args)
  "Run git ARGS in DIR, return stdout; signal error on non-zero exit."
  (with-temp-buffer
    (let* ((default-directory (file-name-as-directory dir))
           (exit (apply #'call-process "git" nil t nil args)))
      (unless (zerop exit)
        (error "git %s failed in %s:\n%s"
               (mapconcat #'identity args " ") dir (buffer-string)))
      (string-trim (buffer-string)))))

(defun org-bootstrap-publish--clean-worktree (wt)
  (let ((keep (cons ".git" org-bootstrap-publish-publish-preserve)))
    (dolist (entry (directory-files wt t directory-files-no-dot-files-regexp))
      (unless (member (file-name-nondirectory entry) keep)
        (if (file-directory-p entry)
            (delete-directory entry t)
          (delete-file entry))))))

;;;###autoload
(defun org-bootstrap-publish-publish ()
  "Build the site into `org-bootstrap-publish-deploy-dir' and push it.
Removes stale files (preserving `.git' and
`org-bootstrap-publish-publish-preserve'), runs
`org-bootstrap-publish', commits with a timestamped message, and
pushes to
`org-bootstrap-publish-deploy-remote'/`-deploy-branch'.

If the deploy dir has no changes after the build, nothing is
committed or pushed."
  (interactive)
  (let ((dir org-bootstrap-publish-deploy-dir))
    (unless dir
      (user-error "Set `org-bootstrap-publish-deploy-dir' first"))
    (unless (file-exists-p (expand-file-name ".git" dir))
      (user-error "%s is not a git checkout (no .git)" dir))
    (message "org-bootstrap-publish-publish: cleaning %s" dir)
    (org-bootstrap-publish--clean-worktree dir)
    (org-bootstrap-publish nil dir)
    (org-bootstrap-publish--git dir "add" "-A")
    (let ((status (org-bootstrap-publish--git dir "status" "--porcelain")))
      (if (string-empty-p status)
          (message "org-bootstrap-publish-publish: no changes to publish")
        (let ((msg (format "Publish %s"
                           (format-time-string "%Y-%m-%d %H:%M:%S"))))
          (org-bootstrap-publish--git dir "commit" "-m" msg)
          (org-bootstrap-publish--git dir "push"
                                      org-bootstrap-publish-deploy-remote
                                      org-bootstrap-publish-deploy-branch)
          (message "org-bootstrap-publish-publish: pushed to %s/%s"
                   org-bootstrap-publish-deploy-remote
                   org-bootstrap-publish-deploy-branch))))))

(provide 'org-bootstrap-publish)

;;; org-bootstrap-publish.el ends here
