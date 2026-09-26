;;;; demos/minimal-xl-boot-demo.lisp --- Boot the minimal-xl/ submodule's
;;;; stripped-down XL OS (no copyrighted ROM dump needed) and serve its
;;;; boot-banner screen to a screenshot client.
;;;;
;;;; Usage:
;;;;   ./demos/minimal-xl-boot-demo.sh [--impl sbcl|lispworks] [path/to/minimal_os.rom]
;;;;   ./scripts/capture-screenshot.py -p <video-port> -o minimal-xl-banner.png
;;;;
;;;; What it does: builds a machine with ONLY the minimal-xl OS ROM
;;;; installed as :OS-ROM (minimal-xl/minimal_os.rom by default; no
;;;; BASIC ROM, no DOS ATR, no SIO/hostdev wiring, no input state --
;;;; the minimal OS never touches PORTB banking, has no keyboard IRQ
;;;; source, and does not read the serial wire), cold-resets, and runs
;;;; 30 frames -- enough for its VBI to copy the OS shadow registers
;;;; into the chips, draw the standard GRAPHICS 0 display list at
;;;; $BC20 / screen memory at $BC40 (40x24), and settle into its idle
;;;; loop (see README.md "Booting the minimal XL OS").  The banner is
;;;; then decoded straight out of screen memory as textual confirmation,
;;;; the same conversion README.md's REPL snippet uses.
;;;;
;;;; Status lines on stdout (the same shape demos/dos-boot-demo.lisp
;;;; prints):
;;;;   AESP_CONTROL <port>
;;;;   AESP_VIDEO   <port>
;;;;   AESP_AUDIO   <port>
;;;;   BANNER <frame>
;;;;
;;;; Exit is by SIGINT / SIGTERM (the capture client or the user kills
;;;; the process once the screenshot is taken).

(require :asdf)

;;; --- Load Quicklisp + atari800-cl (same self-contained preamble
;;; --- demos/dos-boot-demo.lisp uses: repo-local FASL cache, repo-
;;; --- registered source tree, so a stale cache can never shadow
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

;;; --- Command line: the optional single argument overrides the ROM
;;; --- path, same argv access demos/dos-boot-demo.lisp uses.

(defun demo-argv ()
  #+sbcl       (cdr sb-ext:*posix-argv*)
  #+lispworks  (cdr sys:*line-arguments-list*)
  #-(or sbcl lispworks) nil)

;;; --- ROM lookup: argument beats $ATARI800_CL_MINIMAL_XL_ROM beats the
;;; --- checked-in minimal-xl/minimal_os.rom default.

(defparameter *default-rom-path*
  (merge-pathnames #P"minimal-xl/minimal_os.rom" *repo-root*))

(defun find-rom ()
  (or (and (first (demo-argv)) (probe-file (first (demo-argv))))
      (let ((env (uiop:getenv "ATARI800_CL_MINIMAL_XL_ROM")))
        (and env (plusp (length env)) (probe-file env)))
      (probe-file *default-rom-path*)))

(let ((rom (find-rom)))
  (unless rom
    (format *error-output*
            "fatal: minimal-xl OS ROM not found (~A, or pass a path / set ~
             $ATARI800_CL_MINIMAL_XL_ROM) -- run ~
             'git submodule update --init minimal-xl'~%"
            *default-rom-path*)
    (uiop:quit 3))

  (let* ((m      (atari800-cl.machine:make-atari-machine))
         (server (atari800-cl:start-aesp-server m
                                                :control-port 0
                                                :video-port   0
                                                :audio-port   0)))
    (atari800-cl.machine:machine-cold-reset m :os-path rom)

    (format t "AESP_CONTROL ~A~%" (atari800-cl.aesp:aesp-server-control-port server))
    (format t "AESP_VIDEO   ~A~%" (atari800-cl.aesp:aesp-server-video-port server))
    (format t "AESP_AUDIO   ~A~%" (atari800-cl.aesp:aesp-server-audio-port server))
    (force-output)

    ;; --- The boot.  30 frames is what README.md documents to reach the
    ;; --- idle loop with the banner drawn; the machine's own text screen
    ;; --- is decoded afterwards as textual confirmation.
    (dotimes (i 30)
      (atari800-cl.machine:machine-run-frame m))

    (let ((bus (atari800-cl.machine:atari-machine-bus m)))
      (flet ((row-text (row)
               (with-output-to-string (s)
                 (loop for col below 40
                       for code = (logand (atari800-cl.bus:bus-read
                                           bus (+ #xBC40 (* row 40) col))
                                          #x7F)
                       for ascii = (+ (case (ash code -5)
                                        (0 #x20) (1 #x40) (2 #x00) (3 #x60))
                                      (logand code #x1F))
                       do (write-char (if (<= #x20 ascii #x7E)
                                          (code-char ascii) #\Space)
                                      s)))))
        (format t "BANNER ~A~%" (atari800-cl.machine:atari-machine-frame-count m))
        (loop for row below 3
              do (format t "  |~A|~%" (row-text row)))
        (force-output)))

    ;; --- Keep serving frames at ~59.92 fps so a video-port client can
    ;; --- capture one; the banner screen is static once idle, so any
    ;; --- frame after BANNER is the screenshot.  Killed externally.
    (loop
      (atari800-cl.machine:machine-run-frame m)
      (sleep 0.0167))))
