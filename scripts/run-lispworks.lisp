;;;; scripts/run-lispworks.lisp --- Launch atari800-cl with AESP + CLI servers.
;;;;
;;;; Invoked by scripts/run-lispworks.sh via:
;;;;   lw-console -build scripts/run-lispworks.lisp

(require "asdf")

(defpackage #:atari800-cl-launch
  (:use #:cl)
  (:export #:*machine*
           #:*runner*
           #:*aesp-server*
           #:*cli-server*
           #:stop-all))

(in-package #:atari800-cl-launch)

(defparameter *machine* nil)
(defparameter *runner* nil)
(defparameter *aesp-server* nil)
(defparameter *cli-server* nil)

(defun stop-all ()
  "Stop all servers and the machine runner."
  (when *aesp-server* (a800:stop-aesp-server *aesp-server*) (setf *aesp-server* nil))
  (when *cli-server* (a800:stop-cli-socket *cli-server*) (setf *cli-server* nil))
  (when *runner* (a800:stop-machine *runner*) (setf *runner* nil))
  (format t "~&Servers stopped.~%"))

(defun project-root-pathname ()
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname *load-truename*)))

(defun quicklisp-software-pathname ()
  (let ((override (lispworks:environment-variable "QUICKLISP_SOFTWARE")))
    (if (and override (> (length override) 0))
        (uiop:ensure-directory-pathname override)
        (merge-pathnames #P"quicklisp/dists/quicklisp/software/"
                         (user-homedir-pathname)))))

(defun configure-asdf ()
  (let* ((root (project-root-pathname))
         (cache (merge-pathnames #P".cache/fasls/" root))
         (ql-software (quicklisp-software-pathname)))
    (ensure-directories-exist cache)
    (unless (probe-file ql-software)
      (error "Quicklisp software tree not found: ~A. Set QUICKLISP_SOFTWARE."
             ql-software))
    (asdf:initialize-output-translations
     `(:output-translations
       (t (,cache :implementation))
       :ignore-inherited-configuration))
    (asdf:initialize-source-registry
     `(:source-registry
       (:tree ,root)
       (:tree ,ql-software)
       :ignore-inherited-configuration))))

(defun start-servers ()
  (configure-asdf)
  (asdf:load-system :atari800-cl)

  (let* ((root (project-root-pathname))
         (os-rom (merge-pathnames #P"roms/ATARIXL.ROM" root))
         (basic-rom (merge-pathnames #P"roms/ATARIBAS.ROM" root)))
    (unless (and (probe-file os-rom) (probe-file basic-rom))
      (error "ROMs not found in roms/ (need ATARIXL.ROM and ATARIBAS.ROM)")
      (lispworks:quit :status 1)))

  (setf *machine* (a800:make-machine
                    :os-rom os-rom
                    :basic-rom basic-rom))
  (setf *runner* (a800:start-machine *machine*))
  (setf *aesp-server* (a800:start-aesp-server *machine*))
  (setf *cli-server* (a800:start-cli-socket *machine*))

  (format t "~&=== atari800-cl running (LispWorks) ===~%")
  (format t "AESP control: 127.0.0.1:47800~%")
  (format t "AESP video:   127.0.0.1:47801~%")
  (format t "AESP audio:   127.0.0.1:47802~%")
  (format t "CLI socket:   ~A~%"
          (uiop:symbol-call :atari800-cl.cli-socket :cli-server-path *cli-server*))
  (format t "~&Type (atari800-cl-launch:stop-all) to shut down.~%"))

;; Batch LispWorks does not init multiprocessing before -build runs.  The
;; machine loop and server acceptors spawn processes, so start-servers must
;; run as the initial MP process.
(mp:initialize-multiprocessing "atari800-cl-server" nil #'start-servers)
