;;;; xex-loader.lisp --- Load an Atari DOS executable (.xex / .obx) into an
;;;; atari800-cl machine and locate its entry point.
;;;;
;;;; XEX format (the binary MADS emits by default):
;;;;
;;;;   [optional]  $FF $FF                        header marker
;;;;   one or more segments, each:
;;;;     start-addr (little-endian u16)
;;;;     end-addr   (little-endian u16)           ; inclusive
;;;;     data       (end-start+1 bytes)
;;;;
;;;; Two segments have special meaning:
;;;;   start=end=$02E0..$02E1   ->  RUN  vector (program entry point)
;;;;   start=end=$02E2..$02E3   ->  INIT vector (called once before RUN)
;;;;
;;;; This loader installs every segment's data into the machine's bus,
;;;; remembers the most-recent RUN address (or, if none, the start of the
;;;; first non-special segment), and returns it as the entry point.
;;;;
;;;; The loader writes through ATARI800-CL.BUS:BUS-WRITE so RAM, hardware
;;;; mirror, and bank-switched windows all behave correctly.

(in-package #:cl-user)

(defpackage #:atari-xl-bbedit.xex
  (:use #:cl)
  (:export #:load-xex
           #:xex-entry-point))

(in-package #:atari-xl-bbedit.xex)

(defun %read-u8 (stream)
  (let ((b (read-byte stream nil :eof)))
    (when (eq b :eof) (return-from %read-u8 nil))
    b))

(defun %read-u16 (stream)
  "Read two little-endian bytes; return NIL on EOF (clean or torn)."
  (let ((lo (%read-u8 stream)))
    (unless lo (return-from %read-u16 nil))
    (let ((hi (%read-u8 stream)))
      (unless hi (return-from %read-u16 nil))
      (logior lo (ash hi 8)))))

(defun %install-segment (bus start data)
  "Write DATA into BUS starting at address START."
  (let ((bus-write (find-symbol "BUS-WRITE" "ATARI800-CL.BUS")))
    (unless bus-write
      (error "atari800-cl.bus:bus-write not found — is :atari800-cl loaded?"))
    (loop for i from 0 below (length data)
          for addr = (logand #xFFFF (+ start i))
          do (funcall bus-write bus addr (aref data i)))))

(defun load-xex (machine path)
  "Load the XEX file at PATH into MACHINE.  Returns a plist:

  (:entry  16-bit-address    ; PC to set before running
   :init   16-bit-address-or-nil
   :segments ((start . end) ...))    ; in load order

Signals an error on truncated headers or malformed data."
  (let* ((bus     (funcall (find-symbol "ATARI-MACHINE-BUS" "ATARI800-CL.MACHINE")
                           machine))
         (segments nil)
         (run-addr  nil)
         (init-addr nil)
         (first-seg nil)
         (saw-ffff  nil))
    (declare (ignore saw-ffff))
    (with-open-file (s path :element-type '(unsigned-byte 8))
      (loop
        (let ((w (%read-u16 s)))
          (unless w (return))                ; clean EOF between segments
          (cond
            ;; $FFFF header marker.  Allowed before the first segment and
            ;; (per the spec) optionally before any subsequent segment too.
            ((= w #xFFFF)
             (setf saw-ffff t))
            (t
             ;; W was the LO/HI start address of a segment.  Read end.
             (let* ((start w)
                    (end   (%read-u16 s)))
               (unless end
                 (error "truncated XEX: missing end address for segment starting at $~4,'0X" start))
               (when (> start end)
                 (error "malformed XEX: segment start $~4,'0X > end $~4,'0X" start end))
               (let* ((len (1+ (- end start)))
                      (buf (make-array len :element-type '(unsigned-byte 8))))
                 (let ((n (read-sequence buf s)))
                   (unless (= n len)
                     (error "truncated XEX: segment $~4,'0X-$~4,'0X needs ~D bytes, got ~D"
                            start end len n)))
                 (push (cons start end) segments)
                 ;; Special vectors first (so we don't install them as code).
                 (cond
                   ((and (= start #x02E0) (= end #x02E1))
                    (setf run-addr (logior (aref buf 0) (ash (aref buf 1) 8))))
                   ((and (= start #x02E2) (= end #x02E3))
                    (setf init-addr (logior (aref buf 0) (ash (aref buf 1) 8))))
                   (t
                    (%install-segment bus start buf)
                    (unless first-seg (setf first-seg start)))))))))))
    (list :entry    (or run-addr first-seg)
          :init     init-addr
          :segments (nreverse segments))))

(defun xex-entry-point (load-result)
  "Convenience: pluck the PC entry address out of LOAD-XEX's result."
  (getf load-result :entry))
