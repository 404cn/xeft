;;; xeft.el --- Deft feat. Xapian      -*- lexical-binding: t; -*-

;; Author: Yuan Fu <casouri@gmail.com>
;; Version: 1.0

;;; This file is NOT part of GNU Emacs

;;; Commentary:
;;
;; Usage:
;;
;; Type M-x xeft RET, and you should see the Xeft buffer. Type in your
;; search phrase in the first line and the results will show up as you
;; type. Press C-n and C-p to go through each file. You can preview a
;; file by pressing SPC when the point is on a file, or click the file
;; with the mouse. Press RET to open the file in the same window.
;;
;; Type C-c C-g to force a refresh. When point is on the search
;; phrase, press RET to create a file with the search phrase as
;; the filename and title.
;;
;; Note that:
;;
;; 1. Xeft only looks for first-level files in ‘xeft-directory’. Files
;;    in sub-directories are not searched unless ‘xeft-recursive’ is
;;    non-nil.
;;
;; 2. Xeft creates a new file by using the search phrase as the
;;    filename and title. If you want otherwise, redefine
;;    ‘xeft-create-note’ or ‘xeft-filename-fn’.
;;
;; 3. Xeft saves the current window configuration before switching to
;;    Xeft buffer. When Xeft buffer is killed, Xeft restores the saved
;;    window configuration.
;;
;; On search queries:
;;
;; Since Xeft uses Xapian, it supports the query syntax Xapian
;; supports:
;;
;; AND, NOT, OR, XOR and parenthesizes
;; +word1 -word2      which matches documents that contains WORD1 but not
;;                    WORD2.
;; word1 NEAR word2   which matches documents in where word1 is near word2.
;; word1 ADJ word2    which matches documents in where word1 is near word2
;;                    and word1 comes before word2
;; "word1 word2"      which matches exactly “word1 word2”
;;
;; Xeft deviates from Xapian in one aspect: consecutive phrases have
;; implied “AND” between them. So "word1 word2 word3" is actually seen
;; as "word1 AND word2 AND word3". See ‘xeft--tighten-search-phrase’
;; for how exactly is it done.
;;
;; See https://xapian.org/docs/queryparser.html for Xapian’s official
;; documentation on query syntax.

;;; Code:

