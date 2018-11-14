;;; tcp6.scm

;;; License

;; Copyright (c) 2011, Jim Ursetto
;; Copyright (c) 2008-2011, The Chicken Team
;; Copyright (c) 2000-2007, Felix L. Winkelmann
;; All rights reserved.

;; Redistribution and use in source and binary forms, with or without
;; modification, are permitted provided that the following conditions
;; are met:

;; - Redistributions of source code must retain the above copyright
;; notice, this list of conditions and the following disclaimer.
;; - Redistributions in binary form must reproduce the above copyright
;; notice, this list of conditions and the following disclaimer in
;; the documentation and/or other materials provided with the
;; distribution.
;; - Neither the name of the author nor the names of its contributors
;; may be used to endorse or promote products derived from this
;; software without specific prior written permission.

;; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;; "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;; LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
;; FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
;; COPYRIGHT HOLDERS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
;; INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
;; (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
;; SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
;; HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
;; STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
;; ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
;; OF THE POSSIBILITY OF SUCH DAMAGE.

(import scheme)
(cond-expand
 (chicken-4
  (import chicken)
  (use extras)
  (require-library srfi-1) (import (only srfi-1 filter))
  (require-extension socket))
 (else
  (import (chicken base))
  (import (chicken condition))
  (import (only (srfi 1) filter))
  (import socket)))

(define-inline (tcp-error where msg . args)
  (apply ##sys#signal-hook #:network-error where msg args))

(define *support-ipv6-v6only?*
  (let ((s #f))
    (let ((rc (handle-exceptions exn #f
                (set! s (socket af/inet6 sock/stream))  ;; test ipv6 (and save?)
                (set! (ipv6-v6-only? s) #t)             ;; test v6only
                #t)))
      (when s (socket-close* s))
      rc)))

;; Force tcp4 for (tcp-listen port) when v6only enabled or
;; unsupported.  This will fail on an IPv6-only system.  Assume when
;; host is unspecified, the first addrinfo result on a dual-stack
;; system is "::".  If it is "0.0.0.0", IPv6 will be disabled.
(define (bind-tcp-socket port host)
  (let* ((family (if (and (not host) (or (tcp-bind-ipv6-only)
                                         (not *support-ipv6-v6only?*)))
		     af/inet #f))
	 (ai (address-information host port family: family
				  type: sock/stream flags: ai/passive)))
    (when (null? ai)
      (tcp-error 'tcp-listen "node or service lookup failed" host port))
    (let* ((ai (car ai))
	   (addr (addrinfo-address ai)))
    (let* ((so (socket (addrinfo-family ai) (addrinfo-socktype ai) 0))
	   (s (socket-fileno so)))
      (when (= (addrinfo-family ai) af/inet6)
        (when *support-ipv6-v6only?*
          ;; TODO: If host is not #f, can probably omit setting v6only.
          (set! (ipv6-v6-only? so) (tcp-bind-ipv6-only))))
      (set! (so-reuse-address? so) #t)
      (socket-bind so addr)
      so))))

(define-constant default-backlog 10)

(define-record-type tcp6-listener
  (make-tcp6-listener socket)
  tcp-listener?
  (socket tcp-listener-socket))

(define (tcp-listen port #!optional (w default-backlog) host)
  (let ((so (bind-tcp-socket port host)))
    (socket-listen so w)
    (make-tcp6-listener so)))

(define (tcp-listener-fileno tcpl)
  (socket-fileno (tcp-listener-socket tcpl)))

(define (tcp-close tcpl)
  (socket-close (tcp-listener-socket tcpl)))

;; Currently we rely on socket egg defaults for these
(define-constant +input-buffer-size+ 1024)
(define-constant +output-chunk-size+ 8192)

(define tcp-buffer-size (make-parameter #f))
(define tcp-read-timeout (make-parameter (* 60 1000)))
(define tcp-write-timeout (make-parameter (* 60 1000)))
(define tcp-connect-timeout (make-parameter #f))
(define tcp-accept-timeout (make-parameter #f))
(define tcp-bind-ipv6-only (make-parameter #f))

(define (tcp-accept tcpl)
  (parameterize ((socket-accept-timeout (tcp-accept-timeout))
                 (socket-receive-timeout (tcp-read-timeout))
                 (socket-send-timeout    (tcp-write-timeout))
                 ;;(socket-send-size           +output-chunk-size+)
                 ;;(socket-receive-buffer-size +input-buffer-size+)
                 (socket-send-buffer-size    (tcp-buffer-size)))
    (let ((so (socket-accept (tcp-listener-socket tcpl))))
      (socket-i/o-ports so))))

(define (tcp-accept-ready? tcpl)
  (socket-accept-ready? (tcp-listener-socket tcpl)))

(define-inline (network-error where msg . args)
  (apply 
   ##sys#signal-hook #:network-error where msg args))

;; Sequentially connect to all addrinfo objects until one succeeds, as long
;; as the connection is retryable (e.g. refused, no route, or timeout).
;; Otherwise it will error out on non-recoverable errors.
;; Silently skips non-stream objects for user convenience.
;; Returns: I/O ports bound to the succeeding connection, or throws an error
;; corresponding to the last failed connection attempt.
;; WARNING: On Windows, address-information returns 0 for socket-type unless
;; provided via type: (which is redundant info).
(define (tcp-connect/ai ais)
  ;; Filter first to preserve our "last exception" model.  Filter on sock/stream rather
  ;; than ipproto/tcp because Windows is silly.
  (let ((ais (filter (lambda (ai) (eq? (addrinfo-socktype ai) sock/stream))
                     ais))) 
    (parameterize ((socket-connect-timeout (tcp-connect-timeout))
                   (socket-receive-timeout (tcp-read-timeout))
                   (socket-send-timeout    (tcp-write-timeout))
;;                 (socket-send-size           +output-chunk-size+)
;;                 (socket-receive-buffer-size +input-buffer-size+)
                   (socket-send-buffer-size    (tcp-buffer-size))
                   )
      (socket-i/o-ports (socket-connect/ai ais)))))

(define (tcp-connect host . more)
  (let ((port (optional more #f)))
    (##sys#check-string host)
    (unless port
      (set!-values (host port) (parse-inet-address host))
      (unless port (network-error 'tcp-connect "no port specified" host)))
    (let ((ais (address-information host port type: sock/stream)))  ;; protocol: problematic on WIN
      (when (null? ais)
	(network-error 'tcp-connect "node and/or service lookup failed" host port))
      (tcp-connect/ai ais))))

(define (tcp-addresses p)
  (##sys#check-port p 'tcp-addresses)
  (let ((so (socket-i/o-port->socket p)))
    (values
     (sockaddr-address (socket-name so))
     (sockaddr-address (socket-peer-name so)))))

(define (tcp-port-numbers p)
  (##sys#check-port p 'tcp-port-numbers)
  (let ((so (socket-i/o-port->socket p)))
    (values
     (sockaddr-port (socket-name so))
     (sockaddr-port (socket-peer-name so)))))

(define (tcp-listener-port tcpl)
  (sockaddr-port (socket-name (tcp-listener-socket tcpl))))

(define (tcp-abandon-port p)
  (socket-abandon-port p))

(define (tcp-port->socket p)
  (socket-i/o-port->socket p))

;;; notes

;; added tcp-bind-ipv6-only param; if af/inet6, will set IPV6_V6ONLY option on socket
;; tcp-listen accepts service name string
;; tcp-connect accepts service name string (may issue SRV request)
;; tcp-connect connects to multiple addresses (or explicitly with tcp-connect/ai)

;; input buffer and output chunk size are not configurable without using [[socket]] calls

;; On XP, you must do 'netsh interface ipv6 install' to activate ipv6.
