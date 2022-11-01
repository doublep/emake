;;; eldev.el --- Elisp development tool  -*- lexical-binding: t -*-

;;; Copyright (C) 2022 Paul Pogonyshev

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of
;; the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see https://www.gnu.org/licenses.

(require 'eldev)


(defvar eldev--doctests nil)

;; Internal helper for `eldev-defdoctest'.
(defun eldev--register-doctest (doctest name keywords)
  (while keywords
    (eldev-pcase-exhaustive (pop keywords)
      ((and (or :caption :categories :depends-on) keyword)
       (eldev-put doctest keyword (pop keywords)))))
  (eldev--assq-set name doctest eldev--doctests))

(defmacro eldev-defdoctest (name arguments &rest body)
  "Define a doctor test.

Test function should return a plist with at least `result' key.
Associated value is then available to later doctests.  The plist
may also contain `ok', `warnings' and `short-answer' keys.  If
`ok' is not set, it is determined by whether `warnings' is
present and non-empty.  `short-answer' defaults to string “YES”
or “NO”, depending on `ok'."
  (declare (doc-string 3) (indent 2))
  (let ((parsed-body  (eldev-macroexp-parse-body body))
        (doctest-name (intern (replace-regexp-in-string (rx bol (1+ (not (any "-"))) (1+ "-") (? "doctest-")) "" (symbol-name name))))
        keywords)
    (setf body (cdr parsed-body))
    (while (keywordp (car body))
      (pcase (pop body)
        (:name       (setf doctest-name (pop body)))
        (keyword (push keyword keywords) (push (pop body) keywords))))
    `(progn (defun ,name ,arguments
              ,@(car parsed-body)
              ,@body)
            (eldev--register-doctest ',name ',doctest-name ',(nreverse keywords)))))


(defun eldev--do-doctor (selectors)
  (when (or (null selectors) (string-prefix-p "-" (car selectors)))
    (push "all" selectors))
  (let (doctests)
    (dolist (selector selectors)
      (let ((negate (string-prefix-p "-" selector)))
        (setf selector (intern (replace-regexp-in-string (rx bos (any "+-")) "" selector)))
        (if (eq selector 'all)
            (setf doctests (unless negate (copy-sequence eldev--doctests)))
          (let ((matches (assq selector eldev--doctests)))
            (setf matches (if matches
                              (list matches)
                            (or (eldev-filter (memq selector (eldev-listify (eldev-get (cdr it) :categories))) eldev--doctests)
                                (when eldev-dwim
                                  (let ((regexp (rx-to-string (symbol-name selector))))
                                    (eldev-filter (string-match-p regexp (symbol-name (car it))) eldev--doctests))))))
            (unless matches
              (signal 'eldev-error `(:hint ,(when eldev-dwim "As `eldev-dwim' is set, also tried it as a name substring to no success")
                                     "Selector `%s' matches neither a doctest name nor a category" ,selector)))
            (setf doctests (eldev-filter (if (memq it matches) (not negate) (memq it doctests)) eldev--doctests))))))
    (if doctests
        (let ((num-user-requested (length doctests))
              (num-visibly-failed 0)
              (doctests-sequence  (list nil))
              results
              generated-output
              last-with-warnings)
          (dolist (doctest (nreverse doctests))
            (eldev--doctor-build-sequence doctests-sequence (car doctest) t))
          (dolist (doctest (nreverse (car doctests-sequence)))
            (let* ((name           (car doctest))
                   (function       (cdr (assq name eldev--doctests)))
                   (user-requested (cdr doctest)))
              (eldev-verbose "Running doctest `%s' %s..." name (if user-requested "on user request" "needed by some other test"))
              (let ((plist (funcall function results)))
                (when plist
                  (push (cons name (plist-get plist 'result)) results)
                  (unless (plist-member plist 'ok)
                    (setf plist (plist-put plist 'ok (null (plist-get plist 'warnings)))))
                  (let ((failed (not (plist-get plist 'ok))))
                    ;; Non-user-requested doctests are not reported even if they generate
                    ;; warnings.
                    (when (and user-requested (or failed eldev-doctor-print-successful))
                      (when failed
                        (setf num-visibly-failed (1+ num-visibly-failed)))
                      (let ((caption       (eldev-get function :caption))
                            (short-answer  (or (plist-get plist 'short-answer) (if failed "NO" "YES")))
                            (with-warnings (eldev-unless-quiet failed)))
                        (when (or (and with-warnings generated-output) last-with-warnings)
                          (eldev-output ""))
                        (unless (stringp caption)
                          (setf caption (eval caption t)))
                        (eldev-output "%s %s"
                                      (if with-warnings (eldev-colorize caption 'section) caption)
                                      (eldev-colorize short-answer (if failed 'error 'success)))
                        (when with-warnings
                          (dolist (warning (or (eldev-listify (plist-get plist 'warnings)) (eldev-colorize "No warning text provided" 'details)))
                            (unless (plist-get plist :dont-reformat-warnings)
                              (with-temp-buffer
                                (insert warning)
                                (let ((fill-column 78))
                                  (set-mark 1)
                                  (fill-paragraph nil t)
                                  (setf warning (buffer-string)))))
                            (eldev-output "\n%s" warning)))
                        (setf last-with-warnings with-warnings
                              generated-output   t))))))))
          (if (= num-visibly-failed 0)
              (eldev-print "\nRan %s, %s" (eldev-message-plural num-user-requested "doctest")
                           (eldev-colorize (if (= num-user-requested 1) "it didn't generate any warnings" "none generated any warnings") 'success))
            (eldev-warn "Ran %s, %s generated %s"
                        (eldev-message-plural num-user-requested "doctest")
                        (if (= num-visibly-failed num-user-requested)
                            (if (= num-user-requested 1) "it" "all of them")
                          (format "%d of them" num-visibly-failed))
                        (if (= num-visibly-failed 1) "a warning" "warnings"))
            (signal 'eldev-quit 1)))
      (eldev-print "Nothing to delete"))))

(defun eldev--doctor-build-sequence (sequence name user-requested &optional dependency-stack)
  ;; A project may disable certain tests.  They still run when non-user-requested
  ;; (i.e. because of depedencies), but results are not printed.
  (unless (and user-requested (eldev--doctor-test-disabled-p name))
    (let ((scheduled (assq name (car sequence))))
      (if scheduled
          (when user-requested
            (setf (cdr scheduled) t))
        (when (memq name dependency-stack)
          (error "Circular dependency detected: `%s', %s" name (eldev-message-enumerate nil (car sequence))))
        (let ((function (cdr (assq name eldev--doctests))))
          (dolist (depends-on (eldev-listify (eldev-get function :depends-on)))
            (eldev--doctor-build-sequence sequence depends-on nil dependency-stack)))
        (push `(,name . ,user-requested) (car sequence))))))

(defun eldev--doctor-list-tests ()
  (dolist (entry (reverse eldev--doctests))
    (let* ((name     (car entry))
           (function (cdr entry))
           (caption  (eldev-get function :caption)))
      (unless (eldev--doctor-test-disabled-p name)
        (unless (stringp caption)
          (setf caption (eval caption t)))
        (if (eq eldev-verbosity-level 'quiet)
            (eldev-output "%s" name)
          (eldev-output "%-28s %s" (eldev-colorize name 'name) caption)))))
  (signal 'eldev-quit 0))

(defun eldev--doctor-test-disabled-p (name)
  (memq name (eldev-listify eldev-doctor-disabled-tests)))




(eldev-defdoctest eldev-doctest-eldev-presence (_results)
  :caption    (eldev-format-message "Does the project contain file `%s'?" eldev-file)
  :categories eldev
  (if (file-exists-p eldev-file)
      '(result t)
    `(result   nil
      warnings ,(eldev-format-message "\
It is recommended to have file `%s' in your project root if you use Eldev.
Otherwise, certain tools (e.g. Projectile or `flycheck-eldev') won't consider
your project to be Eldev-based.  It is even fine to have a completely empty
file if you don't have anything to configure or customize." eldev-file))))

(eldev-defdoctest eldev-doctest-eldev-byte-compilable (results)
  :caption    (eldev-format-message "Is file `%s' byte-compilable?" eldev-file)
  :categories eldev
  :depends-on eldev-presence
  (when (cdr (assq 'eldev-presence results))
    (if (with-temp-buffer
          (insert-file-contents "Eldev")
          (hack-local-variables)
          no-byte-compile)
        `(result   nil
          warnings ,(eldev-format-message "\
It is recommended to make file `%s' byte-compilable.  This would make it
validatable by `flycheck-eldev'.  Earlier examples of the file would often
contain local variable “no-byte-compile: t”, but this turned out to be
unnecessary." eldev-file))
      `(result t))))

(eldev-defdoctest eldev-doctest-explicit-main-file (_results)
  :caption    "Does the project specify its main file?"
  :categories (eldev package packaging)
  (cond (eldev-project-main-file
         '(result t))
        ((let ((pkg-file (eldev-package-descriptor-file-name)))
           (and pkg-file (file-readable-p pkg-file)))
         '(result nil short-answer "NO (but has a package descriptor)"))
        (t
         (let (with-package-info)
           (dolist (file (directory-files eldev-project-dir nil "\\.el\\'"))
             (with-temp-buffer
               (insert-file-contents file)
               (when (ignore-errors (package-buffer-info))
                 (push file with-package-info))))
           ;; 0 shouldn't happen, as then Eldev should fail to begin with.
           (if (<= (length with-package-info) 1)
               '(result nil short-answer "NO (but has unambiguous headers)")
             `(result   nil
               warnings ,(eldev-format-message "\
You should set variable `eldev-project-main-file' in file `%s' explicitly, as
there are several files at the top level with valid Elisp package headers: %s.
Eldev (and Emacs packaging system) will choose one at random, thus producing
unreliable results." eldev-file (eldev-message-enumerate nil with-package-info))))))))

(eldev-defdoctest eldev-doctest-explicit-emacs-version (_results)
  :caption    "Does the project state which Emacs version it needs?"
  :categories (dependencies deps)
  (let (found)
    (dolist (dependency (package-desc-reqs (eldev-package-descriptor)))
      (when (and (eq (car dependency) 'emacs) (cadr dependency))
        (setf found t)))
    (if found
        '(result t)
      '(result nil warnings "\
The project should explicitly state its minimum required Emacs version in its
package headers or the package descriptor file."))))

(eldev-defdoctest eldev-doctest-stable/unstable-archives (_results)
  :caption    "Are stable/unstable package archives used where possible?"
  :categories (dependencies deps)
  (let (warnings)
    (dolist (archive eldev--known-package-archives)
      (when (eldev--stable/unstable-archive-p (cadr archive))
        ;; We won't detect situations where e.g. `melpa-stable' and `melpa-unstable' are
        ;; added separately, but oh well.
        (let* ((stable        (plist-get (cadr archive) :stable))
               (unstable      (plist-get (cadr archive) :unstable))
               (stable-used   (member (nth 1 (assq stable   eldev--known-package-archives)) package-archives))
               (unstable-used (member (nth 1 (assq unstable eldev--known-package-archives)) package-archives)))
          (when (eldev-xor stable-used unstable-used)
            (push (eldev-format-message "\
It is recommended to use stable/unstable package archive `%s' instead of `%s'
directly.  This way you can switch between the variants using global options
`--stable' and `--unstable'."
                                        (car archive) (if stable-used stable unstable))
                  warnings)))))
    `(result   ,(null warnings)
      warnings ,warnings)))


(provide 'eldev-doctor)
