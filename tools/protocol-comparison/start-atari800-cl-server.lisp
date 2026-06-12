;;;; tools/protocol-comparison/start-atari800-cl-server.lisp
;;;;
;;;; Launcher script for the protocol comparison harness.  Boots a complete
;;;; atari800-cl machine, starts the AESP and CLI socket servers, prints a
;;;; single-line JSON readiness record on stdout, then blocks until killed.
;;;;
;;;; Reads configuration from environment variables (set by the Python
;;;; adapter so the same invocation works under sbcl --no-userinit):
;;;;
;;;;   A800_CONTROL_PORT   AESP control TCP port      (default 0 = ephemeral)
;;;;   A800_VIDEO_PORT     AESP video TCP port        (default 0 = ephemeral)
;;;;   A800_AUDIO_PORT     AESP audio TCP port        (default 0 = ephemeral)
;;;;   A800_CLI_SOCKET     CLI Unix-socket path       (default tmp file)
;;;;   A800_HOST           bind host for AESP         (default 127.0.0.1)
;;;;   A800_READY_FILE     extra file to atomically  rewrite once ready
;;;;                       (optional; readiness JSON is always printed to
;;;;                       stdout regardless)
;;;;
;;;; Stdout is line-buffered.  Always print exactly one
;;;;   ATARI800-CL-READY <json-blob>
;;;; line, then sleep forever — Python uses SIGTERM to terminate.

(require :asdf)

(defun %getenv (name &optional default)
  (or (uiop:getenv name) default))

(defun %parse-int (string &optional (default 0))
  (handler-case (parse-integer string)
    (error () default)))

(defun %main ()
  (let* ((control-port (%parse-int (%getenv "A800_CONTROL_PORT" "0")))
         (video-port   (%parse-int (%getenv "A800_VIDEO_PORT"   "0")))
         (audio-port   (%parse-int (%getenv "A800_AUDIO_PORT"   "0")))
         (host         (%getenv "A800_HOST" "127.0.0.1"))
         (cli-path     (%getenv "A800_CLI_SOCKET"))
         (ready-file   (%getenv "A800_READY_FILE")))
    (asdf:load-system :atari800-cl)
    (let* ((machine (uiop:symbol-call :atari800-cl :make-machine))
           (runner  (uiop:symbol-call :atari800-cl :start-machine machine))
           (aesp    (uiop:symbol-call :atari800-cl :start-aesp-server
                                      machine
                                      :host host
                                      :control-port control-port
                                      :video-port video-port
                                      :audio-port audio-port))
           (cli     (apply #'uiop:symbol-call :atari800-cl :start-cli-socket
                           machine
                           (when cli-path (list :path cli-path))))
           (actual-control (uiop:symbol-call :atari800-cl.aesp :aesp-server-control-port aesp))
           (actual-video   (uiop:symbol-call :atari800-cl.aesp :aesp-server-video-port aesp))
           (actual-audio   (uiop:symbol-call :atari800-cl.aesp :aesp-server-audio-port aesp))
           (actual-cli     (uiop:symbol-call :atari800-cl.cli-socket :cli-server-path cli))
           (json (format nil
                         "{\"implementation\":\"atari800-cl\",~
                          \"aesp_control\":~D,\"aesp_video\":~D,\"aesp_audio\":~D,~
                          \"cli_socket\":~S,\"host\":~S}"
                         actual-control actual-video actual-audio
                         actual-cli host)))
      (format t "ATARI800-CL-READY ~A~%" json)
      (finish-output)
      (when ready-file
        (with-open-file (s ready-file :direction :output
                                       :if-exists :supersede
                                       :if-does-not-exist :create)
          (write-line json s)))
      (unwind-protect
           ;; Block forever; Python sends SIGTERM to kill us.
           (loop (sleep 60))
        (ignore-errors (uiop:symbol-call :atari800-cl :stop-cli-socket cli))
        (ignore-errors (uiop:symbol-call :atari800-cl :stop-aesp-server aesp))
        (ignore-errors (uiop:symbol-call :atari800-cl :stop-machine runner))))))

(handler-case (%main)
  (error (e)
    (format *error-output* "atari800-cl launcher error: ~A~%" e)
    (finish-output *error-output*)
    (uiop:quit 1)))
