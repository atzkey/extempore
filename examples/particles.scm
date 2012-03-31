;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; A little particle example
;;
;; Multicoloured stars
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(load "libs/opengl_lib.scm")
(load "libs/particles.scm")

(define ctx (gl:make-ctx "a" #f 0.0 0.0 900.0 600.0))
(gl-set-view 900.0 600.0)

(bind-val texture1 i32 0)

(definec load-tex
  (lambda (id)
    (let ((t (gl-load-tex "Horde3D/textures/particles/star.png" id)))      
      (set! texture1 t))))

;; 0 meaning load texture into new id
(load-tex 0)

;; init particle system
(definec init-psys
  (lambda (psys)
    (let ((xs (psystem_xs psys))
	  (ys (psystem_ys psys))
	  (xvs (psystem_xvs psys))
	  (yvs (psystem_yvs psys))
	  (sizes (psystem_sizes psys))
	  (reds (psystem_reds psys))
	  (greens (psystem_greens psys))
	  (blues (psystem_blues psys))	    	    
	  (alphas (psystem_alphas psys))
	  (states (psystem_states psys))
	  (i 0))
      (dotimes (i 5000)
	(pset! xs i 0.0) ;(dtof (* 10.0 (random))))
	(pset! ys i 0.0) ;(dtof (* 10.0 (random))))
	(pset! xvs i (* 20.0 (- (dtof (random)) .5)))
	(pset! yvs i (* 20.0 (- (dtof (random)) .5)))
	(pset! sizes i (dtof (* (random) 200.0)))
	(pset! reds i (dtof (random)))
	(pset! greens i (dtof (random)))
	(pset! blues i (dtof (random)))
	(pset! alphas i (dtof (random)))
	(pset! states i 100000))
      void)))

;; gl-code 	  
(definec gl-loop
  (let ((psys (psystem_create 5000 texture1)))
    (init-psys psys)
    (lambda (time:double)
      (glClearColor 0.0 0.0 0.0 1.0)
      (glClear (+ GL_DEPTH_BUFFER_BIT GL_COLOR_BUFFER_BIT))
      (glLoadIdentity)
      (glTranslated 0.0 -50.0 -1000.0)
      (psystem_draw psys)
      (psystem_update psys)
      void)))

;; gl callback loop
(define loop
  (lambda (time)
    (gl-loop time)
    (gl:swap-buffers ctx)
    (callback (+ time 100) 'loop (+ time 1800))))

(begin (sys:sleep 11025)
       (loop (now)))