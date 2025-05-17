;;; transient-compile.el --- Dynamic transient menu for compilation -*- lexical-binding: t -*-

;; Copyright (C) 2025 Victor Gaydov and contributors

;; Author: Victor Gaydov <victor@enise.org>
;; Created: 26 Jan 2025
;; URL: https://github.com/gavv/transient-compile
;; Version: 0.4
;; Package-Requires: ((emacs "29.2") (f "0.21.0") (s "1.13.0"))
;; Keywords: tools, processes

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; transient-compile implements configurable, automatically built transient
;; menu for selecting target and running compilation.

;; When you invoke `M-x transient-compile', it searches for known build files
;; in current directory and parents, retrieves available targets, groups targets
;; by common prefixes, and displays a menu.  After you select the target, it
;; formats command and passes it to compile or other function.

;; Please refer to README.org and docstrings for further details.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'transient)

(require 'f)
(require 's)

(defgroup transient-compile nil
  "Dynamic transient menu for compilation."
  :prefix "transient-compile-"
  :group 'tools
  :group 'processes
  :link '(url-link "https://github.com/gavv/transient-compile"))

(defcustom transient-compile-function #'compile
  "Function to run compilation command.

You can set it to `project-compile' if you're using `project'
or `projectile'."
  :package-version '(transient-compile . "0.1")
  :group 'transient-compile
  :type '(choice (const :tag "compile" compile)
                 (const :tag "project-compile" project-compile)
                 function))

