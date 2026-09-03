;;;; scripts/dos-boot-demo.lisp --- Phase 25 visual verification: boot
;;;; DOS 2.5 over the emulated SIO serial wire and serve the DOS menu to
;;;; a screenshot client.
;;;;
;;;; Usage:
;;;;   sbcl --script scripts/dos-boot-demo.lisp [path/to/dos25.atr]
;;;;   ./scripts/capture-screenshot.py -p <video-port> -o dos-menu.png
;;;;
;;;; What it does: builds a machine on the real OS/BASIC ROMs (roms/
;;;; defaults, overridable via $ATARI800_CL_OS_ROM / $ATARI800_CL_BASIC_ROM
;;;; / $ATARI800_CL_DOS_ATR exactly like the test suite), mounts the DOS
;;;; 2.5 ATR on drive 1, holds OPTION through the boot (BASIC disabled,
;;;; the way a real 800XL enters DOS -- with BASIC on, the OS hands
;;;; control to BASIC's READY prompt and DUP.SYS loads only when the
;;;; user types DOS), and runs the boot.  Every sector -- boot record,
;;;; DOS.SYS, DUP.SYS -- arrives as POKEY SERIN bytes over the emulated
;;;; serial wire; no shortcut touches RAM.  When the menu is up the
;;;; script prints its text rows plus a MENU line and keeps serving
;;;; frames at ~60 fps until killed, so scripts/capture-screenshot.py
;;;; (or capture-video.py for a film) can connect and grab the screen.
;;;;
;;;; Status lines on stdout (the same shape scripts/runner.lisp prints):
;;;;   AESP_CONTROL <port>
;;;;   AESP_VIDEO   <port>
;;;;   MENU <frame>
;;;;
;;;; Exit is by SIGINT / SIGTERM (the capture client or the user kills
;;;; the process once the screenshot is taken).

(require :asdf)

;;; --- Load Quicklisp + atari800-cl (same self-contained preamble
;;; --- scripts/runner.lisp uses: repo-local FASL cache, repo-registered
;;; --- source tree, so a stale cache can never shadow current source).

(defun demo-truename-dir ()
  (uiop:pathname-directory-pathname
   (or *load-truename* *compile-file-truename*
       (make-pathname :defaults *default-pathname-defaults*))))

