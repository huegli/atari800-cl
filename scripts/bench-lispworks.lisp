;;;; scripts/bench-lispworks.lisp --- Noninteractive LispWorks benchmark runner.
;;;;
;;;; Intended to be invoked by scripts/bench-lispworks.sh via:
;;;;   lw-console -build scripts/bench-lispworks.lisp
;;;;
;;;; Mirrors scripts/test-lispworks.lisp (same sandbox/ASDF/source-registry
;;;; handling and mp:initialize-multiprocessing bootstrap) but loads
;;;; :atari800-cl and runs scripts/bench.lisp instead of the test suite.

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

(defvar *bench-status* 0)

;; ROADMAP.md Phase 31's "Gate re-evaluated (2026-08-24)" finding: LOADing
;; scripts/bench.lisp as source runs it INTERPRETED under LispWorks' -build
;; batch mode, so the per-scanline workload closures (display/idle/serve,
;; audio to a lesser degree) interpret 240 times per frame instead of
;; running compiled -- understating official LispWorks absolute fps on
;; those workloads (idle measured 1840 fps interpreted vs. 2631 fps
;; compiled in that evaluation) while leaving A/B deltas valid, since both
;; sides of a bench-ab run are equally interpreted. Compile bench.lisp into
;; the same output-translations cache ASDF already uses, and only
;; recompile when the source is newer than the cached fasl.
(defun compile-and-load-bench ()
  (let* ((source (merge-pathnames #P"bench.lisp"
                                  (merge-pathnames #P"scripts/"
                                                   (project-root-pathname))))
         (fasl (asdf:apply-output-translations
                (compile-file-pathname source))))
    (ensure-directories-exist fasl)
    (when (or (not (probe-file fasl))
              (< (file-write-date fasl) (file-write-date source)))
      (compile-file source :output-file fasl))
    (load fasl)))

(defun run-atari800-cl-bench ()
  (handler-case
      (progn
        (configure-asdf-for-sandbox)
        (asdf:load-system :atari800-cl)
        (compile-and-load-bench)
        (funcall (uiop:find-symbol* :run-benchmarks :atari800-cl.bench)))
    (error (condition)
      (format *error-output* "~&LispWorks benchmark run failed: ~A~%" condition)
      (setf *bench-status* 1)))
  ;; Batch LispWorks images do not export STOP-MULTIPROCESSING, but we must
  ;; leave the MP scheduler before LISPWORKS:QUIT can return a shell status.
  (mp::stop-multiprocessing))

;; Batch LispWorks images do not initialize multiprocessing before -build code
;; runs.  Run the bench body as the initial MP process (mirrors test-lispworks).
(mp:initialize-multiprocessing "atari800-cl-bench-runner" nil
                               #'run-atari800-cl-bench)
(lispworks:quit :status *bench-status*)
