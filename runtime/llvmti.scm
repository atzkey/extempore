;; 
;; Copyright (c) 2011, Andrew Sorensen
;; 
;; All rights reserved.
;; 
;; 
;; Redistribution and use in source and binary forms, with or without 
;; modification, are permitted provided that the following conditions are met:
;; 
;; 1. Redistributions of source code must retain the above copyright notice, 
;;    this list of conditions and the following disclaimer.
;; 
;; 2. Redistributions in binary form must reproduce the above copyright notice,
;;    this list of conditions and the following disclaimer in the documentation 
;;    and/or other materials provided with the distribution.
;; 
;; Neither the name of the authors nor other contributors may be used to endorse
;; or promote products derived from this software without specific prior written 
;; permission.
;; 
;; 
;; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" 
;; AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE 
;; IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE 
;; ARE DISCLEXTD. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE 
;; LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
;; CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF 
;; SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS 
;; INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN 
;; CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) 
;; ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE 
;; POSSIBILITY OF SUCH DAMAGE.
;; 
;; 



(define *impc:ti:print-sub-checks* #f)
(define *impc:ti:print-main-check* #f)
(define *impc:ti:print-unifications* #f)

(define *impc:compile* #t)
(define *impc:compiler:print* #f)
(define *impc:compiler:print-types* #f)
(define *impc:compiler:verbose* #f)

(define *impc:compiler:print-raw-llvm* #f)

(define *impc:zone* (sys:default-mzone))

(define icr:new-zone
   (lambda ()
      (sys:create-mzone)))

(define icr:destroy-zone
   (lambda (zone)
      (if (equal? *impc:zone* zone)
          (set! *impc:zone* (sys:default-mzone)))
      (if (equal? zone (sys:default-mzone))
          (print-notification "You are not allowed to destroy the default zone")
          (sys:destrop-mzone zone))))

(define icr:set-zone
   (lambda (zone)
      (set! *impc:zone* zone)))

(define icr:set-zone-default
   (lambda ()
      (set! *impc:zone* (sys:default-mzone))))


(define llvm:get-function-args-withoutzone
   (lambda (name)
      (if (llvm:get-function (string-append name "_getter"))
          (let ((ftype (llvm:get-function-args name)))
             (list* (car ftype) (cddr ftype)))
          (llvm:get-function-args name))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; strips pretty-types from source code 
;; returns a cons of (the-new-ast any-explicit-types)
;; 
(define impc:ti:get-var-types
   (lambda (ast)
      (let* ((types '())
             (f (lambda (ast)
                   ;(print 'ast: ast 'types: types)
                   (cond ((null? ast) '())
                         ((atom? ast) ast)
                         ((equal? (car ast) 'dotimes)
                          (list* 'dotimes
                                 (list (if (regex:match? (symbol->string (caadr ast)) ":")
                                           (let ((t (regex:split (symbol->string (caadr ast)) ":")))
                                               (if (regex:match? (cadr t) "^\\<|\\[")
                                                   (if (not (regex:match? (cadr t) "\\>|\\]"))
                                                       (print-error 'Compiler 'Error: 'Syntax 'error: 'bad 'type (cadr t))))
                                              (set! types (cons (cons (string->symbol (car t)) (string->symbol (cadr t))) types))
                                              (string->symbol (car t)))
                                           (caadr ast))
                                       (cadadr ast))
                                 (f (cddr ast))))
                         ((equal? (car ast) 'lambda)
                          (list* 'lambda
                                (map (lambda (a)
                                        (if (regex:match? (symbol->string a) ":")
                                            (let ((t (regex:split (symbol->string a) ":")))                                                                                              
                                               (if (regex:match? (cadr t) "^\\<|\\[")
                                                   (if (not (regex:match? (cadr t) "\\>|\\]"))
                                                       (print-error 'Compiler 'Error: 'Syntax 'error: 'bad 'type (cadr t))))
                                               (set! types (cons (cons (string->symbol (car t)) (string->symbol (cadr t))) types))
                                               (string->symbol (car t)))
                                            a))
                                     (cadr ast))
                                (f (cddr ast))))
                         ((member (car ast) '(let let* letrec))
                          (list* (car ast)
                                 (map (lambda (a)
                                         (if (or (atom? a)                                                 
                                                 (null? (cdr a))
                                                 (> (length (cdr a)) 1))
                                             (print-error 'Compiler 'Error: 'syntax 'error: 'badly 'formed 'let 'expression (sexpr->string a)))
                                         (if (regex:match? (symbol->string (car a)) ":")
                                             (let ((t (regex:split (symbol->string (car a)) ":")))
                                                (if (regex:match? (cadr t) "^\\<|\\[")
                                                    (if (not (regex:match? (cadr t) "\\>|\\]"))
                                                        (print-error 'Compiler 'Error: 'Syntax 'error: 'bad 'type (cadr t))))                                               
                                                (set! types (cons (cons (string->symbol (car t)) (string->symbol (cadr t))) types))                                               
                                                (list (string->symbol (car t)) (car (f (cdr a)))))
                                             (list (car a) (car (f (cdr a))))))
                                      (cadr ast))
                                 (f (cddr ast))))
                         ((pair? ast) 
                          (cons (f (car ast))
                                (f (cdr ast))))))))
         (cons (f ast) types))))


;;
;; TRANSFORM CODE
;;
;; Transform straight R5RS code into
;; a simpler but still valid R5RS scheme code
;;

(define impc:ti:and
   (lambda (ast)
      (if (pair? ast)
          (list 'if (car ast)
                (if (null? (cdr ast))
                    (car ast)
                    (impc:ti:and (cdr ast)))
                #f))))

(define impc:ti:or
   (lambda (ast)
      (if (pair? ast)
          (list 'if (car ast)
                (car ast)
                (if (null? (cdr ast))
                    #f
                    (impc:ti:or (cdr ast)))))))

(define impc:ti:cond
   (lambda (ast)
      (if (null? ast) '()          
	      (list 'if (caar ast) 
                (if (null? (cdar ast))
                    '()
                    (apply list 'begin (cdar ast)))
                (impc:ti:cond (cdr ast))))))

(define impc:ti:map   
   (lambda (ast)
      (list 'let 'maplloop (append (map (lambda (p l)
                                       (cons l (list p)))
                                    (cdr ast)
                                    (list 'l1 'l2 'l3 'l4 'l5 'l6 'l7 'l8 'l9))
                               (list (list 'll '(list))))
            (list 'if '(null? l1) '(reverse ll)
                  (append '(maplloop)
                        (map (lambda (p l)
                                (list 'cdr l))
                             (cdr ast)
                             (list 'l1 'l2 'l3 'l4 'l5 'l6 'l7 'l8 'l9))
                        (list (list 'cons (append (list (car ast))
                                                  (map (lambda (p l)
                                                          (list 'car l))
                                                       (cdr ast)
                                                       (list 'l1 'l2 'l3 'l4 'l5 'l6 'l7 'l8 'l9)))
                                    'll)))))))

(define impc:ti:not
   (lambda (ast)
      (list 'if ast #f #t)))

(define impc:ti:case
   (lambda (expr body)
      (if (null? body)
          '(list)
          `(if ,(if (eq? 'else (caar body))
                    #t
                    (list 'member expr (cons 'list (caar body))))
               ,@(cdar body)
               ,(impc:ti:case expr (cdr body))))))
                             

(define impc:ti:quote
   (lambda (ast)
      (cond ((null? ast) '(impc_null)) ;(list))
            ((symbol? ast) `(llvm_make_symbol ,(symbol->string ast)))
            ((list? ast) 
             (cons 'list (map (lambda (a) 
                                 (if (or (eq? 'NIL a)
                                         (null? a))
                                     '(list)
                                     a))
                              ast)))
            (else ast))))


(define impc:ti:random
   (lambda (ast)
      (case (length ast)
            ((0) (append (list 'imp_rand) ast))
            ((1) (append (list 'imp_rand1) ast))
            ((2) (append (list 'imp_rand2) ast)))))

(define impc:ti:array
   (lambda (ast)
      (let* ((sym (string->symbol (string-append "v" (number->string (llvm:count++))))))
         (append '(let) (list (list (list sym (list 'make-array (- (length ast) 1)
                                                    (if (integer? (cadr ast)) 0 0.0)))))
                 (make-list-with-proc (- (length ast) 1)
                                      (lambda (i)
                                         (list 'array-set! sym i (list-ref ast (+ i 1)))))
                 (list sym)))))

(define impc:ti:tuple
   (lambda (ast)
      (let* ((sym (string->symbol (string-append "v" (number->string (llvm:count++))))))
         (append '(let) (list (list (list sym (list 'make-tuple (- (length ast) 1)
                                                    (if (integer? (cadr ast)) 0 0.0)))))
                 (make-list-with-proc (- (length ast) 1)
                                      (lambda (i)
                                         (list 'tuple-set! sym i (list-ref ast (+ i 1)))))
                 (list sym)))))


;; no anonymous lambdas !!!
(define impc:ti:lambda
   (lambda (ast)
      (let* ((fname (gensym))
             (rest (cons (impc:ti:first-transform (cadr ast) #t)
                         (list (cons 'begin (impc:ti:first-transform (cddr ast) #t)))))
             (expr (cons 'lambda rest)))
         `(let ((,fname ,expr))
             (begin ,fname)))))


;; replace (* 2 3 4 5) or (+ 2 3 4 5)
;; with (* 2 (* 3 (* 4 5))) etc..
(define impc:ti:binary-arity
   (lambda (ast inbody?)
      (let ((op (car ast))
            (inlst (reverse (cdr ast))))
         (let loop ((rest (cdr inlst))
                    (lst (car inlst)))
            (if (null? rest) lst
                (loop (cdr rest) (cons op (cons (impc:ti:first-transform (car rest) inbody?) (list lst)))))))))
				
				
(define impc:ti:binary-arity
   (lambda (ast inbody?)
      (let ((op (car ast))
            (inlst (cdr ast)))
         (if (< (length inlst) 2)
                (print-error 'Compiler 'Error: 'Bad 'arity 'in 'math 'expr ast))
         (let loop ((rest (cddr inlst))
                    (lst (list op 
                               (impc:ti:first-transform (car inlst) inbody?) 
                               (impc:ti:first-transform (cadr inlst) inbody?))))
            (if (null? rest) lst
                (loop (cdr rest) (list op lst (impc:ti:first-transform (car rest) inbody?))))))))				


(define impc:ti:first-transform
   (lambda (ast inbody?)
      ;(print inbody? 'transforming-ast: ast)
      (if (null? ast) '()
          (cond ((list? ast)
                 (cond ((eq? (car ast) 'and) 
                        (impc:ti:first-transform (impc:ti:and (cdr ast)) inbody?))
                       ((eq? (car ast) 'random)
                        (impc:ti:first-transform (impc:ti:random (cdr ast)) inbody?))
                       ((eq? (car ast) 'quote)
                        (impc:ti:first-transform (impc:ti:quote (cadr ast)) inbody?))
                       ((member (car ast) '(map for-each))
                        (impc:ti:first-transform (impc:ti:map (cdr ast)) inbody?))
                       ((eq? (car ast) 'case) 
                        (impc:ti:first-transform (impc:ti:case (cadr ast) (cddr ast)) inbody?))
                       ((eq? (car ast) 'or) 
                        (impc:ti:first-transform (impc:ti:or (cdr ast)) inbody?))
                       ((eq? (car ast) 'free) 
                        (list 'free (list 'bitcast (impc:ti:first-transform (cadr ast) inbody?)
                                          'i8*)))
                       ((member (car ast) '(array))
                        (impc:ti:first-transform (impc:ti:array ast) inbody?))
                       ((member (car ast) '(tuple))
                        (impc:ti:first-transform (impc:ti:tuple ast) inbody?))     
                       ;((eq? (car ast) 'null?)
                       ; (impc:ti:first-transform `(impc_isnull ,(cadr ast)) inbody?))
                       ((eq? (car ast) 'not) 
                        (impc:ti:first-transform (impc:ti:not (cadr ast)) inbody?))
                       ((eq? (car ast) 'list)
                        (impc:ti:first-transform (impc:ti:binary-arity (cons 'cons (append (cdr ast) '(nilnil))) inbody?) inbody?))
                       ((and (member (car ast) '(* - / +))
                             (<> (length ast) 3))
                        (impc:ti:first-transform (impc:ti:binary-arity ast inbody?) inbody?))
                       ((eq? (car ast) 'lambda)
                        (if inbody?
                            (impc:ti:lambda ast)
                            (cons (impc:ti:first-transform (car ast) inbody?)
                                  (cons (impc:ti:first-transform (cadr ast) #t)
                                        (list (cons 'begin (impc:ti:first-transform (cddr ast) #t)))))))
                       ((eq? (car ast) 'cons) 
                        (impc:ti:first-transform (impc:ti:cons ast) inbody?))                       
                       ((eq? (car ast) 'cond)
                        (impc:ti:first-transform (impc:ti:cond (cdr ast)) inbody?))
                       ((eq? (car ast) 'dotimes)
                        (list 'dotimes 
                              (impc:ti:first-transform (cadr ast) inbody?)
                              (cons 'begin (impc:ti:first-transform (cddr ast) inbody?))))
                       ((member (car ast) '(let let* letrec))
                        (cons (impc:ti:first-transform (car ast) inbody?)
                              (cons (impc:ti:first-transform (cadr ast) #f)
                                    (list (cons 'begin (impc:ti:first-transform (cddr ast) #t))))))
                       ((and (atom? (car ast))
                             (symbol? (car ast))
                             (not (eq? 'dotimes (car ast)))
                             (defined? (car ast))
                             (macro? (eval (car ast))))
                        (macro-expand ast))                                              
                       (else (cons (impc:ti:first-transform (car ast) inbody?)
                                   (impc:ti:first-transform (cdr ast) inbody?)))))
                (else (cond ((eq? ast #f) '(impc_false))
                            ((eq? ast #t) '(impc_true))
                            ((eq? ast 'else) '(impc_true))
                            ((eq? ast '*samplerate*) '(llvm_samplerate))
                            ((eq? ast 'printf) 'llvm_printf)
							((eq? ast 'null) '(impc_null))
							((eq? ast 'aset!) 'array-set!)
							((eq? ast 'aref) 'array-ref)
							((eq? ast 'tset!) 'tuple-set!)
							((eq? ast 'tref) 'tuple-ref)
                            (else ast)))))))


;;
;; TYPE INFERENCE CODE
;;
;; request? can be a type - or a symbol if it's a symbol it must be a free variable available in vars
;;
;;

;; takes types with symbols and expands them
;; using types associated with symbols in vars
;; if a particular var doesn't have a type yet
;; then we try to reverse expand 
;; (i.e. look at other closure options that may include type values
;; and assign those values into vars)
(define impc:ti:symbol-expand
   (lambda (vs vars all-vs)
      (if (atom? vs)
          (if (symbol? vs)
              (if (not (assoc vs vars)) 
                  (print-error 'Compiler 'Error: 'variable 'not 'marked 'as 'free! vs)
                  ;; check to see a type has been defined
                  ;; otherwise return null
                  (let ((t (cdr (assoc vs vars)))) 
                     ;; first check to see if he symbol vs has a value                     
                     (if (null? t) ;; if it doesn't we might need to reverse match!
                         (let* ((positions (map (lambda (x)
                                                   (if (atom? x)
                                                       (print-error 'Compiler 'Error: 'severe 'type 'error: 'have 'you 'specified 'an 'incorrect 'type?)
                                                       (cl:position vs x)))
                                                all-vs))
                                (position (cl:find-if number? positions))
                                (values (if position
                                            (map (lambda (x)
                                                    (list-ref x position))
                                                 all-vs)
                                            '()))
                                (value (cl:find-if impc:ir:type? values)))
                            ;; if we found a value force it into vars
                            (if value (impc:ti:force-var vs vars '() value))
                            ;(if value (print-notification 'backward 'assigning value 'to vs))
                            (if value
                                value
                                t))
                         t))) ;; else if symbol does have a value then return it
              vs)
          (cons (impc:ti:symbol-expand (car vs) vars all-vs)
                (impc:ti:symbol-expand (cdr vs) vars all-vs)))))



;; impc:ti:intersection* is cl:intersection for 
;; an arbirary number of sets (i.e. args)
;; also handles *impc:ir:other* which we want
;; to match against anything.
(define impc:ti:intersection*   
   (lambda args
      (let loop ((a args)
                 (res '()))
         (if (null? a) res
             (loop (cdr a) 
                   (if (null? res)
                       (car a)
                       (if (null? (car a))
                           res
                           (cl:intersection (car a) res))))))))

(define impc:ti:complex-unify
   (lambda (sym types) 
      ;; first a sanity check
      (if (cl:find-if (lambda (x) (not (list? x))) types)
          (apply print-error 'Compiler 'Error: 'bad 'type: (symbol->string sym) 'invalid 'mixed 'type 'definitions: types))
      ;; first check that all complex types
      ;; are the same length
      ;; otherwise we have a problem
      (if (and (> (length types) 1)
               (not (apply = (map length types))))
          (print-error 'Compiler 'Error: 'bad 'complex 'type 'in types)
          (map (lambda (ts)
                  ;(print 'ts: ts)
                  (let ((ttt (if (list? ts)
                                 (apply impc:ti:intersection* ts)
                                 (impc:ti:intersection* ts))))
                     (if (and (list? ttt)
                              (= (length ttt) 1))
                         (car ttt)
                         ttt)))
               (map (lambda (i)
                       (map (lambda (t)
                               (let ((tt (list-ref t i)))
                                  (if (list? tt) 
                                      ;; check to see if tt need further unification
                                      (cond ((null? tt) '())                                             
                                            ((list? (car tt))
                                             (impc:ti:complex-unify sym tt))
                                            (else tt))
                                      ;; need to make atoms into lists 
                                      ;; so we can pass them through cl:intersection
                                      (list tt))))
                            types))
                    (make-list-with-proc (length (car types)) (lambda (i) i)))))))


;; return simple types without change
;; pass complex types through to impc:ti:complex-unify
(define impc:ti:type-unify
   (lambda (sym types)
      ;(print 'types: types)
      (if (not (cl:find-if list? types))
          (if (= (length types) 1)
              (car types)
              types) ;; if not complex just return it
          (impc:ti:complex-unify sym types))))


;;
;; takes un-unified types and returns unified ones (hopefully!)
;; 
(define impc:ti:unify
   (lambda (vars)
      ;(print 'vars: vars)
      (map (lambda (v)              
              ;(print 'v: v)
              (let* ((sym (car v))
                     ;; expand any symbols and do reverse symbol checks
                     (types-expanded (map (lambda (t)                                   
                                             (if (or (symbol? t)
                                                     (list? t))
                                                 (impc:ti:symbol-expand t vars (cdr v))
                                                 t))
                                          (cdr v)))
                     (types-unified (impc:ti:type-unify sym types-expanded)))  
                 ;(print 'un-expanded (cdr v) 'un-unified types-expanded 'unified types-unified)
                 (cons sym types-unified)))
           vars)))

;; checks to see if a type system is completely unified
(define impc:ti:unity?
   (lambda (vars)
      (map (lambda (x)
              (if (impc:ir:type? (cdr x)) #t #f))
           vars)))
              

;; join elements into a list (without including nulls)
(define impc:ti:join
   (lambda args
      (cl:remove-if null? args)))

;; probably should use a state monad for this but ...
;; vars must be a list of lists
;; NOT an assoc list with pairs
;;
;; don't allow update to add to kts values
(define impc:ti:update-var
   (lambda (sym vars kts t)
      ;(print 'update-var:> sym 'in: vars 'with: t 'kts: kts)      
      (if (member sym kts) ;; if in known types don't do anything
          '()
          (if (not (assoc sym vars))
              (print-error 'Compiler 'Error: 'var (symbol->string sym) 'does 'not 'exist)
              (let ((pair (assoc sym vars)))
                 (if (impc:ir:type? t)
                     (set-cdr! pair (cl:remove-duplicates (append (list t) (cdr pair))))                     
                     (set-cdr! pair (cl:remove-duplicates (append t (cdr pair))))))))))



;; force a var to a particular type
;; (i.e. wipe out other choices)
;;
;; do allow force-var to overwrite kts values
(define impc:ti:force-var
   (lambda (sym vars kts t)
      (if (not (assoc sym vars))
          (print-error 'Compiler 'Error: 'var (symbol->string sym) 'does 'not 'exist)
          (let ((pair (assoc sym vars)))
             (if (list? t)
                 (set-cdr! pair t)
                 (set-cdr! pair (list t)))))))
				 
(define impc:ti:force-var
   (lambda (sym vars kts t)
      (if (and (not (assoc sym vars))
               (not (llvm:get-globalvar (symbol->string sym))))
          (print-error 'Compiler 'Error: 'var (symbol->string sym) 'does 'not 'exist)
          (let ((pair (assoc sym vars)))             
             (if pair
                 (if (list? t)
                     (set-cdr! pair t)
                     (set-cdr! pair (list t)))
                 '())))))				 

(define impc:ti:get-var
   (lambda (sym vars)
      (if (not (assoc sym vars))
          (print-error 'Compiler 'Error: 'var (symbol->string sym) 'does 'not 'exist)
          (assoc sym vars))))
		  
(define impc:ti:get-var
   (lambda (sym vars)
      (if (not (assoc sym vars))
          (if (llvm:get-global-variable-type (symbol->string sym))
              (cons sym (- (impc:ir:get-type-from-str (llvm:get-global-variable-type (symbol->string sym)))
                           *impc:ir:pointer*))
              (print-error 'Compiler 'Error: 'var (symbol->string sym) 'does 'not 'exist))
          (assoc sym vars))))
		  

;; clear all vars
(define impc:ti:clear-all-vars
   (lambda (vars)
      (map (lambda (x)
              (set-cdr! x '()))
           vars)))

(define impc:ti:numeric-check
   (lambda (ast vars kts request?)      
      (if *impc:ti:print-sub-checks* (print 'num:> 'ast: ast 'request? request?))
      (if (and request?
               (not (null? request?)))
          (cond ((symbol? request?) 
                 (let* ((t1 (impc:ti:symbol-check request? vars kts #f))
                        (t2 (impc:ti:numeric-check ast vars kts #f))
                        (t3 (cl:intersection t1 t2)))
                    t3))
                ((list? request?)
                 (let* ((t1 (impc:ti:numeric-check ast vars kts #f))
                        (t2 (cl:intersection request? t1)))
                    t2))
                ((number? request?)
                 (let* ((t1 (impc:ti:numeric-check ast vars kts #f))
                        (t2 (cl:intersection (list request?) t1)))
                    t2))
                (else (print-error 'Compiler 'Error: 'shouldn't 'reach 'here 'in 'numeric 'check 'request? request?)))
          (if (integer? ast)  ;; preference goes to start of list
              (if (< ast 256)
                  (list *impc:ir:si64* *impc:ir:si32* *impc:ir:ui8* *impc:ir:double* *impc:ir:float*)
                  (list *impc:ir:si64* *impc:ir:si32* *impc:ir:double* *impc:ir:float*))
              (list *impc:ir:double* *impc:ir:float*)))))


(define impc:ti:symbol-check
   (lambda (ast vars kts request?)   
      ;(print 'ast: ast 'r: request? 'vars: vars 'kts: kts)      
      (if *impc:ti:print-sub-checks* (print 'sym:> 'ast: ast 'request? request?))
      ;; if a request is made - assume it's forced
      ;; find the intersection between the request
      ;; and the current values and force that intersection
      (if (and (not (assoc ast vars))
               (not (llvm:get-globalvar (symbol->string ast))))
          (print-error 'Compiler 'Error: 'unbound 'symbol: ast))
      (let ((type (if (assoc ast vars)
                      (cdr (assoc ast vars))
                      (list (impc:ir:pointer-- (impc:ir:get-type-from-str (llvm:get-global-variable-type (symbol->string ast))))))))
         (if (and request?
                  (not (null? request?)))             
             (let ((intersection (cl:intersection (if (null? type) ;; if type is null then force request
                                                      (if (atom? request?) (list request?) request?)
                                                      type)
                                                  ;; if request is not a set make it one
                                                  (if (atom? request?) (list request?) request?))))
                (if (not (null? intersection))
                    (begin (impc:ti:force-var ast vars kts intersection)
                           intersection)
                    type))
             type))))


(define impc:ti:math-check
   (lambda (ast vars kts request?)
      (let* ((a (impc:ti:type-check (cadr ast) vars kts request?))
             (b (impc:ti:type-check (caddr ast) vars kts request?))
             (t (cl:intersection (if (atom? a) (list a) a) 
                                 (if (atom? b) (list b) b))))
         ;(print 'math: a b)
         (if *impc:ti:print-sub-checks* (print 'math:> 'ast: ast 'a: a 'b: b 't: t 'request? request?))
         (if (not (null? t)) 
             t
             (cond ((not (cl:find-if symbol? (cdr ast))) t) ;; return t
                   ((and (symbol? (cadr ast)) 
                         (symbol? (caddr ast))                         
                         (not (null? (cdr (impc:ti:get-var (cadr ast) vars))))
                         (not (null? (cdr (impc:ti:get-var (caddr ast) vars)))))
                    ;; if both are symbols and their types cannot unify on anything
                    ;; then we have a problem!  So force both types to NULL
                    (impc:ti:force-var (cadr ast) vars kts '())
                    (impc:ti:force-var (caddr ast) vars kts '())
                    t) ;; and return t (which should be NULL)
                   ((and (symbol? (cadr ast)) (not (null? b)))
                    (impc:ti:update-var (cadr ast) vars kts b) b) ;; return b
                   ((and (symbol? (caddr ast)) (not (null? a)))
                    (impc:ti:update-var (caddr ast) vars kts a) a) ;; return a
                   (else t)))))) ; (print-error 'Compiler 'Error: 'shouldn't 'reach 'here 'in 'impc:ti:math-check)))))))
				   

(define impc:ti:math-check
   (lambda (ast vars kts request?)
      (let* ((a (impc:ti:type-check (cadr ast) vars kts request?))
             (b (impc:ti:type-check (caddr ast) vars kts request?))
             (t (cl:intersection (if (atom? a) (list a) a) 
                                 (if (atom? b) (list b) b))))
         ;(print 'math: a b)
         (if *impc:ti:print-sub-checks* (print 'math:> 'ast: ast 'a: a 'b: b 't: t 'request? request?))
         (if (not (null? t))
             (begin (if (symbol? (cadr ast)) (impc:ti:force-var (cadr ast) vars kts t))
                    (if (symbol? (caddr ast)) (impc:ti:force-var (caddr ast) vars kts t))
                    t)
             (cond ((not (cl:find-if symbol? (cdr ast))) t) ;; return t
                   ((and (symbol? (cadr ast)) 
                         (symbol? (caddr ast))                         
                         (not (null? (cdr (impc:ti:get-var (cadr ast) vars))))
                         (not (null? (cdr (impc:ti:get-var (caddr ast) vars)))))
                    ;; if both are symbols and their types cannot unify on anything
                    ;; then we have a problem!  So force both types to NULL
                    (impc:ti:force-var (cadr ast) vars kts '())
                    (impc:ti:force-var (caddr ast) vars kts '())
                    t) ;; and return t (which should be NULL)                   
                   ((and (symbol? (cadr ast)) (not (null? b)))
                    (impc:ti:update-var (cadr ast) vars kts b) b) ;; return b
                   ((and (symbol? (caddr ast)) (not (null? a)))
                    (impc:ti:update-var (caddr ast) vars kts a) a) ;; return a
                   (else t))))))
				   


(define impc:ti:compare-check
   (lambda (ast vars kts request?)
      (let* ((a (impc:ti:type-check (cadr ast) vars kts request?))
             (b (impc:ti:type-check (caddr ast) vars kts request?))
             (t (cl:intersection (if (atom? a) (list a) a) 
                                 (if (atom? b) (list b) b))))
         (if *impc:ti:print-sub-checks* (print 'compare:> 'ast: ast 'a: a 'b: b 't: t 'request? request?))
         (if (not (null? t)) 
             (list *impc:ir:i1*)
             (cond ((not (cl:find-if symbol? (cdr ast))) (list *impc:ir:i1*)) ;; return t
                   ((and (symbol? (cadr ast)) 
                         (symbol? (caddr ast))                         
                         (not (null? (cdr (impc:ti:get-var (cadr ast) vars))))
                         (not (null? (cdr (impc:ti:get-var (caddr ast) vars)))))
                    ;; if both are symbols and their types cannot unify on anything
                    ;; then we have a problem!  So force both types to NULL
                    (impc:ti:force-var (cadr ast) vars kts '())
                    (impc:ti:force-var (caddr ast) vars kts '())
                    (list *impc:ir:i1*)) ;; and return t (which should be NULL)
                   ((and (symbol? (cadr ast)) (not (null? b)))
                    (impc:ti:update-var (cadr ast) vars kts b)
                    (list *impc:ir:i1*)) ;; return b
                   ((and (symbol? (caddr ast)) (not (null? a)))
                    (impc:ti:update-var (caddr ast) vars kts a) 
                    (list *impc:ir:i1*)) ;; return a
                   (else (list *impc:ir:i1*)))))))


(define impc:ti:nativef-check
   (lambda (ast vars kts request?)   
      (let ((ftype (map impc:ir:get-type-from-str
                        (llvm:get-function-args-withoutzone (symbol->string (car ast))))))
         (if *impc:ti:print-sub-checks* (print 'ftype:> 'ast: ast 'type: ftype))
         (if (<> (length ftype) 
                 (length ast))
             (print-error 'Compiler 'Error: 'bad 'arity 'in 'call ast))
         ;; we don't care what we get back because we already know the return type
         (for-each (lambda (a t)
                      ;; if a is a symbol then add type t to a
                      ;; we also know that for native functions there 
                      ;; is no choice about the type so we should
                      ;; force it to the type not update it
                      (if (symbol? a) (impc:ti:force-var a vars kts t))
                      (impc:ti:type-check a vars kts t))
                   (cdr ast)
                   (cdr ftype))
         (list (car ftype)))))


(define impc:ti:let-check
   (lambda (ast vars kts request?)
      ;; for the symbols we want to set each return type
      (for-each (lambda (e)
                   (let ((a (impc:ti:type-check (cadr e) vars kts request?)))
                      (impc:ti:update-var (car e) vars kts a)))
                (cadr ast))
      ;; then return the return type for the whole let
      ;; which should have a begin body! so caddr should work
      (impc:ti:type-check (caddr ast) vars kts request?)))
	  
	  
(define impc:ti:null-check
   (lambda (ast vars kts request?)
      (let ((a (impc:ti:type-check (cadr ast) vars kts request?)))
         (if (impc:ir:pointer? a)
             (list *impc:ir:i1*)
             (print-error 'Compiler 'Error: 'null? 'must 'take 'a 'pointer 'type (sexpr->string ast))))))
 

(define impc:ti:ret-check
   (lambda (ast vars kts request?)
      ;(print 'ast: ast 'request? request?)
      ;; grab function name from ret->
      (let* ((sym (if (equal? (caddr ast) (cadr ast))
                      '()
                      (impc:ti:get-var (cadr ast) vars)))
             (t (if (null? sym) #f 
                    (if (null? (cdr sym)) #f
                        (car (cdr sym)))))
             ;; if closure has a return type set
             ;; pass it as a request
             (a (impc:ti:type-check (caddr ast) vars kts 
                                    (if (and t
                                             (impc:ir:type? t)
                                             (impc:ir:closure? t))
                                        (cadr t)
                                        #f)))) ;; or else pass #f
         ;; if t is not a closure type we have a problem!
         (if (and t
                  (or (not (impc:ir:type? t))
                      (not (impc:ir:closure? t))))
             (print-error 'Compiler 'Error: 'type 'error 'calculating 'return 'type: ast 
                          'have 'you 'specified 'an 'incorrect 'closure 'type?))
         (if *impc:ti:print-sub-checks* (print 'ret:> 'ast: ast 'a: a 'sym: sym))
         (if t
             ;; if the return value is a symbol then it should be
             ;; give then return type of 't             
             (if (symbol? (caddr ast))
                 (impc:ti:update-var (caddr ast) vars kts (list (cadr t)))
                 ;; else the return value is not a symbol
                 ;; and we should use it's value to update the lambda's type
                 (impc:ti:update-var (car sym) vars kts
                                     (list (impc:ir:pointer++ (list* *impc:ir:closure* a (cddr t)))))))
         a)))


(define impc:ti:begin-check
   (lambda (ast vars kts request?)
      (let ((a (car (reverse (map (lambda (e)
                                     (impc:ti:type-check e vars kts request?))
                                  (cdr ast))))))
         (if *impc:ti:print-sub-checks* (print 'begin:> 'ast: ast 'a: a))
         a)))
		 

(define impc:ti:bitcast-check
   (lambda (ast vars kts request?)
      ;; for the symbols we want to set each return type
      ;(impc:ti:update-var (cadr ast) vars kts (impc:ir:convert-from-pretty-types (caddr ast)))
      (list (impc:ir:convert-from-pretty-types (caddr ast)))))
		 

(define impc:ti:if-check
   (lambda (ast vars kts request?)
      (let* ((a (impc:ti:type-check (cadr ast) vars kts request?))
             (b (impc:ti:type-check (caddr ast) vars kts request?))
             (c (if (null? (cdddr ast))
					'()
			        (impc:ti:type-check (cadddr ast) vars kts request?)))
             (t (cl:intersection (if (atom? b) (list b) b) (if (atom? c) (list c) c))))
         (if *impc:ti:print-sub-checks* (print 'if:> 'a: a 'b: b 'c: c 't: t))
         (if (null? b)
             (set! t c))
         (if (null? c)
             (set! t b))
         ;; return intersection of b and c
         (if (null? t) 
             (print-error 'Compiler 'Error: 'cannot 'unify 'then 'and 'else 'clauses 'in ast)
             t))))

;; make-array should be of the form
;; (make-array num type)
;; where num is fixed point and type is a valid type
(define impc:ti:make-array-check
   (lambda (ast vars kts request?)      
      ;; make-array should have a type
      (let ((a (impc:ir:convert-from-pretty-types (caddr ast)))
            ;; this should be fixed point
            (b (impc:ti:type-check (cadr ast) vars kts (list *impc:ir:si64* *impc:ir:si32*))))
         ;; returns a pointer of type 'a'
		 (if (null? a) a
             (impc:ir:pointer++ a)))))


(define impc:ti:array-set-check
   (lambda (ast vars kts request?)      
      (let* ((a (impc:ti:type-check (cadr ast) vars kts request?))
             ;; b should be fixed point types
             (b (impc:ti:type-check (caddr ast) vars kts (list *impc:ir:si64* *impc:ir:si32*)))
             ;; c should be of type *a
             (c (impc:ti:type-check (cadddr ast) vars kts (if (null? a) #f
                                                              (list (impc:ir:pointer-- (car a)))))))
         ;; array set check will return the type of the value set
         c)))


(define impc:ti:array-ref-check
   (lambda (ast vars kts request?)      
      (let ((a (impc:ti:type-check (cadr ast) vars kts request?))
            ;; b should be fixed point
            (b (impc:ti:type-check (caddr ast) vars kts (list *impc:ir:si64* *impc:ir:si32*))))
         (if (null? a) 
             a
             (impc:ir:pointer-- (car a))))))


;; make-tuple should be of the form
;; (make-array type type type ...)
;; where types are valid types
;; (make-array i64 i8* i32)
(define impc:ti:make-tuple-check
   (lambda (ast vars kts request?)      
      ;; make-tuple should return the tuple type a
      (let ((a (cons *impc:ir:tuple* (impc:ir:convert-from-pretty-types (cdr ast)))))
         ;; returns a pointer of tuple type 'a'
		 (if (null? a) a
             (impc:ir:pointer++ a)))))


(define impc:ti:tuple-set-check
   (lambda (ast vars kts request?)            
      (if (< (length ast) 4)
          (print-error 'Compiler 'Error: 'missing 'operands 'in (sexpr->string ast)))
      ;; (caddr ast) must be an integer 
      (if (not (integer? (caddr ast))) 
          (print-error 'Compiler 'Error: 'tuple-set! 'must 'use 'a 'static 'integer 'index! ast))
      (let* (;; a should be a tuple of some kind
             (a (impc:ti:type-check (cadr ast) vars kts request?))
             ;; b should be 32bit fixed point type -- llvm structs only support 32bit indexes
             (b (impc:ti:type-check (caddr ast) vars kts (list *impc:ir:si32*)))
             ;; c should be an element of a tuple
             (c (impc:ti:type-check (cadddr ast) vars kts
                                    (if (and (not (null? a))
                                             (list? a))
                                        (if (impc:ir:tuple? (car a))
                                            (list-ref (car a) (+ 1 (caddr ast)))
                                            #f)
                                        #f)))) 
         ;; tuple set check will return the type of the value set
         c)))


(define impc:ti:tuple-ref-check
   (lambda (ast vars kts request?)
      ;; (caddr ast) must be an integer 
      (if (not (integer? (caddr ast))) 
          (print-error 'Compiler 'Error: 'tuple-ref 'must 'use 'a 'static 'integer 'index! ast))            
      (let (; a should be a tuple of some kind!
            (a (impc:ti:type-check (cadr ast) vars kts request?))
            ;; b should be fixed point -- llvm structs only support 32bit indexes
            (b (impc:ti:type-check (caddr ast) vars kts (list *impc:ir:si32*))))
         ;(print 'tupref-check 'a: a 'ast: ast (list-ref (car a) (+ 1 (caddr ast))))
         (if (and (not (null? a))
                  (list? a)
                  (impc:ir:tuple? (car a)))
             (list-ref (car a) (+ 1 (caddr ast)))
             '()))))


(define impc:ti:set-check
   (lambda (ast vars kts request?)      
      (let* ((sym (impc:ti:get-var (cadr ast) vars))
             (a (impc:ti:type-check (caddr ast) vars kts (cdr sym))))
         (if *impc:ti:print-sub-checks* (print 'set!:> 'ast: ast 'a: a))
         ;; add return type to sym
         (impc:ti:update-var (car sym) vars kts a)
         a)))


(define impc:ti:lambda-check
   (lambda (ast vars kts request?)
      ;; run body for type coverage     
      ;; grab the last result as return type
      (let ((res (impc:ti:type-check (caddr ast) vars kts request?)))
         ;; if we have a choice between numeric options we force one!
         (if (equal? (cl:sort res <) 
                     (cl:sort (list *impc:ir:double* *impc:ir:float*) <)) 
             (set! res (list *impc:ir:double*))) ;; force doubles
         (if (equal? (cl:sort res <)
                     (cl:sort (list *impc:ir:si64* *impc:ir:si32* *impc:ir:ui8* *impc:ir:float* *impc:ir:double*) <))
             (set! res (list *impc:ir:si64*))) ;; force i64     
         ;; return lambda type which is made up of
         ;; argument symbols plus return type from last body expression         
         (let ((ret (list (impc:ir:pointer++ (list* *impc:ir:closure* res (cadr ast))))))
            ;(print 'return 'ret: ret 'from 'ast ast) 
            ret))))
			
			
;; whenever a closure is called we calculate a type for it
;; at the end these possibly multiple views should unify!
(define impc:ti:closure-call-check
   (lambda (ast vars kts request?)
      ;(print 'cchint 'ast: ast 'vars: vars 'request: request?)      
      ;; otherwise we need to try to find a type definition for the closure      
      (let* ((ctype (if (assoc (car ast) vars)
                        (cdr (assoc (car ast) vars))
                        (print-error 'Compiler 'Error: 'no 'closure 'named: (car ast))))
             ;; get argument expression types
             (res (map (lambda (e t)
                          (let ((res (impc:ti:type-check e vars kts
                                                         (if (symbol? t) 
                                                             (impc:ti:symbol-check t vars kts #f)
                                                             t))))
                             ;; if t is a symbol then add res to t
                             (if (symbol? t) (impc:ti:update-var t vars kts res))
                             res))
                       (cdr ast)
                       (if (or (null? ctype) 
                               (not (impc:ir:closure? (car ctype))))
                           (make-list (length (cdr ast)) #f)
                           ;; if we are using an existing definition then check arity
                           (if (<> (length (cddr (car ctype)))
                                   (length (cdr ast)))
                               (print-error 'Compiler 'Error: 'bad 'arity 'for ast)
                               (cddr (car ctype))))))
             ;; if there was a request that will be the return type
             ;; otherwise if we already have a type defined we can use it's return type
             ;; otherwise we cannot know it
             (ret (if (and request?
                           (not (null? request?)))
                      request?
                      (if (or (null? ctype) 
                              (not (impc:ir:closure? (car ctype))))
                          '()
                          (cadr (car ctype))))))         
         (if *impc:ti:print-sub-checks* (print 'closure:> 'ast: ast 'res: res 'ret: ret)) 
         ; set the closure type for the symbol
         (impc:ti:update-var (car ast) vars kts
                             (list (impc:ir:pointer++ (list* *impc:ir:closure* ret res))))
         ; and return the new closure's return type
         (if (list? ret) ret
             (list ret)))))
			 

(define impc:ti:dotimes-check
   (lambda (ast vars kts request?)
      (let ((a (impc:ti:type-check (cadr (cadr ast)) vars kts 
                                   (list *impc:ir:double* *impc:ir:float* *impc:ir:si64* *impc:ir:si32* *impc:ir:ui8*))))
         ;; if numeric? and multiple choice - then force a type!
         (if (number? (cadr (cadr ast)))
             (cond ((equal? (cl:sort a <)
                            (cl:sort (list *impc:ir:double* *impc:ir:float* *impc:ir:si64* *impc:ir:si32* *impc:ir:ui8*) <))
                    (set! a (list *impc:ir:si64*)))
                   ((equal? (cl:sort a <) 
                            (cl:sort (list *impc:ir:double* *impc:ir:float*) <))
                    (set! b (list *impc:ir:double*)))
                   (else 'leave-a-alone)))                                   
         ;; (car (cadr ast)) should be a symbol that we want to update with a
         (if (not (symbol? (car (cadr ast)))) (print-error 'Compiler 'Error: 'bad 'form 'for 'dotimes. 'Needs 'a 'symbol ast))
         (impc:ti:update-var (car (cadr ast)) vars kts a) 
         ;; stretch over body code but don't worry about return types
         (impc:ti:type-check (caddr ast) vars kts #f)
         ;; dotimes returns void
         (list *impc:ir:void*))))


(define impc:ti:printf-check
   (lambda (ast vars kts request?)
      (let ((a (impc:ti:type-check (cadr ast) vars kts (list (+ *impc:ir:si8* *impc:ir:pointer*)))))
         ;; run through everything else for completeness but don't care about the results
         (map (lambda (x) (impc:ti:type-check x vars kts #f)) (cddr ast))
         ;; printf returns i32
         (list *impc:ir:si32*))))

(define impc:ti:string-check
   (lambda (ast vars kts request?)
      (if (string? ast)
          (list (+ *impc:ir:si8* *impc:ir:pointer*))
          '())))


(define impc:ti:carcdr-check
   (lambda (ast vars kts request?)
      ;; check that we are getter a pair as an argument
      (impc:ti:type-check (cadr ast) vars kts (list (impc:ir:pointer++ *impc:ir:pair*)))
      ;; don't do anything about return type yet
      '()))

(define impc:ti:coerce-check
   (lambda (ast vars kts request?)
      (impc:ti:type-check (cadr ast) vars kts #f)
      (list (caddr ast))))

(define impc:ti:closure-in-first-position
   (lambda (ast vars kts request?)
      ;; first check return type of car ast (which will be a closure)
      ;; then check against it's arg types
      (let ((type (impc:ti:type-check (car ast) vars kts request?)))
         ;(print 'closure-in-first-pos: ast 'type: type)
         (if (<> (+ *impc:ir:closure* *impc:ir:pointer*) (car type))
             (begin (print-error 'Invalid 'Expression ast) (error ""))
             (begin (map (lambda (a b) 
                            (impc:ti:type-check b vars kts a))
                         (cddr type)
                         (cdr ast))
                    (cadr type))))))	  

;; vars is statefull and will be modified in place
(define impc:ti:type-check
   (lambda (ast vars kts request?)
      (if *impc:ti:print-main-check* (print 'type-check: ast 'kts: kts 'request? request?))
      (if *impc:ti:print-main-check* (print 'vars------: vars))
      (cond ((null? ast) '())
            ((and (atom? ast) (number? ast)) (impc:ti:numeric-check ast vars kts request?))
            ((and (atom? ast) (symbol? ast)) (impc:ti:symbol-check ast vars kts request?)) ;#f)) ;request?))
            ((and (atom? ast) (string? ast)) (impc:ti:string-check ast vars kts request?))
            ((atom? ast) (print-error 'Compiler 'Error: 'internal 'error 'unhandled 'atom: ast))
            ((and (list? ast) (member (car ast) '(let let* letrec))) (impc:ti:let-check ast vars kts request?))
            ((and (list? ast) (member (car ast) '(lambda))) (impc:ti:lambda-check ast vars kts request?))
            ((and (list? ast) (member (car ast) '(* / + - modulo))) (impc:ti:math-check ast vars kts request?))
            ((and (list? ast) (member (car ast) '(< > = <>))) (impc:ti:compare-check ast vars kts request?))
            ((and (list? ast) (member (car ast) '(dotimes))) (impc:ti:dotimes-check ast vars kts request?))            
            ((and (list? ast) (member (car ast) '(llvm_printf))) (impc:ti:printf-check ast vars kts request?))
            ((and (list? ast) (member (car ast) '(make-array))) (impc:ti:make-array-check ast vars kts request?))            
            ((and (list? ast) (member (car ast) '(array-set!))) (impc:ti:array-set-check ast vars kts request?))
            ((and (list? ast) (member (car ast) '(array-ref))) (impc:ti:array-ref-check ast vars kts request?))            
            ((and (list? ast) (member (car ast) '(make-tuple))) (impc:ti:make-tuple-check ast vars kts request?))            
            ((and (list? ast) (member (car ast) '(tuple-set!))) (impc:ti:tuple-set-check ast vars kts request?))
            ((and (list? ast) (member (car ast) '(tuple-ref))) (impc:ti:tuple-ref-check ast vars kts request?))                        
            ((and (list? ast) (member (car ast) '(null?))) (impc:ti:null-check ast vars kts request?))                        			
            ((and (list? ast) (member (car ast) '(bitcast))) (impc:ti:bitcast-check ast vars kts request?))
            ((and (list? ast) 
                  (symbol? (car ast))
                  (llvm:get-function (symbol->string (car ast)))) (impc:ti:nativef-check ast vars kts request?))
            ((and (list? ast) (member (car ast) '(begin))) (impc:ti:begin-check ast vars kts request?))
            ((and (list? ast) (member (car ast) '(if ifret))) (impc:ti:if-check ast vars kts request?))
            ((and (list? ast) (member (car ast) '(set!))) (impc:ti:set-check ast vars kts request?))
            ((and (list? ast) (member (car ast) '(ret->))) (impc:ti:ret-check ast vars kts request?))
            ((and (list? ast) (assoc (car ast) vars)) (impc:ti:closure-call-check ast vars kts request?))    
            ((and (list? ast) (list? (car ast))) (impc:ti:closure-in-first-position ast vars kts request?))
            (else (impc:ti:join (impc:ti:type-check (car ast) vars kts request?)
                                (impc:ti:type-check (cdr ast) vars kts request?))))))


(define impc:ti:find-unresolved-simple-types
   (lambda (union)
      (let ((unresolved (cl:remove #f (map (lambda (x) ;; return the first bad variable that is not a closure
                                              (if (null? (cdr x)) #f
                                                  (if (and (list? (cdr x)) ;; check there are multiple choices
                                                           (not (member (modulo (cadr x) *impc:ir:pointer*) 
                                                                        (list *impc:ir:tuple* *impc:ir:closure*))) ;; make sure it's a base type (not closure or tuple)
                                                           (cl:every impc:ir:type? (cdr x))) ;; check that it's choices are valid (not null)
                                                      x #f)))
                                           union))))
         (if (null? unresolved) #f
             unresolved))))


;; run the type checker
;; if we fail to unify completely the first time
;; try some possible substitutions!
(define impc:ti:run-type-check
   (lambda (vars forced-types ast . cnt)
      ;(print '------------------------------------)
      ;(print 'forced-types forced-types)
      ;(print 'vars: vars 'ast: ast)
      ;(if (null? cnt) (sys:clear-log-view))
      (let* ((fvars (map (lambda (t) ;; add any forced-type values to vars
                            (if (assoc (car t) forced-types)
                                (let ((tt (cdr (assoc (car t) forced-types))))                                   
                                   (cons (car t) (list tt)))
                                t))
                         vars))
             (kts (map (lambda (x) (car x)) forced-types)) ;; just need symbols from forced-types
             (ret (impc:ti:type-check ast fvars kts #f))  
             (u (impc:ti:unify fvars))
             (t (impc:ti:unity? u))
             (tt (cl:every (lambda (x) x) t))
             (a (if tt #t
                    (impc:ti:find-unresolved-simple-types u))))
         (if *impc:ti:print-unifications* (print 'tirun:> a '-> u))
         ;; if we have unified types then return them otherwise run through options!
         (if tt 
             u
             (if (or (not (null? cnt)) ;; else if we're not on the first run die
                     (not a))
                 (if a a u)
                 ;; if we are on the first run then attempt substitutions
                 ;; we grab the first unresolved simple type and start
                 ;; testing each of it's options in turn
                 ;; also attempting to unify that choice with all other
                 ;; unresolved simple types before each run
                 (let ((res (map (lambda (x)
                                    ;; first clear vars
                                    (impc:ti:clear-all-vars fvars)
                                    (impc:ti:run-type-check fvars 
                                                            ;; as well as all simple types which have resolved fully
                                                            (append (cl:remove-if-not (lambda (z) (and (not (list? z))
                                                                                                       (pair? z))) u)
                                                                    ;; and any simple types that unify on x
                                                                    (cl:remove 'failed 
                                                                               (map (lambda (k)
                                                                                       (if (null? (cl:intersection (list x) (cdr k)))
                                                                                           'failed
                                                                                           (cons (car k) x)))
                                                                                    (impc:ti:find-unresolved-simple-types u)))
                                                                    forced-types)
                                                            ast 1))
                                 (cdr (car a)))))
                    (let ((r (cl:find-if (lambda (x) 
                                            (cl:every (lambda (x) x) (impc:ti:unity? x)))
                                         res)))
                       (if (not r) 
                           (apply print-error 'Compiler 'Error: 'could 'not 'resolve 'types 
                                  (map (lambda (x) (symbol->string (car x))) (car res)))
                           (car res))
                       r)))))))

            
;;
;; 
;; Other utility code
;;
;;

;; add types to source
;; also add clrun for closure application
(define impc:ti:add-types-to-source
   (let ((cnt 0)) ;names start from 1000
      (lambda (symname ast types . prev)
         ;(print 'symname: symname 'ast: ast 'prev: prev)
         (if (atom? ast) ast
             (cond ((equal? (car ast) 'make-closure)
                    (set! cnt (+ cnt 1))
                    (list (car ast)
                          ;; global name
                          (string-append (symbol->string symname) "__" (number->string cnt))
                          (if (null? prev) ;; this adds return type
                              *impc:ir:other*
                              (caddr (assoc (car prev) types))) 
                          (map (lambda (v) ;; environment types
                                  (assoc v types))
                               (cadr ast))
                          (map (lambda (v) ;; argument types
                                  (assoc v types))
                               (caddr ast))
                          (impc:ti:add-types-to-source symname (cadddr ast) types)))
                   ((equal? (car ast) 'clrun->)
                    (list* (car ast)
                           (cadr ast)
                           (map (lambda (arg type)
                                   ;(print 'clrunargs-> arg type)
                                   (let ((a (impc:ti:add-types-to-source symname arg types ast)))
                                      (if (null? type) 
                                          (print-error 'Compiler 'Error: 'cannot 'infer 'closure 'type 'for 
                                                       (symbol->string (cadr ast)))
                                          a)))
                                (cddr ast)
                                (cdddr (assoc (cadr ast) types)))))
                   ((member (car ast) '(make-env make-env-zone))
                    (list (car ast)
                          (map (lambda (p)
                                  (list (assoc (car p) types)
                                        (impc:ti:add-types-to-source symname (cadr p) types (car p))))
                               (cadr ast))
                          (impc:ti:add-types-to-source symname (caddr ast) types)))
                   ((and (assoc (car ast) types)
                         ;(not (null? (cdr ast)))
                         (impc:ir:closure? (cdr (assoc (car ast) types))))
                    (impc:ti:add-types-to-source symname (cons 'clrun-> ast) types))                   
                   ((list? ast)
                    (map (lambda (x)
                            (impc:ti:add-types-to-source symname x types ast))
                         ast))
                   (else (cons (apply impc:ti:add-types-to-source symname (car ast) types)
                               (apply impc:ti:add-types-to-source symname (cdr ast) types))))))))



;; add types to source
;; also add clrun for closure application
(define impc:ti:add-types-to-source
   (lambda (symname ast types envvars . prev)
      ;(print 'symname: symname 'envvars: envvars 'ast: ast 'prev: prev)
      (if (atom? ast) ast
          (cond ((equal? (car ast) 'make-closure)
                 (list (car ast)
                       ;; global name
                       (string-append (symbol->string symname) "__" (number->string (llvm:count++)))
                       (if (null? prev) ;; this adds return type
                           *impc:ir:other*
                           (caddr (assoc (car prev) types))) 
                       (map (lambda (v) ;; environment types
                               (if (member v envvars)
                                   (let ((p (assoc v types)))
                                      ;(print 'p: p)
                                      (cons (string->symbol (string-append (symbol->string (car p)) "__sub"))
                                            (cdr p)))
                                   (assoc v types)))
                            (cadr ast))
                       (map (lambda (v) ;; argument types
                               (assoc v types))
                            (caddr ast))
                       (impc:ti:add-types-to-source symname (cadddr ast) types (append envvars (cadr ast)))))
                ((equal? (car ast) 'clrun->)
                 (list* (car ast)
                        (cadr ast)
                        (map (lambda (arg type)
                                ;(print 'clrunargs-> arg type)
                                (let ((a (impc:ti:add-types-to-source symname arg types envvars ast)))
                                   (if (null? type) 
                                       (print-error 'Compiler 'Error: 'cannot 'infer 'closure 'type 'for 
                                                    (symbol->string (cadr ast)))
                                       a)))
                             (cddr ast)
                             (cdddr (assoc (cadr ast) types)))))
                ((member (car ast) '(make-env make-env-zone))
                 (list (car ast)
                       (map (lambda (p)
                               (list (assoc (car p) types)
                                     (impc:ti:add-types-to-source symname (cadr p) types envvars (car p))))
                            (cadr ast))
                       (impc:ti:add-types-to-source symname (caddr ast) types envvars)))
                ((and (assoc (car ast) types)
                      ;(not (null? (cdr ast)))
                      (impc:ir:closure? (cdr (assoc (car ast) types))))
                 (impc:ti:add-types-to-source symname (cons 'clrun-> ast) types envvars))                   
                ((list? ast)
                 (map (lambda (x)
                         (impc:ti:add-types-to-source symname x types envvars ast))
                      ast))
                (else (cons (apply impc:ti:add-types-to-source symname (car ast) types envvars)
                            (apply impc:ti:add-types-to-source symname (cdr ast) types envvars)))))))


;; this is uggglly and needs to be redone!!!!!!!
;; adds ret tags
(define impc:ti:mark-returns
   (lambda (ast name in-body? last-pair? blocked?)
      (cond ((atom? ast) 
             (if (and in-body? last-pair?) 
                 (if blocked? ast (list 'ret-> name ast)) 
                 ast))
            ((pair? ast)
             (cond ((equal? (car ast) 'if)
                    ;; if statement need special syntax adjustments for returns
                    (append (if blocked? (list 'if) (list 'ifret)) (list (cadr ast))
                            (list (impc:ti:mark-returns (caddr ast) name in-body? last-pair? blocked?))
                            (if (not (null? (cdddr ast)))
                                (list (impc:ti:mark-returns (cadddr ast) name in-body? last-pair? blocked?)))))
                   ((member (car ast) '(let* let letrec))
                    (append (list (car ast))
                            (list (map (lambda (a)
                                          ;; let assigns always block (lambda can override but nothing else)
                                          (list (car a) (impc:ti:mark-returns (cadr a) (car a) #f #f #t)))
                                       (cadr ast)))
                            (impc:ti:mark-returns (cddr ast) name #t #f blocked?)))
                   ((member (car ast) '(lambda))
                    (append '(lambda) (list (cadr ast))
                            ;; lambda always unblocks because lambdas always need a return
                            (impc:ti:mark-returns (cddr ast) name #t #f #f)))
                   ;((equal? (car ast) 'dotimes)
                   ; (append '(dotimes) (list (cadr ast)) (impc:ti:mark-returns (cddr ast) name #t #f blocked?)))                   
                   ((equal? (car ast) 'begin) 
                    (let* ((rev (reverse (cdr ast)))
                           (last (car rev))
                           (rest (reverse (cdr rev)))
                           (newast (append '(begin) 
                                           (append (map (lambda (a)
                                                           ;; block everything except ...                                     
                                                           (impc:ti:mark-returns a name in-body? #f #t))
                                                       rest)
                                                   ;; the last one which we let through
                                                   ;; ONLY if it hasn't been blocked higher up!
                                                   (list (impc:ti:mark-returns last name in-body? 
                                                                               (if blocked? #f #t) 
                                                                               blocked?))))))
                       newast))
                   ((equal? (car ast) 'begin) 
                    (append '(begin) (impc:ti:mark-returns (cdr ast) name in-body? #f blocked?)))      
                   ((and in-body? last-pair? (not blocked?)) ;; if everything is good add a return!
                    (list 'ret-> name ast))                                 
                   (else (cons (impc:ti:mark-returns (car ast) name in-body? #f blocked?)
                               (impc:ti:mark-returns (cdr ast) name in-body? #f blocked?))))))))


;; this is a dodgy flatten :(
(define impc:ti:flatten-1
   (lambda (lst)
      (cond ((null? lst) '())
            ((list? (car lst))
             (append (car lst) (impc:ti:flatten-1 (cdr lst))))
            (else (list lst)))))


;; find all free vars
;; currently we don't allow shadow vars
(define impc:ti:find-all-vars
   (lambda (ast syms)
      ;(print 'syms syms)
      (cl:remove-duplicates (cond ((pair? ast)
                                   (cond ((equal? (car ast) 'make-closure)
                                          (if (not (null? (cl:intersection (caddr ast) syms)))
                                              (print-error 'Compiler 'Error: 'Sorry 'single 'definition 'variables 'only! 'caught 'trying 'to 'redefine (symbol->string (car (cl:intersection (caddr ast) syms))) 'as 'a 'shadow 'variable))
                                          (impc:ti:find-all-vars (cadddr ast) (append (cadr ast) (caddr ast) syms)))
                                         ((equal? (car ast) 'dotimes)                                          
                                          (impc:ti:find-all-vars (cddr ast) (cons (caadr ast) syms)))
                                         ((member (car ast) '(make-env make-env-zone))
                                          (impc:ti:find-all-vars (caddr ast) 
                                                            (append (impc:ti:flatten-1 (map (lambda (p)
                                                                                       (if (member (car p) syms)
                                                                                           (print-error 'Compiler 'Error: 'Sorry 'single 'definition 'variables 'only! 'caught 'trying 'to 'redefine (symbol->string (car p)) p 'as 'a 'shadow 'variable))
                                                                                       (cons (car p)
                                                                                             (impc:ti:find-all-vars (cadr p) syms)))
                                                                                    (cadr ast)))
                                                                                syms)))
                                         (else (append (impc:ti:find-all-vars (car ast) syms)
                                                       (impc:ti:find-all-vars (cdr ast) syms)))))
                                  ((atom? ast) syms)))))


(define impc:ti:block:check-for-free-syms
   (lambda (ast esyms)
      ;(print 'check: 'ast: ast 'esyms: esyms) 
      (cl:remove-duplicates (let loop ((lst ast))
                               (cond ((pair? lst)
                                      (append (loop (car lst))
                                              (loop (cdr lst))))
                                     ((atom? lst)
                                      (if (member lst esyms)
                                          (list lst)
                                          '())))))))

;;
;; adds make-closure and make-env tags
;;


;; adds make-closure and make-env tags
(define impc:ti:closure:convert
   (lambda (ast esyms)
      ;(print 'ast: ast 'syms: esyms)
      (cond ((pair? ast)
             (if (equal? (car ast) 'lambda)
                 (let ((env (impc:ti:block:check-for-free-syms ast esyms)))
                    (list 'make-closure env (cadr ast) 
                          (impc:ti:closure:convert (caddr ast) (append (cadr ast) esyms))))
                 (if (member (car ast) '(let let* letrec))
                     (let* ((bindings (map (lambda (binding) (car binding)) (cadr ast))))
                            ;(free-syms (impc:ti:block:check-for-free-syms (cddr ast) (append bindings esyms))))
                        (cons 'make-env
                              (list (impc:ti:closure:convert (cadr ast) (append bindings esyms))
                                    (impc:ti:closure:convert (caddr ast) (append bindings esyms)))))
                     (cons (impc:ti:closure:convert (car ast) esyms)
                           (impc:ti:closure:convert (cdr ast) esyms)))))
            ((atom? ast) ast))))





;; expects t1 (i.e. original untransformed code)
(define impc:ti:get-closure-arg-symbols
   (lambda (closure-sym ast)
      ;(print 'ast: ast)
      (cond ((null? ast) '())
            ((atom? ast) '())
            ((vector? ast) '())
            ((and (pair? ast)
                  (eq? (car ast) closure-sym))
             (if (and (not (null? (cdr ast)))
                      (list? (cadr ast))
                      (eq? (caadr ast) 'lambda))
                 (cadr (cadr ast))
                 '()))
            (else (append (impc:ti:get-closure-arg-symbols closure-sym (car ast))
                          (impc:ti:get-closure-arg-symbols closure-sym (cdr ast)))))))    


(define impc:ti:handle-forced-types
   (lambda (t1 . args)
      (if (null? args) '()
          (let* ((forced-types (map (lambda (t)
                                       (map (lambda (tt)
                                               (if (not (or (symbol? tt)
                                                            (list? tt)))
                                                   (print-error 'Compiler 'Error: 'Bad 'fixed 'type t)))
                                            (if (list? t) (cdr t) (list (cdr t))))
                                       (cons (car t) (impc:ir:convert-from-pretty-types (cdr t)))) 
                                    args))
                 (forced-types-updated (apply append (list) 
                                              (map (lambda (t)
                                                      (if (impc:ir:closure? (cdr t))
                                                          (append (map (lambda (sym type)
                                                                          (cons sym type))
                                                                       (impc:ti:get-closure-arg-symbols (car t) t1)
                                                                       (cdddr t))
                                                                  (list t))
                                                          (list t)))
                                                   forced-types)))
                 (checked-for-duplicates (let loop ((types forced-types-updated))
                                            (if (null? types) (cl:remove-duplicates forced-types-updated)
                                                (if (and (assoc (caar types) (cdr types))
                                                         (not (equal? (cdr (assoc (caar types) (cdr types)))
                                                                      (cdr (car types)))))
                                                    (print-error 'Compiler 'Error: 'Type 'mismatch 'with 'fixed 'types
                                                                 (assoc (caar types) (cdr types))
                                                                 'and (car types) '- 'do 'you 'have 'a 'conflicing 'closure 'type?)
                                                    (loop (cdr types)))))))
             ;(print 'checked checked-for-duplicates 'forced-types-udpated forced-types-updated 'forced: forced-types)
             checked-for-duplicates))))
			 
			 

(define impc:ti:get-closure-names
   (lambda (ast . args)
      (let ((blst '()))
         (let loop ((alst ast))
            (cond ((null? alst) '())
                  ((atom? alst) '())
                  ((pair? alst)
                   (if (equal? (car alst) 'make-closure)
                       (set! blst (cons (cadr alst) blst)))
                   (loop (car alst))
                   (loop (cdr alst)))))
         blst)))
			 
			
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; PUBLIC API
;; define closure types properly
(define impc:ti:run
   (lambda (symname code . args)
      ;; don't want type checking to find existing native versions!
      (if *impc:compile*
          (begin ;(llvm:remove-globalvar (string-append (symbol->string symname) "_var"))
                 ;(llvm:erase-function (symbol->string symname))
                 (llvm:erase-function (string-append (symbol->string symname) "_setter"))
                 (llvm:erase-function (string-append (symbol->string symname) "_maker"))))  
      (let* ((c code)       
             (c1 (impc:ti:get-var-types c)) ;; this is a cons pair of (ast . types)
             (t1 (impc:ti:first-transform (car c1) #t)) ;; car is ast
             (t2 (impc:ti:mark-returns t1 symname #f #f #f))
             (t3 (impc:ti:closure:convert t2 (list symname))) 
             (vars (map (lambda (x) (list x)) (impc:ti:find-all-vars t3 '())))
             (forced-types (apply impc:ti:handle-forced-types t1 (append (cdr c1) args)))
             (types (impc:ti:run-type-check vars forced-types t2))             
             (newast (impc:ti:add-types-to-source symname t3 types (list))))
         ;; if we didn't unify print error and bomb out!
         (if (not (cl:every (lambda (x) x) (impc:ti:unity? types)))
             (print-error 'Compiler 'Error: 'could 'not 'resolve 'types 'for 'symbols 
                    (cl:remove 'good (map (lambda (x y) (if y 'good (symbol->string (car x)))) 
                                          types (impc:ti:unity? types)))
                    'try 'forcing 'the 'type 'of 'one 'or 'more 'of 'these 'symbols))
         ;; if this function has been defined before make sure we aren't changing it's signature!!
         (if (and (llvm:get-function (symbol->string symname))
                  (or (<> (length (llvm:get-function-args-withoutzone (symbol->string symname)))
                          (length (cddr (assoc symname types)))) 
                      (cl:position #f (map (lambda (a b)
                                              (equal? a b))
                                           (cons (+ *impc:ir:closure*
                                                    *impc:ir:pointer*)
                                                 (map (lambda (x) (impc:ir:get-type-from-str x))
                                                      (llvm:get-function-args-withoutzone (symbol->string symname))))
                                           (cdr (assoc symname types))))))
             (print-error 'Compiler 'Error: 'sorry 'the 'compiler 'does 'not 'currently
			              'allow 'you 'to 'redefine 'or 'overload 'the 'type 'signature 'of 'existing 'functions. 
						  'in 'this 'case (symbol->string symname) 'to: 
                          (impc:ir:pptype (cdr (assoc symname types))) 'from:
                          (impc:ir:pptype (cons (+ *impc:ir:closure*
                                                   *impc:ir:pointer*)
                                                 (map (lambda (x) (impc:ir:get-type-from-str x))
                                                      (llvm:get-function-args-withoutzone (symbol->string symname)))))))
         ;(print-error "stop")
         (if *impc:compiler:print-types* (print '---------------------------------))
         (if *impc:compiler:print-types* (print 'types: types))
         ;(print 'ctypes: converted-types)
         (if *impc:compiler:print-types* (print 'newast: newast))
         ;; check for unfound types
         (for-each (lambda (t)
                      (cond ((and (list? t)                                  
                                  (member *impc:ir:other* t))
                             (print-error 'Compiler 'Error: 'unresolved 'type 'error 'for 'symbol (car t)))
                            ((and (not (list? t))
                                  (pair? t)
                                  (= *impc:ir:other* (cdr t)))
                             (print-error 'Compiler 'Error: 'unresolved 'type 'error 'for 'symbol (car t)))))
                   types)
         ;; compile to ir
         (define fstr (impc:ir:compiler newast types))
         ;; compile to x86 - i.e. call jit on any new ir functions to force jit compilation
         (for-each (lambda (fn) (llvm:jit-compile-function fn)) (impc:ti:get-closure-names newast))
         ;;
         ;; now compile ir to x86 and make stub code
         (let* ((closure-type (cadr (impc:ir:gname)))
                (compile-stub? (if (llvm:get-globalvar (string-append (symbol->string symname) "_var")) #f #t))				
                (fs (string-append "define ccc " closure-type " @" (string-append (symbol->string symname) "_maker")
                                   "(i8* %_impz){\nentry:\n"
                                   "%_zone = bitcast i8* %_impz to %mzone*\n"                                   
                                   fstr "}\n"))
                (fssetter (string-append (if (llvm:get-globalvar (string-append (symbol->string symname) "_var"))
                                             "" ;; if global var alread exists do nothing
                                             (string-append "@" (symbol->string symname) "_var = global [1 x i8*] [ i8* null ]\n\n"
                                                            "@" (symbol->string symname) "_var_zone = global [1 x i8*] [ i8* null ]\n\n"))
                                         "define ccc void @" (string-append (symbol->string symname) "_setter")
                                         "(i8* %_impz){\nentry:\n" 
                                         "%oldzone1 = getelementptr [1 x i8*]* @" (symbol->string symname) "_var_zone, i32 0, i32 0\n"
                                         "%oldzone2 = load i8** %oldzone1\n"
                                         "%oldzone3 = bitcast i8* %oldzone2 to %mzone*\n"
                                         "store i8* %_impz, i8** %oldzone1\n"
                                         ; existing code
                                         "%closure = call ccc " (cadr (impc:ir:gname))
                                         " @" (string-append (symbol->string symname) "_maker") "(i8* %_impz)\n"
                                         "%ptr = bitcast " (cadr (impc:ir:gname)) " %closure to i8*\n"
                                         "%varptr = bitcast [1 x i8*]* @" (symbol->string symname) "_var to i8**\n"
                                         "store i8* %ptr, i8** %varptr\n"
                                         ;; new code
                                         "; destroy oldzone if not null\n"
                                         "%test = icmp ne %mzone* %oldzone3, null\n"
                                         "br i1 %test, label %then, label %cont\n"
                                         ;"then:\ncall ccc void @llvm_zone_destroy(%mzone* %oldzone3)\nbr label %cont\n"
										 "then:\ncall ccc void @llvm_destroy_zone_after_delay(i8* %oldzone2,double 10.0)\nbr label %cont\n"
                                         "cont:\n"
                                         "ret void\n}\n"))
                ;(stub-type (string->sexpr (impc:ti:string-to-type closure-type)))
                (stub-type (impc:ir:get-closure-type-from-str closure-type))
                (fsgetter (string-append "define ccc i8* @" (symbol->string symname) "_getter(){\n"
                                         "entry:\n"
                                         "%ptr = getelementptr [1 x i8*]* @" (symbol->string symname) "_var, i32 0, i32 0\n"
                                         "%func = load i8** %ptr\n"
                                         "ret i8* %func\n}"))                                                                           
                (fstub (string-append "define ccc " (impc:ir:get-type-str (car stub-type))
                                      " @" (string-append (symbol->string symname) "(i8* %_impz")
                                      (apply string-append (map (lambda (t n c)
                                                                   (string-append c (impc:ir:get-type-str t) " "
                                                                                  n))
                                                                (cdr stub-type)                                           
                                                                '("%a" "%b" "%c" "%d" "%e" "%f" "%g" "%h" "%i" "%j")
                                                                '("," "," "," "," "," "," "," "," "," ",")))
                                      ")\n"
                                      "{\nentry:\n"
                                      ;"%_zone = call ccc %mzone* @malloc_create_zone(0,0)\n"
                                      ;"%_zone = call ccc %mzone* @malloc_default_zone()\n"
                                      ;"%_impz = bitcast %mzone* %_zone to i8*\n"
                                      "%ptr = getelementptr [1 x i8*]* @" (symbol->string symname) "_var, i32 0, i32 0\n"
                                      "%ptrvar = load i8** %ptr\n"
                                      "%closure = bitcast i8* %ptrvar to " closure-type "\n"
                                      "%fPtr = getelementptr " closure-type " %closure, i32 0, i32 2\n"
                                      "%ePtr = getelementptr " closure-type " %closure, i32 0, i32 1\n"
                                      "%ff = load "
                                      (regex:replace closure-type "<\\{ ?i8\\*, ?i8\\*,(.*)\\}>\\*" "$1")
                                      "* %fPtr\n"
                                      "%ee = load i8** %ePtr\n"
                                      (if (impc:ir:void? (car stub-type)) "" "%result = ")
                                      "tail call fastcc " (impc:ir:get-type-str (car stub-type)) " %ff(i8* %_impz, i8* %ee"
                                      (apply string-append (map (lambda (t n)
                                                                   (string-append ", " 
                                                                                  (impc:ir:get-type-str t) 
                                                                                  " " n))
                                                                (cdr stub-type)
                                                                '("%a" "%b" "%c" "%d" "%e" "%f" "%g" "%h" "%i" "%j")))                                                        
                                      ")\nret " (impc:ir:get-type-str (car stub-type)) 
                                      (if (impc:ir:void? (car stub-type)) "\n" " %result\n")
                                      "}")))
            
            (if *impc:compiler:print* (print '--------------------------------compiling----------------------------------->))
            (if *impc:compiler:print* (print fs))

            (if *impc:compile*
                (begin ;(llvm:remove-function (string-append (symbol->string symname) "_maker"))
                       (if (not (llvm:compile fs))
                           (begin (print-error "Compiler Failed")
                                  (error "")))
                       (if *impc:compiler:print* (print-notification "compiled maker"))))
            (if *impc:compiler:print* (print '--------------------------------compiling----------------------------------->))            
            (if *impc:compiler:print* (print fssetter))
            (if *impc:compile*
                (begin ;(llvm:remove-function (string-append (symbol->string symname) "_setter"))
                       ;(llvm:remove-globalvar (string-append (symbol->string symname) "_var"))
                       (if (not (llvm:compile fssetter))
                           (begin (print-error "Compiler Failed")
                                  (error "")))
                       (if *impc:compiler:print* (print-notification "compiled setter"))))
            ;(if *impc:compile*
            ;    (let ((res1 (llvm:get-function (string-append (symbol->string symname) "_setter"))))                   
            ;       (if (cptr? res1)
            ;           (llvm:run res1 (sys:create-mzone))
            ;           (begin (print-error 'Compiler 'Error '- 'error 'creating 'setter 'function)
            ;                  (error "")))))
            (if *impc:compiler:print* (print '--------------------------------compiling----------------------------------->))            
            (if *impc:compiler:print* (print fsgetter))            
            (if (and *impc:compile* compile-stub?) ;; only compile stub first time around!!!
                (begin ;(llvm:remove-function (string-append (symbol->string symname) "_stub"))
                       (if (not (llvm:compile fsgetter))
                           (begin (print-error "Compiler Failed")
                                  (error ""))) 
                       (if *impc:compiler:print* (print-notification "compiled stub"))))
            (if *impc:compiler:print* (print '--------------------------------compiling----------------------------------->))            
            (if *impc:compiler:print* (print fstub))            
            (if (and *impc:compile* compile-stub?) ;; only compile stub first time around!!!
                (begin ;(llvm:remove-function (string-append (symbol->string symname) "_stub"))
                       (if (not (llvm:compile fstub))
                           (begin (print-error "Compiler Failed")
                                  (error ""))) 
                       (if *impc:compiler:print* (print-notification "compiled stub"))))
            (if *impc:compile*
                (let ((ftype (llvm:get-function-args-withoutzone (symbol->string symname)))) 
                   (print-notification 'Successfully 'compiled symname '>>> 
                                       (string->sexpr (impc:ir:pretty-print-type (cons (+ *impc:ir:closure* *impc:ir:pointer*)
                                                                                       ftype))))))
            (cadr (impc:ir:gname))))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; PUBLIC API
;; define closure types properly
(define impc:ti:run
   (lambda (symname code . args)
      ;; don't want type checking to find existing native versions!
      (if *impc:compile*
          (begin ;(llvm:remove-globalvar (string-append (symbol->string symname) "_var"))
                 ;(llvm:erase-function (symbol->string symname))
                 (llvm:erase-function (string-append (symbol->string symname) "_setter"))
                 (llvm:erase-function (string-append (symbol->string symname) "_maker"))))  
      (let* ((c code)       
             (c1 (impc:ti:get-var-types c)) ;; this is a cons pair of (ast . types)
             (t1 (impc:ti:first-transform (car c1) #t)) ;; car is ast
             (t2 (impc:ti:mark-returns t1 symname #f #f #f))
             (t3 (impc:ti:closure:convert t2 (list symname))) 
             (vars (map (lambda (x) (list x)) (impc:ti:find-all-vars t3 '())))
             (forced-types (apply impc:ti:handle-forced-types t1 (append (cdr c1) args)))
             (types (impc:ti:run-type-check vars forced-types t2))             
             (newast (impc:ti:add-types-to-source symname t3 types (list))))
         ;; if we didn't unify print error and bomb out!
         (if (not (cl:every (lambda (x) x) (impc:ti:unity? types)))
             (print-error 'Compiler 'Error: 'could 'not 'resolve 'types 'for 'symbols 
                    (cl:remove 'good (map (lambda (x y) (if y 'good (symbol->string (car x)))) 
                                          types (impc:ti:unity? types)))
                    'try 'forcing 'the 'type 'of 'one 'or 'more 'of 'these 'symbols))
         ;; if this function has been defined before make sure we aren't changing it's signature!!
         (if (and (llvm:get-function (symbol->string symname))
                  (or (<> (length (llvm:get-function-args-withoutzone (symbol->string symname)))
                          (length (cddr (assoc symname types)))) 
                      (cl:position #f (map (lambda (a b)
                                              (equal? a b))
                                           (cons (+ *impc:ir:closure*
                                                    *impc:ir:pointer*)
                                                 (map (lambda (x) (impc:ir:get-type-from-str x))
                                                      (llvm:get-function-args-withoutzone (symbol->string symname))))
                                           (cdr (assoc symname types))))))
             (print-error 'Compiler 'Error: 'sorry 'the 'compiler 'does 'not 'currently
			              'allow 'you 'to 'redefine 'or 'overload 'the 'type 'signature 'of 'existing 'functions. 
						  'in 'this 'case (symbol->string symname) 'to: 
                          (impc:ir:pptype (cdr (assoc symname types))) 'from:
                          (impc:ir:pptype (cons (+ *impc:ir:closure*
                                                   *impc:ir:pointer*)
                                                 (map (lambda (x) (impc:ir:get-type-from-str x))
                                                      (llvm:get-function-args-withoutzone (symbol->string symname)))))))
         ;(print-error "stop")
         (if *impc:compiler:print-types* (print '---------------------------------))
         (if *impc:compiler:print-types* (print 'types: types))
         ;(print 'ctypes: converted-types)
         (if *impc:compiler:print-types* (print 'newast: newast))
         ;; check for unfound types
         (for-each (lambda (t)
                      (cond ((and (list? t)                                  
                                  (member *impc:ir:other* t))
                             (print-error 'Compiler 'Error: 'unresolved 'type 'error 'for 'symbol (car t)))
                            ((and (not (list? t))
                                  (pair? t)
                                  (= *impc:ir:other* (cdr t)))
                             (print-error 'Compiler 'Error: 'unresolved 'type 'error 'for 'symbol (car t)))))
                   types)
         ;; compile to ir
         (define fstr (impc:ir:compiler newast types))
         ;; compile to x86 - i.e. call jit on any new ir functions to force jit compilation
         (for-each (lambda (fn) (llvm:jit-compile-function fn)) (impc:ti:get-closure-names newast))
         ;;
         ;; now compile ir to x86 and make stub code
         (let* ((closure-type (cadr (impc:ir:gname)))
                (compile-stub? (if (llvm:get-globalvar (string-append (symbol->string symname) "_var")) #f #t))				
                (fs (string-append "define ccc " closure-type " @" (string-append (symbol->string symname) "_maker")
                                   "(i8* %_impz){\nentry:\n"
                                   "%_zone = bitcast i8* %_impz to %mzone*\n"                                   
                                   fstr "}\n"))
                (fssetter (string-append (if (llvm:get-globalvar (string-append (symbol->string symname) "_var"))
                                             "" ;; if global var alread exists do nothing
                                             (string-append "@" (symbol->string symname) "_var = global [1 x i8*] [ i8* null ]\n\n"
                                                            "@" (symbol->string symname) "_var_zone = global [1 x i8*] [ i8* null ]\n\n"))
                                         "define ccc void @" (string-append (symbol->string symname) "_setter")
                                         "(i8* %_impz){\nentry:\n" 
                                         "%oldzone1 = getelementptr [1 x i8*]* @" (symbol->string symname) "_var_zone, i32 0, i32 0\n"
                                         "%oldzone2 = load i8** %oldzone1\n"
                                         "%oldzone3 = bitcast i8* %oldzone2 to %mzone*\n"
                                         "store i8* %_impz, i8** %oldzone1\n"
                                         ; existing code
                                         "%closure = call ccc " (cadr (impc:ir:gname))
                                         " @" (string-append (symbol->string symname) "_maker") "(i8* %_impz)\n"
                                         "%ptr = bitcast " (cadr (impc:ir:gname)) " %closure to i8*\n"
                                         "%varptr = bitcast [1 x i8*]* @" (symbol->string symname) "_var to i8**\n"
                                         "store i8* %ptr, i8** %varptr\n"
                                         ;; new code
                                         "; destroy oldzone if not null\n"
                                         "%test = icmp ne %mzone* %oldzone3, null\n"
                                         "br i1 %test, label %then, label %cont\n"
                                         ;"then:\ncall ccc void @llvm_zone_destroy(%mzone* %oldzone3)\nbr label %cont\n"
										 "then:\ncall ccc void @llvm_destroy_zone_after_delay(i8* %oldzone2,double 10.0)\nbr label %cont\n"
                                         "cont:\n"
                                         "ret void\n}\n"))
                ;(stub-type (string->sexpr (impc:ti:string-to-type closure-type)))
                (stub-type (impc:ir:get-closure-type-from-str closure-type))
                (fsgetter (string-append "define ccc i8* @" (symbol->string symname) "_getter(){\n"
                                         "entry:\n"
                                         "%ptr = getelementptr [1 x i8*]* @" (symbol->string symname) "_var, i32 0, i32 0\n"
                                         "%func = load i8** %ptr\n"
                                         "ret i8* %func\n}\n"))                                                                           
                (fstub (string-append "define ccc " (impc:ir:get-type-str (car stub-type))
                                      " @" (string-append (symbol->string symname) "(i8* %_impz")
                                      (apply string-append (map (lambda (t n c)
                                                                   (string-append c (impc:ir:get-type-str t) " "
                                                                                  n))
                                                                (cdr stub-type)                                           
                                                                '("%a" "%b" "%c" "%d" "%e" "%f" "%g" "%h" "%i" "%j")
                                                                '("," "," "," "," "," "," "," "," "," ",")))
                                      ")\n"
                                      "{\nentry:\n"
                                      ;"%_zone = call ccc %mzone* @malloc_create_zone(0,0)\n"
                                      ;"%_zone = call ccc %mzone* @malloc_default_zone()\n"
                                      ;"%_impz = bitcast %mzone* %_zone to i8*\n"
                                      "%ptr = getelementptr [1 x i8*]* @" (symbol->string symname) "_var, i32 0, i32 0\n"
                                      "%ptrvar = load i8** %ptr\n"
                                      "%closure = bitcast i8* %ptrvar to " closure-type "\n"
                                      "%fPtr = getelementptr " closure-type " %closure, i32 0, i32 2\n"
                                      "%ePtr = getelementptr " closure-type " %closure, i32 0, i32 1\n"
                                      "%ff = load "
                                      (regex:replace closure-type "<\\{ ?i8\\*, ?i8\\*,(.*)\\}>\\*" "$1")
                                      "* %fPtr\n"
                                      "%ee = load i8** %ePtr\n"
                                      (if (impc:ir:void? (car stub-type)) "" "%result = ")
                                      "tail call fastcc " (impc:ir:get-type-str (car stub-type)) " %ff(i8* %_impz, i8* %ee"
                                      (apply string-append (map (lambda (t n)
                                                                   (string-append ", " 
                                                                                  (impc:ir:get-type-str t) 
                                                                                  " " n))
                                                                (cdr stub-type)
                                                                '("%a" "%b" "%c" "%d" "%e" "%f" "%g" "%h" "%i" "%j")))                                                        
                                      ")\nret " (impc:ir:get-type-str (car stub-type)) 
                                      (if (impc:ir:void? (car stub-type)) "\n" " %result\n")
                                      "}")))
            
            (if *impc:compiler:print* (print '--------------------------------compiling----------------------------------->))
            (if *impc:compiler:print* (print fs))
            (if *impc:compiler:print-raw-llvm* (print-full-nq fs)) 

            (if *impc:compile*
                (begin ;(llvm:remove-function (string-append (symbol->string symname) "_maker"))
                       (if (not (llvm:compile fs))
                           (begin (print-error "Compiler Failed")
                                  (error "")))
                       (if *impc:compiler:print* (print-notification "compiled maker"))))
            (if *impc:compiler:print* (print '--------------------------------compiling----------------------------------->))            
            (if *impc:compiler:print* (print fssetter))
            (if *impc:compiler:print-raw-llvm* (print-full-nq fssetter))
            (if *impc:compile*
                (begin ;(llvm:remove-function (string-append (symbol->string symname) "_setter"))
                       ;(llvm:remove-globalvar (string-append (symbol->string symname) "_var"))
                       (if (not (llvm:compile fssetter))
                           (begin (print-error "Compiler Failed")
                                  (error "")))
                       (if *impc:compiler:print* (print-notification "compiled setter"))))
            ;(if *impc:compile*
            ;    (let ((res1 (llvm:get-function (string-append (symbol->string symname) "_setter"))))                   
            ;       (if (cptr? res1)
            ;           (llvm:run res1 (sys:create-mzone))
            ;           (begin (print-error 'Compiler 'Error '- 'error 'creating 'setter 'function)
            ;                  (error "")))))
            (if *impc:compiler:print* (print '--------------------------------compiling----------------------------------->))            
            (if *impc:compiler:print* (print fsgetter))            
            (if *impc:compiler:print-raw-llvm* (print-full-nq fsgetter)) 
            (if (and *impc:compile* compile-stub?) ;; only compile stub first time around!!!
                (begin ;(llvm:remove-function (string-append (symbol->string symname) "_stub"))
                       (if (not (llvm:compile fsgetter))
                           (begin (print-error "Compiler Failed")
                                  (error ""))) 
                       (if *impc:compiler:print* (print-notification "compiled stub"))))
            (if *impc:compiler:print* (print '--------------------------------compiling----------------------------------->))            
            (if *impc:compiler:print* (print fstub))            
            (if *impc:compiler:print-raw-llvm* (print-full-nq fstub))
            (if (and *impc:compile* compile-stub?) ;; only compile stub first time around!!!
                (begin ;(llvm:remove-function (string-append (symbol->string symname) "_stub"))
                       (if (not (llvm:compile fstub))
                           (begin (print-error "Compiler Failed")
                                  (error ""))) 
                       (if *impc:compiler:print* (print-notification "compiled stub"))))
            (if *impc:compile*
                (let ((ftype (llvm:get-function-args-withoutzone (symbol->string symname)))) 
                   (if (not *impc:compiler:print-raw-llvm*)
                       (print-notification 'Successfully 'compiled symname '>>> 
                                           (string->sexpr (impc:ir:pretty-print-type (cons (+ *impc:ir:closure* *impc:ir:pointer*)
                                                                                           ftype)))))))
            (cadr (impc:ir:gname))))))

					 
;; definec takes optional type arguments after symname
(define-macro (definec symname . args)
   (let ((types (cdr (reverse args)))
         (expr (car (reverse args))))
      ;(print-full 'types: types 'e: expr 'args: args)
      `(define ,symname
          (let* ((res1 (apply impc:ti:run ',symname '(let ((,symname ,expr)) ,symname) ',types))
                 (setter (llvm:get-function (string-append (symbol->string ',symname) "_setter")))
                 (func (llvm:get-function (symbol->string ',symname))))
             (if setter
                 (llvm:run setter (sys:create-mzone))
                 (begin (print-error 'no 'compiled 'function ',symname 'setter  '... 'turn 'on 'compilation?)
                        (error "")))
             (if func
                 (lambda args (apply llvm:run func *impc:zone* args))
                 (begin (print-error 'no 'compiled 'function ',symname  '... 'turn 'on 'compilation?)
                        (error "")))))))

;; definec-precomp is for setting up precompiled ir functions only
(define-macro (definec-precomp symname)
   `(define ,symname
       (let* ((setter (llvm:get-function (string-append (symbol->string ',symname) "_setter")))
              (func (llvm:get-function (symbol->string ',symname))))
          (if setter
              (llvm:run setter (sys:create-mzone))
              (begin (print-error 'no 'compiled 'function ',symname 'setter  '... 'turn 'on 'compilation?)
                     (error "")))
          (if func
              (lambda args (apply llvm:run func *impc:zone* args))
              (begin (print-error 'no 'compiled 'function ',symname  '... 'turn 'on 'compilation?)
                     (error ""))))))
						
					
;; macro helper for fx code au's							
(define-macro (definec-fx . args)
   `(definec ,(car args)
       (,(car args) . [double,double,double,double,double*]*)
       ,(cadr args)))

;; macro helper for mu code au's
(define-macro (definec-mu . args)
   `(definec ,(car args)
       (,(car args) . [[double,double,double,double,double*]*]*)
       ,(cadr args)))						

(define-macro (bindc symbol type value)
   (if (cptr? (eval value))
       `(begin (if (not (llvm:get-globalvar ,(symbol->string symbol)))
                   (llvm:compile (string-append "@" ,(symbol->string symbol)
                                                " = external global "
                                                ,(impc:ir:get-type-str (impc:ir:convert-from-pretty-types type)))))
               (llvm:bind-global-var ,(symbol->string symbol) ,value))
       (print-error "bindc only accepts cptr values")))