(require 'cl-lib)
(declare-function xapian-lite-reindex-file nil
                  (path dbpath &optional lang force))
(declare-function xapian-lite-query-term nil
                  (term dbpath offset page-size &optional lang))

;;; Customize

(defgroup xeft nil
  "Xeft note interface."
  :group 'applications)

(defcustom xeft-directory "~/.deft"
  "Directory in where notes are stored. Must be a full path."
  :type 'directory)

(defcustom xeft-database "~/.deft/db"
  "The path to the database."
  :type 'directory)

(defcustom xeft-find-file-hook nil
  "Hook run when Xeft opens a file."
  :type 'hook)

(defface xeft-selection
  '((t . (:inherit region :extend t)))
  "Face for the current selected search result.")

(defface xeft-inline-highlight
  '((t . (:inherit underline :extend t)))
  "Face for inline highlighting in Xeft buffer.")

(defface xeft-preview-highlight
  '((t . (:inherit highlight :extend t)))
  "Face for highlighting in the preview buffer.")

(defface xeft-excerpt-title
  '((t . (:inherit (bold underline))))
  "Face for the excerpt title.")

(defface xeft-excerpt-body
  '((t . (:inherit default)))
  "Face for the excerpt body.")

(defcustom xeft-default-extension "txt"
  "The default extension for new files created by xeft."
  :type 'string)

(defcustom xeft-filename-fn
  (lambda (search-phrase)
    (concat search-phrase "." xeft-default-extension))
  "A function that takes the search phrase and returns a filename."
  :type 'function)

(defcustom xeft-ignore-extension '("iimg")
  "Files with extensions in this list are ignored.

To remove the files that you want to ignore but are already
indexed in the database, simply delete the database and start
xeft again."
  :type '(list string))

(defcustom xeft-recursive nil
  "If non-nil, xeft searches for file recursively.
Xeft doesn’t follow symlinks and ignores inaccessible directories."
  :type 'boolean)

(defcustom xeft-file-list-function #'xeft--file-list
  "A function that returns files that xeft should search from.
This function takes no arguments and return a list of absolute paths."
  :type 'function)

;;; Compile

(defun xeft--compile-module ()
  "Compile the dynamic module. Return non-nil if success."
  ;; Just following vterm.el here.
  (when (not (executable-find "make"))
    (user-error "Couldn’t compile xeft: cannot find make"))
  (let* ((source-dir
          (shell-quote-argument
           (file-name-directory
            (locate-library "xeft.el" t))))
         (command (format "cd %s; make PREFIX=%s"
                          source-dir
                          (read-string "PREFIX (empty by default): ")))
         (buffer (get-buffer-create "*xeft compile*")))
    (if (zerop (let ((inhibit-read-only t))
                 (call-process "sh" nil buffer t "-c" command)))
        (progn (message "Successfully compiled the module :-D") t)
      (pop-to-buffer buffer)
      (compilation-mode)
      (message "Failed to compile the module")
      nil)))

(defvar xeft--linux-module-url "https://github.com/casouri/xapian-lite/releases/download/v1.0/xapian-lite-amd64-linux.so"
  "URL for pre-built dynamic module for Linux.")

(defvar xeft--mac-module-url "https://github.com/casouri/xapian-lite/releases/download/v1.0/xapian-lite-amd64-mac.dylib"
  "URL for pre-built dynamic module for Mac.")

(defun xeft--download-module ()
  "Download pre-built module from GitHub. Return non-nil if success."
  (require 'url)
  (let ((module-path (expand-file-name
                      "xapian-lite.so"
                      (file-name-directory
                       (locate-library "xeft.el" t)))))
    (cond
     ((eq system-type 'gnu/linux)
      (url-copy-file xeft--linux-module-url module-path)
      t)
     ((eq system-type 'darwin)
      (url-copy-file xeft--mac-module-url module-path)
      t)
     (t (message "No pre-built module for this operating system. We only have them for GNU/Linux and macOS")
        nil))))

;;; Helpers

(defvar xeft--last-window-config nil
  "Window configuration before Xeft starts.")

(defun xeft--buffer ()
  "Return the xeft buffer."
  (get-buffer-create "*xeft*"))

(defun xeft--work-buffer ()
  "Return the work buffer for Xeft. Used for holding file contents."
  (get-buffer-create " *xeft work*"))

(defun xeft--after-save ()
  "Reindex the file."
  (condition-case _
      (xapian-lite-reindex-file (buffer-file-name) xeft-database)
    (xapian-lite-database-lock-error
     (message "The Xeft database is locked (maybe there is another Xeft instance running) so we will skip indexing this file for now"))
    (xapian-lite-database-corrupt-error
     (message "The Xeft database is corrupted! You should delete the database and Xeft will recreate it. Make sure other programs are not messing with Xeft database"))))

(defvar xeft-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'xeft-create-note)
    (define-key map (kbd "C-c C-g") #'xeft-refresh-full)
    (define-key map (kbd "C-c C-r") #'xeft-full-reindex)
    (define-key map (kbd "C-n") #'xeft-next)
    (define-key map (kbd "C-p") #'xeft-previous)
    map)
  "Mode map for `xeft-mode'.")

(defvar xeft--need-refresh)
(define-derived-mode xeft-mode fundamental-mode
  "Xeft" "Search for notes and display summaries."
  (let ((inhibit-read-only t))
    (visual-line-mode)
    (setq default-directory xeft-directory
          xeft--last-window-config (current-window-configuration))
    ;; Hook ‘after-change-functions’ is too primitive, binding to that
    ;; will cause problems with electric-pairs.
    (add-hook 'post-command-hook
              (lambda (&rest _)
                (when xeft--need-refresh
                  (let ((inhibit-modification-hooks t))
                    ;; We don’t want ‘after-change-functions’ to run
                    ;; when we refresh the buffer, because we set
                    ;; ‘xeft--need-refresh’ in that hook.
                    (xeft-refresh))))
              0 t)
    (add-hook 'after-change-functions
              (lambda (&rest _) (setq xeft--need-refresh t)) 0 t)
    (add-hook 'window-size-change-functions
              (lambda (&rest _) (xeft-refresh)) 0 t)
    (add-hook 'kill-buffer-hook
              (lambda ()
                (when xeft--last-window-config
                  (set-window-configuration xeft--last-window-config)))
              0 t)
    (erase-buffer)
    (insert "\n\nInsert search phrase and press RET to search.")
    (goto-char (point-min))))


;;; Userland

;;;###autoload
(defun xeft ()
  "Start Xeft."
  (interactive)
  (when (not (file-name-absolute-p xeft-directory))
    (user-error "XEFT-DIRECTORY must be an absolute path"))
  (when (not (file-exists-p xeft-directory))
    (mkdir xeft-directory t))
  (when (not (file-name-absolute-p xeft-database))
    (user-error "XEFT-DATABASE must be an absolute path"))
  (when (not (file-exists-p xeft-database))
    (mkdir xeft-database t))
  (unless (require 'xapian-lite nil t)
    ;; I can hide download option for non-Linux/mac users, but I’m
    ;; lazy.
    (let* ((choice (read-char (concat
                               "Xeft needs the dynamic module to work, "
                               "download pre-built module "
                               (propertize "[b]" 'face 'bold)
                               ", compile locally "
                               (propertize "[c]" 'face 'bold)
                               ", or give up "
                               (propertize "[q]" 'face 'bold)
                               "?")))
           (success (cond ((eq choice ?b)
                           (xeft--download-module))
                          ((eq choice ?c)
                           (xeft--compile-module))
                          (t nil))))
      (when success
        (require 'xapian-lite))))
  (if (not (featurep 'xapian-lite))
      (message "Since there is no require dynamic module, we can’t start Xeft")
    (setq xeft--last-window-config (current-window-configuration))
    (switch-to-buffer (xeft--buffer))
    (when (not (derived-mode-p 'xeft-mode))
      (xeft-mode))
    ;; Reindex all files. We reindex every time M-x xeft is called.
    ;; Because sometimes I use other functions to move between files,
    ;; edit them, and come back to Xeft buffer to search. By that time
    ;; some file are changed without Xeft noticing.
    (xeft-full-reindex)
    ;; Also regenerate newest file cache, for the same reason as above.
    (xeft--front-page-cache-refresh)))

(defun xeft-create-note ()
  "Create a new note with the current search phrase as the title."
  (interactive)
  (let* ((search-phrase (xeft--get-search-phrase))
         (file-name (funcall xeft-filename-fn search-phrase))
         (file-path (expand-file-name file-name xeft-directory))
         (exists-p (file-exists-p file-path)))
    ;; If there is no match, create the file without confirmation,
    ;; otherwise prompt for confirmation. NOTE: this is not DRY, but
    ;; should be ok.
    (when (or (search-forward "Press RET to create a new note" nil t)
              (y-or-n-p (format "Create file `%s'? " file-name)))
      (find-file file-path)
      (unless exists-p
        (insert search-phrase "\n\n")
        (save-buffer)
        ;; This should cover most cases.
        (xeft--front-page-cache-refresh))
      (run-hooks 'xeft-find-file-hook))))

(defvar-local xeft--select-overlay nil
  "Overlay used for highlighting selected search result.")

(defun xeft--highlight-file-at-point ()
  "Activate (highlight) the file excerpt button at point."
  (when-let ((button (button-at (point))))
    ;; Create the overlay if it doesn't exist yet.
    (when (null xeft--select-overlay)
      (setq xeft--select-overlay (make-overlay (button-start button)
                                               (button-end button)))
      (overlay-put xeft--select-overlay 'evaporate t)
      (overlay-put xeft--select-overlay 'face 'xeft-selection))
    ;; Move the overlay over the file.
    (move-overlay xeft--select-overlay
                  (button-start button) (button-end button))))

(defun xeft-next ()
  "Move to next file excerpt."
  (interactive)
  (when (forward-button 1 nil nil t)
    (xeft--highlight-file-at-point)))

(defun xeft-previous ()
  "Move to previous file excerpt."
  (interactive)
  (if (backward-button 1 nil nil t)
      (xeft--highlight-file-at-point)
    ;; Go to the end of the search phrase.
    (goto-char (point-min))
    (end-of-line)))

(defun xeft-full-reindex ()
  "Do a full reindex of all files."
  (interactive)
  (condition-case _
      (dolist (file (funcall xeft-file-list-function))
        (xapian-lite-reindex-file file xeft-database))
    (xapian-lite-database-lock-error
     (message "The Xeft database is locked (maybe there is another Xeft instance running) so we will skip indexing for now"))
    (xapian-lite-database-corrupt-error
     (message "The Xeft database is corrupted! You should delete the database and Xeft will recreate it. Make sure other programs are not messing with Xeft database"))))

;;; Draw

(defvar xeft--preview-window nil
  "Xeft shows file previews in this window.")

(defun xeft--get-search-phrase ()
  "Return the search phrase. Assumes current buffer is a xeft buffer."
  (save-excursion
    (goto-char (point-min))
    (string-trim
     (buffer-substring-no-properties (point) (line-end-position)))))

(defun xeft--find-file-at-point ()
  "View file at point."
  (interactive)
  (find-file (button-get (button-at (point)) 'path))
  (run-hooks 'xeft-find-file-hook)
  (add-hook 'after-save-hook #'xeft--after-save 0 t))

(defun xeft--preview-file (file &optional select)
  "View FILE in another window.
If SELECT is non-nil, select the buffer after displaying it."
  (interactive)
  (let* ((buffer (find-file-noselect file))
         (search-phrase (xeft--get-search-phrase))
         (keyword-list (split-string search-phrase)))
    (if (and (window-live-p xeft--preview-window)
             (not (eq xeft--preview-window (selected-window))))
        (with-selected-window xeft--preview-window
          (switch-to-buffer buffer))
      (setq xeft--preview-window
            (display-buffer
             buffer '((display-buffer-use-some-window
                       display-buffer-in-direction
                       display-buffer-pop-up-window)
                      . ((inhibit-same-window . t)
                         (direction . right)
                         (window-width
                          . (lambda (win)
                              (let ((width (window-width)))
                                (when (< width 50)
                                  (window-resize
                                   win (- 50 width) t))))))))))
    (if select (select-window xeft--preview-window))
    (with-current-buffer buffer
      (xeft--highlight-matched keyword-list)
      (run-hooks 'xeft-find-file-hook))))

(define-button-type 'xeft-excerpt
  'action (lambda (button)
            ;; If the file is no already highlighted, highlight it
            ;; first.
            (when (not (and xeft--select-overlay
                            (overlay-buffer xeft--select-overlay)
                            (<= (overlay-start xeft--select-overlay)
                                (button-start button)
                                (overlay-end xeft--select-overlay))))
              (goto-char (button-start button))
              (xeft--highlight-file-at-point))
            (xeft--preview-file (button-get button 'path)))
  'keymap (let ((map (make-sparse-keymap)))
            (set-keymap-parent map button-map)
            (define-key map (kbd "RET") #'xeft--find-file-at-point)
            (define-key map (kbd "SPC") #'push-button)
            map)
  'help-echo "Open this file"
  'follow-link t
  'face 'default
  'mouse-face 'xeft-selection)

(defun xeft--highlight-search-phrase ()
  "Highlight search phrases in buffer."
  (let ((keyword-list (cl-remove-if
                       (lambda (word)
                         (or (member word '("OR" "AND" "XOR" "NOT" "NEAR"))
                             (string-prefix-p "ADJ" word)))
                       (split-string (xeft--get-search-phrase))))
        (inhibit-read-only t))
    (dolist (keyword keyword-list)
      (when (> (length keyword) 1)
        (goto-char (point-min))
        (forward-line 2)
        ;; We use overlay because overlay allows face composition.
        ;; So we can have bold + underline.
        (while (search-forward keyword nil t)
          (let ((ov (make-overlay (match-beginning 0)
                                  (match-end 0))))
            (overlay-put ov 'face 'xeft-inline-highlight)
            (overlay-put ov 'xeft-highlight t)
            (overlay-put ov 'evaporate t)))))))

(defvar xeft--ecache nil
  "Cache for finding excerpt for a file.")

(defun xeft--ecache-buffer (file)
  "Return a buffer that has the content of FILE.
Doesn’t check for modification time, and not used."
  (or (alist-get (sxhash file) xeft--ecache)
      (progn
        (let ((buf (get-buffer-create
                    (format " *xeft-ecache %s*" file))))
          (with-current-buffer buf
            (setq buffer-undo-list t)
            (insert-file-contents file nil nil nil t))
          (push (cons (sxhash file) buf) xeft--ecache)
          (when (> (length xeft--ecache) 30)
            (kill-buffer (cdr (nth 30 xeft--ecache)))
            (setcdr (nthcdr 29 xeft--ecache) nil))
          buf))))

(defun xeft--insert-file-excerpt (file search-phrase)
  "Insert an excerpt for FILE at point.
This excerpt contains note title and content excerpt and is
clickable. FILE should be an absolute path. SEARCH-PHRASE is the
search phrase the user typed."
  (let ((excerpt-len (floor (* 2.7 (1- (window-width)))))
        (last-search-term
         (car (last (split-string search-phrase))))
        title excerpt)
    (with-current-buffer (xeft--work-buffer)
      (setq buffer-undo-list t)
      ;; The times saved by caching is not significant enough. So I
      ;; choose to not cache, but kept the code just in case. See
      ;; ‘xeft--ecache-buffer’.
      (insert-file-contents file nil nil nil t)
      (goto-char (point-min))
      (search-forward "#+TITLE: " (line-end-position) t)
      (let ((bol (point)))
        (end-of-line)
        (setq title (buffer-substring-no-properties bol (point))))
      (when (eq title "") (setq title "no title"))
      (narrow-to-region (point) (point-max))
      ;; Grab excerpt.
      (setq excerpt (string-trim
                     (replace-regexp-in-string
                      "[[:space:]]+"
                      " "
                      (if (and last-search-term
                               (search-forward last-search-term nil t))
                          (buffer-substring-no-properties
                           (max (- (point) (/ excerpt-len 2))
                                (point-min))
                           (min (+ (point) (/ excerpt-len 2))
                                (point-max)))
                        (buffer-substring-no-properties
                         (point)
                         (min (+ (point) excerpt-len)
                              (point-max))))))))
    ;; Now we insert the excerpt
    (let ((start (point)))
      (insert (propertize title 'face 'xeft-excerpt-title)
              "\n"
              (propertize excerpt 'face 'xeft-excerpt-body)
              "\n\n")
      ;; If we use overlay (with `make-button'), the button's face
      ;; will override the bold and light face we specified above.
      (make-text-button start (- (point) 2)
                        :type 'xeft-excerpt
                        'path file))))

;;; Refresh and search

(defun xeft-refresh-full ()
  "Refresh and display _all_ results."
  (interactive)
  (xeft-refresh t))

(defun xeft--file-list ()
  "Default function for ‘xeft-file-list-function’.
Return a list of all files in ‘xeft-directory’, ignoring dot
files and directories and check for ‘xeft-ignore-extension’."
  (cl-remove-if-not
   (lambda (file)
     (and (file-regular-p file)
          (not (string-prefix-p
                "." (file-name-base file)))
          (not (member (file-name-extension file)
                       xeft-ignore-extension))))
   (if xeft-recursive
       (directory-files-recursively
        xeft-directory "" nil (lambda (dir)
                                (not (string-prefix-p
                                      "." (file-name-base dir)))))
     (directory-files
      xeft-directory t nil t))))

(defvar-local xeft--need-refresh t
  "If change is made to the buffer, set this to t.
Once refreshed the buffer, set this to nil.")

(defun xeft--tighten-search-phrase (phrase)
  "Basically insert AND between each term in PHRASE."
  (let ((lst (split-string phrase))
        (in-quote nil))
    ;; Basically we only insert AND between two normal phrases, and
    ;; don’t insert if any of the two is an operator (AND, OR, +/-,
    ;; etc), we also don’t insert AND in quoted phrases.
    (string-join
     (append (cl-loop for idx from 0 to (- (length lst) 2)
                      for this = (nth idx lst)
                      for next = (nth (1+ idx) lst)
                      collect this
                      if (and (not in-quote) (eq (aref this 0) ?\"))
                      do (setq in-quote t)
                      if (and in-quote
                              (eq (aref this (1- (length this))) ?\"))
                      do (setq in-quote nil)
                      if (not
                          (or in-quote
                              (member this '("AND" "NOT" "OR" "XOR" "NEAR"))
                              (string-prefix-p "ADJ" this)
                              (memq (aref this 0) '(?+ ?-))
                              (member next '("AND" "NOT" "OR" "XOR" "NEAR"))
                              (string-prefix-p "ADJ" next)
                              (memq (aref next 0) '(?+ ?-))))
                      collect "AND")
             (last lst))
     " ")))

;; This makes the integrative search results much more stable and
;; experience more fluid. And because we are not showing radically
;; different results from one key-press to another, the latency goes
;; down, I’m guessing because caching in CPU or RAM or OS or whatever.
(defun xeft--ignore-short-phrase (phrase)
  "If the last term in PHRASE is too short, remove it."
  (let* ((lst (or (split-string phrase) '("")))
         (last (car (last lst))))
    (if (and (not (string-match-p (rx (or (category chinese)
                                          (category japanese)
                                          (category korean)))
                                  last))
             (< (length last) 3))
        (string-join (cl-subseq lst 0 (1- (length lst))) " ")
      (string-join lst " "))))

;; See comment in ‘xeft-refresh’.
(defvar xeft--front-page-cache nil
  "Stores the newest 15 or so files.")

(defun xeft--front-page-cache-refresh ()
  "Refresh ‘xeft--front-page-cache’ and return it."
  (setq xeft--front-page-cache
        (cl-sort (funcall xeft-file-list-function)
                 #'file-newer-than-file-p)))

(defun xeft-refresh (&optional full)
  "Search for notes and display their summaries.
By default, only display the first 15 results. If FULL is
non-nil, display all results."
  (interactive)
  (when (derived-mode-p 'xeft-mode)
    (let ((search-phrase (xeft--ignore-short-phrase
                          (xeft--get-search-phrase))))
      (let* ((phrase-empty (equal search-phrase ""))
             (file-list nil)
             (list-clipped nil))
        ;; 1. Get a list of files to show.
        (setq file-list
              ;; If the search phrase is empty (or too short and thus
              ;; ignored), we show the newest files.
              (if phrase-empty
                  (or xeft--front-page-cache
                      ;; Why cache? Turns out sorting this list by
                      ;; modification date is slow enough to be
                      ;; perceivable.
                      (setq xeft--front-page-cache
                            (xeft--front-page-cache-refresh)))
                (xapian-lite-query-term
                 (xeft--tighten-search-phrase search-phrase)
                 xeft-database
                 ;; 16 is just larger than 15, so we will know it when
                 ;; there are more results.
                 0 (if full 2147483647 16))))
        (when (and (null full) (> (length file-list) 15))
          (setq file-list (cl-subseq file-list 0 15)
                list-clipped t))
        ;; 2. Display these files with excerpt. We do a
        ;; double-buffering: first insert in a temp buffer, then
        ;; insert the whole thing into this buffer.
        (let ((inhibit-read-only t)
              (orig-point (point))
              (new-content
               (while-no-input
                 (with-temp-buffer
                   ;; Insert excerpts.
                   (if file-list
                       (dolist (file file-list)
                         (xeft--insert-file-excerpt
                          file search-phrase))
                     ;; NOTE: this string is referred in
                     ;; ‘xeft-create-note’.
                     (unless phrase-empty
                       (insert "Press RET to create a new note")))
                   ;; Insert clipped notice.
                   (when list-clipped
                     (insert
                      (format
                       "[Only showing the first 15 results, type %s to show all of them]\n"
                       (key-description
                        (where-is-internal #'xeft-refresh-full
                                           xeft-mode-map t)))))
                   (buffer-string)))))
          ;; 2.2 Actually insert the content.
          (when (stringp new-content)
            (while-no-input
              (setq buffer-undo-list t)
              (goto-char (point-min))
              (forward-line 2)
              (let ((start (point)))
                (delete-region (point) (point-max))
                (insert new-content)
                (put-text-property (- start 2) (point) 'read-only t)
                (xeft--highlight-search-phrase)
                (set-buffer-modified-p nil)
                ;; If finished, update this variable.
                (setq xeft--need-refresh nil)
                (buffer-enable-undo))))
          ;; Save excursion wouldn’t work since we erased the
          ;; buffer and re-inserted contents.
          (goto-char orig-point)
          ;; Re-apply highlight.
          (xeft--highlight-file-at-point))))))

;;; Highlight matched phrases

(defun xeft--highlight-matched (keyword-list)
  "Highlight keywords in KEYWORD-LIST in the current buffer."
  (save-excursion
    ;; Add highlight overlays.
    (dolist (keyword keyword-list)
      (when (> (length keyword) 1)
        (goto-char (point-min))
        (while (search-forward keyword nil t)
          (let ((ov (make-overlay (match-beginning 0)
                                  (match-end 0))))
            (overlay-put ov 'face 'xeft-preview-highlight)
            (overlay-put ov 'xeft-highlight t)))))
    ;; Add cleanup hook.
    (add-hook 'window-selection-change-functions
              #'xeft--cleanup-highlight
              0 t)))

(defun xeft--cleanup-highlight (window)
  "Cleanup highlights in WINDOW."
  (when (eq window (selected-window))
    (let ((ov-list (overlays-in (point-min)
                                (point-max))))
      (dolist (ov ov-list)
        (when (overlay-get ov 'xeft-highlight)
          (delete-overlay ov))))
    (remove-hook 'window-selection-change-functions
                 #'xeft--cleanup-highlight
                 t)))

;;; Inferred links

(defun xeft--extract-buffer-words (buffer)
  "Extract words in BUFFER and return in a list.
Each element looks like (BEG . WORD) where BEG is the buffer
position of WORD."
  (with-current-buffer buffer
    (goto-char (point-min))
    (let (beg end word-list)
      (while (progn (and (re-search-forward (rx word) nil t)
                         (setq beg (match-beginning 0))
                         (re-search-forward (rx (not word)) nil t)
                         (setq end (match-beginning 0))))
        (push (cons beg (buffer-substring-no-properties beg end))
              word-list))
      (nreverse word-list))))

(defun xeft--generate-phrase-list (word-list max-len)
  "Given WORD-LIST, generate all possible phrases up to MAX-LEN long.
Eg, given WORD-LIST = (a b c), len = 3, return

    ((a) (b) (c) (a b) (b c) (a b c))"
  (cl-loop for len from 1 to max-len
           append (cl-loop
                   for idx from 0 to (- (length word-list) len)
                   collect (cl-subseq word-list idx (+ idx len)))))

(defun xeft--collect-inferred-links
    (buffer max-len lower-bound upper-bound)
  "Collect inferred links in BUFFER.
MAX-LEN is the same as in ‘xeft--generate-phrase-list’. Only
phrases with number of results between LOWER-BOUND and
UPPER-BOUND (inclusive) are collected."
  (let* ((word-list (xeft--extract-buffer-words buffer))
         (phrase-list (xeft--generate-phrase-list
                       word-list max-len))
         (query-list (mapcar (lambda (phrase-list)
                               (let ((pos (caar phrase-list))
                                     (words (mapcar #'cdr phrase-list)))
                                 (cons pos (concat "\""
                                                   (string-join
                                                    words)
                                                   "\""))))
                             phrase-list))
         (link-list
          ;; QUERY-CONS = (POS . QUERY-TERM)
          (cl-loop for query-cons in query-list
                   for file-list = (xapian-lite-query-term
                                    (cdr query-cons) xeft-database
                                    0 (1+ upper-bound))
                   if (<= lower-bound (length file-list) upper-bound)
                   collect (cons (cdr query-cons)
                                 (length file-list)))))
    link-list))

(provide 'xeft)

;;; xeft.el ends here
