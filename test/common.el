;;  -*- lexical-binding: t -*-

(require 'eldev)
(require 'eldev-vc)
(require 'ert)
(require 'subr-x)
(require 'tar-mode)


(defvar eldev--test-project nil
  "All `test-project' arguments default to this value.")

(defvar eldev--test-eldev-local nil)
(defvar eldev--test-eldev-dir nil)

(defvar eldev--test-shell-command (expand-file-name "bin/eldev" eldev-project-dir))

(defvar eldev--test-packaged-self nil)


(defun eldev--test-dir ()
  (file-name-as-directory (expand-file-name "test" eldev-project-dir)))

(defun eldev--test-tmp-subdir (name)
  (expand-file-name name (expand-file-name (format "test/.tmp/%s.%s" emacs-major-version emacs-minor-version) eldev-project-dir)))

(defun eldev--test-eldev-dir ()
  (or eldev--test-eldev-dir (eldev--test-tmp-subdir "stdroot")))


(defun eldev--test-project-dir (&optional test-project)
  (file-name-as-directory (expand-file-name (or test-project eldev--test-project) (eldev--test-dir))))

(defun eldev--test-project-cache-dir (&optional test-project)
  (expand-file-name eldev-cache-dir (eldev--test-project-dir test-project)))

(defun eldev--test-delete-cache (&optional test-project)
  (let ((dir (eldev--test-project-cache-dir test-project)))
    (when (file-exists-p dir)
      (ignore-errors (delete-directory dir t)))))

(defmacro eldev--test-call-process (program-name executable command-line &rest body)
  (declare (indent 3) (debug (sexp body)))
  (let ((actual-command-line `(list ,@command-line))
        (no-errors           (make-symbol "$no-errors"))
        (discard-ansi        t)
        (robust-mode         'propagate)
        description
        process-input-form
        important-values
        important-files
        previous-calls)
    (pcase command-line
      (`(:eval ,expression) (setf actual-command-line expression)))
    (while (keywordp (car body))
      (eldev-pcase-exhaustive (pop body)
        (:description     (setf description        (pop body)))
        (:process-input   (setf process-input-form (pop body)))
        (:discard-ansi    (setf discard-ansi       (pop body)))
        (:robust-mode     (unless (equal program-name "Eldev")
                            (error "`:robust-mode' is only for invoking child Eldev"))
                          (setf robust-mode        (pop body)))
        (:important-value (push (pop body)         important-values))
        (:important-files (setf important-files    (eldev-listify (pop body))))
        (:previous-call   (let ((name (pop body))
                                (call (pop body)))
                            (push `(cons ,name ,call) previous-calls)))))
    `(let* ((command-line       ,actual-command-line)
            (process-input      ,process-input-form)
            (process-input-file (when process-input (make-temp-file "eldev-test")))
            (stderr-file        (make-temp-file "eldev-stderr-")))
       (when process-input-file
         (with-temp-file process-input-file
           (insert process-input)))
       ,@(when (equal program-name "Eldev")
           `((push ,(format "--robust-mode=%s" (if (if (eq robust-mode 'propagate) (eldev-retry-on-errors-p) robust-mode) "always" "never")) command-line)))
       (unwind-protect
           ;; Using `eldev-call-process' here mostly for a bit of testing for it.
           (eldev-call-process ,executable (mapcar (lambda (argument) (if (stringp argument) argument (prin1-to-string argument))) command-line)
             :destination  `(t ,stderr-file)
             :discard-ansi ,discard-ansi
             :infile       process-input-file
             (let* ((stdout    (buffer-string))
                    (stderr    (with-temp-buffer
                                 (insert-file-contents stderr-file)
                                 (buffer-string)))
                    (call-info (list :program      ,program-name
                                     :executable   executable
                                     :command-line command-line
                                     :directory    default-directory
                                     :description  ,description
                                     :input        process-input
                                     :stdout       stdout
                                     :stderr       stderr
                                     :exit-code    exit-code))
                   ,no-errors)
               (goto-char 1)
               (unwind-protect
                   (condition-case error
                       (prog1 (progn ,@body)
                         (setf ,no-errors t))
                     (ert-test-skipped (setf ,no-errors t)
                                       (signal (car error) (cdr error))))
                 (unless ,no-errors
                   (eldev--test-call-process-show call-info)
                   ,@(when important-values
                       `((eldev-warn "Important values:")
                         ,@(mapcar (lambda (x) `(eldev-warn "%S:\n%S" ',x ,x)) (nreverse important-values))))
                   ,@(when important-files
                       `((eldev-warn "Important files (oldest first):")
                         (dolist (data (sort (mapcar (lambda (file) (cons file (nth 5 (file-attributes file)))) ',important-files)
                                             (lambda (a b) (< (if (cdr a) (float-time (cdr a)) 0) (if (cdr b) (float-time (cdr b)) 0)))))
                           ;; Not using `current-time-string' as not precise enough.
                           (eldev-warn "    `%s': %s" (car data) (if (cdr data) (float-time (cdr data)) "missing")))))
                   ,@(when previous-calls
                       `((eldev--test-call-process-show-previous-calls ,@(nreverse previous-calls))))))))
         (when process-input-file
           (ignore-errors (delete-file process-input-file)))
         (ignore-errors (delete-file stderr-file))))))

(defun eldev--test-call-process-show (call)
  (when (plist-get call :description)
    (eldev-warn "%s" (eldev-colorize (apply #'eldev-format-message (eldev-listify (plist-get call :description))) 'error)))
  (eldev-warn "Ran %s as `%s' in directory `%s'"
              (plist-get call :program)
              (eldev-message-command-line (plist-get call :executable) (plist-get call :command-line))
              (plist-get call :directory))
  (when (plist-get call :input)
    (eldev-warn "Process input:\n%s" (eldev-colorize (plist-get call :input) 'verbose)))
  (eldev-warn "Stdout contents:\n%s" (eldev-colorize (plist-get call :stdout) 'verbose))
  (unless (string= (plist-get call :stderr) "")
    (eldev-warn "Stderr contents:\n%s" (eldev-colorize (plist-get call :stderr) 'verbose)))
  (eldev-warn "Process exit code: %s" (plist-get call :exit-code)))

(defun eldev--test-call-process-show-previous-calls (&rest calls)
  (setf calls (eldev-filter (cdr it) calls))
  (when calls
    (eldev-warn "\nImportant previous process calls:")
    (dolist (entry calls)
      (eldev-warn "\n%s:" (car entry))
      (eldev--test-call-process-show (cdr entry))
      (eldev-warn ""))))

(defmacro eldev--test-run (test-project command-line &rest body)
  "Execute child Eldev process.
BODY is executed with output bound as STDOUT and STDERR
variables.  Stdout output is also available to BODY in the
current (temporary) buffer, with the point positioned at the
beginning.  Exit code of the process is bound as EXIT-CODE."
  (declare (indent 2) (debug (stringp sexp body)))
  `(let* ((eldev--test-project (or ,test-project eldev--test-project))
          (default-directory   (eldev--test-project-dir ,test-project))
          (force-bootstrapping (list nil))
          (process-environment (eldev--test-run-create-process-environment force-bootstrapping)))
     (when (car force-bootstrapping)
       (eldev--test-force-bootstrapping-now))
     (eldev--test-call-process "Eldev" eldev--test-shell-command ,command-line
       ,@body)))

(defun eldev--test-run-create-process-environment (force-bootstrapping)
  `(,(format "ELDEV_LOCAL=%s" (or eldev--test-eldev-local
                                  ;; When in mode `packaged', also generate
                                  ;; a package for spawned processes to use.
                                  (when (and (eq eldev-project-loading-mode 'packaged)
                                             (not (eq eldev--test-packaged-self 'in-process))
                                             (null eldev--test-eldev-dir))
                                    (unless eldev--test-packaged-self
                                      ;; Set to prevent recursive reentry.
                                      (setf eldev--test-packaged-self 'in-process)
                                      (eldev--test-create-eldev-archive "packaged-self")
                                      (setf eldev--test-packaged-self t)
                                      ;; Delete any previously installed in such a way Eldev.
                                      (ignore-errors (delete-directory (eldev--test-tmp-subdir (format "stdroot/%s.%s/bootstrap"
                                                                                                       emacs-major-version emacs-minor-version))
                                                                       t))
                                      ;; Make sure to rebootstrap test Eldev explicitly, else its message
                                      ;; "Bootstrapping..." on stderr can screw up some tests.  Don't do
                                      ;; it in this function, since `process-environment' is not bound yet.
                                      (setf (car force-bootstrapping) t))
                                    (concat ":pa:" (eldev--test-tmp-subdir "packaged-self")))
                                  ;; Otherwise, let the child processes use the
                                  ;; sources (maybe byte-compiled) directly.
                                  eldev-project-dir))
    ,(format "ELDEV_DIR=%s"   (eldev--test-eldev-dir))
    ,@process-environment))

(defun eldev--test-emacsloadpath (&rest extras)
  (format "EMACSLOADPATH=%s" (mapconcat #'identity (append extras load-path) path-separator)))


(defmacro eldev--test-and-delete-temp-directory (directory-var description &rest body)
  (declare (indent 2) (debug (symbolp stringp body)))
  (let ((directory-form directory-var))
    (while (keywordp (car body))
      (eldev-pcase-exhaustive (pop body)
        (:directory-form (setf directory-form (pop body)))))
    `(unwind-protect
         (prog1 (progn ,@body)
           ;; Delete the copy if there are no errors.
           (when ,directory-var
             (ignore-errors (delete-directory ,directory-form t))
             (setf ,directory-var nil)))
       (when ,directory-var
         (eldev-warn (format "%s left intact for investigation: `%%s'" ,description) ,directory-form)))))

(defun eldev--test-force-bootstrapping-now ()
  (eldev-call-process eldev--test-shell-command nil :die-on-error t))

(defun eldev--test-file-name-parent-directory (filename)
  (if (fboundp 'file-name-parent-directory)
      (with-no-warnings (file-name-parent-directory filename)))
  ;; In 2024 they finally decided this would be a useful function.  Have to backport.
  (let* ((expanded-filename (expand-file-name filename))
         (parent (file-name-directory (directory-file-name expanded-filename))))
    (cond ((or (null parent) (equal parent expanded-filename))
           nil)
          ((not (file-name-absolute-p filename))
           (file-relative-name parent))
          (t
           parent))))

(defmacro eldev--test-with-temp-copy (test-project vc-backend &rest body)
  "Execute BODY in a temporary copy of TEST-PROJECT.
The copy will be made with the specified VC-BACKEND; if it is not
available, test is skipped automatically.

Inside BODY, `eldev--test-project' will be bound to the temporary
copied directory, not to the one specified by TEST-PROJECT."
  (declare (indent 2) (debug (stringp sexp body)))
  (let ((enabled t)
        (ignores :std)
        after-copy)
    (while (keywordp (car body))
      (eldev-pcase-exhaustive (pop body)
        (:enabled    (setf enabled    (pop body)))
        (:ignores    (setf ignores    (pop body)))
        (:after-copy (push (pop body) after-copy))))
    `(let ((vc-backend ,vc-backend)
           eldev--test-project)
       (if ,enabled
           (unless (setf eldev--test-project (eldev--test-make-temp-copy ,test-project vc-backend ,ignores
                                                                         ,(when after-copy `(lambda () ,@(reverse after-copy)))))
             (ert-skip (eldev-format-message "%s couldn't be found" (eldev-vc-full-name vc-backend))))
         (setf vc-backend nil))
       (eldev--test-and-delete-temp-directory eldev--test-project (format "%s copy" (eldev-vc-full-name vc-backend))
         :directory-form (eldev--test-file-name-parent-directory eldev--test-project)
         ,@body))))

(defun eldev--test-make-temp-copy (test-project vc-backend ignores after-copy)
  "Create a copy of the TEST-PROJECT with given VC-BACKEND.
The backend may be nil, in which case the copy is not versioned.

Returns a new project directory.  The caller may assume that its
parent is the real temporary root (it may be used to create
copies of something external to the project)."
  (unless (memq vc-backend '(nil Git Hg SVN))
    (error "Cannot create temporary VC copy for backend `%s'" vc-backend))
  (let* ((svnadmin   (when (eq vc-backend 'SVN) (eldev-svnadmin-executable t)))
         (executable (if vc-backend
                         (when (or (not (eq vc-backend 'SVN)) svnadmin)
                           (eldev-vc-executable vc-backend t))
                       t)))
    (unless executable
      (ert-skip (eldev-format-message "%s doesn't appear to be installed" (eldev-vc-full-name vc-backend))))
    (let* ((project-dir    (eldev--test-project-dir test-project))
           (copy-base-dir  (file-name-as-directory (make-temp-file "eldev-" t (if vc-backend (format "-test-%s" (downcase (symbol-name vc-backend))) "-test"))))
           ;; Since the result of `package-dir-info' depends on the directory name (oh
           ;; lol, the robustness) when reading `*-pkg.el' file, create a subdirectory
           ;; with "the proper" name here.  Eventually need a subdirectory anyway if we
           ;; copy our local package archives along.
           (copy-dir       (file-name-as-directory (expand-file-name test-project copy-base-dir)))
           (repository-dir (when svnadmin
                             (file-name-as-directory (make-temp-file "eldev-" t "-test-svnrepo"))))
           (repository-url (format "file://%s%s"
                                   ;; Windows file paths require the extra root node at the front.
                                   (if (eq system-type 'windows-nt) "/" "")
                                   repository-dir)))
      ;; To avoid copying generated files.
      (eldev--test-run test-project ("clean" "everything")
        (should (= exit-code 0)))
      (when svnadmin
        (eldev-call-process svnadmin   `("create" ,repository-dir) :die-on-error t)
        (eldev-call-process executable `("mkdir" ,(format "%s/trunk" repository-url) ,(format "%s/branches" repository-url) "--message" "Init") :die-on-error t)
        (eldev-call-process executable `("checkout" ,(format "%s/trunk" repository-url) ,copy-dir) :die-on-error t))
      (copy-directory project-dir copy-dir t nil t)
      (let (local-archives-to-copy)
        ;; Pretty ugly, but here it is only important that it works.  Copy local package
        ;; archives that are referred to in file `Eldev' of the project.  Otherwise you
        ;; wouldn't even be able to run the tests in the temporary copy, for example.
        ;; Another option would be to modify paths in the copied `Eldev', but that feels
        ;; even uglier.
        (with-temp-buffer
          (ignore-errors (insert-file-contents (locate-file eldev-file (list project-dir))))
          (while (re-search-forward (rx "(expand-file-name \"../" (group (1+ (not (any ?\"))))) nil t)
            (let ((archive-path (file-name-as-directory (match-string 1))))
              (unless (member archive-path local-archives-to-copy)
                (push archive-path local-archives-to-copy)))))
        (dolist (archive-path local-archives-to-copy)
          (copy-directory (expand-file-name archive-path (eldev--test-dir)) (expand-file-name archive-path copy-base-dir) t nil t)))
      (let ((default-directory copy-dir))
        (when after-copy
          (funcall after-copy))
        (when vc-backend
          (unless svnadmin
            (eldev-call-process executable `("init") :die-on-error t))
          (when (eq ignores :std)
            (eldev--vc-ignore-standard-files vc-backend))
          (pcase vc-backend
            (`Git (eldev-call-process executable `("config" "user.name"  "Eldev")             :die-on-error t)
                  (eldev-call-process executable `("config" "user.email" "eldev@example.com") :die-on-error t))
            ;; Mercurial doesn't appear to provide commands for this.
            (`Hg  (with-temp-file ".hg/hgrc"
                    (erase-buffer)
                    (insert "[ui]\nusername = Eldev <eldev@example.com>\n"))))
          ;; Subversion doesn't allow 'add .'.
          (let ((all-files (directory-files copy-dir)))
            (dolist (special-file '("." ".." ".git" ".hg" ".svn"))
              (setf all-files (remove special-file all-files)))
            (eldev-call-process executable `("add" ,@all-files) :die-on-error t))
          (eldev-call-process executable `("commit" "--message" "Copy") :die-on-error t)))
      copy-dir)))

(defmacro eldev--test-with-temp-script-copy (&rest body)
  (declare (indent 0) (debug (body)))
  `(let* ((temp-script-dir           (make-temp-file "eldev-" t "-test-bin"))
          (eldev--test-shell-command (expand-file-name "bin/eldev" temp-script-dir)))
     (copy-directory (expand-file-name "bin" eldev-project-dir) (file-name-as-directory temp-script-dir))
     (eldev--test-and-delete-temp-directory temp-script-dir "Temporary copy of script directory"
       ,@body)))

(defun eldev--test-switch-vc-branch (vc-backend branch-name)
  (unless (eldev-external-or-absolute-filename (file-relative-name (eldev--test-project-dir) eldev-project-dir))
    (error "Refusing to switch branches in non-external project"))
  (let ((default-directory (eldev--test-project-dir)))
    (dolist (command (eldev-pcase-exhaustive vc-backend
                       (`Git `(("branch"   ,branch-name)
                               ("checkout" ,branch-name)))
                       (`Hg  `(("branch"   ,branch-name)))
                       (`SVN `(("copy"     "^/trunk" ,(format "^/branches/%s" branch-name) "--message" "Branching")
                               ("switch"   ,(format "^/branches/%s" branch-name))))))
      (eldev-call-process (eldev-vc-executable vc-backend) command
        :die-on-error t))))


(defmacro eldev--test-with-external-dir (test-project packages &rest body)
  "Execute BODY with a directory containing copies of the PACKAGES.
The directory is meant to simulate `~/.emacs.d/elpa' for testing
option `--external'.  Variable named `external-dir' will be
visible inside BODY.

If the BODY starts with keyword `:enabled' with a nil value
afterwards, directory creation is skipped."
  (declare (indent 2) (debug (stringp sexp body)))
  (let ((enabled t))
    (while (keywordp (car body))
      (eldev-pcase-exhaustive (pop body)
        (:enabled (setf enabled (pop body)))))
    `(let* ((eldev--test-project (or ,test-project eldev--test-project))
            (external-dir        (when ,enabled (eldev--test-create-external-dir ,packages)))
            ;; User-accessible variable so that it can be modified.
            (preexisting-files   (when external-dir (eldev--test-find-files external-dir))))
       (eldev--test-and-delete-temp-directory external-dir "External directory"
         (prog1 ,@body
           (when external-dir
             ;; Eldev must not modify contents of the external directory.
             (eldev--test-assert-files external-dir preexisting-files)))))))

(defun eldev--test-create-external-dir (packages)
  (setf packages (eldev-listify packages))
  (let ((external-dir (make-temp-file "eldev-" t "-test")))
    ;; Certainly not the fastest way, but at least robust.  Call a child process to
    ;; install the dependencies and then copy them to the temporary external directory.
    (when packages
      (eldev--test-run nil ("exec" `(dolist (dependency ',(eldev-listify packages))
                                      (copy-directory (package-desc-dir (eldev-find-package-descriptor dependency)) ,(file-name-as-directory external-dir))))
        (unless (= exit-code 0)
          (error "Unable to create external dependency directory"))))
    ;; Just create an empty directory to simplify some tests; in real use this directory
    ;; will be present and even not empty.
    (make-directory (expand-file-name "archives" external-dir))
    external-dir))


(defun eldev--test-file (file &optional test-project)
  (expand-file-name file (eldev--test-project-dir test-project)))

(defun eldev--test-file-contents (test-project file &optional not-required)
  (condition-case error
      (with-temp-buffer
        (insert-file-contents (eldev--test-file file test-project))
        (buffer-string))
    (file-error (unless not-required
                  (signal (car error) (cdr error))))))

(defmacro eldev--test-with-file-buffer (test-project file &rest body)
  "Execute in a buffer with FILE from TEST-PROJECT and write results back."
  (declare (indent 2) (debug (stringp sexp body)))
  `(eldev-with-file-buffer (eldev--test-file ,file ,test-project)
     ,@body))

(defmacro eldev--test-capture-output (&rest body)
  `(with-temp-buffer
     (let ((standard-output              (current-buffer))
           (eldev-output-time-diffs      nil)
           (eldev-output-newline-pending nil)
           (eldev-coloring-mode          nil))
       ,@body
       (buffer-string))))

(defun eldev--test-first-line (text)
  (replace-regexp-in-string (rx bos (0+ nonl) (group (0+ anything)) eos) "" text t t 1))

(defun eldev--test-lines (&rest arguments)
  "Join specified lines (expected output) into one string."
  (if arguments
      (let ((formatter   nil)
            (trailing-lf "\n"))
        (while (keywordp (car arguments))
          (eldev-pcase-exhaustive (pop arguments)
            (:fmt    (setf formatter nil))
            (:nofmt  (setf formatter #'identity))
            (:lf     (setf trailing-lf "\n"))
            (:nolf   (setf trailing-lf ""))))
        (concat (mapconcat (or formatter (lambda (line) (eldev-format-message (replace-regexp-in-string "%" "%%" line)))) (eldev-flatten-tree arguments) "\n")
                trailing-lf))
    ""))

(defun eldev--test-line-list (multiline-string)
  (split-string multiline-string "\n" t))

(defmacro eldev--test-canonicalize-bin/eldev-path (path)
  (let ((result (make-symbol "$result")))
    (if (eq system-type 'windows-nt)
        `(let ((,result  ,path))
           (if (string-match "^\\(.*/bin/eldev\\)" ,result)
               (let* ((matched (match-string 1 ,result))
                      (replacement
                       (replace-regexp-in-string "bin\\\\eldev" "bin\\eldev.bat"
                                                 (replace-regexp-in-string "/" "\\" matched
                                                                           nil 'literal)
                                                 nil 'literal)))
                 (replace-match replacement nil 'literal ,result 1))
             ,result))
      path)))

(defmacro eldev--test-in-project-environment (&rest body)
  `(let ((eldev-project-dir   (eldev--test-project-dir))
         (eldev-shell-command (eldev--test-canonicalize-bin/eldev-path
                               eldev--test-shell-command)))
     ,@body))


(defmacro eldev--test-without-files (test-project files-to-delete &rest body)
  (declare (indent 2)
           (debug (stringp sexp body)))
  (let ((files                  (make-symbol "$files"))
        (actual-files-to-delete `(list ,@(eldev-listify files-to-delete))))
    (pcase files-to-delete
      (`(:eval ,expression) (setf actual-files-to-delete expression)))
    `(let ((,files              ,actual-files-to-delete)
           (eldev--test-project (or ,test-project eldev--test-project)))
       (eldev--test-delete-quietly nil ,files)
       (let* ((project-dir       (eldev--test-project-dir))
              (preexisting-files (eldev--test-find-files project-dir)))
         (ignore preexisting-files)
         (unwind-protect
             (progn ,@body)
           (eldev--test-delete-quietly nil ,files))))))

(declare-function directory-files-recursively "subr" t)

(defun eldev--test-find-files (directory)
  ;; Not using `eldev-find-files' if easily possible (Emacs 25 and
  ;; up) to avoid making tests depend on its correctness.
  (let (files)
    (if (fboundp #'directory-files-recursively)
        (dolist (file (directory-files-recursively directory (rx (1+ any))))
          (let ((relative-name (file-relative-name file directory)))
            (unless (string-match-p (rx "." (or "eldev" "git") "/") relative-name)
              (push relative-name files))))
      (setf files (eldev-find-files '("!.eldev/" "!.git/") nil directory)))
    (sort files #'string<)))

(defun eldev--test-delete-quietly (test-project files)
  (let ((dir (eldev--test-project-dir test-project)))
    (dolist (file (eldev-listify files))
      (ignore-errors (delete-file (expand-file-name file dir))))))


(defun eldev--test-assert-files (directory &rest arguments)
  (eldev--test-assert-unsorted (eldev--test-find-files directory) (eldev-flatten-tree arguments) (eldev-format-message "Wrong files in `%s'" directory)))

(defun eldev--test-assert-building (stdout targets)
  (eldev--test-assert-unsorted (eldev--test-line-list stdout)
                               (mapcar (lambda (target)
                                         (format "%-8s %s" (or (car (cdr-safe target)) "ELC") (if (consp target) (car target) target)))
                                       targets)
                               "Wrong building steps"))

(defun eldev--test-assert-unsorted (actual expected &optional error-header)
  (setf actual   (sort (copy-sequence actual)   #'string<)
        expected (sort (copy-sequence expected) #'string<))
  (let (unexpected
        missing
        problems)
    (while (or actual expected)
      (cond ((and actual expected (string= (car actual) (car expected)))
             (setf actual   (cdr actual)
                   expected (cdr expected)))
            ((or (not expected) (and actual expected (string< (car actual) (car expected))))
             (push (pop actual) unexpected))
            (t
             (push (pop expected) missing))))
    (when missing
      (push (eldev-format-message "%s missing" (eldev-message-enumerate nil (nreverse missing))) problems))
    (when unexpected
      (push (eldev-format-message "%s unexpected" (eldev-message-enumerate nil (nreverse unexpected))) problems))
    (when problems
      (ert-fail (format "%s: %s" (or error-header "Expectations failed") (eldev-message-enumerate nil problems nil t t))))))

;; Optional modification entries should have the form of (FILE AFTER INSERTED-TEXT), where
;; AFTER is an optional regexp.  The regexp and INSERTED-TEXT should contain whitespace as
;; needed, this function doesn't add any.
(defun eldev--test-create-eldev-archive (archive-name &optional forced-version &rest modifications)
  (let ((archive-dir (eldev--test-tmp-subdir archive-name)))
    (ignore-errors (delete-directory archive-dir t))
    (if forced-version
        (eldev--test-run ".." ("--setup" `(setf eldev-dist-dir ,archive-dir)
                               "package" "--entry-file" "--force-version" forced-version)
          (should (= exit-code 0)))
      (eldev--test-run ".." ("--setup" `(setf eldev-dist-dir ,archive-dir)
                             "package" "--entry-file")
        (should (= exit-code 0))))
    (with-temp-file (expand-file-name "archive-contents" archive-dir)
      (prin1 `(1 ,(with-temp-buffer
                    (insert-file-contents-literally (expand-file-name (format "eldev-%s.entry" (or forced-version (eldev-message-version (eldev-find-package-descriptor 'eldev)))) archive-dir))
                    (read (current-buffer))))
             (current-buffer)))
    (when modifications
      ;; We can edit `.tar' archives with Elisp functions, though in quite an ugly way.
      (let ((inhibit-message        t)
            ;; This is a workaround for Emacs bug, else produced `.tar' file is corrupt on
            ;; Windows.
            (inhibit-eol-conversion t)
            (tar-file-name          (format "eldev-%s.tar" (or forced-version (eldev-message-version (eldev-package-descriptor)))))
            tar-buffers)
        (unwind-protect
            (with-current-buffer (car (push (find-file-noselect (expand-file-name tar-file-name archive-dir)) tar-buffers))
              (dolist (entry modifications)
                (goto-char 1)
                (search-forward (format "/%s" (nth 0 entry)))
                (with-current-buffer (car (push (tar-extract) tar-buffers))
                  (when (nth 1 entry)
                    (search-forward-regexp (nth 1 entry)))
                  (insert (nth 2 entry))
                  (save-buffer)))
              (save-buffer))
          (dolist (buffer tar-buffers)
            (kill-buffer buffer)))))
    archive-dir))


(defun eldev--test-skip-if-missing-tool (exit-code stderr)
  (unless (= exit-code 0)
    (let ((lines (eldev--test-line-list stderr)))
      (while lines
        (let ((line (pop lines)))
          (when (and (string-match-p (rx "Emacs version" (+ any) "required" (+ any)) line)
                     (and lines (string-match-p "required as a development tool" (car lines))))
            (ert-skip line)))))))

(defun eldev--test-skip-if-missing-linter (exit-code stderr)
  (unless (= exit-code 0)
    (dolist (line (eldev--test-line-list stderr))
      (when (string-match-p (rx "Emacs version" (+ any) "required" (+ any) "cannot use linter") line)
        (ert-skip line)))))


(defun eldev--test-pretend-source-is-changed (el-file &optional test-project)
  "Make given EL-FILE newer than all `.elc' file in TEST-PROJECT.
Also the project's package tarball used for loading in mode
`packaged' (if at all generated).  The purpose is to make sure
that those files get regenerated.  The file may or may not really
be changed before or after by the caller, this function deals
only with modification time."
  (let* ((el-file      (expand-file-name el-file (eldev--test-project-dir test-project)))
         ;; Consider all `.elc' files in the directory, not only the
         ;; direct product of compiling `el-file'.
         (elc-files    (directory-files (file-name-directory el-file) t (rx ".elc" eos)))
         ;; Assuming the location, but good enough for tests.
         (package-file (expand-file-name (format "%s.tar" (let ((eldev-verbosity-level 'quiet))
                                                            (eldev--package-name-version (eldev--test-project-dir test-project))))
                                         (expand-file-name "local/generated" (let ((eldev-project-dir (eldev--test-project-dir test-project))) (eldev-cache-dir t))))))
    (while (progn (set-file-times el-file)
                  (eldev-any-p (not (and it (file-newer-than-file-p el-file it))) (cons package-file elc-files)))
      ;; Apparently if OS time granularity is large enough, we can set
      ;; `.el' modification time equal to that of `.elc', not newer.
      ;; Working with time in Elisp is a fucking nightmare, let's just
      ;; sleep instead.
      (sleep-for 0.1))))


(defun eldev--test-unstable-version-rx (version &optional full-string)
  "Create a regexp to match VERSION plus typical snapshot suffix.
I.e. plus “YYYYMMDD.HHMM” of the last commit.  VERSION can be
either a string or a list."
  (let ((regexp (if (stringp version)
                    (rx-to-string `(seq ,version ".2" (= 7 digit) "." (** 1 4 digit)))
                  (rx-to-string `(seq ,(substring (prin1-to-string version) 0 -1) " 2" (= 7 digit) " " (** 1 4 digit) ")")))))
    (when full-string
      (setf regexp (format "\\`%s\\'" regexp)))
    regexp))


(defmacro eldev-ert-defargtest (name arguments values &rest body)
  "Define a parameterized test with given NAME.
This is a poor-man's substitute for functionality missing from
ERT.  Parameters are passed to the defined function as ARGUMENTS.
The specific sets to use are defined by VALUES.  These values are
additionally embedded into final (from ERT point of view) test
name, and can, therefore, be used in selectors.  Check existing
uses to see VALUES format and how they affect actual test names."
  (declare (indent 3))
  (let ((function (make-symbol (format "%s:impl" name))))
    `(progn
       ;; Implementation of `skip-unless' is copied from Emacs source.
       (cl-macrolet ((skip-unless (form) `(ert--skip-unless ,form)))
         ;; Apparently we cannot get away with unnamed lambdas here.
         (defun ,function ,arguments ,@body))
       ,@(mapcar (lambda (arg-values)
                   `(ert-deftest ,(intern (format "%s/%s" name (eldev--ert-defargtest-format-arguments arg-values))) ()
                      (,function ,@(if (= (length arguments) 1) (list arg-values) arg-values))))
                 values))))

(defun eldev--ert-defargtest-format-arguments (arguments)
  (let ((print-quoted t))
    (downcase (replace-regexp-in-string " " "/" (replace-regexp-in-string (rx (not (any word "-" " "))) "" (prin1-to-string arguments))))))


(provide 'test/common)
