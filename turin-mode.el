;;; turin-mode.el --- Play guided codebase tours -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Alex Afshar
;;
;; Author: Alex Afshar
;; Maintainer: Alex Afshar
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools, convenience
;; URL: https://github.com/afsharalex/turin-mode
;; License: MIT
;; SPDX-License-Identifier: MIT
;;
;; This file is not part of GNU Emacs.

;;; Commentary:
;;
;; Plays guided tours of a codebase.  A tour lives in a `.turin/'
;; directory at the project root and consists of:
;;
;;   .turin/tour.json    -- ordered list of stop filenames + metadata
;;   .turin/<stop>.md    -- one stop per file (markdown body with TOML
;;                          frontmatter for `file', `anchor', etc.)
;;
;; Run `M-x turin-start' from anywhere in the project to begin.  The
;; commentary appears in a side window; the source buffer for each stop
;; jumps cursor to the resolved anchor and overlays a highlight on the
;; relevant region.
;;
;; While a tour is active, the commentary buffer enables
;; `turin-commentary-mode' which binds:
;;
;;   n        next stop
;;   p        previous stop
;;   g        goto stop by index
;;   l        list stops in the minibuffer
;;   q        quit the tour
;;
;; The source buffer gets no key rebindings, so you can read and edit
;; freely while the commentary is up.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'subr-x)

(defgroup turin nil
  "Codebase tour playback."
  :group 'tools
  :prefix "turin-")

