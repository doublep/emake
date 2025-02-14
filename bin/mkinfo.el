;;; mkinfo.el --- Make .info  -*- lexical-binding: t -*-

(defun fix-targets ()
  "Fix targets in links."
  (let ((make-backup-files nil)
        targets)
    (beginning-of-buffer)
    (while (re-search-forward "<<\\(.+\\)>>" nil t)
      (push (match-string 1) targets))
    (dolist (target targets)
      (beginning-of-buffer)
      (let ((pattern (format "\\[\\[\\(#%s\\)\\]" target)))
        (while (re-search-forward pattern nil t)
          ;; NOTE: While this is the correct form of hyperlink to
          ;; marked objects, this won't get rendered as hyperlinks in
          ;; .info upon conversion. Still better than errors stopping
          ;; it.
          (replace-match (format "[[%s]" target)))))
    (save-buffer)))

(defun make-info ()
  "Make the .info file from the given Org document."
  (let ((filename (car (last command-line-args))))
    (find-file filename)
    (fix-targets)
    (org-texinfo-export-to-texinfo)))
