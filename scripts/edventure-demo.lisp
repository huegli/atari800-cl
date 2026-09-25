;;;; scripts/edventure-demo.lisp --- Boot the EdVenture homebrew game
;;;; (github.com/EdSalisbury/edventure) over the emulated SIO serial wire
;;;; and serve its screen to a screenshot client.
;;;;
;;;; Usage:
;;;;   sbcl --script scripts/edventure-demo.lisp [branch]
;;;;   ./scripts/capture-screenshot.py -p <video-port> -o edventure.png
;;;;
;;;; scripts/edventure-demo.sh wraps this (and its LispWorks counterpart
;;;; scripts/edventure-demo-lispworks.lisp) behind a single --impl
;;;; sbcl|lispworks command-line option, defaulting to sbcl:
;;;;   ./scripts/edventure-demo.sh [--impl sbcl|lispworks] [branch]
;;;;
;;;; BRANCH selects which branch of the EdVenture repo to clone (the
;;;; tutorial series is one branch per episode); it defaults to
;;;; episode_29_work, the newest at the time this script was written --
;;;; NOT the repo's own default branch, episode_1, which is an early
;;;; "HELLO ATARI!" stub.  $ATARI800_CL_EDVENTURE_BRANCH is a lower-
;;;; priority default (checked when no argument is given).
;;;;
;;;; EdVenture is not vendored into this repository: it is a separate,
;;;; independently versioned project, so this script shallow-clones it
;;;; fresh into a temporary directory every run, assembles it there
;;;; (shelling out to `mads`, which must be on PATH), and deletes the
;;;; clone again on exit (normal completion, a fatal error, or SIGINT /
;;;; SIGTERM) -- nothing from EdVenture ever touches this checkout.
;;;;
;;;; What it does: builds a machine on the real OS/BASIC ROMs (roms/
;;;; defaults, overridable via $ATARI800_CL_OS_ROM / $ATARI800_CL_BASIC_ROM,
;;;; exactly like scripts/dos-boot-demo.lisp and the test suite), wraps
;;;; the assembled binary in a synthesized bootable ATR via
;;;; ATARI800-CL:LOAD-XEX (src/xex.lisp's xexboot loader, which defaults
;;;; RUNAD to the first segment's start -- $B000 here, since MADS output
;;;; with no .run directive never sets it) and mounts it on drive 1,
;;;; holds OPTION through the boot (BASIC disabled, so $A000-BFFF is
;;;; free RAM for the game's code/data the same reason the DOS demo
;;;; holds it), and runs the boot.  Unlike the DOS demo there is no
;;;; DOS.SYS/DUP.SYS to load and no text-mode menu to decode -- the game
;;;; draws a custom-charset graphics screen -- so this just runs a fixed
;;;; number of frames and then serves whatever is on screen.
;;;;
;;;; Status lines on stdout (the same shape scripts/dos-boot-demo.lisp
;;;; prints, plus BRANCH):
;;;;   BRANCH <name>
;;;;   AESP_CONTROL <port>
;;;;   AESP_VIDEO   <port>
;;;;   AESP_AUDIO   <port>
;;;;   READY <frame>
;;;;
;;;; Exit is by SIGINT / SIGTERM (the capture client or the user kills
;;;; the process once the screenshot is taken) -- the temp clone is
;;;; removed either way.

(require :asdf)

;;; --- Load Quicklisp + atari800-cl (same self-contained preamble
;;; --- scripts/dos-boot-demo.lisp uses: repo-local FASL cache,
;;; --- repo-registered source tree, so a stale cache can never shadow
;;; --- current source).

(defun demo-truename-dir ()
  (uiop:pathname-directory-pathname
   (or *load-truename* *compile-file-truename*
       (make-pathname :defaults *default-pathname-defaults*))))

