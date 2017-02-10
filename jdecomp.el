;;; jdecomp.el --- Interface to Java decompilers  -*- lexical-binding: t; -*-

;; Copyright (C) 2016  Tianxiang Xiong

;; Author: Tianxiang Xiong <tianxiang.xiong@gmail.com>
;; Keywords: decompile, java, languages, tools
;; Package-Requires: ((emacs "24.5"))
;; URL: https://github.com/xiongtx/jdecomp
;; Version: 0.1.0

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Interface to Java decompilers.

;;; Code:

(require 'cl-lib)
(require 'subr-x)


;;;; Customize

(defgroup jdecomp nil
  "Interface to Java decompilers."
  :group 'development
  :link '(url-link :tag "GitHub" "https://github.com/xiongtx/jdecomp")
  :prefix "jdecomp-"
  :tag "JDecomp")

(defcustom jdecomp-decompiler-type 'cfr
  "Type of Java decompiler to use."
  :group 'jdecomp
  :type '(radio
          (const :tag "CFR" 'cfr)
          (const :tag "Fernflower" 'fernflower)))

(defcustom jdecomp-decompiler-paths nil
  "Alist of Java decompiler types and their paths."
  :group 'jdecomp
  :options '(cfr fernflower)
  :type '(alist :key-type symbol :value-type (file :must-match t)))

(defcustom jdecomp-decompiler-options nil
  "Alist of Java decompiler command line options."
  :group 'jdecomp
  :options '(cfr fernflower)
  :type '(alist :key-type symbol :value-type (repeat string)))


;;;; Utilities
(defun jdecomp--jar-p (file)
  "Return t if FILE is a JAR."
  (ignore-errors
    (let ((type-output (with-output-to-string
                         (process-file "file" nil standard-output nil
                                       "-bL" "--mime-type"
                                       (expand-file-name file)))))
      (string= "application/java-archive" (string-trim type-output)))))

(defun jdecomp--classfile-p (file)
  "Return t if FILE is a Java class file."
  (string= (file-name-extension file) "class"))

(defun jdecomp--java-files (dir)
  "Return list of Java files in directory DIR."
  (directory-files dir t "\\.java\\'"))

(defun jdecomp--make-temp-file (prefix &optional dir-flag suffix)
  "Like `make-temp-file', but creates parent dirs as necessary."
  (with-file-modes ?\700
    (let (file)
      (while (condition-case ()
                 (progn
                   (setq file
                         (make-temp-name
                          (if (zerop (length prefix))
                              (file-name-as-directory
                               temporary-file-directory)
                            (expand-file-name prefix
                                              temporary-file-directory))))
                   (if suffix
                       (setq file (concat file suffix)))
                   (if dir-flag
                       ;; All `make-temp-file' is missing here is a `t'
                       (make-directory file t)
                     (write-region "" nil file nil 'silent nil 'excl))
                   nil)
               (file-already-exists t))
        ;; the file was somehow created by someone else between
        ;; `make-temp-name' and `write-region', let's try again.
        nil)
      file)))

;; From: http://emacs.stackexchange.com/a/3843/10269
(defun jdecomp---extract-to-file (jar file)
  "Return path of extracted FILE.

FILE is extracted from JAR using COMMAND. The extracted file is
saved to a temp dir."
  (let* ((command archive-zip-extract)
         (output-dir (jdecomp--make-temp-file (concat "jdecomp" "/" (file-name-sans-extension file)) t))
         (output-file (expand-file-name (file-name-nondirectory file) output-dir)))
    (apply #'call-process
           (car command)                ;program
           nil                          ;infile
           `(:file ,output-file)        ;destination
           nil                          ;display
           (append (cdr command) (list jar file)))
    output-file))


;;;; Internal

(defun jdecomp--decompiled-buffer-name (file)
  "Return the buffer name of decompiled FILE."
  (format "*Decompiled %s*" (file-name-nondirectory file)))

(defun jdecomp--decompiler-path (decompiler-type)
  "Return path for DECOMPILER-TYPE from `jdecomp-decompiler-paths'."
  (assoc-default decompiler-type jdecomp-decompiler-paths))

(defun jdecomp--decompiler-options (decompiler-type)
  "Return list of normalized options for DECOMPILER-TYPE.

Normalization example:

   (\"--foo-opt foo\" \"--bar-opt\" \"bar\")
=> (\"--foo-opt\" \"foo\" \"--bar-opt\" \"bar\")"
  (let ((options (assoc-default decompiler-type jdecomp-decompiler-options)))
    (split-string (string-join options " ") " ")))

(cl-defun jdecomp--decompile-command (&optional (decompiler-type jdecomp-decompiler-type))
  "Return the decompile command.

Optional parameter DECOMPILER-TYPE defaults to
`jdecomp-decompiler-type'."
  (condition-case nil
      (cl-ecase decompiler-type
        ('cfr #'jdecomp--cfr-command)
        ('fernflower #'jdecomp--fernflower-command))
    (error (user-error "%s is not a known decompiler" decompiler-type))))

(cl-defun jdecomp--ensure-decompiler (&optional decompiler-type jdecomp-decompiler-type)
  "Ensure that the decompiler for DECOMPILER-TYPE is available.

Optional parameter DECOMPILER-TYPE defaults to
`jdecomp-decompiler-type'."
  (unless (condition-case nil
              (cl-ecase decompiler-type
                ('cfr (jdecomp--jar-p (jdecomp--decompiler-path 'cfr)))
                ('fernflower (jdecomp--jar-p (jdecomp--decompiler-path 'fernflower))))
            (error (user-error "%s is not a known decompiler" decompiler-type)))
    (user-error "%s decompiler is not available" decompiler-type)))

(defun jdecomp--cfr-command (file &optional jar)
  "Decompile FILE with CFR and return result as string.

FILE must be a Java classfile."
  (jdecomp--ensure-decompiler 'cfr)
  (with-output-to-string
    (let ((classpath (or jar (file-name-directory file) default-directory)))
      (apply #'call-process "java" nil standard-output nil
             `("-jar" ,(expand-file-name (jdecomp--decompiler-path 'cfr))
               "--extraclasspath" ,classpath
               ,@(jdecomp--decompiler-options 'cfr)
               ,file)))))

(defun jdecomp--fernflower-decompile-file (file &optional extracted-p)
  "Decompile FILE with Fernflower and return result as string.

FILE must be a Java classfile.

Optional parameter EXTRACTED-P, when non-nil, indicates that FILE
was extracted from a JAR with `jdecomp--extract-to-file'."
  (jdecomp--ensure-decompiler 'fernflower)
  (with-temp-buffer
    (let* ((classpath (or (file-name-directory file) default-directory))
           (destination (if extracted-p
                            (file-name-directory file)
                          (jdecomp--make-temp-file (concat "jdecomp" (file-name-sans-extension file)) t))))
      ;; The java-decompiler.jar is not executable
      ;; See: http://stackoverflow.com/a/39868281/864684
      (apply #'call-process "java" nil nil nil
             `("-cp" ,(expand-file-name (jdecomp--decompiler-path 'fernflower))
               "org.jetbrains.java.decompiler.main.decompiler.ConsoleDecompiler"
               "-cp" ,classpath
               ,@(jdecomp--decompiler-options 'fernflower)
               ,file
               ,destination))
      (insert-file-contents (cl-first (jdecomp--java-files destination)))
      (buffer-string))))

(defun jdecomp--fernflower-decompile-file-in-jar (file jar)
  "Decompile FILE with Fernflower and return result as string.

FILE must be a Java classfile."
  (let ((extracted-file (jdecomp---extract-to-file jar file)))
    (jdecomp--fernflower-decompile-file extracted-file t)))

(defun jdecomp--fernflower-command (file &optional jar)
  "Decompile FILE with Fernflower and return result as string.

FILE must be a Java classfile."
  (if jar
      (jdecomp--fernflower-decompile-file-in-jar file jar)
    (jdecomp--fernflower-decompile-file file)))


;;;; API

(defvar jdecomp-preview-mode-map
  (let ((map (copy-keymap special-mode-map)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    map)
  "Keymap for decompiled Java class file buffers.")

;;;###autoload
(define-derived-mode jdecomp-preview-mode java-mode "JDecomp/preview"
  "Major mode for previewing decompiled Java class files.

\\{jdecomp-preview-mode-map}")

;;;###autoload
(defun jdecomp-decompile (file &optional jar)
  "Decompile FILE and return buffer of decompiled contents.

FILE must be a Java class file.

Optional parameter JAR is the name of the JAR archive FILE is
in."
  ;; Check that FILE is a class file
  (unless (jdecomp--classfile-p file)
    (user-error (format "%s is not a Java class file" file)))

  (let ((result (funcall (jdecomp--decompile-command) file jar))
        (buf (get-buffer-create (jdecomp--decompiled-buffer-name file))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert result)
        (setq default-directory (file-name-directory (or jar file)))
        (setq buffer-file-name (if jar
                                   (concat jar ":" file)
                                 file)))
      (setq buffer-read-only t)
      (goto-char (point-min))
      (jdecomp-preview-mode)
      (set-buffer-modified-p nil))
    buf))

;;;###autoload
(defun jdecomp-decompile-and-view (file &optional jar)
  "Decompile FILE and view buffer of decompiled contents.

FILE must be a Java class file.

If called interactively, FILE is the name of the file the current
buffer is visiting."
  (interactive (list (buffer-file-name)))
  (when-let ((buf (jdecomp-decompile file jar)))
    (switch-to-buffer buf)))


;;;; Minor mode

(defun jdecomp-hook-function ()
  (let ((file (buffer-file-name)))
    (when (and jdecomp-mode
               (jdecomp--classfile-p file))
      (kill-buffer (current-buffer))
      (jdecomp-decompile-and-view file))))

(defun jdecomp-archive-hook-function ()
  (pcase-let ((`(,jar ,file) (split-string (buffer-file-name) ":")))
    (when (and jdecomp-mode
               (jdecomp--classfile-p file))
      (kill-buffer (current-buffer))
      (jdecomp-decompile-and-view file jar))))

;;;###autoload
(define-minor-mode jdecomp-mode
  "Automatically decompile Java class files."
  :global t
  (if jdecomp-mode
      (progn
        (add-hook 'find-file-hook #'jdecomp-hook-function)
        (add-hook 'archive-extract-hook #'jdecomp-archive-hook-function))
    (remove-hook 'find-file-hook #'jdecomp-hook-function)
    (remove-hook 'archive-extract-hook #'jdecomp-archive-hook-function)))


(provide 'jdecomp)

;;; jdecomp.el ends here
