;;  -*- lexical-binding: t -*-

(require 'test/common)


;; https://github.com/emacs-eldev/eldev/issues/29
;;
;; Not about any particular command, but about initializing dependencies.  Eldev would
;; often report dependencies as required by wrong packages, if they were required by
;; several, but in different versions.
(ert-deftest eldev-issue-29 ()
  (eldev--test-run "issue-29-project" ("--setup" `(eldev-use-local-sources "../issue-29-insane-dependency") "prepare")
    (should (string-match-p "issue-29-insane-dependency" stderr))
    (should (= exit-code 1))))


;; https://github.com/emacs-eldev/eldev/issues/32
;;
;; Eldev would fail to provide Org snapshot to a project that depends on Org version newer
;; than what is built into Emacs, even if appropriate package archive was configured.  It
;; actually worked locally (bug in our `eldev--global-cache-url-retrieve-synchronously',
;; was triggered only for remote URLs), see corresponding integration tests.  This one is
;; added for completeness, to catch potential errors in the future.
(ert-deftest eldev-issue-32-local ()
  (let ((eldev--test-project "issue-32-project"))
    (eldev--test-delete-cache)
    ;; Test that it fails when no archive is configured.
    (eldev--test-run nil ("prepare")
      (should (= exit-code 1)))
    (eldev--test-delete-cache)
    ;; But with an appropriate archive it should work.
    (eldev--test-run nil ("--setup" `(eldev-use-package-archive `("org-pseudoarchive" . ,(expand-file-name "../org-pseudoarchive"))) "prepare")
      (should (= exit-code 0)))
    (eldev--test-run nil ("dependency-tree" "--list-built-ins")
      (should (eldev-any-p (string-match-p "\\<org\\>.+overriden.+99999999.9999" it) (eldev--test-line-list stdout)))
      (should (= exit-code 0)))))


(ert-deftest eldev-issue-102-1 ()
  ;; Org is an Emacs built-in.  Make sure it still can be developed with Eldev.
  (let ((eldev--test-project "project-fake-org"))
    (eldev--test-delete-cache)
    (eldev--test-run nil ("eval" `(bound-and-true-p org-is-fake))
      (should (string= stdout "t\n"))
      (should (= exit-code 0)))))

(ert-deftest eldev-issue-102-2 ()
  (let ((eldev--test-project "dependency-org"))
    (eldev--test-run nil ("eval" `(progn (require 'org) (bound-and-true-p org-is-fake)))
      (should (string= stdout "nil\n"))
      (should (= exit-code 0)))
    ;; Must load the local-sourced dependency package if requested, even if Org is a built-in.
    (eldev--test-run nil ("--setup" `(eldev-use-local-sources "../project-fake-org")
                          "eval" `(progn (require 'org) (bound-and-true-p org-is-fake)))
      (should (string= stdout "t\n"))
      (should (= exit-code 0)))))

(ert-deftest eldev-version-0 ()
  ;; Issue #107: Eldev wouldn't work with a project that declared version 0.0.
  (eldev--test-run "version-0-0" ("eval" 1)
    (should (string= stdout "1\n"))
    (should (= exit-code 0))))


;; Not a bug, just doesn't seem to fit anywhere else.  Test that
;; `eldev-known-tool-packages' can be customized.
(ert-deftest eldev-known-tool-packages-1 ()
  (let ((eldev--test-project "trivial-project"))
    (eldev--test-delete-cache)
    (eldev--test-run nil ("--setup" `(push '(relint :archive relint-pseudoarchive) eldev-known-tool-packages)
                          "--setup" `(setf eldev--known-package-archives '((relint-pseudoarchive ("relint-pseudoarchive" . ,(expand-file-name "../relint-pseudoarchive")) 0)))
                          "eval" `(progn (eldev-add-extra-dependencies 'runtime '(:tool relint))
                                         (eldev-load-extra-dependencies 'runtime)
                                         (require 'relint)
                                         (relint-hello)))
      (should (string= stdout "\"Hello, I'm a fake\"\n"))
      (should (= exit-code 0)))))


;; https://github.com/emacs-eldev/eldev/issues/57
;;
;; `(message nil)' is a valid call in Emacs, so it must not fail under Eldev either.
(ert-deftest eldev-message-nil ()
  (eldev--test-run "trivial-project" ("exec" `(message nil))
    (should (string= stdout ""))
    (should (string= stderr "\n"))
    (should (= exit-code 0))))


;; https://github.com/emacs-eldev/eldev/issues/61
;;
;; `vc-responsible-backend' actually throws if there is no active backend, and not returns
;; nil.  Hard to notice when your home directory is Git-managed.
(ert-deftest eldev-vc-detect-must-not-throw ()
  (eldev-vc-detect "/"))


;; https://debbugs.gnu.org/db/67/67025.html
(eldev-ert-defargtest eldev-emacs-bug-67025 (with-debug)
                      (nil t)
  (let ((eldev--test-project "project-a"))
    (eldev--test-delete-cache)
    (eldev--test-run nil ("--setup" `(eldev-use-package-archive `("seq-pseudoarchive" . ,(expand-file-name "../seq-pseudoarchive")))
                          "--setup" `(eldev-add-extra-dependencies 'exec '(:package seq :version "99999999"))
                          (if with-debug "--debug" "--no-debug") "exec" 1)
      (should (string= stdout ""))
      (should (= exit-code 0)))))

;; https://debbugs.gnu.org/db/65/65763.html
(eldev-ert-defargtest eldev-emacs-bug-65763 (with-debug)
                      (nil t)
  (eval-and-compile (require 'vc-git))
  (let ((debug-on-error  with-debug)
        (vc-git-program  "im-not-installed-for-sure"))
    (condition-case error
        (let ((dir (eldev--test-tmp-subdir "emacs-bug-65763")))
          (mkdir dir t)
          ;; Using a random filename, else Emacs might cache VC-related data between tests.
          (with-current-buffer (find-file-noselect (expand-file-name (format "whatever-%s.txt" (random)) dir) t)
            (insert "bla bla bla")
            (save-buffer)))
      (error (ert-fail error)))))


(provide 'test/integration/misc)