(defcustom turin-commentary-side 'right
  "Side of the frame on which to display the commentary window."
  :type '(choice (const left) (const right) (const top) (const bottom))
  :group 'turin)

(defcustom turin-commentary-size 0.4
  "Fractional size of the commentary window.
Width when `turin-commentary-side' is `left' or `right'; height otherwise."
  :type 'number
  :group 'turin)

(defface turin-highlight-face
  '((((background dark)) :background "#3a3a4e" :extend t)
    (((background light)) :background "#dbe2ff" :extend t))
  "Face used to highlight the anchor region in the source buffer."
  :group 'turin)

;;; ----- state -----

(cl-defstruct turin--state
  tour                  ;; alist: ((meta . _) (stops . _) (turin-dir . _) (project-root . _))
  index                 ;; 1-based index of the current stop
  source-buffer
  source-window
  commentary-buffer
  overlays)

(defvar turin--state nil
  "Current session, or nil if no tour is running.")

(defun turin--active-p ()
  (not (null turin--state)))

;;; ----- locating the tour -----

(defun turin--find-dir ()
  "Locate the nearest `.turin/' directory upward from the current buffer.
Returns the absolute path, or nil if not found."
  (let* ((start (or buffer-file-name default-directory))
         (root (locate-dominating-file start ".turin")))
    (when root
      (file-name-as-directory (expand-file-name ".turin" root)))))

;;; ----- frontmatter parser -----
;;
;; The frontmatter schema is fixed, so we don't pull in a TOML parser.
;; We extract just the fields we use:
;;
;;   id        = "..."
;;   file      = "..."
;;   title     = "..."
;;   anchor    = { kind = "line"|"pattern"|"treesitter",
;;                 value = "..." or N,    (line | pattern)
;;                 query = "..." }        (treesitter)
;;   highlight = { lines = N }

(defun turin--match-1 (re s)
  "Return the first capture group of RE in S, or nil."
  (when (and s (string-match re s))
    (match-string 1 s)))

(defun turin--parse-frontmatter (text)
  "Parse the frontmatter block TEXT into an alist."
  (let* ((anchor-block    (turin--match-1 "anchor[ \t]*=[ \t]*\\({[^}]+}\\)" text))
         (highlight-block (turin--match-1 "highlight[ \t]*=[ \t]*\\({[^}]+}\\)" text))
         (anchor (when anchor-block
                   (list (cons 'kind      (turin--match-1 "kind[ \t]*=[ \t]*\"\\([^\"]+\\)\"" anchor-block))
                         (cons 'value-str (turin--match-1 "value[ \t]*=[ \t]*\"\\([^\"]*\\)\"" anchor-block))
                         (cons 'value-num (let ((s (turin--match-1 "value[ \t]*=[ \t]*\\(-?[0-9]+\\)" anchor-block)))
                                            (when s (string-to-number s))))
                         (cons 'query     (turin--match-1 "query[ \t]*=[ \t]*\"\\([^\"]+\\)\"" anchor-block)))))
         (highlight (when highlight-block
                      (let ((s (turin--match-1 "lines[ \t]*=[ \t]*\\([0-9]+\\)" highlight-block)))
                        (list (cons 'lines (when s (string-to-number s))))))))
    (list (cons 'id        (turin--match-1 "id[ \t]*=[ \t]*\"\\([^\"]*\\)\"" text))
          (cons 'file      (turin--match-1 "file[ \t]*=[ \t]*\"\\([^\"]*\\)\"" text))
          (cons 'title     (turin--match-1 "title[ \t]*=[ \t]*\"\\([^\"]*\\)\"" text))
          (cons 'anchor    anchor)
          (cons 'highlight highlight))))

(defun turin--parse-stop (path)
  "Read the stop file at PATH.  Returns (FRONTMATTER-ALIST . BODY-STRING)."
  (with-temp-buffer
    (insert-file-contents path)
    (goto-char (point-min))
    (unless (looking-at "---\n")
      (error "turin: missing `---' frontmatter delimiter in %s" path))
    (forward-line)
    (let ((fm-start (point)))
      (unless (re-search-forward "^---\n" nil t)
        (error "turin: missing closing `---' in %s" path))
      (let ((fm-text (buffer-substring-no-properties fm-start (match-beginning 0)))
            (body    (buffer-substring-no-properties (match-end 0) (point-max))))
        (cons (turin--parse-frontmatter fm-text) body)))))

;;; ----- tour loader -----

(defun turin--load (turin-dir)
  "Load the tour at TURIN-DIR (a directory ending in `.turin/')."
  (let* ((index-path (expand-file-name "tour.json" turin-dir))
         (data (with-temp-buffer
                 (insert-file-contents index-path)
                 (goto-char (point-min))
                 (json-parse-buffer :array-type 'list :object-type 'alist)))
         (meta (alist-get 'tour data))
         (filenames (alist-get 'stops data))
         (stops (mapcar (lambda (filename)
                          (let* ((path (expand-file-name filename turin-dir))
                                 (parsed (turin--parse-stop path)))
                            (list (cons 'filename    filename)
                                  (cons 'frontmatter (car parsed))
                                  (cons 'body        (cdr parsed)))))
                        filenames)))
    (list (cons 'meta         meta)
          (cons 'stops        stops)
          (cons 'turin-dir    turin-dir)
          (cons 'project-root (file-name-directory (directory-file-name turin-dir))))))

;;; ----- anchor resolution -----

(defun turin--resolve-anchor (anchor buffer)
  "Resolve ANCHOR in BUFFER.  Returns a 1-based line number, or nil."
  (when anchor
    (let ((kind (alist-get 'kind anchor)))
      (cond
       ((equal kind "line")
        (alist-get 'value-num anchor))
       ((equal kind "pattern")
        (let ((pat (alist-get 'value-str anchor)))
          (when (and pat (not (string-empty-p pat)))
            (with-current-buffer buffer
              (save-excursion
                (goto-char (point-min))
                (when (re-search-forward pat nil t)
                  (line-number-at-pos (match-beginning 0))))))))
       ((equal kind "treesitter")
        (turin--resolve-treesitter (alist-get 'query anchor) buffer))))))

(defun turin--resolve-treesitter (query buffer)
  "Run tree-sitter QUERY against BUFFER.
Return the first capture's start line, or nil when tree-sitter is unavailable."
  (when (and query (not (string-empty-p query))
             (fboundp 'treesit-available-p) (treesit-available-p)
             (fboundp 'treesit-query-capture)
             (fboundp 'treesit-language-at)
             (fboundp 'treesit-parser-create)
             (fboundp 'treesit-parser-root-node)
             (fboundp 'treesit-node-start))
    (with-current-buffer buffer
      (ignore-errors
        (let* ((lang (treesit-language-at (point-min))))
          (when lang
            (let* ((parser (treesit-parser-create lang))
                   (root (treesit-parser-root-node parser))
                   (matches (treesit-query-capture root query)))
              (when matches
                (let ((node (cdr (car matches))))
                  (line-number-at-pos (treesit-node-start node)))))))))))

;;; ----- UI -----

(defun turin--clear-overlays ()
  "Remove all highlight overlays from the active session."
  (when turin--state
    (mapc (lambda (ov) (when (overlayp ov) (delete-overlay ov)))
          (turin--state-overlays turin--state))
    (setf (turin--state-overlays turin--state) nil)))

(defun turin--apply-highlight (buffer start-line n-lines)
  "Highlight N-LINES rows starting at START-LINE (1-based) in BUFFER."
  (let ((n (max 1 (or n-lines 1))))
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-min))
        (forward-line (1- start-line))
        (let* ((beg (point))
               (_   (forward-line n))
               (end (point))
               (ov  (make-overlay beg end)))
          (overlay-put ov 'face 'turin-highlight-face)
          (overlay-put ov 'turin-highlight t)
          (push ov (turin--state-overlays turin--state)))))))

(defun turin--commentary-window-params ()
  (cond
   ((memq turin-commentary-side '(left right))
    `((side . ,turin-commentary-side)
      (window-width . ,turin-commentary-size)))
   ((memq turin-commentary-side '(top bottom))
    `((side . ,turin-commentary-side)
      (window-height . ,turin-commentary-size)))))

(defun turin--display-commentary (title body)
  "Show TITLE and BODY in the commentary side window.  Returns the buffer."
  (let ((buf (get-buffer-create "*turin commentary*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "# " title "\n\n" body))
      (goto-char (point-min))
      (when (fboundp 'markdown-mode)
        (ignore-errors (markdown-mode)))
      (read-only-mode 1)
      (turin-commentary-mode 1))
    (display-buffer-in-side-window buf (turin--commentary-window-params))
    buf))

(defun turin--commentary-window-p (window)
  "Return non-nil if WINDOW is currently showing Turin commentary."
  (and turin--state
       (window-live-p window)
       (eq (window-buffer window)
           (turin--state-commentary-buffer turin--state))))

(defun turin--source-window-candidate (selected)
  "Return the best window for source display, using SELECTED as fallback."
  (let ((current (and turin--state
                      (turin--state-source-window turin--state))))
    (cond
     ((and (window-live-p current)
           (not (turin--commentary-window-p current)))
      current)
     ((not (turin--commentary-window-p selected))
      selected)
     (t
      (or (cl-find-if
           (lambda (win)
             (not (turin--commentary-window-p win)))
           (window-list nil 'no-minibuf))
          selected)))))

(defun turin--display-source-buffer (buffer)
  "Display BUFFER in a normal source window and return that window."
  (let ((win (turin--source-window-candidate (selected-window))))
    (if (and (window-live-p win)
             (not (turin--commentary-window-p win)))
        (set-window-buffer win buffer)
      (setq win (display-buffer buffer '((display-buffer-reuse-window
                                          display-buffer-pop-up-window)))))
    (setf (turin--state-source-window turin--state) win)
    win))

(defun turin--close-commentary ()
  (let ((buf (get-buffer "*turin commentary*")))
    (when buf
      (when-let ((win (get-buffer-window buf)))
        (delete-window win))
      (kill-buffer buf))))

;;; ----- core display -----

(defun turin--display-stop (&optional stay-in-commentary)
  "Render the stop at `turin--state-index'.
When STAY-IN-COMMENTARY is non-nil, leave focus in the commentary buffer."
  (let* ((tour    (turin--state-tour turin--state))
         (stops   (alist-get 'stops tour))
         (idx     (turin--state-index turin--state))
         (stop    (nth (1- idx) stops))
         (fm      (alist-get 'frontmatter stop))
         (root    (alist-get 'project-root tour))
         (file    (alist-get 'file fm))
         (path    (expand-file-name (or file "") root))
         (anchor  (alist-get 'anchor fm))
         (hl      (alist-get 'highlight fm))
         (buf     (find-file-noselect path))
         (source-window (turin--display-source-buffer buf)))
    (setf (turin--state-source-buffer turin--state) buf)
    (let ((line (turin--resolve-anchor anchor buf)))
      (when line
        (let ((total (with-current-buffer buf (line-number-at-pos (point-max)))))
          (setq line (max 1 (min line total))))
        (with-selected-window source-window
          (goto-char (point-min))
          (forward-line (1- line))
          (recenter))
        (turin--apply-highlight buf line (alist-get 'lines hl))))
    (let ((title (format "[%d/%d] %s"
                         idx (length stops)
                         (or (alist-get 'title fm) (alist-get 'filename stop)))))
      (setf (turin--state-commentary-buffer turin--state)
            (turin--display-commentary title (alist-get 'body stop))))
    (if stay-in-commentary
        (when-let ((win (get-buffer-window
                         (turin--state-commentary-buffer turin--state))))
          (select-window win))
      (select-window source-window))))

;;; ----- commands -----

;;;###autoload
(defun turin-start ()
  "Begin the codebase tour for the current project."
  (interactive)
  (when (turin--active-p) (turin-quit))
  (let ((dir (turin--find-dir)))
    (unless dir
      (user-error "turin: no .turin/ directory found upward from current buffer"))
    (let ((tour (turin--load dir)))
      (when (null (alist-get 'stops tour))
        (user-error "turin: tour has no stops"))
      (setq turin--state (make-turin--state :tour tour :index 1 :overlays nil))
      (turin--display-stop))))

;;;###autoload
(defun turin-next (&optional stay-in-commentary)
  "Advance to the next tour stop.
When STAY-IN-COMMENTARY is non-nil, leave focus in the commentary buffer."
  (interactive)
  (unless (turin--active-p) (user-error "turin: no active tour"))
  (let* ((stops (alist-get 'stops (turin--state-tour turin--state)))
         (idx (turin--state-index turin--state)))
    (when (< idx (length stops))
      (turin--clear-overlays)
      (setf (turin--state-index turin--state) (1+ idx))
      (turin--display-stop stay-in-commentary))))

;;;###autoload
(defun turin-next-commentary ()
  "Advance to the next tour stop and keep focus in the commentary buffer."
  (interactive)
  (turin-next t))

;;;###autoload
(defun turin-prev (&optional stay-in-commentary)
  "Retreat to the previous tour stop.
When STAY-IN-COMMENTARY is non-nil, leave focus in the commentary buffer."
  (interactive)
  (unless (turin--active-p) (user-error "turin: no active tour"))
  (let ((idx (turin--state-index turin--state)))
    (when (> idx 1)
      (turin--clear-overlays)
      (setf (turin--state-index turin--state) (1- idx))
      (turin--display-stop stay-in-commentary))))

;;;###autoload
(defun turin-prev-commentary ()
  "Retreat to the previous tour stop and keep focus in the commentary buffer."
  (interactive)
  (turin-prev t))

;;;###autoload
(defun turin-goto (n)
  "Jump to stop N (1-based)."
  (interactive "nStop number: ")
  (unless (turin--active-p) (user-error "turin: no active tour"))
  (let ((stops (alist-get 'stops (turin--state-tour turin--state))))
    (unless (and (integerp n) (>= n 1) (<= n (length stops)))
      (user-error "turin: index out of range (1..%d)" (length stops)))
    (turin--clear-overlays)
    (setf (turin--state-index turin--state) n)
    (turin--display-stop)))

;;;###autoload
(defun turin-quit ()
  "Close the active tour."
  (interactive)
  (when (turin--active-p)
    (turin--clear-overlays)
    (turin--close-commentary)
    (setq turin--state nil)))

;;;###autoload
(defun turin-list ()
  "Show the list of stops in the minibuffer."
  (interactive)
  (unless (turin--active-p) (user-error "turin: no active tour"))
  (let* ((stops (alist-get 'stops (turin--state-tour turin--state)))
         (cur (turin--state-index turin--state)))
    (message
     "%s"
     (mapconcat
      (lambda (entry)
        (let* ((i (car entry))
               (s (cdr entry))
               (fm (alist-get 'frontmatter s))
               (marker (if (= i cur) "▶" " "))
               (title (or (alist-get 'title fm) (alist-get 'filename s)))
               (file (or (alist-get 'file fm) "?")))
          (format "%s %d. %s  (%s)" marker i title file)))
      (cl-loop for s in stops
               for i from 1
               collect (cons i s))
      "\n"))))

;;; ----- commentary buffer minor mode -----

(defvar turin-commentary-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'turin-next)
    (define-key map (kbd "N") #'turin-next-commentary)
    (define-key map (kbd "p") #'turin-prev)
    (define-key map (kbd "P") #'turin-prev-commentary)
    (define-key map (kbd "g") #'turin-goto)
    (define-key map (kbd "l") #'turin-list)
    (define-key map (kbd "q") #'turin-quit)
    map)
  "Keymap for `turin-commentary-mode'.")

(define-minor-mode turin-commentary-mode
  "Minor mode for the turin commentary side window.
Binds single-letter keys for tour navigation: n/p/g/l/q."
  :lighter " Tour"
  :keymap turin-commentary-mode-map)

(provide 'turin-mode)

;;; turin-mode.el ends here
