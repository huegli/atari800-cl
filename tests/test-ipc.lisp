;;;; tests/test-ipc.lisp --- IPC server lifecycle and wire protocol.
;;;;
;;;; All IPC tests are gated on SBCL because the server uses
;;;; SB-BSD-SOCKETS.  On other implementations the IPC suite skips
;;;; gracefully so the umbrella test-system stays green.

(in-package #:atari800-cl/tests)

(def-suite ipc-suite
  :description "Headless IPC server (Unix-domain socket frame streamer)."
  :in atari800-cl-suite)

(in-suite ipc-suite)

#+sbcl
(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-bsd-sockets))

(defun %temp-socket-path ()
  "Build a unique path under TMPDIR for a Unix-domain test socket."
  (let* ((tmp (or (uiop:getenv "TMPDIR") "/tmp/"))
         (name (format nil "atari800-cl-test-~A.sock" (get-universal-time))))
    (merge-pathnames name (pathname tmp))))

;;; ---------------------------------------------------------------------------
;;; Synthetic ROM helper (defined in test-machine.lisp via %MAKE-SYNTHETIC-OS-ROM)

;;; ---------------------------------------------------------------------------
;;; Server lifecycle

#+sbcl
(test ipc-server-start-spawns-a-live-thread
  "Starting the IPC server creates a thread that is alive after startup."
  (let* ((m (atari800-cl.machine:make-atari-machine))
         (path (%temp-socket-path)))
    (atari800-cl.machine:machine-cold-reset
     m :os-rom (%make-synthetic-os-rom))
    (let ((server (atari800-cl.ipc:ipc-server-start m path)))
      (unwind-protect
           (progn
             (sleep 0.05)
             (is-true (bt:thread-alive-p
                       (atari800-cl.ipc:ipc-server-thread server))
                      "IPC server thread must be alive after start"))
        (atari800-cl.ipc:ipc-server-stop server)))))

#+sbcl
(test ipc-server-stop-terminates-the-thread
  "IPC-SERVER-STOP causes the background thread to exit within timeout."
  (let* ((m (atari800-cl.machine:make-atari-machine))
         (path (%temp-socket-path)))
    (atari800-cl.machine:machine-cold-reset
     m :os-rom (%make-synthetic-os-rom))
    (let ((server (atari800-cl.ipc:ipc-server-start m path)))
      (sleep 0.05)
      (is-true (atari800-cl.ipc:ipc-server-stop server :timeout 2.0)
               "ipc-server-stop must report clean termination within 2s")
      (is-false (bt:thread-alive-p
                 (atari800-cl.ipc:ipc-server-thread server))
                "Thread must no longer be alive after ipc-server-stop"))))

;;; ---------------------------------------------------------------------------
;;; Loopback: a real client receives one frame's worth of data.

#+sbcl
(test ipc-loopback-receives-magic-and-frame-number
  "Connect a client over the Unix socket, let one frame run, and check
the wire-format header bytes: magic = 'A8XL', frame-number = 1."
  (let* ((m (atari800-cl.machine:make-atari-machine))
         (path (namestring (%temp-socket-path))))
    (atari800-cl.machine:machine-cold-reset
     m :os-rom (%make-synthetic-os-rom))
    (let* ((server (atari800-cl.ipc:ipc-server-start m path)))
      (unwind-protect
           (let ((client (make-instance 'sb-bsd-sockets:local-socket
                                        :type :stream)))
             (unwind-protect
                  (progn
                    ;; Connect to the listening server.
                    (sb-bsd-sockets:socket-connect client path)
                    ;; Receive exactly one frame.
                    (let ((buf (make-array atari800-cl.ipc:+ipc-frame-size+
                                           :element-type '(unsigned-byte 8))))
                      ;; Read may return short; loop until we have all bytes.
                      (let ((got 0))
                        (loop while (< got atari800-cl.ipc:+ipc-frame-size+)
                              do (multiple-value-bind (_ len)
                                     (sb-bsd-sockets:socket-receive
                                      client buf
                                      (- atari800-cl.ipc:+ipc-frame-size+ got)
                                      :element-type '(unsigned-byte 8)
                                      :oob nil)
                                   (declare (ignore _))
                                   (when (or (null len) (zerop len))
                                     (return))
                                   (incf got len))))
                      ;; Magic bytes 'A8XL'.
                      (is (= #x41 (aref buf 0)))
                      (is (= #x38 (aref buf 1)))
                      (is (= #x58 (aref buf 2)))
                      (is (= #x4C (aref buf 3)))
                      ;; Frame number (u32 LE) = 1 after the first run-frame.
                      (let ((fn (logior (aref buf 4)
                                        (ash (aref buf 5) 8)
                                        (ash (aref buf 6) 16)
                                        (ash (aref buf 7) 24))))
                        (is (= 1 fn)
                            "First frame must report frame-number=1; got ~A"
                            fn))))
               (ignore-errors (sb-bsd-sockets:socket-close client))))
        (atari800-cl.ipc:ipc-server-stop server)))))

;;; ---------------------------------------------------------------------------
;;; Constant-sanity check (always runs, even on non-SBCL)

(test ipc-frame-size-is-56-bytes
  "Wire-frame is fixed at +IPC-HEADER-SIZE+ + GTIA(32) + audio(8) = 56."
  (is (= 56 atari800-cl.ipc:+ipc-frame-size+)))

;;; ---------------------------------------------------------------------------
;;; Non-SBCL fallback

#-sbcl
(test ipc-unsupported-on-this-implementation
  "On non-SBCL implementations the IPC layer is intentionally a stub."
  (skip "IPC server is SBCL-only in this build."))
