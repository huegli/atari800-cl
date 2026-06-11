;;;; tests/test-aesp.lisp --- AESP codec + server tests.
;;;;
;;;; Two child suites under the root: AESP-CODEC-SUITE (pure, byte-exact)
;;;; and AESP-SERVER-SUITE (boots a real 3-port TCP server and exercises the
;;;; control messages over a loopback usocket client).

(in-package #:atari800-cl/tests)

(def-suite aesp-suite
  :description "AESP binary protocol (codec + server)."
  :in atari800-cl-suite)

;;; ===========================================================================
;;; Codec — pure, byte-exact

(def-suite aesp-codec-suite :description "AESP wire codec." :in aesp-suite)
(in-suite aesp-codec-suite)

(defun %octets (&rest bytes)
  (make-array (length bytes) :element-type '(unsigned-byte 8)
                             :initial-contents bytes))

(test aesp-encode-ping-is-byte-exact
  "A no-payload PING encodes to the canonical 8-byte header."
  (let ((bytes (atari800-cl.aesp:encode-aesp-message atari800-cl.aesp:+aesp-ping+)))
    (is (equalp (%octets #xAE #x50 #x01 #x00 #x00 #x00 #x00 #x00) bytes)
        "PING header; got ~S" bytes)))

(test aesp-encode-with-payload-sets-length-big-endian
  "The 4-byte length field is big-endian and the payload follows the header."
  (let* ((payload (%octets 1 2 3))
         (bytes (atari800-cl.aesp:encode-aesp-message atari800-cl.aesp:+aesp-info+ payload)))
    (is (= 11 (length bytes)))
    (is (equalp (%octets #xAE #x50 #x01 #x06 #x00 #x00 #x00 #x03 1 2 3) bytes))))

(test aesp-decode-header-roundtrip
  "DECODE-AESP-HEADER recovers the type and length ENCODE put in."
  (let ((bytes (atari800-cl.aesp:encode-aesp-message #x44 (%octets 9 9 9 9 9))))
    (multiple-value-bind (type len) (atari800-cl.aesp:decode-aesp-header bytes)
      (is (= #x44 type))
      (is (= 5 len)))))

(test aesp-decode-rejects-bad-magic
  "A header with the wrong magic raises AESP-PROTOCOL-ERROR."
  (signals atari800-cl.aesp:aesp-protocol-error
    (atari800-cl.aesp:decode-aesp-header
     (%octets #x00 #x00 #x01 #x00 #x00 #x00 #x00 #x00))))

(test aesp-decode-rejects-bad-version
  "A header with an unknown version raises AESP-PROTOCOL-ERROR."
  (signals atari800-cl.aesp:aesp-protocol-error
    (atari800-cl.aesp:decode-aesp-header
     (%octets #xAE #x50 #x02 #x00 #x00 #x00 #x00 #x00))))

(test aesp-decode-rejects-oversize-length
  "A length over the 16 MiB cap raises AESP-PROTOCOL-ERROR."
  (signals atari800-cl.aesp:aesp-protocol-error
    (atari800-cl.aesp:decode-aesp-header
     (%octets #xAE #x50 #x01 #x00 #xFF #xFF #xFF #xFF))))

(test aesp-read-write-over-a-stream-roundtrip
  "WRITE-AESP-MESSAGE then READ-AESP-MESSAGE over an in-memory binary stream
recovers the type and payload."
  (let ((buf (flexi-streams:make-in-memory-output-stream)))
    (atari800-cl.aesp:write-aesp-message buf atari800-cl.aesp:+aesp-status+ (%octets #x2A))
    (let ((in (flexi-streams:make-in-memory-input-stream
               (flexi-streams:get-output-stream-sequence buf))))
      (multiple-value-bind (type payload) (atari800-cl.aesp:read-aesp-message in)
        (is (= atari800-cl.aesp:+aesp-status+ type))
        (is (equalp (%octets #x2A) payload))))))

(test aesp-read-signals-eof-on-empty-stream
  "Reading from a closed/empty stream signals END-OF-FILE (clean close)."
  (let ((in (flexi-streams:make-in-memory-input-stream (%octets))))
    (signals end-of-file (atari800-cl.aesp:read-aesp-message in))))