(let ((ql-init (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (unless (find-package :ql)
    (when (probe-file ql-init)
      (load ql-init))))

(defparameter *repo-root*
  (uiop:pathname-parent-directory-pathname (demo-truename-dir)))

(let* ((cache (merge-pathnames #P".cache/fasls/" *repo-root*)))
  (ensure-directories-exist cache)
  (asdf:initialize-output-translations
   `(:output-translations (t (,cache :implementation))
     :ignore-inherited-configuration))
  (asdf:initialize-source-registry
   `(:source-registry (:tree ,*repo-root*)
      (:tree ,(merge-pathnames #P"quicklisp/dists/quicklisp/software/"
                               (user-homedir-pathname)))
      :ignore-inherited-configuration)))

(handler-case
    (funcall (read-from-string "ql:quickload") :atari800-cl :silent t)
  (error (c)
    (format *error-output* "fatal: could not load :atari800-cl -- ~A~%" c)
    (uiop:quit 3)))

;;; --- Command line: the optional single argument picks the EdVenture
;;; --- branch to clone, same argv access scripts/dos-boot-demo.lisp uses.

(defun demo-argv ()
  #+sbcl       (cdr sb-ext:*posix-argv*)
  #+lispworks  (cdr sys:*line-arguments-list*)
  #-(or sbcl lispworks) nil)

;;; --- Fatal errors: signalled by any step below, caught once at the
;;; --- bottom so the temp clone (once it exists) is always removed
;;; --- before this process exits.

(define-condition demo-fatal-error (error)
  ((message :initarg :message :reader demo-fatal-error-message)))

(defun fatal (format-control &rest format-args)
  (error 'demo-fatal-error :message (apply #'format nil format-control format-args)))

;;; --- Temp clone lifecycle.  *EDVENTURE-DIR* is set once the temp
;;; --- directory is created; CLEANUP is safe to call multiple times
;;; --- (fatal-error path, then the outer form again) and from a signal
;;; --- handler.

(defparameter *edventure-dir* nil)
(defparameter *edventure-repo-url* "https://github.com/EdSalisbury/edventure")
;; The repo's default branch (episode_1) is an early "HELLO ATARI!" stub;
;; the tutorial series' branches are per-episode.  episode_29_work is the
;; newest at the time this script was written -- the one its 300-frame
;; boot budget was tuned and screenshotted against -- and stays the
;; default; pass another branch as the command-line argument (or set
;; $ATARI800_CL_EDVENTURE_BRANCH) to try a different episode, keeping in
;; mind the boot-frame budget below may need adjusting for it.
;;
;; Positional argv is only consulted under SBCL: `lw-console -build`
;; owns the command line, so sys:*line-arguments-list* holds LispWorks's
;; own arguments (e.g. "-build") rather than anything a caller passed --
;; scripts/edventure-demo-lispworks.lisp's header explains this in more
;; detail.  scripts/edventure-demo.sh --impl lispworks therefore passes
;; a branch through the env var instead, which is why that path is
;; checked regardless of implementation.
(defparameter *edventure-branch*
  (or #+sbcl (first (demo-argv))
      (let ((env (uiop:getenv "ATARI800_CL_EDVENTURE_BRANCH")))
        (and env (plusp (length env)) env))
      "episode_29_work"))

(defun cleanup ()
  (when (and *edventure-dir* (probe-file *edventure-dir*))
    (ignore-errors (uiop:delete-directory-tree *edventure-dir* :validate t))
    (setf *edventure-dir* nil)))

#+sbcl
(dolist (signo (list sb-unix:sigint sb-unix:sigterm))
  (sb-sys:enable-interrupt
   signo (lambda (&rest args)
           (declare (ignore args))
           (cleanup)
           (sb-ext:exit :code 0))))

(defun make-temp-dir ()
  (let* ((base (string-right-trim "/" (or (uiop:getenv "TMPDIR") "/tmp")))
         (template (format nil "~A/atari800-cl-edventure.XXXXXXXX" base)))
    (multiple-value-bind (output error-output status)
        (uiop:run-program (list "mktemp" "-d" template)
                           :output '(:string) :error-output '(:string)
                           :ignore-error-status t)
      (unless (zerop status)
        (fatal "mktemp failed: ~A" error-output))
      (uiop:ensure-directory-pathname (string-trim '(#\Newline #\Space) output)))))

(defun clone-edventure (dest-dir)
  (multiple-value-bind (output error-output status)
      (uiop:run-program (list "git" "clone" "--quiet" "--depth" "1"
                               "--branch" *edventure-branch*
                               *edventure-repo-url* (namestring dest-dir))
                         :output '(:string) :error-output '(:string)
                         :ignore-error-status t)
    (declare (ignore output))
    (unless (zerop status)
      (fatal "git clone of ~A failed:~%~A" *edventure-repo-url* error-output))))

;;; --- Assemble main.asm with MADS.  MADS exits non-zero on warnings
;;; --- alone (the current source has two harmless "register changed"
;;; --- warnings), so success is judged by the object file actually
;;; --- appearing, not by the process exit code.

(defun assemble-edventure (dir)
  (let* ((src (merge-pathnames #P"main.asm" dir))
         (obx (merge-pathnames #P"main.obx" dir)))
    (unless (probe-file src)
      (fatal "~A not found after cloning" src))
    (multiple-value-bind (output error-output status)
        (uiop:run-program (list "mads" "-l" "-t" (namestring src))
                           :directory dir
                           :output '(:string) :error-output '(:string)
                           :ignore-error-status t)
      (declare (ignore status))
      (unless (probe-file obx)
        (fatal "mads did not produce ~A~%~A~A" obx output error-output)))
    obx))

;;; --- Asset lookup: same candidate lists / env-var-beats-roms/-default
;;; --- rule as scripts/dos-boot-demo.lisp, so a checkout the test suite
;;; --- can find its ROMs in works here too.

(defparameter *os-rom-names*    '("atariosxl.rom" "ATARIXL.ROM" "atarixl.rom"))
(defparameter *basic-rom-names* '("ataribas.rom" "ATARIBAS.ROM"))

(defun find-asset (env-var filenames)
  (or (let ((env (uiop:getenv env-var)))
        (and env (plusp (length env)) (probe-file env)))
      (let ((roms (merge-pathnames
                   (make-pathname :directory '(:relative "roms"))
                   *repo-root*)))
        (loop for name in filenames
              thereis (probe-file (merge-pathnames name roms))))))

;;; --- Main.

(handler-case
    (let ((os    (find-asset "ATARI800_CL_OS_ROM"    *os-rom-names*))
          (basic (find-asset "ATARI800_CL_BASIC_ROM" *basic-rom-names*)))
      (unless (and os basic)
        (fatal "OS/BASIC ROMs not found (roms/~{~A~^, roms/~}, or ~
                $ATARI800_CL_OS_ROM/$ATARI800_CL_BASIC_ROM)"
               (list (first *os-rom-names*) (first *basic-rom-names*))))

      (format t "BRANCH ~A~%" *edventure-branch*)
      (force-output)

      (setf *edventure-dir* (make-temp-dir))
      (clone-edventure *edventure-dir*)
      (let* ((obx (assemble-edventure *edventure-dir*))
             (m   (atari800-cl.machine:make-atari-machine))
             (inp (atari800-cl.input:make-input-state))
             (server (atari800-cl:start-aesp-server m
                                                    :control-port 0
                                                    :video-port   0
                                                    :audio-port   0)))
        (atari800-cl.machine:machine-cold-reset m :os-path os :basic-path basic)
        ;; OPTION held through the boot: the OS leaves BASIC unmapped so
        ;; $A000-BFFF is plain RAM for the game's room-type tables and
        ;; code, and the boot ends in the no-cartridge JMP (DOSVEC)
        ;; handoff -- here into xexboot's own RUNAD jump rather than
        ;; DUP.SYS.
        (atari800-cl.machine:attach-input m inp)
        (atari800-cl.input:input-set-console inp :option t)
        (atari800-cl:load-xex m obx :unit 1)

        (format t "AESP_CONTROL ~A~%" (atari800-cl.aesp:aesp-server-control-port server))
        (format t "AESP_VIDEO   ~A~%" (atari800-cl.aesp:aesp-server-video-port server))
        (format t "AESP_AUDIO   ~A~%" (atari800-cl.aesp:aesp-server-audio-port server))
        (force-output)

        ;; --- The boot.  No DOS.SYS/DUP.SYS to load -- xexboot streams
        ;; --- the ~16K binary directly and jumps to it -- so this
        ;; --- settles far faster than the DOS demo's 900 frames.
        (dotimes (i 300)
          (atari800-cl.machine:machine-run-frame m))

        (format t "READY ~A~%" (atari800-cl.machine:atari-machine-frame-count m))
        (force-output)

        ;; --- The clone has done its job (the binary is loaded into the
        ;; --- emulated machine); remove it now rather than holding it
        ;; --- until the process eventually exits.
        (cleanup)

        ;; --- Keep serving frames at ~59.92 fps so a video-port client
        ;; --- can capture one.  Killed externally (SIGINT/SIGTERM,
        ;; --- handled above).
        (loop
          (atari800-cl.machine:machine-run-frame m)
          (sleep 0.0167))))
  (demo-fatal-error (c)
    (cleanup)
    (format *error-output* "fatal: ~A~%" (demo-fatal-error-message c))
    (uiop:quit 3)))
