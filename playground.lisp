(cd "~/common-lisp/atari800-cl/")
(asdf:load-system :atari800-cl)

(in-package #:cl-user)
(defpackage #:a800-playground
  (:use #:atari800-cl)
  (:documentation
   "Playground for experiments with the atari800-cl emulator.")
  (:export
   #:boot-minimal))


;; Quietly grow the stack when it overflows
(setf sys:*stack-overflow-behaviour* nil)

(defparameter *machine* nil)
(defparameter *runner* nil)

;; (defparameter *aesp*   (a800:start-aesp-server *m*)) 
;; (defparameter *cli*    (a800:start-cli-socket  *m*)) 

(defun boot-minimal ()
  (setf *machine* (a800:make-machine :os-rom    #P"minimal-xl/minimal_os.rom"))
  (setf *runner*  (a800:start-machine     *machine*))
  (print "Hello"))

;; (atari800-cl.cli-socket:cli-server-path *cli*)

;; (defun start ()
;;  (atari800-cl.machine:machine-submit *m* 
;;                                      (lambda (m) (setf (atari800-cl.machine:atari-machine-running-p m) t)) 
;;                                      :priority t))

;; (a800:stop-aesp-server *aesp*)
;; (a800:stop-cli-socket  *cli*)
;; (a800:stop-machine     *runner*)
