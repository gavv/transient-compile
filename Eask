(package "transient-compile"
         "0.4"
         "Dynamic transient menu for compilation")

(website-url "https://github.com/gavv/transient-compile")
(keywords "tools" "processes")
(license "GPLv3")

(package-file "transient-compile.el")

(source "gnu")
(source "melpa")

(depends-on "emacs" "29.2")
(depends-on "f")
(depends-on "s")

;; Allow setting checkdoc flags via local variables during eask invocation.
(put 'checkdoc--argument-missing-flag
     'safe-local-variable
     #'booleanp)