(defcustom transient-compile-interactive nil
  "Whether to call compile function interactively.

If non-nil, `transient-compile-function' is invoked using `call-interactively',
with initial minibuffer contents set to the selected target's command.

If nil, `transient-compile-function' is invoked directly, with the command
passed as an argument."
  :package-version '(transient-compile . "0.4")
  :group 'transient-compile
  :type 'boolean)

(defcustom transient-compile-verbose nil
  "Print what's happening to messages."
  :package-version '(transient-compile . "0.1")
  :group 'transient-compile
  :type 'boolean)

(defcustom transient-compile-tool-alist
  `(
    ;; https://github.com/go-task/task
    (task :match ,(lambda (directory)
                    (seq-some (lambda (f)
                                (string-match "^[Tt]askfile\\(\\.dist\\)?\\.ya?ml$" f))
                              (directory-files directory)))
          :exe "task"
          :chdir t
          :targets transient-compile-taskfile-targets
          :command transient-compile-taskfile-command)
    ;; https://github.com/casey/just
    (just :match ,(lambda (directory)
                    (or (member-ignore-case "justfile" (directory-files directory))
                        (member-ignore-case ".justfile" (directory-files directory))))
          :exe "just"
          :chdir t
          :targets transient-compile-justfile-targets
          :command transient-compile-justfile-command)
    ;; https://github.com/pydoit/doit
    (doit :match ("dodo.py")
          :exe "doit"
          :chdir t
          :targets transient-compile-dodofile-targets
          :command transient-compile-dodofile-command)
    ;; https://github.com/ruby/rake
    (rake :match ("Rakefile" "rakefile" "Rakefile.rb" "rakefile.rb")
          :exe "rake"
          :chdir t
          :targets transient-compile-rakefile-targets
          :command transient-compile-rakefile-command)
    ;; any POSIX-compliant make
    (make :match ("GNUmakefile" "BSDmakefile" "makefile" "Makefile")
          :exe "make"
          :chdir t
          :targets transient-compile-makefile-targets
          :command transient-compile-makefile-command)
    ;;
    )
  "Assoc list of supported tools.

Alist key is a symbol, e.g. \\='make.
Alist value is a plist with the following fields:
  :match - list of file names or functions for auto-detection (see below)
  :exe - executable name or path
  :chdir - whether to change directory when running
  :targets - function to get list of targets
  :command - function to format build command

When you invoke `transient-compile', it performs a search from the current
directory through the parents, until it finds a match with any of the
commands registered in `transient-compile-tool-alist'.

A command is matched if any of the elements in its `:match' list is matched:
 - If an element is a string, it matches if the directory contains a file
   with that name.
 - If an element is a function, then the function is invoked with the
   directory path, and the element matches if it returned non-nil.

`:match' can be also just a string or a function, which is equivalent to
a single-element list.

If multiple tools can be matched, the order of `transient-compile-tool-alist'
keys defines their precedence.

After a command is matched, it is used to collect targets, build the
transient menu, and run the compilation command.

The `:targets' property defines a function that takes the matched directory
path as an argument (e.g. where Makefile is located in case of `make'), and
returns the list of string names of the available targets.

The `:command' property defines a function that takes two arguments: the
matched directory and the target name.  It returns a string with the command
to run.  The command is then passed to `compile' (or other function, as
defined by `transient-compile-function').

`:exe' and `:chdir' properties are used by the default implementations of
the functions set in `:targets' and `:command' properties, e.g.
`transient-compile-makefile-targets' and `transient-compile-makefile-command'.

`:exe' is useful when the tool is not available in PATH or is named
differently on your system.

`:chdir' defines how to pass matched directory path to the tool:
  - when t, we'll run the tool from that directory
  - when nil, we'll instead pass the directory as an argument
    (`:command' function should do it)"
  :package-version '(transient-compile . "0.1")
  :group 'transient-compile
  :type 'sexp)

(defvar-local transient-compile-tool nil
  "Currently active compilation tool.

This variable is holding a symbol key from `transient-compile-tool-alist'
\(like \\='make).

Normally, `transient-compile' automatically detects tool and directory and binds
`transient-compile-tool' and `transient-compile-directory' during the call.

If desired, you can manually bind one or both of the variables before calling
`transient-compile' to force using of specific tool and/or directory.")

(defvar-local transient-compile-directory nil
  "Currently active compilation directory.

This variable is holding a directory path with the tool-specific build file
\(e.g. for \\='make it's the directory with Makefile).

Normally, `transient-compile' automatically detects tool and directory and binds
`transient-compile-tool' and `transient-compile-directory' during the call.

If desired, you can manually bind one or both of the variables before calling
`transient-compile' to force using of specific tool and/or directory.")

(defvar-local transient-compile-target nil
  "Currently active compilation target.

After the user selects target in transient menu, `transient-compile' binds this
variable to the selected target during the call to `transient-compile-function'
\(In addition to `transient-compile-tool' and `transient-compile-directory').

It may be useful if you provide your own compilation function.
Setting this variable manually has no effect.")

(defcustom transient-compile-detect-function #'transient-compile-default-detect-function
  "Function that detects compilation tool and directory.

Should take no arguments and return a cons, where car is the tool (symbol key
from `transient-compile-tool-alist'), and cdr is directory path.

Default implementation is based on `:match' lists defined in
`transient-compile-tool-alist' for each tool.

For most cases, it should be enough to modify `transient-compile-tool-alist' and
there is no need to redefine this function.

You can also temporary bind local variables `transient-compile-tool' and/or
`transient-compile-directory' instead of redefining this function."
  :package-version '(transient-compile . "0.1")
  :group 'transient-compile
  :type 'function)

(defcustom transient-compile-group-fallback "default"
  "The name of the fallback group for targets without group."
  :package-version '(transient-compile . "0.1")
  :group 'transient-compile
  :type 'string)

(defcustom transient-compile-group-regexp "^\\(.+\\)[^[:alnum:]][[:alnum:]]+$"
  "Regexp to match group name from target name.
Group name should be captured by the first parenthesized sub-expression.
Used by `transient-compile-default-group-function'."
  :package-version '(transient-compile . "0.1")
  :group 'transient-compile
  :type 'regexp)

(defcustom transient-compile-group-function #'transient-compile-default-group-function
  "Function to determine target's group.

Takes target name and returns group name.
If it returns nil, fallback group is used (`transient-compile-group-fallback').

Default implementation uses `transient-compile-group-regexp'."
  :package-version '(transient-compile . "0.1")
  :group 'transient-compile
  :type 'function)

(defcustom transient-compile-split-function #'transient-compile-default-split-function
  "Function to divide targets into groups.

Takes list of targets names and returns assoc list, where key is
group name, and value is list of target names in this group.

Default implementation uses `transient-compile-group-function' with some
reasonable heuristics.

For most customizations, it should be enough to override either
`transient-compile-group-regexp' or `transient-compile-group-function'.

Providing custom `transient-compile-split-function' is useful when you need
custom groupping logic that takes into account all available targets."
  :package-version '(transient-compile . "0.1")
  :group 'transient-compile
  :type 'function)

(defcustom transient-compile-sort-function #'transient-compile-default-sort-function
  "Function to sort groups and targets inside groups.

Takes assoc list returned by `transient-compile-split-function',
and returns its sorted version.

The function is allowed to sort both groups and targets inside groups.

Default implementation sorts groups alphabetically, does not sort targets,
and places fallback group first."
  :package-version '(transient-compile . "0.1")
  :group 'transient-compile
  :type 'function)

(defcustom transient-compile-merge-prefix-targets t
  "Whether to merge group-less targets into larger groups.

If non-nil, if a target doesn't have a group, and target name is a prefix
of a group name, move target into that group.

Has effect only if you're using `transient-compile-default-split-function'."
  :package-version '(transient-compile . "0.1")
  :group 'transient-compile
  :type 'boolean)

(defcustom transient-compile-merge-prefix-groups 1
  "Whether to merge small groups into larger groups.

If non-nil, if a group has no more than specified number of targets, and there
is another group which name is the prefix of the first one, move targets into
that prefix group.

Has effect only if you're using `transient-compile-default-split-function'."
  :package-version '(transient-compile . "0.1")
  :group 'transient-compile
  :type '(choice (const :tag "Disable" nil)
                 (integer :tag "Threshold")))

(defcustom transient-compile-merge-dangling-groups 1
  "Whether to merge small groups into fallback group.

If non-nil, if a group has no more than given number of targets, move
targets into fallback group.

Has effect only if you're using `transient-compile-default-split-function'."
  :package-version '(transient-compile . "0.1")
  :group 'transient-compile
  :type '(choice (const :tag "Disable" nil)
                 (integer :tag "Threshold")))

(defcustom transient-compile-keychar-highlight t
  "Whether to highlight key characters in the menu.

If non-nil, highlight key characters inside group and target names with
`transient-compile-keychar' face."
  :package-version '(transient-compile . "0.1")
  :group 'transient-compile
  :type 'boolean)

(defcustom transient-compile-keychar-unfold t
  "Whether to use upcase/downcase key characters.

If non-nil, allow using upcase and downcase variants of the original
character as the key character."
  :package-version '(transient-compile . "0.1")
  :group 'transient-compile
  :type 'boolean)

(defcustom transient-compile-keychar-regexp "[[:alnum:]]"
  "Regexp for allowed key characters.

Only those characters in group and target names, which match this regex,
can become key characters."
  :package-version '(transient-compile . "0.1")
  :group 'transient-compile
  :type 'regexp)

(defcustom transient-compile-keychar-function nil
  "Custom function that chooses unique key character for a word.

The function should take 3 arguments:
  - name - group or target name for which we choose a key
  - all-names - list of all names, among which the key must be unique
  - key-map - hashtable of taken keys
  - group-p - whether it's group or target

The function should return character to be used as a key.
Character must not be taken by other words (other groups
or other targets in group), i.e. it must not be present
in the key-map.

The function can return nil if it doesn't have a good key.
In this case default algorithm is used for this word."
  :package-version '(transient-compile . "0.1")
  :group 'transient-compile
  :type '(choice (const :tag "Default" nil)
                 function))

(defface transient-compile-heading
  '((t :inherit font-lock-builtin-face))
  "Face used for transient menu heading.
Applied by `transient-compile-default-menu-heading-function'."
  :package-version '(transient-compile . "0.1")
  :group 'transient-compile)

(defface transient-compile-keychar
  '((t :inherit font-lock-string-face :underline t))
  "Face to highlight key character inside group or target name.
Applied if `transient-compile-keychar-highlight' is t."
  :package-version '(transient-compile . "0.1")
  :group 'transient-compile)

(defcustom transient-compile-menu-heading-function
  #'transient-compile-default-menu-heading-function
  "Function that returns menu heading.

Takes 2 arguments:
  - tool - symbol key from `transient-compile-tool-alist', e.g. \\='make
  - directory - path to dir where command will be executed

Returns propertized string heading or nil to hide heading."
  :package-version '(transient-compile . "0.1")
  :group 'transient-compile
  :type 'function)

(defcustom transient-compile-menu-columns-limit nil
  "If non-nil, limits maximum allowed number of menu columns.
Used by `transient-compile-default-menu-columns-function'."
  :package-version '(transient-compile . "0.1")
  :group 'transient-compile
  :type '(choice (const :tag "Unlimited" nil)
                 (integer :tag "Limit")))

(defcustom transient-compile-menu-columns-spread nil
  "Whether to spread the columns so they span across the frame.

If non-nil, columns will have spacing between them and will
occupy the entire frame width.  Otherwise, columns will have
the minimum width needed to fit the contents."
  :package-version '(transient-compile . "0.4")
  :group 'transient-compile
  :type 'boolean)

(defcustom transient-compile-menu-columns-function
  #'transient-compile-default-menu-columns-function
  "Function that returns menu column count.

Takes assoc list returned by `transient-compile-split-function'.
Returns desired number of columns.

`transient-compile' will arange groups into N columns by inserting
a break after each Nth group."
  :package-version '(transient-compile . "0.1")
  :group 'transient-compile
  :type 'function)

;; Prevent byte-compiler warning.
(declare-function transient-compile--menu "transient-compile" t t)

;;;###autoload
(defun transient-compile ()
  "Open transient menu for compilation.

The following steps are performed:

 - Build tool and directory is detected.  See `transient-compile-tool-alist'
   and `transient-compile-detect-function'.

 - Available targets are collected according to the `:targets' function
   of the selected tool from `transient-compile-tool-alist'.

 - Targets are organized into groups.  See `transient-compile-group-function',
   `transient-compile-split-function', `transient-compile-sort-function' and
   other related options.

 - For each target, a unique key sequence is assigned.  See
   `transient-compile-keychar-function' and other related options.

 - Transient menu is built.  See `transient-compile-menu-heading-function' and
   `transient-compile-menu-columns-function' for altering its appearance.

 - Transient menu is opened.  Now we wait until selects target using its
   key sequence, or cancels operation.

 - After user have selected target, compilation command is formatted using
   `:command' function of the selected tool from `transient-compile-tool-alist'.

 - Formatted command is padded to `compile', or `project-compile', or other
   function.  See `transient-compile-function'.

After that, `transient-compile' closes menu and returns, while the command
keeps running in the compilation buffer."
  (interactive)
  ;; Detect tool and dir.
  (let* ((tool-and-dir (transient-compile--tool-detect))
         (tool (car tool-and-dir))
         (directory (cdr tool-and-dir)))
    ;; Bind values during the call.
    ;; If user already bound these variables, we'll keep the same values.
    (let ((transient-compile-tool tool)
          (transient-compile-directory directory))
      ;; Collect data.
      (let* ((targets (transient-compile--tool-targets tool directory))
             (grouped-targets (funcall transient-compile-sort-function
                                       (funcall transient-compile-split-function
                                                targets)))
             (menu-heading
              (funcall transient-compile-menu-heading-function
                       tool directory))
             (menu-columns
              (funcall transient-compile-menu-columns-function
                       grouped-targets)))
        ;; Rebuild menu.
        (eval `(transient-define-prefix transient-compile--menu ()
                 ,@(transient-compile--build-grid
                    menu-heading
                    menu-columns
                    (transient-compile--build-menu
                     tool
                     directory
                     grouped-targets))))
        ;; Clear echo area from our own logs.
        (when transient-compile-verbose
          (message ""))
        ;; Open menu.
        (transient-compile--menu)))))

(defun transient-compile-default-detect-function ()
  "Default implementation of `transient-compile-detect-function'.

Detects compilation tool and directory.
E.g. for this file layout:
  /foo
    Makefile
    /bar   <- current directory

it would return (make . “/foo“)

In that cons, \\='make defines compilation tool (a symbol key of the
`transient-compile-tool-alist'), and “/foo“ defines tool-specific
compilation directory.

Detection is based on `:match' lists from `transient-compile-tool-alist'."
  ;; If both tool and directory are forced, there is nothing to do.
  (if (and transient-compile-tool
           transient-compile-directory)
      (cons transient-compile-tool transient-compile-directory)
    ;; If only one of the tool and directory is forced, it will be
    ;; used during matching.
    (transient-compile--apply-matchers
     (transient-compile--build-matchers))))

(defun transient-compile-default-group-function (target)
  "Default implementation for `transient-compile-group-function'.
Matches group using `transient-compile-group-regexp'."
  (when (string-match transient-compile-group-regexp target)
    (match-string 1 target)))

(defun transient-compile-default-split-function (targets)
  "Default implementation for `transient-compile-split-function'.

Takes list of target names and returns assoc list, where key is
group name, and value is list of target names in this group.

Default implementation uses `transient-compile-group-function' to get group
names of the targets.

It also implements heruistics enabled by variables:
  - `transient-compile-merge-prefix-targets'
  - `transient-compile-merge-prefix-groups'
  - `transient-compile-merge-dangling-groups'"
  (let (groups fallback-group)
    ;; Split targets into groups.
    ;; Fallback group is for targets without group.
    (dolist (target targets)
      (unless (let ((group-name (funcall transient-compile-group-function target)))
                (when (and (s-present-p group-name)
                           (not (string= group-name transient-compile-group-fallback)))
                  (if-let ((group (assoc group-name groups)))
                      (nconc (cdr group) (list target))
                    (setq groups
                          (nconc groups (list (cons group-name (list target))))))))
        (setq fallback-group
              (nconc fallback-group (list target)))))
    ;; If there is target "foo" in fallback group, and there is group "foo"
    ;; or "foo_bar", move target "foo" into that group.
    (when transient-compile-merge-prefix-targets
      (dolist (target (seq-copy fallback-group))
        ;; shortest prefix
        (when-let ((group (car
                           (seq-sort (lambda (a b)
                                       (string< (car a) (car b)))
                                     (seq-filter (lambda (gr)
                                                   (s-prefix-p target (car gr)))
                                                 groups)))))
          (push target (cdr group))
          (setq fallback-group (seq-remove (lambda (tg)
                                             (string= tg target))
                                           fallback-group)))))
    ;; If there is a small group "foo_bar", and there is group "foo", then
    ;; move the elements of "foo_bar" group into group "foo".
    (when transient-compile-merge-prefix-groups
      (while (seq-find
              (lambda (group)
                (let ((group-name (car group))
                      (group-targets (cdr group)))
                  (when (<= (length group-targets)
                            transient-compile-merge-prefix-groups)
                    ;; shortest prefix
                    (when-let ((prefix-group
                                (car
                                 (seq-sort (lambda (a b)
                                             (string< (car a) (car b)))
                                           (seq-filter
                                            (lambda (gr)
                                              (and (not (string= (car gr) group-name))
                                                   (s-prefix-p (car gr) group-name)))
                                            groups)))))
                      (nconc (cdr prefix-group) group-targets)
                      (setq groups (seq-remove (lambda (gr)
                                                 (string= (car gr) group-name))
                                               groups))))))
              groups)))
    ;; Merge remaining groups that are too small into fallback group.
    (when transient-compile-merge-dangling-groups
      (dolist (group (seq-copy groups))
        (let ((group-name (car group))
              (group-targets (cdr group)))
          (when (<= (length group-targets)
                    transient-compile-merge-dangling-groups)
            (setq fallback-group
                  (nconc fallback-group group-targets))
            (setq groups (seq-remove (lambda (gr)
                                       (string= (car gr) group-name))
                                     groups))))))
    ;; Return groups.
    (append (when fallback-group
              (list (cons transient-compile-group-fallback
                          fallback-group)))
            groups)))

(defun transient-compile-default-sort-function (groups)
  "Default implementation for `transient-compile-sort-function'.

Takes assoc list returned by `transient-compile-split-function', and returns
sorted list.

Default implementation sorts groups alphabetically and does not sort targets
inside groups.  Also it always places fallback group first."
  (let ((fallback-group (assoc transient-compile-group-fallback groups)))
    (append (when fallback-group
              (list fallback-group))
            (seq-sort (lambda (a b)
                        (string< (car a) (car b)))
                      (seq-remove (lambda (gr)
                                    (eq gr fallback-group))
                                  groups)))))

(defun transient-compile-default-menu-heading-function (tool _directory)
  "Default implementation for `transient-compile-menu-heading-function'."
  (propertize
   (format "Choose target for tool \"%s\"" tool)
   'face 'transient-compile-heading))

(defun transient-compile-default-menu-columns-function (groups)
  "Default implementation for `transient-compile-menu-columns-function'."
  (let* ((max-width
          (max
           ;; longest group name
           (apply 'max (seq-map 'length
                                (seq-map 'car groups)))
           ;; longest target name
           (apply 'max (seq-map 'length
                                (seq-mapcat 'cdr groups)))))
         ;; how much columns we can fit
         (max-columns
          (max (/ (frame-width) (+ max-width 10))
               1))) ; At least 1 column.
    (if (and transient-compile-menu-columns-limit
             (> transient-compile-menu-columns-limit 0))
        (min transient-compile-menu-columns-limit
             max-columns)
      max-columns)))

(defun transient-compile-taskfile-targets (directory)
  "Get list of targets from a taskfile."
  (when-let* ((executable (transient-compile--tool-property 'task :exe))
              (command (transient-compile--shell-join
                        executable
                        (unless (transient-compile--tool-property 'task :chdir)
                          `("-d" , directory))
                        "--json"
                        "--list-all"))
              (output (transient-compile--shell-run command))
              (json (json-read-from-string output)))
    (seq-map (lambda (task)
               (cdr (assoc 'name task)))
             (cdr (assoc 'tasks json)))))

(defun transient-compile-taskfile-command (directory target)
  "Format build command for a taskfile."
  (when-let* ((executable (transient-compile--tool-property 'task :exe)))
    (transient-compile--shell-join
     executable
     (unless (transient-compile--tool-property 'task :chdir)
       `("-d" , directory))
     target)))

(defun transient-compile-justfile-targets (directory)
  "Get list of targets from a justfile."
  (when-let* ((executable (transient-compile--tool-property 'just :exe))
              (justfile (seq-find (lambda (f)
                                    (member-ignore-case f '("justfile" ".justfile")))
                                  (directory-files directory)))
              (command (transient-compile--shell-join
                        executable
                        (unless (transient-compile--tool-property 'just :chdir)
                          `("-d" , directory
                            "-f" ,(f-join directory justfile)))
                        "--list"))
              (output (transient-compile--shell-run command))
              (lines (s-lines output)))
    (seq-map (lambda (line)
               (car (transient-compile--shell-tokens line)))
             (seq-filter (lambda (line)
                           (s-starts-with-p " " line))
                         lines))))

(defun transient-compile-justfile-command (directory target)
  "Format build command for a justfile."
  (when-let* ((executable (transient-compile--tool-property 'just :exe))
              (justfile (seq-find (lambda (f)
                                    (member-ignore-case f '("justfile" ".justfile")))
                                  (directory-files directory))))
    (transient-compile--shell-join
     executable
     (unless (transient-compile--tool-property 'just :chdir)
       `("-d" , directory
         "-f" ,(f-join directory justfile)))
     target)))

(defun transient-compile-dodofile-targets (_directory)
  "Get list of targets from a dodofile."
  (when-let* ((executable (transient-compile--tool-property 'doit :exe))
              (command (transient-compile--shell-join
                        executable
                        "list"))
              (output (transient-compile--shell-run command))
              (lines (s-lines output)))
    (seq-map (lambda (line)
               (car (transient-compile--shell-tokens line)))
             lines)))

(defun transient-compile-dodofile-command (_directory target)
  "Format build command for a dodofile."
  (when-let* ((executable (transient-compile--tool-property 'doit :exe)))
    (transient-compile--shell-join
     executable
     target)))

(defun transient-compile-rakefile-targets (directory)
  "Get list of targets from a rakefile."
  (when-let* ((executable (transient-compile--tool-property 'rake :exe))
              (command (transient-compile--shell-join
                        executable
                        (unless (transient-compile--tool-property 'rake :chdir)
                          `("-C" , directory))
                        "-P"))
              (output (transient-compile--shell-run command))
              (lines (s-lines output)))
    (seq-map (lambda (line)
               (cadr (transient-compile--shell-tokens line)))
             lines)))

(defun transient-compile-rakefile-command (directory target)
  "Format build command for a rakefile."
  (when-let* ((executable (transient-compile--tool-property 'rake :exe)))
    (transient-compile--shell-join
     executable
     (unless (transient-compile--tool-property 'rake :chdir)
       `("-C" , directory))
     target)))

(defun transient-compile-makefile-targets (directory)
  "Get list of targets from a makefile."
  (when-let* ((executable (transient-compile--tool-property 'make :exe))
              (command (transient-compile--shell-join
                        executable
                        (unless (transient-compile--tool-property 'make :chdir)
                          `("-C" ,directory))
                        "-pq"
                        ":"))
              (output (transient-compile--shell-run command)))
    (let (targets skip-target)
      (with-temp-buffer
        (insert output)
        (goto-char (point-min))
        (when (re-search-forward "^# Files" nil t)
          (forward-line 1)
          (while (not (looking-at-p "^# Finished Make data base"))
            (if (looking-at-p "^# Not a target")
                (setq skip-target t)
              (unless skip-target
                (let ((line (buffer-substring-no-properties (line-beginning-position)
                                                            (line-end-position))))
                  (when (string-match
                         (rx bol (group (not (any "#" ":" "." whitespace))
                                        (zero-or-more (not (any ":" whitespace))))
                             ":")
                         line)
                    (push (match-string 1 line) targets))))
              (setq skip-target nil))
            (forward-line 1))))
      (seq-uniq (sort targets 'string<)))))

(defun transient-compile-makefile-command (directory target)
  "Format build command for a makefile."
  (when-let* ((executable (transient-compile--tool-property 'make :exe)))
    (transient-compile--shell-join
     executable
     (unless (transient-compile--tool-property 'make :chdir)
       `("-C" ,directory))
     target)))

(defun transient-compile--log (&rest args)
  "Print log message, if enabled."
  (when transient-compile-verbose
    (apply 'message args)))

(defun transient-compile--shell-run (command)
  "Run shell command and return stdout as string."
  (transient-compile--log "Running command: %s" command)
  (with-temp-buffer
    (let* ((process-environment
            (cons "LC_ALL=C" process-environment))
           (exit-code
            (process-file-shell-command command nil (current-buffer) nil)))
      (transient-compile--log "Command finished with status %s" exit-code)
      (buffer-string))))

(defun transient-compile--shell-quote (arg)
  "Quote argument for shell."
  (let ((home (expand-file-name "~/"))
        (unix (not (member system-type '(windows-nt ms-dos))))
        (str (format "%s" arg)))
    ;; Minimize quoting if possible
    (cond ((s-matches-p "^[a-zA-Z0-9/:.,_-]+$" str)
           (or (when (and unix
                          home
                          (s-prefix-p home str))
                 (replace-regexp-in-string (s-concat "^" (regexp-quote home))
                                           "~/"
                                           str))
               str))
          ((and (not (s-contains-p "'" str))
                (eq system-type 'gnu/linux))
           (format "'%s'" str))
          (t
           (shell-quote-argument str)))))

(defun transient-compile--shell-join (&rest args)
  "Quote and concatenate arguments into a command.
Flatten nested lists.
Skip nil arguments (but not empty strings)."
  (s-join
   " "
   (seq-map
    'transient-compile--shell-quote
    (seq-remove
     'not
     (seq-mapcat (lambda (arg)
                   (if (listp arg)
                       arg
                     (list arg)))
                 args)))))

(defun transient-compile--shell-tokens (arg)
  "Split line by whitespace."
  (split-string arg "[ \t\n]+" t "[ \t\n]*"))

(defun transient-compile--tool-detect ()
  "Detect tool and directory."
  (if-let* ((tool-and-dir (funcall transient-compile-detect-function))
            (tool (car tool-and-dir))
            (directory (cdr tool-and-dir)))
      (cons tool directory)
    (cond (transient-compile-tool
           (user-error
            "No build file for '%s tool found in current directory and parents"
            transient-compile-tool))
          (transient-compile-directory
           (user-error
            "No known build file found in %s" transient-compile-directory))
          (t
           (user-error
            "No known build file found in current directory and parents")))))

(defun transient-compile--tool-targets (tool directory)
  "Retrieve list of compile targets."
  (if-let* ((targets-fn (transient-compile--tool-property tool :targets))
            (targets (seq-uniq
                      (seq-remove 's-blank-p
                                  (funcall targets-fn directory)))))
      (progn
        (transient-compile--log
         "Detected %s targets for \"%s\"" (length targets) tool)
        targets)
    (user-error "Failed to parse list of targets for \"%s\" tool" tool)))

(defun transient-compile--tool-command (tool directory target)
  "Format compile command."
  (if-let* ((command-fn (transient-compile--tool-property tool :command))
            (command (funcall command-fn directory target)))
      command
    (user-error "Failed to format command for \"%s\" tool" tool)))

(defun transient-compile--tool-property (tool property)
  "Get property for command."
  (if-let* ((entry (assoc tool transient-compile-tool-alist))
            (entry-props (cdr entry)))
      (if (plist-member entry-props property)
          (plist-get entry-props property)
        (user-error "Missing property %S for key '%S in %S"
                    property tool 'transient-compile-tool-alist))
    (user-error "Missing key '%S in %S"
                tool 'transient-compile-tool-alist)))

(defun transient-compile--build-matchers ()
  "Build list of matchers to run for every dominating directory."
  (seq-mapcat (lambda (elem)
                (let* ((tool (car elem))
                       (match-list (plist-get (cdr elem) :match)))
                  ;; If transient-compile-tool is forced, ignore all other tools.
                  (when (or (not transient-compile-tool)
                            (eq tool transient-compile-tool))
                    (seq-map (lambda (matcher)
                               (cons tool matcher))
                             (if (and (listp match-list)
                                      (not (functionp match-list)))
                                 match-list
                               (list match-list))))))
              transient-compile-tool-alist))

(defun transient-compile--apply-matchers (match-list)
  "Find nearest dominating directory matched by any element of the MATCH-LIST.
MATCH-LIST element may be either string file name (like “Makefile“), or
function that takes directory path and returns t or nil."
  (when default-directory
    ;; If transient-compile-directory is forced,
    ;; use it instead of default-directory.
    (let ((dir (or transient-compile-directory
                   (f-full default-directory)))
          result)
      (while (and dir (not result))
        (setq result (seq-some
                      (lambda (matcher)
                        (when-let ((tool (car matcher))
                                   (file-or-func (cdr matcher)))
                          (cond
                           ((functionp file-or-func)
                            (when (funcall file-or-func dir)
                              (cons tool dir)))
                           ((stringp file-or-func)
                            (let ((file-path (f-join dir file-or-func)))
                              (when (f-exists-p file-path)
                                (cons tool dir))))
                           (t
                            (user-error "Bad property :match for key '%S in %S"
                                        tool 'transient-compile-tool-alist)))))
                      match-list))
        ;; If transient-compile-directory is forced,
        ;; don't do directory search.
        (if transient-compile-directory
            (setq dir nil)
          (setq dir (f-parent dir))))
      (when result
        (transient-compile--log
         "Detected \"%s\" tool for %s" (car result) (cdr result)))
      result)))

(defun transient-compile--keychar-p (char)
  "Check if character can be used as a key."
  (string-match-p
   transient-compile-keychar-regexp (string char)))

(defconst transient-compile--keychar-table
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

(defun transient-compile--random-key (word key-map)
  "Generate random key for WORD, trying to return same results for same words."
  (let ((counter 0)
        result)
    (while (not result)
      (cl-incf counter)
      (let* ((hash (abs (sxhash word)))
             (index (mod hash (length transient-compile--keychar-table)))
             (char (elt transient-compile--keychar-table index)))
        (if (and (transient-compile--keychar-p char)
                 (not (gethash char key-map)))
            ;; Hit!
            (setq result char)
          (if (< counter (length transient-compile--keychar-table))
              ;; Repeat with hash of hash, and so on.
              (setq word (number-to-string hash))
            ;; Give up.
            "_"))))
    result))

(defun transient-compile--propertize-key (word word-index group-p)
  "Highligh key character inside word."
  (if (not group-p)
      ;; Target.
      (add-text-properties word-index (1+ word-index)
                           '(face transient-compile-keychar) word)
    ;; Group.
    (when (> word-index 0)
      (add-text-properties 0 word-index
                           '(face transient-heading) word))
    (add-text-properties word-index (1+ word-index)
                         '(face (transient-compile-keychar transient-heading)) word)
    (when (< (1+ word-index) (length word))
      (add-text-properties (1+ word-index) (length word)
                           '(face transient-heading) word))))

(defun transient-compile--assign-keys (words group-p)
  "Map words to unique keys."
  (let* ((key-map (make-hash-table :test 'equal))
         (shared-prefix (seq-reduce 's-shared-start
                                    words
                                    (car words)))
         (sorted-words (seq-sort
                        'string< words))
         (max-len (seq-max (seq-map (lambda (w) (length w))
                                    sorted-words)))
         word-keys)
    (while (< (length word-keys)
              (length words))
      (let (word
            word-index
            word-key)
        (unless (and transient-compile-keychar-function
                     (seq-find
                      (lambda (w)
                        (when-let ((key (funcall transient-compile-keychar-function
                                                 w
                                                 words
                                                 key-map
                                                 group-p)))
                          ;; Special case: custom user-provided key.
                          (unless (characterp key)
                            (user-error
                             "Got non-char key %S from transient-compile-keychar-function"
                             key))
                          (when (gethash key key-map)
                            (user-error
                             "Got duplicate key %s from transient-compile-keychar-function"
                             (string key)))
                          (setq word w
                                word-index (seq-position word key)
                                word-key key)))
                      (seq-remove (lambda (w)
                                    (assoc w word-keys))
                                  sorted-words)))
          (if (and (seq-contains-p sorted-words shared-prefix)
                   (not (assoc shared-prefix word-keys)))
              ;; Special case: word = shared prefix.
              (setq word shared-prefix
                    word-index 0
                    word-key (elt word 0))
            ;; Normal case.
            (seq-find
             (lambda (prefer-first)
               (seq-find
                (lambda (casefn)
                  ;; If prefer-first is true:
                  ;;  - Find word with minimal N so that its Nth character is not taken.
                  ;; Else:
                  ;;  - Find word with minimal N so that its Nth character is not taken
                  ;;    AND is unique among Nth characters of all words.
                  (seq-find
                   (lambda (index)
                     (when (setq word
                                 (seq-find
                                  (lambda (word)
                                    (and (not (assoc word word-keys))
                                         (> (length word) index)
                                         (transient-compile--keychar-p (elt word index))
                                         (not (gethash
                                               (funcall casefn (elt word index)) key-map))
                                         (or prefer-first
                                             (not (seq-find
                                                   (lambda (other-word)
                                                     (and
                                                      (not (string= other-word word))
                                                      (> (length other-word) index)
                                                      (eq (funcall casefn (elt other-word index))
                                                          (funcall casefn (elt word index)))))
                                                   sorted-words)))))
                                  sorted-words))
                       (setq word-index index
                             word-key (funcall casefn (elt word index)))))
                   (number-sequence (length shared-prefix)
                                    max-len)))
                ;; Repeat above search a few times: first try characters as-is, then try
                ;; their upper-case and down-case variants.
                (if transient-compile-keychar-unfold
                    (list 'identity 'upcase 'downcase)
                  (list 'identity))))
             ;; If group-p is set, do above search once with prefer-first set to t.
             ;; Otherwise, first try it with prefer-first set to nil, then with t.
             ;; When prefer-first is nil, less matches are possible, but we have a
             ;; nice effect when keychars are placed in the same column or close,
             ;; so we try to maximize this effect.
             (if group-p
                 '(t)
               '(nil t)))))
        ;; Can't choose key char from word's letters, fallback to random key.
        ;; Randomness is based on word hash, so that we return same key
        ;; for same word, when possible.
        (unless word
          (setq word (seq-find (lambda (w)
                                 (not (assoc w word-keys)))
                               sorted-words)
                word-key (transient-compile--random-key word key-map)
                word-index (seq-position word word-key)))
        (let ((word-label (substring word 0)))
          (when (and transient-compile-keychar-highlight
                     word-index)
            (aset word-label word-index word-key)
            (transient-compile--propertize-key word-label word-index group-p))
          (push (list word
                      word-label
                      (string word-key))
                word-keys)
          (puthash word-key t key-map))))
    word-keys))

(defun transient-compile--build-menu (tool directory groups)
  "Build transient menu for grouped targets."
  (let ((group-keys (transient-compile--assign-keys
                     (seq-map 'car groups) t)))
    (seq-map (lambda (group)
               (let* ((group-name (car group))
                      (group-targets (cdr group))
                      (group-label (cadr (assoc group-name group-keys)))
                      (group-target-keys (transient-compile--assign-keys
                                          group-targets nil)))
                 (append
                  (list group-label)
                  (seq-map
                   (lambda (target-name)
                     (let* ((target-label
                             (cadr (assoc target-name group-target-keys)))
                            (target-key
                             (if (> (length groups) 1)
                                 (s-concat (caddr (assoc group-name group-keys))
                                           (caddr (assoc target-name group-target-keys)))
                               (caddr (assoc target-name group-target-keys))))
                            (target-command
                             (transient-compile--tool-command
                              tool
                              directory
                              target-name))
                            (target-dir
                             (and (transient-compile--tool-property tool :chdir)
                                  directory))
                            (target-hint
                             (format "Run: %s" target-command)))
                       `(,target-key
                         ,target-label
                         (lambda () ,target-hint (interactive)
                           (transient-compile--invoke-target
                            ,target-name ,target-command ,target-dir)))))
                   group-targets))))
             groups)))

(defun transient-compile--build-grid (menu-heading column-count items)
  "Align menu items into a grid."
  (let* ((columns (make-list column-count nil))
         (index 0))
    (dolist (item items)
      (setf (nth index columns) (append (nth index columns)
                                        (list item)))
      (setq index (% (1+ index) column-count)))
    (let* ((row-count (apply 'max (seq-map 'length columns)))
           (rows (make-list row-count nil)))
      (dotimes (row-index row-count)
        (dotimes (col-index column-count)
          (when (< row-index (length (nth col-index columns)))
            (setf (nth row-index rows) (append (nth row-index rows)
                                               (list (nth row-index (nth col-index columns))))))))
      (let ((grid (seq-map-indexed (lambda (row index)
                                     (vconcat
                                      (append (when (and menu-heading (eq index 0))
                                                `(:description ,(s-concat menu-heading "\n")))
                                              (list :class 'transient-columns)
                                              (seq-map 'vconcat row))))
                                   rows)))
        (when transient-compile-menu-columns-spread
          (setq grid (append `(:column-widths
                               ',(make-list column-count (/ (frame-width) column-count)))
                             grid)))
        grid))))

(defun transient-compile--invoke-target (target-name target-command target-directory)
  "Invoke compilation command for a target."
  (unless transient-compile-function
    (user-error "Missing transient-compile-function"))
  (let ((transient-compile-target target-name)
        (default-directory (or target-directory default-directory)))
    (if transient-compile-interactive
        (minibuffer-with-setup-hook
                  (lambda ()
                    (delete-minibuffer-contents)
                    (insert target-command))
          (call-interactively transient-compile-function))
      (funcall transient-compile-function target-command))))

(provide 'transient-compile)
;;; transient-compile.el ends here
