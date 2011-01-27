;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;
; Simplest possible audio example
; Just eval each expression in turn
;

;; compile sample by sample dsp code
(definec dsp
  (lambda (in:double time:double channel:double	data:double*)
    (random)))

;; set compiled function named "dsp" to be the dsp callback
(dsp:set! "dsp")

;; recompile dsp to produce two sine wave in left and right
(definec dsp
  (lambda (in:double time:double channel:double	data:double*)
    (cond	((= channel 1.0)
           (* 0.3 (sin (* 3.14152 2.0 time (/ 440.0 44100.0)))))
          ((= channel 0.0)
           (* 0.3 (sin (* 3.14152 2.0 time (/ 660.0 44100.0)))))
          (else	0.0))))


;; abstract out an oscillator function                                                                        
(definec make-oscil
   (lambda (phase)
      (lambda (amp freq)
         (let ((inc (* 3.141592 (* 2.0 (/ freq 44100.)))))
            (set! phase (+ phase inc))
            (* amp (sin phase))))))

;; slightly more complex example uses make-oscil
(definec dsp
  (let ((oscs (make-array 9 [double,double,double]*)))
    (dotimes (i 9)
       (aset! oscs i (make-oscil 0.0)))
    (lambda (a:double b:double c:double d:double*)
      (cond ((= c 0.0) ;; left channel
             (+ ((aref oscs 0) (+ 0.3 ((aref oscs 2) 0.2 1.0)) 60.0)
                ((aref oscs 3) 0.2 220.0)
                ((aref oscs 4) 0.2 (+ 400. ((aref oscs 5) 200. .1)))
                ((aref oscs 6) 0.1 900.0)))
            ((= c 1.0) ;; right channel                                                                       
             ((aref oscs 7) 0.3 (+ 220.0 ((aref oscs 8) 110.0 20.0))))
            (else 0.0))))) ;; any remaining channels                                                          