(let ((ql-init (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (unless (find-package :ql)
    (when (probe-file ql-init)
      (load ql-init))))

(let* ((root (uiop:pathname-parent-directory-pathname (demo-truename-dir)))
       (cache (merge-pathnames #P".cache/fasls/" root)))
  (ensure-directories-exist cache)
  (asdf:initialize-output-translations
   `(:output-translations (t (,cache :implementation))
     :ignore-inherited-configuration))
  (asdf:initialize-source-registry
   `(:source-registry (:tree ,root)
      (:tree ,(merge-pathnames #P"quicklisp/dists/quicklisp/software/"
                               (user-homedir-pathname)))
      :ignore-inherited-configuration)))

(handler-case
    (funcall (read-from-string "ql:quickload") :atari800-cl :silent t)
  (error (c)
    (format *error-output* "fatal: could not load :atari800-cl -- ~A~%" c)
    (uiop:quit 3)))

;;; --- Command line: the optional single argument is the ATR path
;;; --- (same argv access scripts/runner.lisp uses).

(defun demo-argv ()
  #+sbcl       (cdr sb-ext:*posix-argv*)
  #+lispworks  (cdr sys:*line-arguments-list*)
  #-(or sbcl lispworks) nil)

;;; --- Asset lookup: argument beats environment beats roms/ default.

(defun find-asset (env-var filename)
  (or (let ((env (uiop:getenv env-var)))
        (and env (plusp (length env)) (probe-file env)))
      (let ((default (merge-pathnames
                      (make-pathname :directory '(:relative "roms")
                                     :name (pathname-name filename)
                                     :type (pathname-type filename))
                      (uiop:pathname-parent-directory-pathname
                       (demo-truename-dir)))))
        (probe-file default))))

(let* ((os     (find-asset "ATARI800_CL_OS_ROM" "atariosxl.rom"))
       (basic  (find-asset "ATARI800_CL_BASIC_ROM" "ataribas.rom"))
       (atr    (or (and (second (demo-argv))
                        (probe-file (second (demo-argv))))
                   (find-asset "ATARI800_CL_DOS_ATR" "dos25.atr"))))
  (unless (and os basic)
    (format *error-output*
            "fatal: OS/BASIC ROMs not found (roms/atariosxl.rom, ~
             roms/ataribas.rom, or $ATARI800_CL_OS_ROM/$ATARI800_CL_BASIC_ROM)~%")
    (uiop:quit 3))
  (unless atr
    (format *error-output*
            "fatal: no DOS 2.5 ATR -- run ./scripts/fetch-dos-atr.sh or ~
             pass one as the argument / $ATARI800_CL_DOS_ATR~%")
    (uiop:quit 3))

  (let* ((m   (atari800-cl.machine:make-atari-machine))
         (inp (atari800-cl.input:make-input-state))
         (server (atari800-cl:start-aesp-server m
                                                :control-port 0
                                                :video-port   0
                                                :audio-port   0)))
    (atari800-cl.machine:machine-cold-reset m :os-path os :basic-path basic)
    ;; OPTION held through the boot: GTIA CONSOL reports it pressed, the
    ;; OS leaves BASIC unmapped, and the boot ends in the no-cartridge
    ;; JMP (DOSVEC) handoff that loads DUP.SYS and enters the menu.
    (atari800-cl.machine:attach-input m inp)
    (atari800-cl.input:input-set-console inp :option t)
    ;; One mount serves both the Phase 16 host bridge and the Phase 25
    ;; serial wire (SIO: 25c).
    (atari800-cl.hostdev:mount-disk-file
     (atari800-cl.machine:atari-machine-hostdev m) 1 atr)

    (format t "AESP_CONTROL ~A~%" (atari800-cl.aesp:aesp-server-control-port server))
    (format t "AESP_VIDEO   ~A~%" (atari800-cl.aesp:aesp-server-video-port server))
    (format t "AESP_AUDIO   ~A~%" (atari800-cl.aesp:aesp-server-audio-port server))
    (force-output)

    ;; --- The boot.  The menu appears around frame 600 on the reference
    ;; --- ATR; 900 (~15 s emulated) leaves margin.  The machine's own
    ;; --- text screen is decoded afterwards as textual confirmation.
    (dotimes (i 900)
      (atari800-cl.machine:machine-run-frame m))

    (let* ((bus    (atari800-cl.machine:atari-machine-bus m))
           (savmsc (logior (atari800-cl.bus:bus-read bus #x58)
                           (ash (atari800-cl.bus:bus-read bus #x59) 8))))
      (flet ((row-text (row)
               (with-output-to-string (s)
                 (loop for col below 40
                       for code = (logand (atari800-cl.bus:bus-read
                                           bus (logand
                                                #xFFFF
                                                (+ savmsc (* row 40) col)))
                                          #x7F)
                       for ascii = (+ (case (ash code -5)
                                        (0 #x20) (1 #x40) (2 #x00) (3 #x60))
                                      (logand code #x1F))
                       do (write-char (if (<= #x20 ascii #x7E)
                                          (code-char ascii) #\Space)
                                      s)))))
        (format t "MENU ~A~%" (atari800-cl.machine:atari-machine-frame-count m))
        (loop for row below 8
              do (format t "  |~A|~%" (row-text row)))
        (force-output)))

    ;; --- Keep serving frames at ~59.92 fps so a video-port client can
    ;; --- capture one; the menu is static, so any frame after MENU is
    ;; --- the screenshot.  Killed externally.
    (loop
      (atari800-cl.machine:machine-run-frame m)
      (sleep 0.0167))))