;;;; scripts/test-lispworks.lisp --- Noninteractive LispWorks test runner.
;;;;
;;;; Intended to be invoked by scripts/test-lispworks.sh via:
;;;;   lw-console -build scripts/test-lispworks.lisp

(require "asdf")

(defun getenv-or-nil (name)
  #+lispworks (lispworks:environment-variable name)
  #-lispworks (uiop:getenv name))

(defun project-root-pathname ()
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname *load-truename*)))

(defun quicklisp-software-pathname ()
  (let ((override (getenv-or-nil "QUICKLISP_SOFTWARE")))
    (if (and override (> (length override) 0))
        (uiop:ensure-directory-pathname override)
        (merge-pathnames #P"quicklisp/dists/quicklisp/software/"
                         (user-homedir-pathname)))))

(defun configure-asdf-for-sandbox ()
  (let* ((root (project-root-pathname))
         (cache (merge-pathnames #P".cache/fasls/" root))
         (ql-software (quicklisp-software-pathname)))
    (ensure-directories-exist cache)
    (unless (probe-file ql-software)
      (error "Quicklisp software tree not found: ~A. Set QUICKLISP_SOFTWARE." ql-software))
    (asdf:initialize-output-translations
     `(:output-translations
       (t (,cache :implementation))
       :ignore-inherited-configuration))
    (asdf:initialize-source-registry
     `(:source-registry
       (:tree ,root)
       (:tree ,ql-software)
       :ignore-inherited-configuration))))

(defvar *test-status* 0)

(defun run-atari800-cl-tests ()
  (handler-case
      (progn
        (configure-asdf-for-sandbox)
        (asdf:load-system :atari800-cl/tests)
        (setf *test-status*
              (if (uiop:symbol-call :fiveam :run!
                                    (uiop:find-symbol* :atari800-cl-suite
                                                       :atari800-cl/tests))
                  0
                  1)))
    (error (condition)
      (format *error-output* "~&LispWorks test run failed: ~A~%" condition)
      (setf *test-status* 1)))
  ;; LispWorks does not export STOP-MULTIPROCESSING, but batch tests need to
  ;; leave the MP scheduler before LISPWORKS:QUIT can return a shell status.
  (mp::stop-multiprocessing))

;; Batch LispWorks images do not initialize multiprocessing before -build code
;; runs.  The machine loop, AESP server, and CLI socket tests create processes,
;; so run the test body as the initial MP process.
(mp:initialize-multiprocessing "atari800-cl-test-runner" nil
                               #'run-atari800-cl-tests)
(lispworks:quit :status *test-status*)
