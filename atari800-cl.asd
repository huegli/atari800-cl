;;;; atari800-cl.asd --- ASDF system definition for atari800-cl
;;;;
;;;; A headless Atari 800 XL emulator written in portable Common Lisp.
;;;; Primary target: LispWorks. Also supported: SBCL.

(defsystem #:atari800-cl
  :description "Headless Atari 800 XL emulator (Common Lisp)"
  :author "Nikolai Schlegel"
  :license "MIT"
  :version "0.0.1"
  :homepage "https://example.com/atari800-cl"
  :depends-on (#:alexandria
               #:bordeaux-threads
               #:usocket          ; AESP TCP transport (no local-socket support; CLI uses compat)
               #:flexi-streams)   ; octet <-> string for AESP INFO payloads
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "package")
                             (:file "compat")
                             (:file "input")
                             (:file "memory")
                             (:file "mmu")
                             (:file "bus")
                             (:file "pia")
                             (:file "cpu")
                             (:file "cpu-opcodes")
                             (:file "illegal")
                             (:file "antic")
                             (:file "gtia")
                             (:file "pokey")
                             (:file "irq")
                             (:file "machine")
                             (:file "main"))))
  :in-order-to ((test-op (test-op #:atari800-cl/tests))))

(defsystem #:atari800-cl/tests
  :description "Test suite for atari800-cl"
  :author "Nikolai Schlegel"
  :license "MIT"
  :depends-on (#:atari800-cl
               #:fiveam)
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "package")
                             (:file "test-suite")
                             (:file "test-helpers")
                             (:file "test-compat")
                             (:file "test-memory")
                             (:file "test-cpu")
                             (:file "test-cpu-opcodes")
                             (:file "test-illegal")
                             (:file "test-mmu")
                             (:file "test-pia")
                             (:file "test-antic")
                             (:file "test-gtia")
                             (:file "test-pokey")
                             (:file "test-machine")
                             (:file "test-input")
                             (:file "test-regressions"))))
  :perform (test-op (op c)
             (uiop:symbol-call :fiveam :run!
                               (uiop:find-symbol* :atari800-cl-suite
                                                  :atari800-cl/tests))))
