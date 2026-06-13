#!/bin/sh
# Launch atari800-cl with ROMs, AESP server, and CLI server using SBCL

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Ensure ROMs exist
if [ ! -f "roms/ATARIXL.ROM" ] || [ ! -f "roms/ATARIBAS.ROM" ]; then
    echo "ERROR: ROMs not found in roms/ (need ATARIXL.ROM and ATARIBAS.ROM)" >&2
    exit 1
fi

echo "Starting atari800-cl with AESP + CLI servers..."

sbcl --non-interactive \
     --eval '(load "~/quicklisp/setup.lisp")' \
     --eval '(ql:quickload :atari800-cl)' \
     --eval '
(defparameter *m* 
  (atari800-cl:make-machine 
    :os-rom    #P"roms/ATARIXL.ROM"
    :basic-rom #P"roms/ATARIBAS.ROM"))
(defparameter *runner* (atari800-cl:start-machine *m*))
(defparameter *aesp* (atari800-cl:start-aesp-server *m*))
(defparameter *cli* (atari800-cl:start-cli-socket *m*))
(format t "~&=== Servers running ===~%")
(format t "AESP control: 127.0.0.1:47800~%")
(format t "AESP video:   127.0.0.1:47801~%")
(format t "AESP audio:   127.0.0.1:47802~%")
(format t "CLI socket:   /tmp/atari800-cl-~A.sock~%" (sb-posix:getpid))
(format t "~&Press Ctrl+C to stop...~%")
(sb-thread:join-thread (sb-thread:current-thread)))' \
     --eval '(atari800-cl:stop-aesp-server *aesp*)' \
     --eval '(atari800-cl:stop-cli-socket *cli*)' \
     --eval '(atari800-cl:stop-machine *runner*)'