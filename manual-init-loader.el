;;; manual-init-loader.el --- Manual Init Loader -*- lexical-binding: t -*-

;; Copyright (C) 2014  Ken Okada

;; Author: Ken Okada <keno.ss57@gmail.com>
;; Keywords: convenience

;; This file is not part of GNU Emacs.

;; Apache License, Version 2.0

;;; Commentary:

;; This package, MiLo, is an init config file loader for Emacs, which is easily configurable and
;; controlable.
;; For more details, see ./README.md .

;; Due to the case ERFI is installed by package manager like `el-get' and it is loaded by MiLo,
;; MiLo have not to depend on ERFI.  We avoid this by writting functions almost ERFI free
;; and duplicate definitions of depending functions.

;;; Code:

;; Public namespace: milo-
;; Internal namespace: milo:



(eval-when-compile (require 'cl))
(require 'button)
(require 'benchmark)



;;;
;;; Custam variables
;;;

(defgroup milo nil
  "Manual Init Loader."
  :group 'environment)

;; Control loading

(defcustom milo-file-name-prefix "init-"
  "If non-nil, `milo:load-file' search elisp with this prefix too.
For more precisely, see `milo:load-file'."
  :type 'string
  :group 'milo)

(defcustom milo-load-file-function 'milo:load-file
  "Used to load file.  File can not exist."
  :type 'function
  :group 'milo)

(defcustom milo-preprocess-specs-function 'milo:preprocess-specs
  "For each directory, preprocess specs under it."
  :type 'function
  :group 'milo)

(defcustom milo-ex-ante-specs '(("preload.el" (@ :only-when-exists t))
                                ("init.el"    (@ :only-when-exists t)))
  "For each directory, load these specs before designated specs.
For more flexible control, use `milo-preprocess-specs-function'."
  :group 'milo)

(defcustom milo-ex-post-specs '(("key-binding.el" (@ :only-when-exists t))
                                ("look.el"        (@ :only-when-exists t)))
  "For each directory, load these specs after designated specs.
For more flexible control, use `milo-preprocess-specs-function'."
  :group 'milo)

(defcustom milo-pre-load-hook nil
  "Hooks run when `milo-load' start."
  :type 'hook
  :group 'milo)

