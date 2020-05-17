(require 'test/common)


(ert-deftest eldev-archives-1 ()
  (eldev--test-run "trivial-project" ("archives")
    (should (string-prefix-p "None specified" stdout))
    (should (= exit-code 0))))

(ert-deftest eldev-archives-2 ()
  (eldev--test-run "trivial-project" ("--quiet" "archives")
    (should (string= stdout ""))
    (should (= exit-code 0))))

(ert-deftest eldev-archives-3 ()
  (eldev--test-run "project-a" ("archives")
    (should (string= stdout (format "archive-a: %s  (priority: 0, defaulted)\n"
                                    (expand-file-name "test/package-archive-a" eldev-project-dir))))
    (should (= exit-code 0))))

(ert-deftest eldev-archives-4 ()
  (eldev--test-run "project-b" ("archives")
    (should (string= stdout (format "archive-a: %s  (priority: 0, defaulted)\n"
                                    (expand-file-name "test/package-archive-a" eldev-project-dir))))
    (should (= exit-code 0))))

(ert-deftest eldev-archives-5 ()
  (eldev--test-run "project-c" ("archives")
    (should (string= stdout (format "archive-a: %s  (priority: 0, defaulted)\n"
                                    (expand-file-name "test/package-archive-a" eldev-project-dir))))
    (should (= exit-code 0))))

(ert-deftest eldev-archives-with-priorities-1 ()
  (eldev--test-run "missing-dependency-a" ("--setup" `(eldev-use-package-archive `("archive-a" . ,(expand-file-name "../package-archive-a")) 100)
                                           "--setup" `(eldev-use-package-archive `("archive-b" . ,(expand-file-name "../package-archive-b")) 0)
                                           "archives")
    (should (string= stdout (format "archive-a: %s  (priority: 100)\narchive-b: %s  (priority: 0)\n"
                                    (expand-file-name "test/package-archive-a" eldev-project-dir) (expand-file-name "test/package-archive-b" eldev-project-dir))))
    (should (= exit-code 0))))

(ert-deftest eldev-archives-with-priorities-2 ()
  (eldev--test-run "missing-dependency-a" ("--setup" `(eldev-use-package-archive `("archive-a" . ,(expand-file-name "../package-archive-a")) 0)
                                           "--setup" `(eldev-use-package-archive `("archive-b" . ,(expand-file-name "../package-archive-b")) 100)
                                           "archives")
    ;; Archives must be reordered according to their priorities.
    (should (string= stdout (format "archive-b: %s  (priority: 100)\narchive-a: %s  (priority: 0)\n"
                                    (expand-file-name "test/package-archive-b" eldev-project-dir) (expand-file-name "test/package-archive-a" eldev-project-dir))))
    (should (= exit-code 0))))

;; It doesn't matter that the project is broken.
(ert-deftest eldev-archives-missing-dependency-1 ()
  ;; It might be installed by a different test that provides a
  ;; suitable archive in setup form.
  (let ((eldev--test-project "missing-dependency-a"))
    (eldev--test-delete-cache)
    (eldev--test-run nil ("archives")
      (should (string-prefix-p "None specified" stdout))
      (should (= exit-code 0)))))


(provide 'test/archives)
