;;;; tests/test-cli-socket.lisp --- CLI line protocol parser + server tests.
;;;;
;;;; CLI-PARSE-SUITE is pure; CLI-SERVER-SUITE boots a real Unix-domain
;;;; socket server (compat helpers) and exercises every MVP verb.

(in-package #:atari800-cl/tests)

(def-suite cli-suite
  :description "CLI/GUI text line protocol (parser + server)."
  :in atari800-cl-suite)

;;; ===========================================================================
;;; Parser — pure

(def-suite cli-parse-suite :description "CLI request parser." :in cli-suite)
(in-suite cli-parse-suite)

(test cli-parse-command-strips-prefix-and-tokenizes
  "PARSE-CLI-COMMAND drops the CMD: prefix and splits verb + args."
  (multiple-value-bind (verb args)
      (atari800-cl.cli-socket:parse-cli-command "CMD:read $1000 16")
    (is (string= "read" verb))
    (is (equal '("$1000" "16") args))))

(test cli-parse-command-without-prefix
  "A line without CMD: is parsed the same way."
  (multiple-value-bind (verb args)
      (atari800-cl.cli-socket:parse-cli-command "  ping  ")
    (is (string= "ping" verb))
    (is (null args))))

(test cli-parse-command-blank-is-nil
  "A blank line yields (values NIL NIL)."
  (multiple-value-bind (verb args)
      (atari800-cl.cli-socket:parse-cli-command "   ")
    (is (null verb))
    (is (null args))))

(test cli-parse-hex-address-forms
  "$, 0x, and bare hex all parse; junk signals CLI-PARSE-ERROR."
  (is (= #x1000 (atari800-cl.cli-socket:parse-hex-address "$1000")))
  (is (= #x1000 (atari800-cl.cli-socket:parse-hex-address "0x1000")))
  (is (= #x00FF (atari800-cl.cli-socket:parse-hex-address "FF")))
  (signals atari800-cl.cli-socket:cli-parse-error
    (atari800-cl.cli-socket:parse-hex-address "$zz")))

(test cli-parse-hex-byte-list-forms
  "Comma-separated hex bytes parse; an out-of-range byte signals."
  (is (equal '(#xDE #xAD #xBE #xEF)
             (atari800-cl.cli-socket:parse-hex-byte-list "DE,AD,BE,EF")))
  (is (equal '(1 2 3)
             (atari800-cl.cli-socket:parse-hex-byte-list "$01, 02 ,$03")))
  (signals atari800-cl.cli-socket:cli-parse-error
    (atari800-cl.cli-socket:parse-hex-byte-list "100")))   ; > $FF

(test cli-parse-register-assignments-forms
  "REG=VAL tokens parse to an alist; bad register / form signal."
  (is (equal '((:a . #x10) (:pc . #x1234))
             (atari800-cl.cli-socket:parse-register-assignments '("A=$10" "PC=$1234"))))
  (signals atari800-cl.cli-socket:cli-parse-error
    (atari800-cl.cli-socket:parse-register-assignments '("Z=$10")))
  (signals atari800-cl.cli-socket:cli-parse-error
    (atari800-cl.cli-socket:parse-register-assignments '("A"))))

;;; ===========================================================================
;;; Server — real Unix-domain socket server

(def-suite cli-server-suite
  :description "CLI Unix-socket server: every MVP verb + clean shutdown."
  :in cli-suite)
(in-suite cli-server-suite)

(defparameter *cli-test-counter* 0)
(defun %cli-test-path ()
  (format nil "/tmp/atari800-cl-clitest-~D-~D.sock"
          (current-process-id) (incf *cli-test-counter*)))

(defun %cli-request (stream line)
  "Send a request LINE and read one reply line."
  (write-line line stream)
  (force-output stream)
  (read-line stream))

(defmacro with-cli-server ((mvar svar streamvar) &body body)
  "Start a paused run-loop + a CLI Unix-socket server on a unique path,
connect a client (STREAMVAR), run BODY, then tear it all down."
  (let ((stop (gensym "STOP")) (loop-th (gensym "LOOP")) (path (gensym "PATH")))
    `(let* ((,mvar (atari800-cl.machine:make-atari-machine))
            (,stop (list nil))
            (,loop-th (make-thread
                       (lambda () (atari800-cl.machine:machine-run-loop
                                   ,mvar :stop-flag (lambda () (car ,stop))))
                       :name "cli-test-runloop"))
            (,path (%cli-test-path))
            (,svar (atari800-cl.cli-socket:start-cli-socket ,mvar :path ,path))
            (,streamvar (atari800-cl.transport:unix-connect ,path)))
       (declare (ignorable ,mvar ,svar ,streamvar))
       (unwind-protect (progn ,@body)
         (ignore-errors (close ,streamvar))
         (atari800-cl.cli-socket:stop-cli-socket ,svar)
         (setf (car ,stop) t)
         (join-thread ,loop-th)))))

(test cli-server-ping-and-version
  "ping -> OK:pong; version -> OK:<version>."
  (with-cli-server (m srv s)
    (is (string= "OK:pong" (%cli-request s "CMD:ping")))
    (is (eql 0 (search "OK:" (%cli-request s "CMD:version"))))))

(test cli-server-pause-resume
  "resume/pause flip running-p and reply accordingly."
  (with-cli-server (m srv s)
    (is (string= "OK:running" (%cli-request s "CMD:resume")))
    (is-true (%wait-until (lambda () (atari800-cl.machine:atari-machine-running-p m))))
    (is (string= "OK:paused" (%cli-request s "CMD:pause")))
    (is-true (%wait-until (lambda () (not (atari800-cl.machine:atari-machine-running-p m)))))))

(test cli-server-memory-read-write-fill
  "write/read round-trip through RAM; fill sets a range."
  (with-cli-server (m srv s)
    (is (string= "OK:wrote 4" (%cli-request s "CMD:write $1000 DE,AD,BE,EF")))
    (is (string= "OK:DE AD BE EF" (%cli-request s "CMD:read $1000 4")))
    (is (string= "OK:filled 4" (%cli-request s "CMD:fill $2000 $2003 $FF")))
    (is (string= "OK:FF FF FF FF" (%cli-request s "CMD:read $2000 4")))))

(test cli-server-registers-get-and-set
  "registers reports A/X/Y/SP/P/PC; assignment updates them."
  (with-cli-server (m srv s)
    (let ((before (%cli-request s "CMD:registers")))
      (is (eql 0 (search "OK:A=$" before))))
    (let ((set (%cli-request s "CMD:registers A=$42 PC=$1234")))
      (is-true (search "A=$42" set))
      (is-true (search "PC=$1234" set)))
    (is-true (search "A=$42" (%cli-request s "CMD:registers")))))

(test cli-server-step-and-status
  "step runs N instructions; status reports machine state."
  (with-cli-server (m srv s)
    (is (eql 0 (search "OK:stepped 3" (%cli-request s "CMD:step 3"))))
    (is (eql 0 (search "OK:running=" (%cli-request s "CMD:status"))))))

(test cli-server-unknown-and-deferred
  "Unknown verbs and recognized-but-unimplemented verbs give ERR replies."
  (with-cli-server (m srv s)
    (is (string= "ERR:unknown command \"frobnicate\""
                 (%cli-request s "CMD:frobnicate")))
    (is (string= "ERR:Not implemented" (%cli-request s "CMD:basic list")))))

(test cli-server-bad-args-error-not-crash
  "Malformed arguments produce an ERR reply, not a dropped connection."
  (with-cli-server (m srv s)
    (is (eql 0 (search "ERR:" (%cli-request s "CMD:read $zz 4"))))
    ;; connection still usable afterward
    (is (string= "OK:pong" (%cli-request s "CMD:ping")))))

(test cli-server-quit-closes-connection
  "quit replies OK:bye then closes the connection (EOF on next read)."
  (with-cli-server (m srv s)
    (is (string= "OK:bye" (%cli-request s "CMD:quit")))
    (is (eq :eof (read-line s nil :eof)))))

(test cli-server-stops-cleanly-with-active-client
  "STOP-CLI-SOCKET returns promptly with a client still connected."
  (with-cli-server (m srv s)
    (is (atari800-cl.cli-socket:cli-server-p srv))))