(defcustom milo-post-load-hook '(milo:inform-error-modestly)
  "Hooks run when `milo-load' end."
  :type 'hook
  :group 'milo)

;; Logging

(defcustom milo-buffer-name "*milo-log*"
  "Buffer name used for logging."
  :type 'string
  :group 'milo)

(defcustom milo-file-name-truncate-function 'file-name-nondirectory
  "Used in `milo:loading-message' to print paths of Emacs Lisp files."
  :type function
  :group 'milo)

(defcustom milo-raise-error nil
  "Used in `milo:load-file'.  If non-nil, raise an error when `load-file' raise that."
  :type 'boolean
  :group 'milo)

(defcustom milo-longest-file-name-length 22
  "Used in `milo:loading-message' to print path name."
  :type 'integer
  :group 'milo)

(defface milo-success-face
  '((((class color))
     (:foreground "green")))
  "Used for a part of success message"
  :group 'milo)

(defface milo-failure-face
  '((((class color))
     (:foreground "red")))
  "Used for a part of failure message"
  :group 'milo)



;;;
;;; Internal variables
;;;

(defvar milo:buffer nil)
(defvar milo:current-indent 2)
(defvar milo:load-status 'success)
(defvar milo:dry-run-flag nil)



;;;
;;; ERFI free; copied from `erfi-macros.el' and `erfi-misc.el'.
;;;

(eval-when-compile
  (defmacro let1 (var expr &rest body)
    (declare (indent 2))
    "[Gauche] Equivalent to (let ((VAR EXPR)) BODY ...)"
    `(let ((,var ,expr))
       ,@body))
  )

;; Macroexpanded code of `erfi-emacs:etched-overlays-in'.
(defun milo:erfi-emacs:etched-overlays-in (start end &optional object)
  "Detect etched overlays between START and END of OBJECT.
Return a list of '(,range ,overlay-properties), where range is '(,s ,e)."
  ;; Take care of properties of first character.  `next-single-property-change'
  ;; only detect that between (1+ START) and END.
  (let ((--erfi-continue-- t)
        (--erfi-result-- nil)
        (res (let ((ps (text-properties-at start)))
               (if (memq 'overlay-plist ps)
                   `(((,start ,(+ start (cadr (memq 'overlay-length ps))))
                      ,(cadr (memq 'overlay-plist ps))))
                   '())))
        (pos start))
    (while --erfi-continue--
      (catch '--erfi-repeat--
        (setq --erfi-result--
              (let ((next (and (< pos end)
                               (next-single-property-change pos 'overlay-plist object end))))
                (if (or (null next) (= next end))
                    (nreverse res)
                    (let ((len (get-text-property next 'overlay-length object))
                          (prop (get-text-property next 'overlay-plist object)))
                      (if (null len)
                          (progn
                            (setq pos next)
                            (throw '--erfi-repeat-- nil))
                          (progn
                            (setq res (cons (list (list next (+ next len)) prop) res))
                            (setq pos next)
                            (throw '--erfi-repeat-- nil)))))))
        (setq --erfi-continue-- nil)))
    --erfi-result--))

(defun milo:erfi-emacs:buffer-substring/etched-overlays (start end &optional buffer)
  (with-current-buffer (or buffer (current-buffer))
    (let ((str (buffer-substring start end))
          (overlays (overlays-in start end)))
      (dolist (ol overlays)
        (let ((s (- (overlay-start ol) start))
              (e (- (overlay-end ol) start)))
          (add-text-properties s e
                               `(overlay-length ,(- e s)
                                 overlay-plist ,(overlay-properties ol))
                               str)))
      str)))

(defun milo:erfi-emacs:restore-etched-overlays! (start end &optional buffer)
  (let* ((buffer (or buffer (current-buffer)))
         (etched-overlays (milo:erfi-emacs:etched-overlays-in start end buffer)))
    (remove-text-properties start end '(overlay-length nil overlay-plist nil) buffer)
    (dolist (eo etched-overlays)
      (destructuring-bind ((s e) plis) eo
        (let1 ol (make-overlay s e buffer)
          (while (not (null plis))
            (overlay-put ol (car plis) (cadr plis))
            (setq plis (cddr plis))))))))

(defun milo:erfi-emacs:insert/etched-overlays (str)
  (let1 p (point)
    (insert str)
    (milo:erfi-emacs:restore-etched-overlays! p (point))))

(defun milo:erfi-emacs:make-button-string/etched-overlays (&rest properties)
  (with-temp-buffer
    (apply 'insert-button properties)
    (milo:erfi-emacs:buffer-substring/etched-overlays (point-min) (point-max))))



;;;
;;; Auxiliary functions
;;;

(defmacro milo:in-directory (dir &rest body)
  (declare (indent 1))
  `(cond ((file-directory-p ,dir)
          (milo:loading-message 'directory ,dir)
          (setq milo:current-indent (+ milo:current-indent 2))
          ,@body
          (setq milo:current-indent (- milo:current-indent 2)))
         ((file-exists-p ,dir)
          (milo:loading-message 'not-directory path))
         (t
          (milo:loading-message 'does-not-exist path))))

(defun milo:x->string (x)
  "Return string of X.  X have to be a string or symbol."
  (cond ((stringp x) x)
        ((symbolp x) (symbol-name x))
        (t (lwarn 'milo :error "wrong type argument"))))



;;;
;;; API
;;;

(defun milo-load (path spec)
  "Load files indicated by SPEC under root PATH.

SPEC alikes SXML:
  spec = rel-path
       | \"(\" rel-path \"(\" \"@\" options \")\" \")\"
       | \"(\" rel-dir-path specs \")\"
       | \"(\" rel-dir-path \"(\" \"@\" options \")\" specs \")\"
  specs = nil | spec specs
  options = plist
  rel-path     = string
  rel-dir-path = string (or symbol)

For more details and example, see document.

Note: Currently this is a function but we may rewrite this as a macro for
loading speed.

Supported options:
  :load-after-load FILE
    Enclose load function within `eval-after-load' with FILE.
  :only-when-exists VAL
    If VAL is non-nil, ignore and do nothing when all candidate paths not exist.
    Currently this is only availabre for elisp file."
  (prog1 nil
    (run-hooks 'milo-pre-load-hook)
    (let ((time (benchmark-elapse
                  (setq milo:buffer (get-buffer-create milo-buffer-name)
                        milo:load-status 'success)
                  (with-current-buffer milo:buffer
                    (delete-region (point-min) (point-max)))
                  (milo:message "MiLo -- Manual Init Loader\n\n")
                  (milo:message "With root directory: %s\n" path)
                  (milo:load path spec)
                  (milo:message "\n")
                  (cond ((eq milo:load-status 'success)
                         (milo:message (propertize "All files loaded successfully.\n"
                                                   'font-lock-face 'milo-success-face)))
                        ((eq milo:load-status 'error)
                         (milo:message (propertize "There were errors on the loading.\n"
                                                   'font-lock-face 'milo-failure-face)))))))
      (milo:message "Total time: %f seconds\n\n\n" time))
    (run-hooks 'milo-post-load-hook)))


(defmacro milo-lazyload (func library &rest body)
  "See source code or result of `macroexpand'."
  (declare (indent 2))
  `(when (locate-library ,library)
     ,@(mapcar (lambda (f) `(autoload ',f ,library nil t)) func)
     (eval-after-load ,library
       '(funcall ,`(lambda () ,@body)))))



;;;
;;; Core
;;;

(defun milo:load (path spec)
  (cond ((atom spec)
         (milo:load:aux (expand-file-name (milo:x->string spec) path)
                        nil nil))
        ((milo:have-option-p spec)
         (milo:load:aux (expand-file-name (milo:x->string (car spec)) path)
                        (cadr spec) (cddr spec)))
        (t
         (milo:load:aux (expand-file-name (milo:x->string (car spec)) path)
                        nil (cdr spec)))))
(defun milo:load:aux (path option specs)
  (let ((load-after (or (memq :load-after-load option)
                        (memq :load-before-call option)
                        (memq :load-after-call option))))
    ;; Notice that the case value is nil, is used in `milo:lazy-load'.
    (if (and load-after (cadr load-after))
        (milo:lazy-load path option specs (car load-after) (cadr load-after))
        (if (file-accessible-directory-p path)
            (milo:in-directory path
              (mapc (lambda (x) (milo:load path x))
                    (funcall milo-preprocess-specs-function path option specs)))
            (funcall milo-load-file-function path option)))))

(defun milo:preprocess-specs (directory option specs)
  "See source code."
  (append milo-ex-ante-specs specs milo-ex-post-specs))

(defun milo:have-option-p (spec)
  (and (consp spec)
       (not (null (cdr spec)))
       (consp (cadr spec))
       (eq '@ (caadr spec))))

(defun milo:lazy-load (path option specs condition condition-option)
  (progn
    (when (or (and (memq :load-after-load option)  ; Dirty due to independency of ERFI.
                   (or (memq :load-before-load option)
                       (memq :load-after-call option)))
              (and (memq :load-before-load option)
                   (memq :load-after-call option)))
      (let ((msg (concat "lazy-load: ERROR: :load-after-load, :load-before-call and :load-after-call"
                         " may not occur together.")))
        (lwarn 'milo :error msg)
        (error (concat "milo: " msg))))
    (let* ((option (cons '@  ; option = `(@ . ,plist)
                         (plist-put (copy-sequence (cdr option)) condition nil)))
           (loaded-flag nil)
           (load-fn (lambda ()
                      (when (not loaded-flag)
                        (milo:message "Lazy load:\n")
                        (milo:load:aux path option specs)
                        (setq loaded-flag t)))))
      (cond ((eq condition :load-after-load)
             (eval-after-load condition-option `(funcall ,load-fn)))
            ((eq condition :load-before-call)
             (milo:lazy-load:advice 'before condition-option load-fn))
            ((eq condition :load-after-call)
             (milo:lazy-load:advice 'after condition-option load-fn)))
      (milo:loading-message 'lazy-load path))))
(defun milo:lazy-load:advice (timing fn load-fn)
  (progn
    (when (or (not (symbolp fn))
              (not (fboundp fn)))
      (let ((msg (concat "lazy-load: ERROR: Value for :load-" (milo:x->string timing)
                         "-call must be a function: %s")))
        (lwarn 'milo :error msg fn)
        (error (concat "milo: " msg) fn)))
;    (ad-add-advice (function fn)
    (ad-add-advice fn
                   `(milo-lazy-load-ad nil t
                                       (advice . (lambda ()
                                                   "Load user init file or directory (only once)."
                                                   (funcall ,load-fn)
                                                   (ad-disable-advice ,fn ,timing 'milo-lazy-load-ad)
                                                   (ad-activate ,fn))))
                   timing 0)
;    (ad-activate (function fn))))
    (ad-activate fn)))


;; Loading one file

(defun milo:complete-el-path (path)
  (loop for f in (if milo-file-name-prefix
                     (list path
                           (expand-file-name (concat milo-file-name-prefix
                                                     (file-name-nondirectory path))
                                             (file-name-directory path)))
                     (list path))
        if (file-exists-p f)
        return f
        finally return nil))

(defun milo:load-file (path option)
  "Load .el file desingated by absolute path PATH.

Assume that the variable `milo-file-name-prefix' is a string \"init-\"
in this explanation.

If path is an elisp file, for example \"/path/to/file.el\", search files with
name \"/path/to/file.el\", \"/path/to/init-file.el\" in this order, and load
that file.  If .el file exists and .elc file is valid, load .elc file instead.

Supported option:
  :only-when-exists VAL
    If VAL is non-nil, ignore and do nothing when all candidate paths not exist."
  (let ((only-when-exists (memq :only-when-exists option))
        (file (milo:complete-el-path path)))
    (if file
        (let ((elc (concat file "c")))
          (milo:load-file:aux (if (and (file-exists-p elc) (not (file-newer-than-file-p file elc)))
                                  elc
                                  file)
                              option))
        (when (not only-when-exists)
          (milo:loading-message 'does-not-exist path)))))
(defun milo:load-file:aux (path option)
  (cond ((file-exists-p path)
         (cond (milo:dry-run-flag
                (milo:loading-message 'file path))
               (milo-raise-error
                (let ((time (benchmark-elapse (load-file path))))
                  (milo:loading-message 'file path time)))
               (t
                (condition-case _
                    (let ((time (benchmark-elapse (load-file path))))
                      (milo:loading-message 'file path time))
                  (error (milo:loading-message 'load-error path))))))
        ((loop for r in milo-regexp-ignore-file-not-exist
               thereis (string-match r path))
         nil)
        (t
         (milo:loading-message 'does-not-exist path))))



;;;
;;; Logging
;;;

(defun milo:message (&rest args)
  (with-current-buffer milo:buffer
    (goto-char (point-max))
    (milo:erfi-emacs:insert/etched-overlays (apply 'format args))))
(defun milo:loading-message (type path &rest args)
  (let ((file (funcall milo-file-name-truncate-function path))
        (indent (make-string milo:current-indent ?\ ))
        (success (format "[%s]" (propertize "OK" 'font-lock-face 'milo-success-face)))
        (failure (format "[%s]" (propertize "XX" 'font-lock-face 'milo-failure-face)))
        (fmt (concat "%s%-" (number-to-string milo-longest-file-name-length) "s\t: %s %s\n")))
    (cond ((eq type 'file)
           (milo:message fmt indent (milo:erfi-emacs:make-button-string/etched-overlays
                                     file
                                     'path (replace-regexp-in-string "\\.elc$" ".el" path)
                                     'action (lambda (x) (find-file (button-get x 'path))))
                         success
                         (if (not (null args))
                             (format "loaded in %f seconds" (car args))
                             "loaded successfully")))
          ((eq type 'directory)
           (milo:message "%s%s\n" indent file))
          ((eq type 'lazy-load)
           (let ((path (if (string-match "\\.el$" path)
                           (milo:complete-el-path path)
                           path)))
             (milo:message fmt indent (milo:erfi-emacs:make-button-string/etched-overlays
                                       (funcall milo-file-name-truncate-function path)
                                       'path path
                                       'action (lambda (x) (find-file (button-get x 'path))))
                           "[  ]" "loading is delayed.")))
          ((memq type '(does-not-exist error not-dirrectory load-error))
           (setq milo:load-status 'error)
           (milo:message fmt indent file failure
                         (cond ((eq type 'does-not-exist) "no such file")
                               ((eq type 'not-directory)  "not a directory")
                               ((eq type 'load-error)     "load error"))))
          (t
           (lwarn 'milo :error "PROGRAM ERROR")
           (error "milo: PROGRAM ERROR")))))

(defun milo:inform-error-modestly ()
  "Separate window and show error modestly."
  (interactive)
  (when (and (eq 'error milo:load-status)
             (not milo-raise-error))
    (split-window-horizontally)
    (other-window 1)
    (switch-to-buffer milo:buffer)
    (other-window -1)))



(provide 'manual-init-loader)
;;; manual-init-loader.el ends here
