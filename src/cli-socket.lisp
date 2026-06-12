;;;; src/cli-socket.lisp --- Text CLI line protocol over a Unix socket.
;;;;
;;;; The Attic CLI/GUI protocol: newline-terminated requests
;;;;
;;;;   CMD:<verb> [args...]
;;;;
;;;; and replies
;;;;
;;;;   OK:<data>      success (single line; multi-line uses the 0x1E
;;;;                  record separator between records)
;;;;   ERR:<message>  failure
;;;;
;;;; This file has two halves: a pure parser (PARSE-CLI-COMMAND and the
;;;; PARSE-HEX-* / PARSE-REGISTER-ASSIGNMENTS helpers — unit-testable without
;;;; sockets) and a server that listens on a Unix-domain socket and drives
;;;; the machine through its command mailbox.

(in-package #:atari800-cl.cli-socket)

(defparameter +cli-version+ "0.0.1"
  "Version string reported by the `version` verb.")

(defparameter +cli-record-separator+ (code-char #x1E)
  "ASCII 0x1E, the record separator used between lines of a multi-line reply.")

(define-condition cli-parse-error (error)
  ((message :initarg :message :reader cli-parse-error-message))
  (:report (lambda (c s) (format s "~A" (cli-parse-error-message c))))
  (:documentation "Signalled by the CLI parser on malformed arguments."))

;;; ---------------------------------------------------------------------------
;;; Tokenizing helpers

(defun %whitespace-p (ch)
  (member ch '(#\Space #\Tab #\Return #\Newline #\Page)))

(defun %tokenize (string)
  "Split STRING on runs of whitespace into a list of non-empty tokens."
  (let ((tokens '()) (start nil) (len (length string)))
    (dotimes (i len)
      (let ((ws (%whitespace-p (char string i))))
        (cond ((and (not ws) (null start)) (setf start i))
              ((and ws start) (push (subseq string start i) tokens) (setf start nil)))))
    (when start (push (subseq string start len) tokens))
    (nreverse tokens)))

(defun %split-on (string char)
  "Split STRING on CHAR; trim whitespace from each part; drop empty parts."
  (let ((parts '()) (start 0))
    (dotimes (i (length string))
      (when (char= (char string i) char)
        (push (string-trim '(#\Space #\Tab) (subseq string start i)) parts)
        (setf start (1+ i))))
    (push (string-trim '(#\Space #\Tab) (subseq string start)) parts)
    (remove "" (nreverse parts) :test #'string=)))

(defun %strip-hex-prefix (string)
  "Drop a leading $ or 0x/0X from STRING (hex literal prefixes)."
  (cond ((and (>= (length string) 1) (char= (char string 0) #\$))
         (subseq string 1))
        ((and (>= (length string) 2) (char= (char string 0) #\0)
              (char-equal (char string 1) #\x))
         (subseq string 2))
        (t string)))

;;; ---------------------------------------------------------------------------
;;; Parser

(defun parse-cli-command (line)
  "Parse a request LINE (with or without a leading CMD: prefix) into
(values verb args): VERB a downcased string, ARGS a list of string tokens.
Returns (values NIL NIL) for a blank line."
  (let* ((trimmed (string-trim '(#\Space #\Tab #\Return #\Newline) line))
         (body (if (and (>= (length trimmed) 4)
                        (string-equal "CMD:" (subseq trimmed 0 4)))
                   (subseq trimmed 4)
                   trimmed))
         (tokens (%tokenize body)))
    (if (null tokens)
        (values nil nil)
        (values (string-downcase (first tokens)) (rest tokens)))))

(defun parse-hex-address (string)
  "Parse a hex address/number token (\"$1000\", \"0x1000\", \"1000\") into an
integer.  Signals CLI-PARSE-ERROR on malformed input."
  (let ((s (%strip-hex-prefix string)))
    (handler-case (parse-integer s :radix 16)
      (error () (error 'cli-parse-error
                       :message (format nil "bad hex number: ~S" string))))))

(defun parse-hex-byte (string)
  "Parse one hex byte token into an integer 0..255."
  (let ((v (handler-case (parse-integer (%strip-hex-prefix string) :radix 16)
             (error () (error 'cli-parse-error
                              :message (format nil "bad hex byte: ~S" string))))))
    (unless (<= 0 v #xFF)
      (error 'cli-parse-error :message (format nil "byte out of range: ~S" string)))
    v))

(defun parse-hex-byte-list (string)
  "Parse a comma-separated hex byte list (\"DE,AD,BE,EF\") into a list of
integers 0..255."
  (let ((parts (%split-on string #\,)))
    (when (null parts)
      (error 'cli-parse-error :message "empty byte list"))
    (mapcar #'parse-hex-byte parts)))

(defun parse-register-assignments (tokens)
  "Parse REG=VALUE tokens (\"A=$10\" \"PC=$1234\") into an alist
((:a . 16) (:pc . 4660)).  Valid registers: A X Y SP P PC."
  (mapcar
   (lambda (tok)
     (let ((eq (position #\= tok)))
       (unless (and eq (plusp eq) (< eq (1- (length tok))))
         (error 'cli-parse-error :message (format nil "bad assignment: ~S" tok)))
       (let ((reg (intern (string-upcase (subseq tok 0 eq)) :keyword))
             (val (parse-hex-address (subseq tok (1+ eq)))))
         (unless (member reg '(:a :x :y :sp :p :pc))
           (error 'cli-parse-error :message (format nil "unknown register: ~A"
                                                    (subseq tok 0 eq))))
         (cons reg val))))
   tokens))

;;; ---------------------------------------------------------------------------
;;; Verb handlers
;;;
;;; Each handler takes (server args) and returns a reply string.  Handlers
;;; that touch machine state run their work through the command mailbox so it
;;; executes on the emulator thread (a MACHINE-RUN-LOOP must be draining it).

(defun %with-machine (server thunk &key priority)
  (machine-submit (cli-server-machine server) thunk :priority priority))

(defun %parse-count (string)
  (handler-case (parse-integer string)
    (error () (error 'cli-parse-error :message (format nil "bad count: ~S" string)))))

(defun %registers-string (cpu)
  (format nil "OK:A=$~2,'0X X=$~2,'0X Y=$~2,'0X SP=$~2,'0X P=$~2,'0X PC=$~4,'0X"
          (atari800-cl.cpu:cpu-a cpu)  (atari800-cl.cpu:cpu-x cpu)
          (atari800-cl.cpu:cpu-y cpu)  (atari800-cl.cpu:cpu-sp cpu)
          (atari800-cl.cpu:cpu-flags cpu) (atari800-cl.cpu:cpu-pc cpu)))

(defun %verb-ping (server args)    (declare (ignore server args)) "OK:pong")
(defun %verb-version (server args) (declare (ignore server args)) (format nil "OK:~A" +cli-version+))

(defun %verb-pause (server args)
  (declare (ignore args))
  (%with-machine server (lambda (m) (setf (atari-machine-running-p m) nil)) :priority t)
  "OK:paused")

(defun %verb-resume (server args)
  (declare (ignore args))
  (%with-machine server (lambda (m) (setf (atari-machine-running-p m) t)) :priority t)
  "OK:running")

(defun %verb-reset (server args)
  (declare (ignore args))                 ; cold|warm both cold-reset in MVP
  (%with-machine server (lambda (m) (machine-cold-reset m)) :priority t)
  "OK:reset")

(defun %verb-status (server args)
  (declare (ignore args))
  (%with-machine server
    (lambda (m)
      (format nil "OK:running=~A frame=~D scanline=~D pc=$~4,'0X"
              (if (atari-machine-running-p m) "t" "nil")
              (atari-machine-frame-count m)
              (machine-scanline m)
              (atari800-cl.cpu:cpu-pc (atari-machine-cpu m))))))

(defun %verb-step (server args)
  (let ((count (if args (min (%parse-count (first args)) 65535) 1)))
    (%with-machine server
      (lambda (m)
        (let ((cpu (atari-machine-cpu m)) (done 0))
          (handler-case
              (dotimes (i count) (declare (ignore i))
                (atari800-cl.cpu:step-cpu cpu) (incf done))
            (atari800-cl.cpu:illegal-opcode () nil))
          (format nil "OK:stepped ~D pc=$~4,'0X" done (atari800-cl.cpu:cpu-pc cpu)))))))

(defun %verb-read (server args)
  (unless (>= (length args) 2)
    (error 'cli-parse-error :message "usage: read $ADDR COUNT"))
  (let ((addr (parse-hex-address (first args)))
        (count (%parse-count (second args))))
    (%with-machine server
      (lambda (m)
        (let ((bus (atari-machine-bus m)))
          (with-output-to-string (s)
            (write-string "OK:" s)
            (dotimes (i count)
              (when (plusp i) (write-char #\Space s))
              (format s "~2,'0X" (atari800-cl.bus:bus-peek-ram
                                  bus (ldb (byte 16 0) (+ addr i)))))))))))

(defun %verb-write (server args)
  (unless (>= (length args) 2)
    (error 'cli-parse-error :message "usage: write $ADDR HEX,HEX,..."))
  (let ((addr  (parse-hex-address (first args)))
        (bytes (parse-hex-byte-list (second args))))
    (%with-machine server
      (lambda (m)
        (let ((bus (atari-machine-bus m)))
          (loop for b in bytes for i from 0
                do (atari800-cl.bus:bus-poke-ram bus (ldb (byte 16 0) (+ addr i)) b))
          (format nil "OK:wrote ~D" (length bytes)))))))

(defun %verb-fill (server args)
  (unless (>= (length args) 3)
    (error 'cli-parse-error :message "usage: fill $START $END $VALUE"))
  (let ((start (parse-hex-address (first args)))
        (end   (parse-hex-address (second args)))
        (val   (parse-hex-byte (third args))))
    (when (> start end) (error 'cli-parse-error :message "start > end"))
    (%with-machine server
      (lambda (m)
        (let ((bus (atari-machine-bus m)) (n 0))
          (loop for a from start to end
                do (atari800-cl.bus:bus-poke-ram bus (ldb (byte 16 0) a) val) (incf n))
          (format nil "OK:filled ~D" n))))))

(defun %verb-registers (server args)
  (if args
      (let ((assigns (parse-register-assignments args)))
        (%with-machine server
          (lambda (m)
            (let ((cpu (atari-machine-cpu m)))
              (dolist (a assigns)
                (ecase (car a)
                  (:a  (setf (atari800-cl.cpu:cpu-a cpu)     (ldb (byte 8 0) (cdr a))))
                  (:x  (setf (atari800-cl.cpu:cpu-x cpu)     (ldb (byte 8 0) (cdr a))))
                  (:y  (setf (atari800-cl.cpu:cpu-y cpu)     (ldb (byte 8 0) (cdr a))))
                  (:sp (setf (atari800-cl.cpu:cpu-sp cpu)    (ldb (byte 8 0) (cdr a))))
                  (:p  (setf (atari800-cl.cpu:cpu-flags cpu) (ldb (byte 8 0) (cdr a))))
                  (:pc (setf (atari800-cl.cpu:cpu-pc cpu)    (ldb (byte 16 0) (cdr a))))))
              (%registers-string cpu)))))
      (%with-machine server (lambda (m) (%registers-string (atari-machine-cpu m))))))

(defparameter *cli-verbs*
  (list (cons "ping"      #'%verb-ping)
        (cons "version"   #'%verb-version)
        (cons "pause"     #'%verb-pause)
        (cons "resume"    #'%verb-resume)
        (cons "reset"     #'%verb-reset)
        (cons "status"    #'%verb-status)
        (cons "step"      #'%verb-step)
        (cons "read"      #'%verb-read)
        (cons "write"     #'%verb-write)
        (cons "fill"      #'%verb-fill)
        (cons "registers" #'%verb-registers))
  "Alist mapping a CLI verb string to its handler (server args -> reply
string).  Add a verb by adding a line here.")

(defparameter +cli-deferred-verbs+
  '("basic" "dos" "boot" "screen" "disassemble" "assemble" "breakpoint"
    "mount" "unmount" "drives" "state" "screenshot" "inject" "shutdown")
  "Recognized-but-unimplemented verbs; these reply ERR:Not implemented.")

(defun dispatch-cli-line (server line)
  "Parse and execute one request LINE.  Returns (values reply quit-p): REPLY a
string (or NIL for a blank line), QUIT-P true when the client asked to quit.
Never signals — parse/exec errors become ERR: replies."
  (handler-case
      (multiple-value-bind (verb args) (parse-cli-command line)
        (cond
          ((null verb) (values nil nil))
          ((string= verb "quit") (values "OK:bye" t))
          (t (let ((handler (cdr (assoc verb *cli-verbs* :test #'string=))))
               (cond
                 (handler (values (funcall handler server args) nil))
                 ((member verb +cli-deferred-verbs+ :test #'string=)
                  (values "ERR:Not implemented" nil))
                 (t (values (format nil "ERR:unknown command ~S" verb) nil)))))))
    (cli-parse-error (e) (values (format nil "ERR:~A" (cli-parse-error-message e)) nil))
    (mailbox-full ()      (values "ERR:server busy" nil))
    (error (e)            (values (format nil "ERR:~A" e) nil))))

;;; ---------------------------------------------------------------------------
;;; Server

(defstruct (cli-server (:constructor %make-cli-server))
  "Handle for a running CLI Unix-socket server."
  machine
  path
  listener
  (lock    (make-lock "cli-server"))
  (threads '())
  (clients '())
  (running t))

(defun %cli-add-thread (server th)
  (with-lock ((cli-server-lock server)) (push th (cli-server-threads server)))
  th)

(defun %cli-register (server stream)
  (with-lock ((cli-server-lock server)) (push stream (cli-server-clients server))))

(defun %cli-unregister (server stream)
  (with-lock ((cli-server-lock server))
    (setf (cli-server-clients server) (remove stream (cli-server-clients server)))))

(defun %cli-reader (server stream)
  "Per-client reader: one request line -> one reply line, until quit/EOF."
  (unwind-protect
       (handler-case
           (loop
             (let ((line (read-line stream nil :eof)))
               (when (eq line :eof) (return))
               (multiple-value-bind (reply quit) (dispatch-cli-line server line)
                 (when reply (write-line reply stream) (force-output stream))
                 (when quit (return)))))
         (error () nil))
    (%cli-unregister server stream)
    (ignore-errors (close stream))))

(defun %cli-acceptor (server)
  (loop
    (let ((stream (handler-case (unix-accept (cli-server-listener server))
                    (error () (return)))))
      (cond
        ((not (cli-server-running server)) (ignore-errors (close stream)) (return))
        (t (%cli-register server stream)
           (%cli-add-thread server
             (make-thread (lambda () (%cli-reader server stream))
                          :name "cli-reader")))))))

(defun %default-cli-path ()
  (format nil "/tmp/atari800-cl-~D.sock" (current-process-id)))

(defun start-cli-socket (machine &key path)
  "Start the CLI line-protocol server on a Unix-domain socket (default
/tmp/atari800-cl-<pid>.sock, mode 0600) and return a CLI-SERVER.  Commands
that mutate the machine go through the command mailbox, so a MACHINE-RUN-LOOP
must be draining it.  Pass it to STOP-CLI-SOCKET to shut down."
  (declare (type atari-machine machine))
  (let* ((p (or path (%default-cli-path)))
         (listener (unix-listen p)))
    (ignore-errors (chmod-file p #o600))
    (let ((server (%make-cli-server :machine machine :path p :listener listener)))
      (%cli-add-thread server
        (make-thread (lambda () (%cli-acceptor server)) :name "cli-acceptor"))
      server)))

(defun stop-cli-socket (server &key (timeout 2.0))
  "Stop SERVER: close the listener (unblocking the acceptor) and all client
streams (unblocking the readers), join/destroy the threads, and unlink the
socket file.  Returns SERVER."
  (setf (cli-server-running server) nil)
  (ignore-errors (unix-close (cli-server-listener server)))
  (dolist (s (copy-list (cli-server-clients server)))
    (ignore-errors (close s)))
  (dolist (th (copy-list (cli-server-threads server)))
    (let ((deadline (+ (get-internal-real-time)
                       (truncate (* timeout internal-time-units-per-second)))))
      (loop while (and (thread-alive-p th) (< (get-internal-real-time) deadline))
            do (sleep 0.005))
      (when (thread-alive-p th) (destroy-thread th))))
  server)
