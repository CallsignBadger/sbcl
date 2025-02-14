;;;; Utilities for separating an SBCL core file into two pieces:
;;;; 1. An assembly language file containing the immobile code space
;;;; 2. A '.o' file wrapping a core file containing everything else
;;;; We operate as a "tool" that processes external files rather than
;;;; operating on the in-process data, but it is also possible to dump
;;;; the current image by creating a straight-through translation
;;;; of internal/external code addresses.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(load (merge-pathnames "corefile.lisp" *load-pathname*))

(defpackage "SB-EDITCORE"
  (:use "CL" "SB-ALIEN" "SB-COREFILE" "SB-INT" "SB-EXT"
        "SB-KERNEL" "SB-SYS" "SB-VM")
  (:export #:move-dynamic-code-to-text-space #:redirect-text-space-calls
           #:split-core #:copy-to-elf-obj)
  (:import-from "SB-ALIEN-INTERNALS"
                #:alien-type-bits #:parse-alien-type
                #:alien-value-sap #:alien-value-type)
  (:import-from "SB-C" #:+backend-page-bytes+)
  (:import-from "SB-VM" #:map-objects-in-range #:reconstitute-object
                #:%closure-callee #:code-object-size)
  (:import-from "SB-DISASSEM" #:get-inst-space #:find-inst
                #:make-dstate #:%make-segment #:make-code-segment
                #:seg-virtual-location #:seg-length #:seg-sap-maker
                #:map-segment-instructions #:inst-name
                #:dstate-next-addr #:dstate-cur-offs)
  (:import-from "SB-X86-64-ASM" #:near-jump-displacement
                #:near-cond-jump-displacement #:mov #:call #:jmp
                #:get-gpr #:reg-name
                #:machine-ea #:machine-ea-base #:machine-ea-index #:machine-ea-disp)
  (:import-from "SB-IMPL" #:symbol-hashset #:package-%name
                #:symtbl-%cells
                #:hash-table-pairs #:hash-table-%count))

(in-package "SB-EDITCORE")

(declaim (muffle-conditions compiler-note))

(eval-when (:execute)
  (setq *evaluator-mode* :compile))

;;; Some high address that won't conflict with any of the ordinary spaces
;;; It's more-or-less arbitrary, but we must be able to discern whether a
;;; pointer looks like it points to code in case coreparse has to walk the heap.
(defconstant +code-space-nominal-address+ #x550000000000)

(defglobal +noexec-stack-note+ ".section .note.GNU-stack, \"\", @progbits")

(defstruct (core-space ; "space" is a CL symbol
            (:conc-name space-)
            (:constructor make-space (id addr data-page page-adjust nwords)))
  (page-table nil :type (or null simple-vector))
  id addr data-page page-adjust nwords)
(defmethod print-object ((self core-space) stream)
  (print-unreadable-object (self stream :type t)
    (format stream "~d" (space-id self))))
(defun space-size (space) (* (space-nwords space) n-word-bytes))
(defun space-end (space) (+  (space-addr space) (space-size space)))
(defun space-nbytes-aligned (space)
  (align-up (space-size space) +backend-page-bytes+))
(defun space-physaddr (space spacemap)
  (sap+ (car spacemap) (* (space-data-page space) +backend-page-bytes+)))

;;; Given VADDR which is an address in the target core, return the address at which
;;; VADDR is currently mapped while performing the split.
;;; SPACEMAP is a cons of a SAP and an alist whose elements are (ADDR . CORE-SPACE)
(defun translate-ptr (vaddr spacemap)
  (let ((space (find vaddr (cdr spacemap) :key #'space-addr :test #'>=)))
    ;; FIXME: duplicates SPACE-PHYSADDR to avoid consing a SAP.
    ;; macroize or something.
    (+ (sap-int (car spacemap)) (* (space-data-page space) +backend-page-bytes+)
       (- vaddr (space-addr space)))))

;;;
(defun get-space (id spacemap)
  (find id (cdr spacemap) :key #'space-id))
(defun compute-nil-object (spacemap)
  (let ((space (get-space static-core-space-id spacemap)))
    ;; TODO: The core should store its address of NIL in the initial function entry
    ;; so this kludge can be removed.
    (%make-lisp-obj (logior (space-addr space) #x117)))) ; SUPER KLUDGE

;;; Given OBJ which is tagged pointer into the target core, translate it into
;;; the range at which the core is now mapped during execution of this tool,
;;; so that host accessors can dereference its slots.
;;; Use extreme care: while it works to use host accessors on the target core,
;;; we must avoid type checks on instances because LAYOUTs need translation.
;;; Printing boxed objects from the target core will almost always crash.
(defun translate (obj spacemap)
  (%make-lisp-obj (translate-ptr (get-lisp-obj-address obj) spacemap)))

(defstruct (core-sym (:copier nil) (:predicate nil)
                     (:constructor make-core-sym (package name external)))
  (package nil)
  (name nil :read-only t)
  (external nil :read-only t))

(defstruct (bounds (:constructor make-bounds (low high)))
  (low 0 :type word) (high 0 :type word))

(defstruct (core (:predicate nil)
                 (:copier nil)
                 (:constructor %make-core))
  (spacemap)
  (nil-object)
  ;; mapping from small integer ID to package
  (pkg-id->package)
  ;; mapping from string naming a package to list of symbol names (strings)
  ;; that are external in the package.
  (packages (make-hash-table :test 'equal))
  ;; hashset of symbol names (as strings) that should be package-qualified.
  ;; (Prefer not to package-qualify unambiguous names)
  (nonunique-symbol-names)
  (code-bounds nil :type bounds :read-only t)
  (fixedobj-bounds nil :type bounds :read-only t)
  (linkage-bounds nil :type bounds :read-only t)
  (linkage-symbols nil)
  (linkage-symbol-usedp nil)
  (linkage-entry-size nil)
  (new-fixups (make-hash-table))
  (new-fixup-words-used 0)
  ;; For assembler labels that we want to invent at random
  (label-counter 0)
  (enable-pie nil)
  (dstate (make-dstate nil) :read-only t)
  (seg (%make-segment :sap-maker (lambda () (error "Bad sap maker"))
                      :virtual-location 0) :read-only t)
  (fixup-addrs nil)
  (call-inst nil :read-only t)
  (jmp-inst nil :read-only t)
  (pop-inst nil :read-only t))

(defglobal *editcore-ppd*
  ;; copy no entries for macros/special-operators (flet, etc)
  (let ((ppd (sb-pretty::make-pprint-dispatch-table #() nil nil)))
    (set-pprint-dispatch 'string
                         ;; Write strings without string quotes
                         (lambda (stream string) (write-string string stream))
                         0
                         ppd)
    ppd))

(defun c-name (lispname core pp-state &optional (prefix ""))
  (when (typep lispname '(string 0))
    (setq lispname "anonymous"))
  ;; Perform backslash escaping on the exploded string
  ;; Strings were stringified without surrounding quotes,
  ;; but there might be quotes embedded anywhere, so escape them,
  ;; and also remove newlines and non-ASCII.
  (let ((characters
         (mapcan (lambda (char)
                   (cond ((not (typep char 'base-char)) (list #\?))
                         ((member char '(#\\ #\")) (list #\\ char))
                         ((eql char #\newline) (list #\_))
                         (t (list char))))
                 (coerce (cond
                           #+darwin
                           ((and (stringp lispname)
                                 ;; L denotes a symbol which can not be global on macOS.
                                 (char= (char lispname 0) #\L))
                            (concatenate 'string "_" lispname))
                           (t
                            (write-to-string lispname
                              ;; Printing is a tad faster without a pretty stream
                              :pretty (not (typep lispname 'core-sym))
                              :pprint-dispatch *editcore-ppd*
                              ;; FIXME: should be :level 1, however see
                              ;; https://bugs.launchpad.net/sbcl/+bug/1733222
                              :escape t :level 2 :length 5
                              :case :downcase :gensym nil
                              :right-margin 10000)))
                         'list))))
    (let ((string (concatenate 'string prefix characters)))
      ;; If the string appears in the linker symbols, then string-upcase it
      ;; so that it looks like a conventional Lisp symbol.
      (cond ((find-if (lambda (x) (string= string (if (consp x) (car x) x)))
                      (core-linkage-symbols core))
             (setq string (string-upcase string)))
            ((string= string ".") ; can't use the program counter symbol either
             (setq string "|.|")))
      ;; If the symbol is still nonunique, add a random suffix.
      ;; The secondary value is whether the symbol should be a linker global.
      ;; For now, make nothing global, thereby avoiding potential conflicts.
      (let ((occurs (incf (gethash string (car pp-state) 0))))
        (if (> occurs 1)
            (values (concatenate 'string  string "_" (write-to-string occurs))
                    nil)
            (values string
                    nil))))))

(defmethod print-object ((sym core-sym) stream)
  (format stream "~(~:[~*~;~:*~A~:[:~;~]:~]~A~)"
          (core-sym-package sym)
          (core-sym-external sym)
          (core-sym-name sym)))

(defun space-bounds (id spacemap)
  (let ((space (get-space id spacemap)))
    (if space
        (make-bounds (space-addr space) (space-end space))
        (make-bounds 0 0))))
(defun in-bounds-p (addr bounds)
  (and (>= addr (bounds-low bounds)) (< addr (bounds-high bounds))))

(defun make-string-hashset (contents count)
  (let ((hs (sb-int:make-hashset count #'string= #'sxhash)))
    (dolist (string contents hs)
      (sb-int:hashset-insert hs string))))

(defun scan-symbol-hashset (function table core)
  (let* ((spacemap (core-spacemap core))
         (nil-object (core-nil-object core))
         (cells (translate (symtbl-%cells (truly-the symbol-hashset
                                                     (translate table spacemap)))
                           spacemap)))
    (dovector (x (translate (cdr cells) spacemap))
      (unless (fixnump x)
        (funcall function
                 (if (eq x nil-object) ; any random package can export NIL. wow.
                     "NIL"
                     (translate (symbol-name (translate x spacemap)) spacemap))
                 x)))))

(defun %fun-name-from-core (name core &aux (spacemap (core-spacemap core))
                                           (packages (core-packages core))
                                           (core-nil (core-nil-object core)))
  (named-let recurse ((depth 0) (x name))
    (unless (is-lisp-pointer (get-lisp-obj-address x))
      (return-from recurse x)) ; immediate object
    (when (eq x core-nil)
      (return-from recurse nil))
    (setq x (translate x spacemap))
    (ecase (lowtag-of x)
      (#.list-pointer-lowtag
       (cons (recurse (1+ depth) (car x))
             (recurse (1+ depth) (cdr x))))
      ((#.instance-pointer-lowtag #.fun-pointer-lowtag) "?")
      (#.other-pointer-lowtag
       (cond
        ((stringp x)
         (let ((p (position #\/ x :from-end t)))
           (if p (subseq x (1+ p)) x)))
        ((symbolp x)
         (let ((package-id (symbol-package-id x))
               (name (translate (symbol-name x) spacemap)))
           (when (eq package-id 0) ; uninterned
             (return-from recurse (string-downcase name)))
           (let* ((package (truly-the package
                                      (aref (core-pkg-id->package core) package-id)))
                  (package-name (translate (package-%name package) spacemap)))
             ;; The name-cleaning code wants to compare against symbols
             ;; in CL, PCL, and KEYWORD, so use real symbols for those.
             ;; Other than that, we avoid finding host symbols
             ;; because the externalness could be wrong and misleading.
             ;; It's a very subtle point, but best to get it right.
             (when (member package-name '("COMMON-LISP" "KEYWORD" "SB-PCL")
                           :test #'string=)
               ;; NIL can't occur. It was picked off above.
               (awhen (find-symbol name package-name) ; if existing symbol, use it
                 (return-from recurse it)))
             (unless (gethash name (core-nonunique-symbol-names core))
               ;; Don't care about package
               (return-from recurse (make-core-sym nil name nil)))
             (when (string= package-name "KEYWORD") ; make an external core-symbol
               (return-from recurse (make-core-sym nil name t)))
             (let ((externals (gethash package-name packages))
                   (n 0))
               (unless externals
                 (scan-symbol-hashset
                  (lambda (string symbol)
                    (declare (ignore symbol))
                    (incf n)
                    (push string externals))
                  (package-external-symbols package)
                  core)
                 (setf externals (make-string-hashset externals n)
                       (gethash package-name packages) externals))
               (make-core-sym package-name
                              name
                              (sb-int:hashset-find externals name))))))
        (t "?"))))))

(defun remove-name-junk (name)
  (setq name
        (named-let recurse ((x name))
          (cond ((typep x '(cons (eql lambda)))
                 (let ((args (second x)))
                   `(lambda ,(if args sb-c::*debug-name-sharp* "()")
                      ,@(recurse (cddr x)))))
                ((eq x :in) "in")
                ((and (typep x '(or string symbol))
                      (= (mismatch (string x) "CLEANUP-FUN-")
                         (length "CLEANUP-FUN-")))
                 '#:cleanup-fun)
                ((consp x) (recons x (recurse (car x)) (recurse (cdr x))))
                (t x))))
  ;; Shorten obnoxiously long printed representations of methods.
  (flet ((unpackageize (thing)
           (when (typep thing 'core-sym)
             (setf (core-sym-package thing) nil))
           thing))
    (when (typep name '(cons (member sb-pcl::slow-method sb-pcl::fast-method
                                     sb-pcl::slot-accessor)))
      (setq name `(,(case (car name)
                      (sb-pcl::fast-method "method")
                      (sb-pcl::slow-method "Method") ; something visually distinct
                      (sb-pcl::slot-accessor "accessor"))
                   ,@(cdr name)))
      (setf (second name) (unpackageize (second name)))
      (let ((last (car (last name))))
        (when (listp last)
          (dolist (qual last)
            (unpackageize qual))))))
  name)

(defun fun-name-from-core (name core)
  (remove-name-junk (%fun-name-from-core name core)))

;;; A problem: COMPILED-DEBUG-FUN-ENCODED-LOCS (a packed integer) might be a
;;; bignum - in fact probably is. If so, it points into the target core.
;;; So we have to produce a new instance with an ENCODED-LOCS that
;;; is the translation of the bignum, and call the accessor on that.
;;; The accessors for its sub-fields are abstract - we don't know where the
;;; fields are so we can't otherwise unpack them. (See CDF-DECODE-LOCS if
;;; you really need to know)
(defun cdf-offset (compiled-debug-fun spacemap)
  ;; (Note that on precisely GC'd platforms, this operation is dangerous,
  ;; but no more so than everything else in this file)
  (let ((locs (sb-c::compiled-debug-fun-encoded-locs
               (truly-the sb-c::compiled-debug-fun compiled-debug-fun))))
    (when (consp locs)
      (setq locs (cdr (translate locs spacemap))))
    (sb-c::compiled-debug-fun-offset
     (sb-c::make-compiled-debug-fun
      :name nil
      :encoded-locs (if (fixnump locs) locs (translate locs spacemap))))))

;;; Return a list of ((NAME START . END) ...)
;;; for each C symbol that should be emitted for this code object.
;;; Start and and are relative to the object's base address,
;;; not the start of its instructions. Hence we add HEADER-BYTES
;;; too all the PC offsets.
(defun code-symbols (code core &aux (spacemap (core-spacemap core)))
  (let ((cdf (translate
                  (sb-c::compiled-debug-info-fun-map
                   (truly-the sb-c::compiled-debug-info
                              (translate (%code-debug-info code) spacemap)))
                  spacemap))
        (header-bytes (* (code-header-words code) n-word-bytes))
        (start-pc 0)
        (blobs))
    (loop
      (let* ((name (fun-name-from-core
                    (sb-c::compiled-debug-fun-name
                     (truly-the sb-c::compiled-debug-fun cdf))
                    core))
             (next (when (%instancep (sb-c::compiled-debug-fun-next cdf))
                     (translate (sb-c::compiled-debug-fun-next cdf) spacemap)))
             (end-pc (if next
                         (+ header-bytes (cdf-offset next spacemap))
                         (code-object-size code))))
        (unless (= end-pc start-pc)
          ;; Collapse adjacent address ranges named the same.
          ;; Use EQUALP instead of EQUAL to compare names
          ;; because instances of CORE-SYMBOL are not interned objects.
          (if (and blobs (equalp (caar blobs) name))
              (setf (cddr (car blobs)) end-pc)
              (push (list* name start-pc end-pc) blobs)))
        (if next
            (setq cdf next start-pc end-pc)
            (return))))
    (nreverse blobs)))

(defstruct (descriptor (:constructor make-descriptor (bits)))
  (bits 0 :type word))
(defmethod print-object ((self descriptor) stream)
  (format stream "#<ptr ~x>" (descriptor-bits self)))
(defun descriptorize (obj)
  (if (is-lisp-pointer (get-lisp-obj-address obj))
      (make-descriptor (get-lisp-obj-address obj))
      obj))
(defun undescriptorize (target-descriptor)
  (%make-lisp-obj (descriptor-bits target-descriptor)))

(defun target-hash-table-alist (table spacemap)
  (let ((table (truly-the hash-table (translate table spacemap))))
    (let ((cells (the simple-vector (translate (hash-table-pairs table) spacemap))))
      (collect ((pairs))
        (do ((count (hash-table-%count table) (1- count))
             (i 2 (+ i 2)))
            ((zerop count)
             (pairs))
          (pairs (cons (descriptorize (svref cells i))
                       (descriptorize (svref cells (1+ i))))))))))

(defmacro package-id (name) (sb-impl::package-id (find-package name)))

;;; Return either the physical or logical address of the specified symbol.
(defun %find-target-symbol (package-id symbol-name spacemap
                            &optional (address-mode :physical))
  (dolist (id `(,immobile-fixedobj-core-space-id
                ,static-core-space-id
                ,dynamic-core-space-id))
    (binding* ((space (get-space id spacemap) :exit-if-null)
               (start (translate-ptr (space-addr space) spacemap))
               (end (+ start (space-size space)))
               (physaddr start))
     (loop
       (when (>= physaddr end) (return))
       (let* ((word (sap-ref-word (int-sap physaddr) 0))
              (size
               (if (= (logand word widetag-mask) filler-widetag)
                   (ash (ash word -32) word-shift)
                   (let ((obj (reconstitute-object (ash physaddr (- n-fixnum-tag-bits)))))
                     (when (and (symbolp obj)
                                (string= symbol-name (translate (symbol-name obj) spacemap))
                                (= (symbol-package-id obj) package-id))
                       (return-from %find-target-symbol
                         (%make-lisp-obj
                          (logior (ecase address-mode
                                    (:physical physaddr)
                                    (:logical (+ (space-addr space) (- physaddr start))))
                                  other-pointer-lowtag))))
                     (primitive-object-size obj)))))
         (incf physaddr size))))))
(defun find-target-symbol (package-id symbol-name spacemap &optional (address-mode :physical))
  (or (%find-target-symbol package-id symbol-name spacemap address-mode)
      (bug "Can't find symbol ~A::~A" package-id symbol-name)))

(defparameter label-prefix (if (member :darwin *features*) "_" ""))
(defun labelize (x) (concatenate 'string label-prefix x))

(defun compute-linkage-symbols (spacemap)
  (let* ((linkage-info (symbol-global-value
                        (find-target-symbol (package-id "SB-SYS") "*LINKAGE-INFO*"
                                            spacemap :physical)))
         (hashtable (car (translate linkage-info spacemap)))
         (pairs (target-hash-table-alist hashtable spacemap))
         (min (reduce #'min pairs :key #'cdr))
         (max (reduce #'max pairs :key #'cdr))
         (n (1+ (- max min)))
         (vector (make-array n)))
    (dolist (entry pairs vector)
      (let* ((key (undescriptorize (car entry)))
             (entry-index (- (cdr entry) min))
             (string (labelize (translate (if (consp key) (car (translate key spacemap)) key)
                                          spacemap))))
        (setf (aref vector entry-index)
              (if (consp key) (list string) string))))))

(defconstant inst-call (find-inst #b11101000 (get-inst-space)))
(defconstant inst-jmp (find-inst #b11101001 (get-inst-space)))
(defconstant inst-jmpz (find-inst #x840f (get-inst-space)))
(defconstant inst-pop (find-inst #x5d (get-inst-space)))
(defconstant inst-mov (find-inst #x8B (get-inst-space)))
(defconstant inst-lea (find-inst #x8D (get-inst-space)))

(defun make-core (spacemap code-bounds fixedobj-bounds &optional enable-pie)
  (let* ((linkage-bounds
          (let ((text-space (get-space immobile-text-core-space-id spacemap)))
            (if text-space
                (let ((text-addr (space-addr text-space)))
                  (make-bounds (- text-addr alien-linkage-table-space-size) text-addr))
                (make-bounds 0 0))))
         (linkage-entry-size
          (symbol-global-value
           (find-target-symbol (package-id "SB-VM") "ALIEN-LINKAGE-TABLE-ENTRY-SIZE"
                               spacemap :physical)))
         (linkage-symbols (compute-linkage-symbols spacemap))
         (nil-object (compute-nil-object spacemap))
         (ambiguous-symbols (make-hash-table :test 'equal))
         (core
          (%make-core
           :spacemap spacemap
           :nil-object nil-object
           :nonunique-symbol-names ambiguous-symbols
           :code-bounds code-bounds
           :fixedobj-bounds fixedobj-bounds
           :linkage-bounds linkage-bounds
           :linkage-entry-size linkage-entry-size
           :linkage-symbols linkage-symbols
           :linkage-symbol-usedp (make-array (length linkage-symbols) :element-type 'bit
                                             :initial-element 0)
           :enable-pie enable-pie)))
    (let ((package-table
           (symbol-global-value
            (find-target-symbol (package-id "SB-IMPL") "*ALL-PACKAGES*" spacemap :physical)))
          (package-alist)
          (symbols (make-hash-table :test 'equal)))
      (labels ((scan-symtbl (table)
                 (scan-symbol-hashset
                    (lambda (str sym)
                      (pushnew (get-lisp-obj-address sym) (gethash str symbols)))
                    table core))
               (scan-package (x)
                 (let ((package (truly-the package (translate x spacemap))))
                   ;; a package can appear in *ALL-PACKAGES* under each of its nicknames
                   (unless (assoc (sb-impl::package-id package) package-alist)
                     (push (cons (sb-impl::package-id package) package) package-alist)
                     (scan-symtbl (package-external-symbols package))
                     (scan-symtbl (package-internal-symbols package))))))
        (dovector (x (translate package-table spacemap))
          (cond ((%instancep x) (scan-package x))
                ((listp x) (loop (if (eq x nil-object) (return))
                                 (setq x (translate x spacemap))
                                 (scan-package (car x))
                                 (setq x (cdr x)))))))
      (let ((package-by-id (make-array (1+ (reduce #'max package-alist :key #'car))
                                       :initial-element nil)))
        (loop for (id . package) in package-alist
              do (setf (aref package-by-id id) package))
        (setf (core-pkg-id->package core) package-by-id))
      (dohash ((string symbols) symbols)
        (when (cdr symbols)
          (setf (gethash string ambiguous-symbols) t))))
    core))

;;; Emit .byte or .quad directives dumping memory from SAP for COUNT units
;;; (bytes or qwords) to STREAM.  SIZE specifies which direcive to emit.
;;; EXCEPTIONS specify offsets at which a specific string should be
;;; written to the file in lieu of memory contents, useful for emitting
;;; expressions involving the assembler '.' symbol (the current PC).
(defun emit-asm-directives (size sap count stream &optional exceptions)
  (declare (optimize speed))
  (declare (stream stream))
  (let ((*print-base* 16)
        (string-buffer (make-array 18 :element-type 'base-char))
        (fmt #.(coerce "0x%lx" 'base-string))
        (per-line 0))
    (declare ((integer 0 32) per-line)
             (fixnum count))
    string-buffer fmt
    (ecase size
      (:qword
       (format stream " .quad")
       (dotimes (i count)
         (declare ((unsigned-byte 20) i))
         (declare (simple-vector exceptions))
         (write-char (if (> per-line 0) #\, #\space) stream)
         (acond ((and (< i (length exceptions)) (aref exceptions i))
                 (write-string it stream))
                (t
                 (write-string "0x" stream)
                 (write (sap-ref-word sap (* i n-word-bytes)) :stream stream)))
         (when (and (= (incf per-line) 16) (< (1+ i) count))
           (format stream "~% .quad")
           (setq per-line 0))))
      (:byte
       (aver (not exceptions))
       (format stream " .byte")
       (dotimes (i count)
         (write-char (if (> per-line 0) #\, #\space) stream)
         (write-string "0x" stream)
         (write (sap-ref-8 sap i) :stream stream)
         (when (and (= (incf per-line) 32) (< (1+ i) count))
           (format stream "~% .byte")
           (setq per-line 0))))))
  (terpri stream))

(defun code-fixup-locs (code spacemap)
  (let ((locs (sb-vm::%code-fixups code)))
    ;; Return only the absolute fixups
    ;; Ensure that a bignum LOCS is translated before using it.
    (values (sb-c::unpack-code-fixup-locs
             (if (fixnump locs) locs (translate locs spacemap))))))

;;; Disassemble the function pointed to by SAP for LENGTH bytes, returning
;;; all instructions that should be emitted using assembly language
;;; instead of .quad and/or .byte directives.
;;; This includes (at least) two categories of instructions:
;;; - function prologue instructions that setup the call frame
;;; - jmp/call instructions that transfer control to the fixedoj space
;;;    delimited by bounds in STATE.
;;; At execution time the function will have virtual address LOAD-ADDR.
(defun list-textual-instructions (sap length core load-addr emit-cfi)
  (let ((dstate (core-dstate core))
        (seg (core-seg core))
        (next-fixup-addr
         (or (car (core-fixup-addrs core)) most-positive-word))
        (list))
    (setf (seg-virtual-location seg) load-addr
          (seg-length seg) length
          (seg-sap-maker seg) (lambda () sap))
    ;; KLUDGE: "8f 45 08" is the standard prologue
    (when (and emit-cfi (= (logand (sap-ref-32 sap 0) #xFFFFFF) #x08458f))
      (push (list* 0 3 "pop" "8(%rbp)") list))
    (map-segment-instructions
     (lambda (dchunk inst)
       (cond
         ((< next-fixup-addr (dstate-next-addr dstate))
          (let ((operand (sap-ref-32 sap (- next-fixup-addr load-addr)))
                (offs (dstate-cur-offs dstate)))
            (when (in-bounds-p operand (core-code-bounds core))
              (cond
                ((and (eq (inst-name inst) 'mov) ; match "mov eax, imm32"
                      (eql (sap-ref-8 sap offs) #xB8))
                 (let ((text (format nil "mov $(CS+0x~x),%eax"
                                      (- operand (bounds-low (core-code-bounds core))))))
                   (push (list* (dstate-cur-offs dstate) 5 "mov" text) list)))
                ((and (eq (inst-name inst) 'mov) ; match "mov qword ptr [R+disp8], imm32"
                      (member (sap-ref-8 sap (1- offs)) '(#x48 #x49)) ; REX.w and maybe REX.b
                      (eql (sap-ref-8 sap offs)         #xC7)
                      ;; modRegRm = #b01 #b000 #b___
                      (eql (logand (sap-ref-8 sap (1+ offs)) #o370) #o100))
                 (let* ((reg (ldb (byte 3 0) (sap-ref-8 sap (1+ offs))))
                        (text (format nil "movq $(CS+0x~x),~d(%~a)"
                                      (- operand (bounds-low (core-code-bounds core)))
                                      (signed-sap-ref-8 sap (+ offs 2))
                                      (reg-name (get-gpr :qword reg)))))
                   (push (list* (1- (dstate-cur-offs dstate)) 8 "mov" text) list)))
                ((let ((bytes (ldb (byte 24 0) (sap-ref-32 sap offs))))
                   (or (and (eq (inst-name inst) 'call) ; match "{call,jmp} qword ptr [addr]"
                            (eql bytes #x2514FF)) ; ModRM+SIB encodes disp32, no base, no index
                       (and (eq (inst-name inst) 'jmp)
                            (eql bytes #x2524FF))))
                 (let ((new-opcode (ecase (sap-ref-8 sap (1+ offs))
                                     (#x14 "call *")
                                     (#x24 "jmp *"))))
                   ;; This instruction form is employed for asm routines when
                   ;; compile-to-memory-space is :AUTO.  If the code were to be loaded
                   ;; into dynamic space, the offset to the called routine isn't
                   ;; a (signed-byte 32), so we need the indirection.
                   (push (list* (dstate-cur-offs dstate) 7 new-opcode operand) list)))
                (t
                 (bug "Can't reverse-engineer fixup: ~s ~x"
                      (inst-name inst) (sap-ref-64 sap offs))))))
          (pop (core-fixup-addrs core))
          (setq next-fixup-addr (or (car (core-fixup-addrs core)) most-positive-word)))
         ((or (eq inst inst-jmp) (eq inst inst-call))
          (let ((target-addr (+ (near-jump-displacement dchunk dstate)
                                (dstate-next-addr dstate))))
            (when (or (in-bounds-p target-addr (core-fixedobj-bounds core))
                      (in-bounds-p target-addr (core-linkage-bounds core)))
              (push (list* (dstate-cur-offs dstate)
                           5 ; length
                           (if (eq inst inst-call) "call" "jmp")
                           target-addr)
                    list))))
         ((eq inst inst-jmpz)
          (let ((target-addr (+ (near-cond-jump-displacement dchunk dstate)
                                (dstate-next-addr dstate))))
            (when (in-bounds-p target-addr (core-linkage-bounds core))
              (push (list* (dstate-cur-offs dstate) 6 "je" target-addr)
                    list))))
         ((and (or (and (eq inst inst-mov)
                        (eql (sap-ref-8 sap (dstate-cur-offs dstate)) #x8B))
                   (eq inst inst-lea))
                (let ((modrm (sap-ref-8 sap (1+ (dstate-cur-offs dstate)))))
                  (= (logand modrm #b11000111) #b00000101)) ; RIP-relative mode
                (in-bounds-p (+ (signed-sap-ref-32 sap (+ (dstate-cur-offs dstate) 2))
                                (dstate-next-addr dstate))
                             (core-linkage-bounds core)))
          (let* ((abs-addr (+ (signed-sap-ref-32 sap (+ (dstate-cur-offs dstate) 2))
                              (dstate-next-addr dstate)))
                 (reg (logior (ldb (byte 3 3) (sap-ref-8 sap (1+ (dstate-cur-offs dstate))))
                              (if (logtest (sb-disassem::dstate-inst-properties dstate)
                                           #b0100) ; REX.r
                                  8 0)))
                 (op (if (eq inst inst-lea) "lea" "mov-gotpcrel"))
                 (args (list abs-addr (reg-name (get-gpr :qword reg)))))
            (push (list* (1- (dstate-cur-offs dstate)) 7 op args) list)))
         ((and (eq inst inst-pop) (eq (logand dchunk #xFF) #x5D))
          (push (list* (dstate-cur-offs dstate) 1 "pop" "%rbp") list))))
     seg
     dstate
     nil)
    (nreverse list)))

;;; Using assembler directives and/or real mnemonics, dump COUNT bytes
;;; of memory at PADDR (physical addr) to STREAM.
;;; The function's address as per the core file is VADDR.
;;; (Its eventual address is indeterminate)
;;; If EMIT-CFI is true, then also emit cfi directives.
;;;
;;; Notice that we can use one fewer cfi directive than usual because
;;; Lisp always carries a frame pointer as set up by the caller.
;;;
;;; C convention
;;; ============
;;; pushq %rbp
;;; .cfi_def_cfa_offset 16   # CFA offset from default register (rsp) is +16
;;; .cfi_offset 6, -16       # old rbp was saved in -16(CFA)
;;; movq %rsp, %rbp
;;; .cfi_def_cfa_register 6  # use rbp as CFA register
;;;
;;; Lisp convention
;;; ===============
;;; popq 8(%rbp) # place saved %rip in its ABI-compatible stack slot
;;;              # making RSP = RBP after the pop, and RBP = CFA - 16
;;; .cfi_def_cfa 6, 16
;;; .cfi_offset 6, -16
;;;
;;; Of course there is a flip-side to this: unwinders think that the new frame
;;; is already begun in the caller. Interruption between these two instructions:
;;;   MOV RBP, RSP / CALL #xzzzzz
;;; will show the backtrace as if two invocations of the caller are on stack.
;;; This is tricky to fix because while we can relativize the CFA to the
;;; known frame size, we can't do that based only on a disassembly.

;;; Return the list of locations which must be added to code-fixups
;;; in the event that heap relocation occurs on image restart.
(defun emit-lisp-function (paddr vaddr count stream emit-cfi core &optional labels)
  (when emit-cfi
    (format stream " .cfi_startproc~%"))
  ;; Any byte offset that appears as a key in the INSTRUCTIONS causes the indicated
  ;; bytes to be written as an assembly language instruction rather than opaquely,
  ;; thereby affecting the ELF data (cfi or relocs) produced.
  (let ((instructions
         (merge 'list labels
                (list-textual-instructions (int-sap paddr) count core vaddr emit-cfi)
                #'< :key #'car))
        (extra-fixup-locs)
        (ptr paddr))
    (symbol-macrolet ((cur-offset (- ptr paddr)))
      (loop
        (let ((until (if instructions (caar instructions) count)))
          ;; if we're not aligned, then write some number of bytes
          ;; to cause alignment. But do not write past the next offset
          ;; that needs to be written as an instruction.
          (when (logtest ptr #x7) ; unaligned
            (let ((n (min (- (nth-value 1 (ceiling ptr 8)))
                          (- until cur-offset))))
              (aver (<= 0 n 7))
              (emit-asm-directives :byte (int-sap ptr) n stream)
              (incf ptr n)))
          ;; Now we're either aligned to a multiple of 8, or the current
          ;; offset needs to be written as a textual instruction.
          (let ((n (- until cur-offset)))
            (aver (>= n 0))
            (multiple-value-bind (qwords remainder) (floor n 8)
              (when (plusp qwords)
                (emit-asm-directives :qword (int-sap ptr) qwords stream #())
                (incf ptr (* qwords 8)))
              (when (plusp remainder)
                (emit-asm-directives :byte (int-sap ptr) remainder stream)
                (incf ptr remainder))))
          ;; If the current offset is COUNT, we're done.
          (when (= cur-offset count) (return))
          (aver (= cur-offset until))
          ;; A label and a textual instruction could co-occur.
          ;; If so, the label must be emitted first.
          (when (eq (cadar instructions) :label)
            (destructuring-bind (c-symbol globalp) (cddr (pop instructions))
              ;; The C symbol is global only if the Lisp name is a legal function
              ;; designator and not random noise.
              ;; This is a technique to try to avoid appending a uniquifying suffix
              ;; on all the junky internal things like "(lambda # in srcfile.lisp)"
              (when emit-cfi
                (format stream "~:[~; .globl ~a~:*~%~] .type ~a, @function~%"
                        globalp c-symbol))
              (format stream "~a:~%" c-symbol)))
          ;; If both a label and textual instruction occur here, handle the latter.
          ;; [This could could be simpler if all labels were emitted as
          ;; '.set "thing", .+const' together in a single place, but it's more readable
          ;; to see them where they belong in the instruction stream]
          (when (and instructions (= (caar instructions) cur-offset))
            (destructuring-bind (length opcode . operand) (cdr (pop instructions))
              (when (cond ((member opcode '("jmp" "je" "call") :test #'string=)
                           (when (in-bounds-p operand (core-linkage-bounds core))
                             (let ((entry-index
                                    (/ (- operand (bounds-low (core-linkage-bounds core)))
                                       (core-linkage-entry-size core))))
                               (setf (bit (core-linkage-symbol-usedp core) entry-index) 1
                                     operand (aref (core-linkage-symbols core) entry-index))))
                           (when (and (integerp operand)
                                      (in-bounds-p operand (core-fixedobj-bounds core)))
                             (push (+ vaddr cur-offset) extra-fixup-locs))
                           (format stream " ~A ~:[0x~X~;~a~:[~;@PLT~]~]~%"
                                   opcode (stringp operand) operand
                                   (core-enable-pie core)))
                          ((string= opcode "mov-gotpcrel")
                           (let* ((entry-index
                                   (/ (- (car operand) (bounds-low (core-linkage-bounds core)))
                                      (core-linkage-entry-size core)))
                                  (c-symbol (car (aref (core-linkage-symbols core) entry-index))))
                             (setf (bit (core-linkage-symbol-usedp core) entry-index) 1)
                             (format stream " mov ~A@GOTPCREL(%rip), %~(~A~)~%" c-symbol (cadr operand))))
                          ((string= opcode "lea") ; lea becomes "mov" with gotpcrel as src, which becomes lea
                           (let* ((entry-index
                                   (/ (- (car operand) (bounds-low (core-linkage-bounds core)))
                                      (core-linkage-entry-size core)))
                                  (c-symbol (aref (core-linkage-symbols core) entry-index)))
                             (setf (bit (core-linkage-symbol-usedp core) entry-index) 1)
                             (format stream " mov ~A@GOTPCREL(%rip), %~(~A~)~%" c-symbol (cadr operand))))
                          ((string= opcode "pop")
                           (format stream " ~A ~A~%" opcode operand)
                           (cond ((string= operand "8(%rbp)")
                                  (format stream " .cfi_def_cfa 6, 16~% .cfi_offset 6, -16~%"))
                                 ((string= operand "%rbp")
                                        ;(format stream " .cfi_def_cfa 7, 8~%")
                                  nil)
                                 (t)))
                          ((string= opcode "mov")
                           ;; the so-called "operand" is the entire instruction
                           (write-string operand stream)
                           (terpri stream))
                          ((or (string= opcode "call *") (string= opcode "jmp *"))
                           ;; Indirect call - since the code is in immobile space,
                           ;; we could render this as a 2-byte NOP followed by a direct
                           ;; call. For simplicity I'm leaving it exactly as it was.
                           (format stream " ~A(CS+0x~x)~%"
                                   opcode ; contains a "*" as needed for the syntax
                                   (- operand (bounds-low (core-code-bounds core)))))
                          (t))
                (bug "Random annotated opcode ~S" opcode))
              (incf ptr length)))
          (when (= cur-offset count) (return)))))
    (when emit-cfi
      (format stream " .cfi_endproc~%"))
    extra-fixup-locs))

;;; Examine CODE, returning a list of lists describing how to emit
;;; the contents into the assembly file.
;;;   ({:data | :padding} . N) | (start-pc . end-pc)
(defun get-text-ranges (code spacemap)
    (let ((cdf (translate (sb-c::compiled-debug-info-fun-map
                           (truly-the sb-c::compiled-debug-info
                                      (translate (%code-debug-info code) spacemap)))
                          spacemap))
          (next-simple-fun-pc-offs (%code-fun-offset code 0))
          (start-pc (code-n-unboxed-data-bytes code))
          (simple-fun-index -1)
          (simple-fun)
          (blobs))
      (when (plusp start-pc)
        (aver (zerop (rem start-pc n-word-bytes)))
        (push `(:data . ,(ash start-pc (- word-shift))) blobs))
      (loop
        (let* ((next (when (%instancep (sb-c::compiled-debug-fun-next
                                        (truly-the sb-c::compiled-debug-fun cdf)))
                       (translate (sb-c::compiled-debug-fun-next
                                   (truly-the sb-c::compiled-debug-fun cdf))
                                  spacemap)))
               (end-pc (if next
                           (cdf-offset next spacemap)
                           (%code-text-size code))))
          (cond
            ((= start-pc end-pc)) ; crazy shiat. do not add to blobs
            ((<= start-pc next-simple-fun-pc-offs (1- end-pc))
             (incf simple-fun-index)
             (setq simple-fun (%code-entry-point code simple-fun-index))
             (let ((padding (- next-simple-fun-pc-offs start-pc)))
               (when (plusp padding)
                 ;; Assert that SIMPLE-FUN always begins at an entry
                 ;; in the fun-map, and not somewhere in the middle:
                 ;;   |<--  fun  -->|<--  fun  -->|
                 ;;   ^- start (GOOD)      ^- alleged start (BAD)
                 (cond ((eq simple-fun (%code-entry-point code 0))
                        (bug "Misaligned fun start"))
                       (t ; sanity-check the length of the filler
                        (aver (< padding (* 2 n-word-bytes)))))
                 (push `(:pad . ,padding) blobs)
                 (incf start-pc padding)))
             (push `(,start-pc . ,end-pc) blobs)
             (setq next-simple-fun-pc-offs
                   (if (< (1+ simple-fun-index ) (code-n-entries code))
                       (%code-fun-offset code (1+ simple-fun-index))
                       -1)))
            (t
             (let ((current-blob (car blobs)))
               (setf (cdr current-blob) end-pc)))) ; extend this blob
          (unless next
            (return (nreverse blobs)))
          (setq cdf next start-pc end-pc)))))

(defun c-symbol-quote (name)
  (concatenate 'string '(#\") name '(#\")))

(defun emit-symbols (blobs core pp-state output &aux base-symbol)
  (dolist (blob blobs base-symbol)
    (destructuring-bind (name start . end) blob
      (let ((c-name (c-name (or name "anonymous") core pp-state)))
        (unless base-symbol
          (setq base-symbol c-name))
        (format output " lsym \"~a\", 0x~x, 0x~x~%"
                c-name start (- end start))))))

(defun emit-funs (code vaddr core dumpwords output base-symbol emit-cfi)
  (let* ((spacemap (core-spacemap core))
         (ranges (get-text-ranges code spacemap))
         (text-sap (code-instructions code))
         (text (sap-int text-sap))
         ;; Like CODE-INSTRUCTIONS, but where the text virtually was
         (text-vaddr (+ vaddr (* (code-header-words code) n-word-bytes)))
         (additional-relative-fixups)
         (max-end 0))
    ;; There is *always* at least 1 word of unboxed data now
    (aver (eq (caar ranges) :data))
    (let ((jump-table-size (code-jump-table-words code))
          (total-nwords (cdr (pop ranges))))
      (cond ((> jump-table-size 1)
             (format output "# jump table~%")
             (format output ".quad ~d" (sap-ref-word text-sap 0))
             (dotimes (i (1- jump-table-size))
               (format output ",\"~a\"+0x~x"
                       base-symbol
                       (- (sap-ref-word text-sap (ash (1+ i) word-shift))
                          vaddr)))
             (terpri output)
             (let ((remaining (- total-nwords jump-table-size)))
               (when (plusp remaining)
                 (funcall dumpwords
                          (sap+ text-sap (ash jump-table-size word-shift))
                          remaining output))))
            (t
             (funcall dumpwords text-sap total-nwords output))))
    (loop
      (destructuring-bind (start . end) (pop ranges)
        (setq max-end end)
        ;; FIXME: it seems like this should just be reduced to emitting 2 words
        ;; now that simple-fun headers don't hold any boxed words.
        ;; (generality here is without merit)
        (funcall dumpwords (sap+ text-sap start) simple-fun-insts-offset output
                 #(nil #.(format nil ".+~D" (* (1- simple-fun-insts-offset)
                                             n-word-bytes))))
        (incf start (* simple-fun-insts-offset n-word-bytes))
        ;; Pass the current physical address at which to disassemble,
        ;; the notional core address (which changes after linker relocation),
        ;; and the length.
        (let ((new-relative-fixups
               (emit-lisp-function (+ text start) (+ text-vaddr start) (- end start)
                                   output emit-cfi core)))
          (setq additional-relative-fixups
                (nconc new-relative-fixups additional-relative-fixups)))
        (cond ((not ranges) (return))
              ((eq (caar ranges) :pad)
               (format output " .byte ~{0x~x~^,~}~%"
                       (loop for i from 0 below (cdr (pop ranges))
                             collect (sap-ref-8 text-sap (+ end i))))))))
    ;; All fixups should have been consumed by writing out the text.
    (aver (null (core-fixup-addrs core)))
    ;; Emit bytes from the maximum function end to the object end.
    ;; We can't just round up %CODE-CODE-SIZE to a double-lispword
    ;; because the boxed header could end at an odd word, requiring that
    ;; the unboxed bytes have an odd size in words making the total even.
    (format output " .byte ~{0x~x~^,~}~%"
            (loop for i from max-end
                  below (- (code-object-size code)
                           (* (code-header-words code) n-word-bytes))
                  collect (sap-ref-8 text-sap i)))
    (when additional-relative-fixups
      (binding* ((existing-fixups (sb-vm::%code-fixups code))
                 ((absolute relative immediate)
                  (sb-c::unpack-code-fixup-locs
                   (if (fixnump existing-fixups)
                       existing-fixups
                       (translate existing-fixups spacemap))))
                 (new-sorted
                  (sort (mapcar (lambda (x)
                                  ;; compute offset of the fixup from CODE-INSTRUCTIONS.
                                  ;; X is the location of the CALL instruction,
                                  ;; 1+ is the location of the fixup.
                                  (- (1+ x)
                                     (+ vaddr (ash (code-header-words code)
                                                   word-shift))))
                                additional-relative-fixups)
                        #'<)))
        (sb-c:pack-code-fixup-locs
         absolute (merge 'list relative new-sorted #'<) immediate)))))

(defconstant +gf-name-slot+ 5)

(defun output-bignum (label bignum stream)
  (let ((nwords (sb-bignum:%bignum-length bignum)))
    (format stream "~@[~a:~] .quad 0x~x"
            label (logior (ash nwords 8) bignum-widetag))
    (dotimes (i nwords)
      (format stream ",0x~x" (sb-bignum:%bignum-ref bignum i)))
    (when (evenp nwords) ; pad
      (format stream ",0"))
    (format stream "~%")))

(defun write-preamble (output)
  (format output " .text~% .file \"sbcl.core\"
~:[~; .macro .size sym size # ignore
 .endm
 .macro .type sym type # ignore
 .endm~]
 .macro lasmsym name size
 .set \"\\name\", .
 .size \"\\name\", \\size
 .type \"\\name\", function
 .endm
 .macro lsym name start size
 .set \"\\name\", . + \\start
 .size \"\\name\", \\size
 .type \"\\name\", function
 .endm
 .globl ~alisp_code_start, ~alisp_jit_code, ~alisp_code_end
 .balign 4096~%~alisp_code_start:~%CS: # code space~%"
          (member :darwin *features*)
          label-prefix label-prefix label-prefix label-prefix))

(defun %widetag-of (word) (logand word widetag-mask))

(defun make-code-obj (addr spacemap)
  (let ((translation (translate-ptr addr spacemap)))
    (aver (= (%widetag-of (sap-ref-word (int-sap translation) 0))
             code-header-widetag))
    (%make-lisp-obj (logior translation other-pointer-lowtag))))

(defun output-lisp-asm-routines (core spacemap code-addr output &aux (skip 0))
  (write-preamble output)
  (dotimes (i 2)
    (let* ((paddr (int-sap (translate-ptr code-addr spacemap)))
           (word (sap-ref-word paddr 0)))
      ;; After running the converter which moves dynamic-space code to text space,
      ;; the text space starts with an array of uint32 for the offsets to each object
      ;; and an array of uint64 containing some JMP instructions.
      (unless (or (= (%widetag-of word) simple-array-unsigned-byte-32-widetag)
                  (= (%widetag-of word) simple-array-unsigned-byte-64-widetag))
        (return))
      (let* ((array (%make-lisp-obj (logior (sap-int paddr) other-pointer-lowtag)))
             (size (primitive-object-size array))
             (nwords (ash size (- word-shift))))
        (dotimes (i nwords)
          (format output "~A 0x~x"
                  (case (mod i 8)
                    (0 #.(format nil "~% .quad"))
                    (t ","))
                  (sap-ref-word paddr (ash i word-shift))))
        (terpri output)
        (incf skip size)
        (incf code-addr size))))
  (let* ((code-component (make-code-obj code-addr spacemap))
         (obj-sap (int-sap (- (get-lisp-obj-address code-component)
                              other-pointer-lowtag)))
         (header-len (code-header-words code-component))
         (jump-table-count (sap-ref-word (code-instructions code-component) 0)))
    ;; Write the code component header
    (format output "lar: # lisp assembly routines~%")
    (emit-asm-directives :qword obj-sap header-len output #())
    ;; Write the jump table
    (format output " .quad ~D" jump-table-count)
    (dotimes (i (1- jump-table-count))
      (format output ",lar+0x~x"
              (- (sap-ref-word (code-instructions code-component)
                               (ash (1+ i) word-shift))
                 code-addr)))
    (terpri output)
    (let ((name->addr
           ;; the CDR of each alist item is a target cons (needing translation)
           (sort
            (mapcar (lambda (entry &aux (name (translate (undescriptorize (car entry)) spacemap)) ; symbol
                                   ;; VAL is (start end . index)
                                   (val (translate (undescriptorize (cdr entry)) spacemap))
                                   (start (car val))
                                   (end (car (translate (cdr val) spacemap))))
                      (list* (translate (symbol-name name) spacemap) start end))
                    (target-hash-table-alist (%code-debug-info code-component) spacemap))
            #'< :key #'cadr)))
      ;; Possibly unboxed words and/or padding
      (let ((here (ash jump-table-count word-shift))
            (first-entry-point (cadar name->addr)))
        (when (> first-entry-point here)
          (format output " .quad ~{0x~x~^,~}~%"
                  (loop for offs = here then (+ offs 8)
                        while (< offs first-entry-point)
                        collect (sap-ref-word (code-instructions code-component) offs)))))
      ;; Loop over the embedded routines
      (let ((list name->addr)
            (obj-size (code-object-size code-component)))
        (loop
          (destructuring-bind (name start-offs . end-offs) (pop list)
            (let ((nbytes (- (if (endp list)
                                 (- obj-size (* header-len n-word-bytes))
                                 (1+ end-offs))
                             start-offs)))
              (format output " lasmsym ~(\"~a\"~), ~d~%" name nbytes)
              (let ((fixups
                     (emit-lisp-function
                      (+ (sap-int (code-instructions code-component))
                         start-offs)
                      (+ code-addr
                         (ash (code-header-words code-component) word-shift)
                         start-offs)
                      nbytes output nil core)))
                (aver (null fixups)))))
          (when (endp list) (return)))
        (format output "~%# end of lisp asm routines~2%")
        (+ skip obj-size)))))

;;; Convert immobile text space to an assembly file in OUTPUT.
(defun write-assembler-text
    (spacemap output
     &optional enable-pie (emit-cfi t)
     &aux (code-bounds (space-bounds immobile-text-core-space-id spacemap))
          (fixedobj-bounds (space-bounds immobile-fixedobj-core-space-id spacemap))
          (core (make-core spacemap code-bounds fixedobj-bounds enable-pie))
          (code-addr (bounds-low code-bounds))
          (total-code-size 0)
          (pp-state (cons (make-hash-table :test 'equal) nil))
          (prev-namestring "")
          (n-linker-relocs 0)
          (temp-output (make-string-output-stream :element-type 'base-char))
          end-loc)
  (labels ((dumpwords (sap count stream &optional (exceptions #()) logical-addr)
             (aver (sap>= sap (car spacemap)))
             ;; Add any new "header exceptions" that cause intra-code-space pointers
             ;; to be computed at link time
             (dotimes (i (if logical-addr count 0))
               (unless (and (< i (length exceptions)) (svref exceptions i))
                 (let ((word (sap-ref-word sap (* i n-word-bytes))))
                   (when (and (= (logand word 3) 3) ; is a pointer
                              (in-bounds-p word code-bounds)) ; to code space
                     #+nil
                     (format t "~&~(~x: ~x~)~%" (+ logical-addr  (* i n-word-bytes))
                             word)
                     (incf n-linker-relocs)
                     (setf exceptions (adjust-array exceptions (max (length exceptions) (1+ i))
                                                    :initial-element nil)
                           (svref exceptions i)
                           (format nil "CS+0x~x"
                                   (- word (bounds-low code-bounds))))))))
             (emit-asm-directives :qword sap count stream exceptions)))

    (let ((skip (output-lisp-asm-routines core spacemap code-addr output)))
      (incf code-addr skip)
      (incf total-code-size skip))

    (loop
      (when (>= code-addr (bounds-high code-bounds))
        (setq end-loc code-addr)
        (return))
      (ecase (%widetag-of (sap-ref-word (int-sap (translate-ptr code-addr spacemap)) 0))
        (#.code-header-widetag
         (let* ((code (make-code-obj code-addr spacemap))
                (objsize (code-object-size code)))
           (incf total-code-size objsize)
           (cond
             ((%instancep (%code-debug-info code)) ; assume it's a COMPILED-DEBUG-INFO
              (aver (plusp (code-n-entries code)))
              (let* ((source
                      (sb-c::compiled-debug-info-source
                       (truly-the sb-c::compiled-debug-info
                                  (translate (%code-debug-info code) spacemap))))
                     (namestring
                      (debug-source-namestring
                       (truly-the sb-c::debug-source (translate source spacemap)))))
                (setq namestring (if (eq namestring (core-nil-object core))
                                     "sbcl.core"
                                     (translate namestring spacemap)))
                (unless (string= namestring prev-namestring)
                  (format output " .file \"~a\"~%" namestring)
                  (setq prev-namestring namestring)))
              (setf (core-fixup-addrs core)
                    (mapcar (lambda (x)
                              (+ code-addr (ash (code-header-words code) word-shift) x))
                            (code-fixup-locs code spacemap)))
              (let ((code-physaddr (logandc2 (get-lisp-obj-address code) lowtag-mask)))
                (format output "#x~x:~%" code-addr)
                ;; Emit symbols before the code header data, because the symbols
                ;; refer to "." (the current PC) which is the base of the object.
                (let* ((base (emit-symbols (code-symbols code core) core pp-state output))
                       (altered-fixups
                        (emit-funs code code-addr core #'dumpwords temp-output base emit-cfi))
                       (header-exceptions (vector nil nil nil nil))
                       (fixups-ptr))
                  (when altered-fixups
                    (setf (aref header-exceptions sb-vm:code-fixups-slot)
                          (cond ((fixnump altered-fixups)
                                 (format nil "0x~x" (ash altered-fixups n-fixnum-tag-bits)))
                                (t
                                 (let ((ht (core-new-fixups core)))
                                   (setq fixups-ptr (gethash altered-fixups ht))
                                   (unless fixups-ptr
                                     (setq fixups-ptr (ash (core-new-fixup-words-used core)
                                                           word-shift))
                                     (setf (gethash altered-fixups ht) fixups-ptr)
                                     (incf (core-new-fixup-words-used core)
                                           (align-up (1+ (sb-bignum:%bignum-length altered-fixups)) 2))))
                                 ;; tag the pointer properly for a bignum
                                 (format nil "lisp_fixups+0x~x"
                                         (logior fixups-ptr other-pointer-lowtag))))))
                  (dumpwords (int-sap code-physaddr)
                             (code-header-words code) output header-exceptions code-addr)
                  (write-string (get-output-stream-string temp-output) output))))
             (t
              (error "Strange code component: ~S" code)))
           (incf code-addr objsize)))
        (#.filler-widetag
         (let* ((word (sap-ref-word (int-sap (translate-ptr code-addr spacemap)) 0))
                (nwords (ash word -32))
                (nbytes (* nwords n-word-bytes)))
           (format output " .quad 0x~x~% .fill ~d~%" word (- nbytes n-word-bytes))
           (incf code-addr nbytes)))
        ;; This is a trailing array which contains a jump instruction for each
        ;; element of *C-LINKAGE-REDIRECTS* (see "rewrite-asmcalls.lisp").
        (#.simple-array-unsigned-byte-64-widetag
         (let* ((paddr (translate-ptr code-addr spacemap))
                (array (%make-lisp-obj (logior paddr other-pointer-lowtag)))
                (nwords (+ vector-data-offset (align-up (length array) 2))))
           (format output "# alien linkage redirects:~% .quad")
           (dotimes (i nwords (terpri output))
             (format output "~a0x~x" (if (= i 0) " " ",")
                     (sap-ref-word (int-sap paddr) (ash i word-shift))))
           (incf code-addr (ash nwords word-shift))
           (setq end-loc code-addr)
           (return))))))

  ;; coreparse uses the 'lisp_jit_code' symbol to set text_space_highwatermark
  ;; The intent is that compilation to memory can use this reserved area
  ;; (if space remains) so that profilers can associate a C symbol with the
  ;; program counter range. It's better than nothing.
  (format output "~a:~%" (labelize "lisp_jit_code"))

  ;; Pad so that non-lisp code can't be colocated on a GC page.
  ;; (Lack of Lisp object headers in C code is the issue)
  (let ((aligned-end (align-up end-loc 4096)))
    (when (> aligned-end end-loc)
      (multiple-value-bind (nwords remainder)
          (floor (- aligned-end end-loc) n-word-bytes)
        (aver (>= nwords 2))
        (aver (zerop remainder))
        (decf nwords 2)
        (format output " .quad 0x~x, ~d # (simple-array fixnum (~d))~%"
                simple-array-fixnum-widetag
                (ash nwords n-fixnum-tag-bits)
                nwords)
        (when (plusp nwords)
          (format output " .fill ~d~%" (* nwords n-word-bytes))))))
  ;; Extend with 1 MB of filler
  (format output " .fill ~D~%~alisp_code_end:
 .size lisp_jit_code, .-lisp_jit_code~%"
          (* 1024 1024) label-prefix)
  (values core total-code-size n-linker-relocs))

;;;; ELF file I/O

(defconstant +sht-null+     0)
(defconstant +sht-progbits+ 1)
(defconstant +sht-symtab+   2)
(defconstant +sht-strtab+   3)
(defconstant +sht-rela+     4)
(defconstant +sht-rel+      9)

(define-alien-type elf64-ehdr
  (struct elf64-edhr
    (ident     (array unsigned-char 16)) ; 7F 45 4C 46 2 1 1 0 0 0 0 0 0 0 0 0
    (type      (unsigned 16))   ; 1 0
    (machine   (unsigned 16))   ; 3E 0
    (version   (unsigned 32))   ; 1 0 0 0
    (entry     unsigned)        ; 0 0 0 0 0 0 0 0
    (phoff     unsigned)        ; 0 0 0 0 0 0 0 0
    (shoff     unsigned)        ;
    (flags     (unsigned 32))   ; 0 0 0 0
    (ehsize    (unsigned 16))   ; 40 0
    (phentsize (unsigned 16))   ;  0 0
    (phnum     (unsigned 16))   ;  0 0
    (shentsize (unsigned 16))   ; 40 0
    (shnum     (unsigned 16))   ;  n 0
    (shstrndx  (unsigned 16)))) ;  n 0
(defconstant ehdr-size (ceiling (alien-type-bits (parse-alien-type 'elf64-ehdr nil)) 8))
(define-alien-type elf64-shdr
  (struct elf64-shdr
    (name      (unsigned 32))
    (type      (unsigned 32))
    (flags     (unsigned 64))
    (addr      (unsigned 64))
    (off       (unsigned 64))
    (size      (unsigned 64))
    (link      (unsigned 32))
    (info      (unsigned 32))
    (addralign (unsigned 64))
    (entsize   (unsigned 64))))
(defconstant shdr-size (ceiling (alien-type-bits (parse-alien-type 'elf64-shdr nil)) 8))
(define-alien-type elf64-sym
  (struct elf64-sym
    (name  (unsigned 32))
    (info  (unsigned 8))
    (other (unsigned 8))
    (shndx (unsigned 16))
    (value unsigned)
    (size  unsigned)))
(define-alien-type elf64-rela
  (struct elf64-rela
    (offset (unsigned 64))
    (info   (unsigned 64))
    (addend (signed 64))))

(defun make-elf64-sym (name info)
  (let ((a (make-array 24 :element-type '(unsigned-byte 8) :initial-element 0)))
    (with-pinned-objects (a)
      (setf (sap-ref-32 (vector-sap a) 0) name
            (sap-ref-8 (vector-sap a) 4) info))
    a))

;;; Return two values: an octet vector comprising a string table
;;; and an alist which maps string to offset in the table.
(defun string-table (strings)
  (let* ((length (+ (1+ (length strings)) ; one more null than there are strings
                    (reduce #'+ strings :key #'length))) ; data length
         (bytes (make-array length :element-type '(unsigned-byte 8)
                            :initial-element 0))
         (index 1)
         (alist))
    (dolist (string strings)
      (push (cons string index) alist)
      (replace bytes (map 'vector #'char-code string) :start1 index)
      (incf index (1+ (length string))))
    (cons (nreverse alist) bytes)))

(defun write-alien (alien size stream)
  (dotimes (i size)
    (write-byte (sap-ref-8 (alien-value-sap alien) i) stream)))

(defun copy-bytes (in-stream out-stream nbytes
                             &optional (buffer
                                        (make-array 1024 :element-type '(unsigned-byte 8))))
  (loop (let ((chunksize (min (length buffer) nbytes)))
          (aver (eql (read-sequence buffer in-stream :end chunksize) chunksize))
          (write-sequence buffer out-stream :end chunksize)
          (when (zerop (decf nbytes chunksize)) (return)))))

;;; core header should be an array of words in '.rodata', not a 32K page
(defconstant core-header-size +backend-page-bytes+) ; stupidly large (FIXME)

(defun write-elf-header (shdrs-start sections output)
  (let ((shnum (1+ (length sections))) ; section 0 is implied
        (shstrndx (1+ (position :str sections :key #'car)))
        (ident #.(coerce '(#x7F #x45 #x4C #x46 2 1 1 0 0 0 0 0 0 0 0 0)
                         '(array (unsigned-byte 8) 1))))
  (with-alien ((ehdr elf64-ehdr))
    (dotimes (i (ceiling ehdr-size n-word-bytes))
      (setf (sap-ref-word (alien-value-sap ehdr) (* i n-word-bytes)) 0))
    (with-pinned-objects (ident)
      (%byte-blt (vector-sap ident) 0 (alien-value-sap ehdr) 0 16))
    (setf (slot ehdr 'type)      1
          (slot ehdr 'machine)   #x3E
          (slot ehdr 'version)   1
          (slot ehdr 'shoff)     shdrs-start
          (slot ehdr 'ehsize)    ehdr-size
          (slot ehdr 'shentsize) shdr-size
          (slot ehdr 'shnum)     shnum
          (slot ehdr 'shstrndx)  shstrndx)
    (write-alien ehdr ehdr-size output))))

(defun write-section-headers (placements sections string-table output)
  (with-alien ((shdr elf64-shdr))
    (dotimes (i (ceiling shdr-size n-word-bytes)) ; Zero-fill
      (setf (sap-ref-word (alien-value-sap shdr) (* i n-word-bytes)) 0))
    (dotimes (i (1+ (length sections)))
      (when (plusp i) ; Write the zero-filled header as section 0
        (destructuring-bind (name type flags link info alignment entsize)
            (cdr (aref sections (1- i)))
          (destructuring-bind (offset . size)
              (pop placements)
            (setf (slot shdr 'name)  (cdr (assoc name (car string-table)))
                  (slot shdr 'type)  type
                  (slot shdr 'flags) flags
                  (slot shdr 'off)   offset
                  (slot shdr 'size)  size
                  (slot shdr 'link)  link
                  (slot shdr 'info)  info
                  (slot shdr 'addralign) alignment
                  (slot shdr 'entsize) entsize))))
      (write-alien shdr shdr-size output))))

(defconstant core-align 4096)
(defconstant sym-entry-size 24)

;;; Write everything except for the core file itself into OUTPUT-STREAM
;;; and leave the stream padded to a 4K boundary ready to receive data.
(defun prepare-elf (core-size relocs output pie)
  ;; PIE uses coreparse relocs which are 8 bytes each, and no linker relocs.
  ;; Otherwise, linker relocs are 24 bytes each.
  (let* ((reloc-entry-size (if pie 8 24))
         (sections
          ;;        name | type | flags | link | info | alignment | entry size
          `#((:core "lisp.core"       ,+sht-progbits+ 0 0 0 ,core-align 0)
             (:sym  ".symtab"         ,+sht-symtab+   0 3 1 8 ,sym-entry-size)
                          ; section with the strings -- ^ ^ -- 1+ highest local symbol
             (:str  ".strtab"         ,+sht-strtab+   0 0 0 1  0)
             (:rel
              ,@(if pie
              ;; Don't bother with an ELF reloc section; it won't do any good.
              ;; It would apply at executable link time, which is without purpose,
              ;; it just offsets the numbers based on however far the lisp.core
              ;; section is into the physical file. Non-loaded sections don't get
              ;; further relocated on execution, so 'coreparse' has to fix the
              ;; entire dynamic space at execution time anyway.
                  `("lisp.rel"        ,+sht-progbits+ 0 0 0 8 8)
                  `(".relalisp.core"  ,+sht-rela+     0 2 1 8 ,reloc-entry-size)))
                                      ; symbol table -- ^ ^ -- for which section
             (:note ".note.GNU-stack" ,+sht-progbits+ 0 0 0 1  0)))
         (string-table
          (string-table (append '("lisp_code_start") (map 'list #'second sections))))
         (strings (cdr string-table))
         (padded-strings-size (align-up (length strings) 8))
         (symbols-size (* 2 sym-entry-size))
         (shdrs-start (+ ehdr-size symbols-size padded-strings-size))
         (shdrs-end (+ shdrs-start (* (1+ (length sections)) shdr-size)))
         (relocs-size (* (length relocs) reloc-entry-size))
         (relocs-end (+ shdrs-end relocs-size))
         (core-start (align-up relocs-end core-align)))

    (write-elf-header shdrs-start sections output)

    ;; Write symbol table
    (aver (eql (file-position output) ehdr-size))
    (write-sequence (make-elf64-sym 0 0) output)
    ;; The symbol name index is always 1 by construction. The type is #x10
    ;; given: #define STB_GLOBAL 1
    ;;   and: #define ELF32_ST_BIND(val) ((unsigned char) (val)) >> 4)
    ;; which places the binding in the high 4 bits of the low byte.
    (write-sequence (make-elf64-sym 1 #x10) output)

    ;; Write string table
    (aver (eql (file-position output) (+ ehdr-size symbols-size)))
    (write-sequence strings output) ; an octet vector at this point
    (dotimes (i (- padded-strings-size (length strings)))
      (write-byte 0 output))

    ;; Write section headers
    (aver (eql (file-position output) shdrs-start))
    (write-section-headers
     (map 'list
          (lambda (x)
            (ecase (car x)
              (:note '(0 . 0))
              (:sym  (cons ehdr-size symbols-size))
              (:str  (cons (+ ehdr-size symbols-size) (length strings)))
              (:rel  (cons shdrs-end relocs-size))
              (:core (cons core-start core-size))))
          sections)
     sections string-table output)

    ;; Write relocations
    (aver (eql (file-position output) shdrs-end))
    (let ((buf (make-array relocs-size :element-type '(unsigned-byte 8)))
          (ptr 0))
      (if pie
          (dovector (reloc relocs)
            (setf (%vector-raw-bits buf ptr) reloc)
            (incf ptr))
          (with-alien ((rela elf64-rela))
            (dovector (reloc relocs)
              (destructuring-bind (place addend . kind) reloc
                (setf (slot rela 'offset) place
                      (slot rela 'info)   (logior (ash 1 32) kind) ; 1 = symbol index
                      (slot rela 'addend) addend))
              (setf (%vector-raw-bits buf (+ ptr 0)) (sap-ref-word (alien-value-sap rela) 0)
                    (%vector-raw-bits buf (+ ptr 1)) (sap-ref-word (alien-value-sap rela) 8)
                    (%vector-raw-bits buf (+ ptr 2)) (sap-ref-word (alien-value-sap rela) 16))
              (incf ptr 3))))
      (write-sequence buf output))

    ;; Write padding
    (dotimes (i (- core-start (file-position output)))
      (write-byte 0 output))
    (aver (eq (file-position output) core-start))))

(defconstant R_X86_64_64    1) ; /* Direct 64 bit  */
(defconstant R_X86_64_PC32  2) ; /* PC relative 32 bit signed */
(defconstant R_X86_64_32   10) ; /* Direct 32 bit zero extended */
(defconstant R_X86_64_32S  11) ; /* Direct 32 bit sign extended */

;;; Fill in the FIXUPS vector with a list of places to fixup.
;;; For PIE-enabled cores, each place is just a virtual address.
;;; For non-PIE-enabled, the fixup corresponds to an ELF relocation which will be
;;; applied at link time of the excutable.
;;; Note that while this "works" for PIE, it is fairly inefficient because
;;; fundamentally Lisp objects contain absolute pointers, and there may be
;;; millions of words that need fixing at load (execution) time.
;;; Several techniques can mitigate this:
;;; * for funcallable-instances, put a second copy of funcallable-instance-tramp
;;;   in dynamic space so that funcallable-instances can jump to a known address.
;;; * for each closure, create a one-instruction trampoline in dynamic space,
;;;   - embedded in a (simple-array word) perhaps - which jumps to the correct
;;;   place in the text section. Point all closures over the same function
;;;   to the new closure stub. The trampoline, being pseudostatic, is effectively
;;;   immovable. (And you can't re-save from an ELF core)
;;; * for arbitrary pointers to simple-funs, create a proxy simple-fun in dynamic
;;;   space whose entry point is the real function in the ELF text section.
;;;   The GC might have to learn how to handle simple-funs that point externally
;;;   to themselves. Also there's a minor problem of hash-table test functions
;;; The above techniques will reduce by a huge factor the number of fixups
;;; that need to be applied on startup of a position-independent executable.
;;;
(defun collect-relocations (spacemap fixups pie &key (verbose nil) (print nil))
  (let* ((code-bounds (space-bounds immobile-text-core-space-id spacemap))
         (code-start (bounds-low code-bounds))
         (n-abs 0)
         (n-rel 0)
         (affected-pages (make-hash-table)))
    (labels
        ((abs-fixup (vaddr core-offs referent)
           (incf n-abs)
           (when print
              (format t "~x = 0x~(~x~): (a)~%" core-offs vaddr #+nil referent))
           (touch-core-page core-offs)
           ;; PIE relocations are output as a file section that is
           ;; interpreted by 'coreparse'. The addend is implicit.
           (setf (sap-ref-word (car spacemap) core-offs)
                 (if pie
                     (+ (- referent code-start) +code-space-nominal-address+)
                     0))
           (if pie
               (vector-push-extend vaddr fixups)
               (vector-push-extend `(,(+ core-header-size core-offs)
                                     ,(- referent code-start) . ,R_X86_64_64)
                                   fixups)))
         (abs32-fixup (core-offs referent)
           (aver (not pie))
           (incf n-abs)
           (when print
              (format t "~x = 0x~(~x~): (a)~%" core-offs (core-to-logical core-offs) #+nil referent))
           (touch-core-page core-offs)
           (setf (sap-ref-32 (car spacemap) core-offs) 0)
           (vector-push-extend `(,(+ core-header-size core-offs)
                                 ,(- referent code-start) . ,R_X86_64_32)
                               fixups))
         (touch-core-page (core-offs)
           ;; use the OS page size, not +backend-page-bytes+
           (setf (gethash (floor core-offs 4096) affected-pages) t))
         ;; Given a address which is an offset into the data pages of the target core,
         ;; compute the logical address which that offset would be mapped to.
         ;; For example core address 0 is the virtual address of static space.
         (core-to-logical (core-offs &aux (page (floor core-offs +backend-page-bytes+)))
           (setf (gethash page affected-pages) t)
           (dolist (space (cdr spacemap)
                          (bug "Can't translate core offset ~x using ~x"
                               core-offs spacemap))
             (let* ((page0 (space-data-page space))
                    (nwords (space-nwords space))
                    (id (space-id space))
                    (npages (ceiling nwords (/ +backend-page-bytes+ n-word-bytes))))
               (when (and (<= page0 page (+ page0 (1- npages)))
                          (/= id immobile-text-core-space-id))
                 (return (+ (space-addr space)
                            (* (- page page0) +backend-page-bytes+)
                            (logand core-offs (1- +backend-page-bytes+))))))))
         (scanptrs (vaddr obj wordindex-min wordindex-max &optional force &aux (n-fixups 0))
           (do* ((base-addr (logandc2 (get-lisp-obj-address obj) lowtag-mask))
                 (sap (int-sap base-addr))
                 ;; core-offs is the offset in the lisp.core ELF section.
                 (core-offs (- base-addr (sap-int (car spacemap))))
                 (i wordindex-min (1+ i)))
                ((> i wordindex-max) n-fixups)
             (let* ((byte-offs (ash i word-shift))
                    (ptr (sap-ref-word sap byte-offs)))
               (when (and (or (is-lisp-pointer ptr) force) (in-bounds-p ptr code-bounds))
                 (abs-fixup (+ vaddr byte-offs) (+ core-offs byte-offs) ptr)
                 (incf n-fixups)))))
         (scanptr (vaddr obj wordindex)
           (plusp (scanptrs vaddr obj wordindex wordindex))) ; trivial wrapper
         (scan-obj (vaddr obj widetag size
                    &aux (core-offs (- (logandc2 (get-lisp-obj-address obj) lowtag-mask)
                                       (sap-int (car spacemap))))
                         (nwords (ceiling size n-word-bytes)))
           (when (listp obj)
             (scanptrs vaddr obj 0 1)
             (return-from scan-obj))
           (case widetag
             (#.instance-widetag
              (let ((type (truly-the layout (translate (%instance-layout obj) spacemap))))
                (do-layout-bitmap (i taggedp type (%instance-length obj))
                  (when taggedp
                    (scanptr vaddr obj (1+ i))))))
             (#.simple-vector-widetag
              (let ((len (length (the simple-vector obj))))
                (cond ((logtest (get-header-data obj) vector-addr-hashing-flag)
                       (do ((i 2 (+ i 2)) (needs-rehash))
                           ;; Refer to the figure at the top of src/code/hash-table.lisp.
                           ;; LEN is an odd number.
                           ((>= i (1- len))
                            (when needs-rehash
                              (setf (svref obj 1) 1)))
                         ;; A weak or EQ-based hash table any of whose keys is a function
                         ;; or code-component might need the 'rehash' flag set.
                         ;; In practice, it is likely already set, because any object that
                         ;; could move in the final GC probably did move.
                         (when (scanptr vaddr obj (+ vector-data-offset i))
                           (setq needs-rehash t))
                         (scanptr vaddr obj (+ vector-data-offset i 1))))
                      (t
                       (scanptrs vaddr obj 1 (+ len 1))))))
             (#.fdefn-widetag
              (scanptrs vaddr obj 1 2)
              (scanptrs vaddr obj 3 3 t))
             ((#.closure-widetag #.funcallable-instance-widetag)
              ;; read the trampoline slot
              (let ((word (sap-ref-word (int-sap (get-lisp-obj-address obj))
                                        (- n-word-bytes fun-pointer-lowtag))))
                (when (in-bounds-p word code-bounds)
                  (abs-fixup (+ vaddr n-word-bytes)
                             (+ core-offs n-word-bytes)
                             word)))
              ;; untaggged pointers are generally not supported in
              ;; funcallable instances, so scan everything.
              (scanptrs vaddr obj 1 (1- nwords)))
             ;; mixed boxed/unboxed objects
             (#.code-header-widetag
              (aver (not pie))
              (dolist (loc (code-fixup-locs obj spacemap))
                (let ((val (sap-ref-32 (code-instructions obj) loc)))
                  (when (in-bounds-p val code-bounds)
                    (abs32-fixup (sap- (sap+ (code-instructions obj) loc) (car spacemap))
                                 val))))
              (dotimes (i (code-n-entries obj))
                ;; I'm being lazy and not computing vaddr, which is wrong,
                ;; but does not matter if non-pie; and if PIE, we can't get here.
                ;; [PIE requires all code in immobile space, and this reloc
                ;; is for a dynamic space object]
                (scanptrs 0 (%code-entry-point obj i) 2 5))
              (scanptrs vaddr obj 1 (1- (code-header-words obj))))
             ;; boxed objects that can reference code/simple-funs
             ((#.value-cell-widetag #.symbol-widetag #.weak-pointer-widetag)
              (scanptrs vaddr obj 1 (1- nwords))))))
      (dolist (space (cdr spacemap))
        (unless (= (space-id space) immobile-text-core-space-id)
          (let* ((logical-addr (space-addr space))
                 (size (space-size space))
                 (physical-addr (space-physaddr space spacemap))
                 (physical-end (sap+ physical-addr size))
                 (vaddr-translation (+ (- (sap-int physical-addr)) logical-addr)))
            (dx-flet ((visit (obj widetag size)
                        ;; Compute the object's intended virtual address
                        (scan-obj (+ (logandc2 (get-lisp-obj-address obj) lowtag-mask)
                                     vaddr-translation)
                                  obj widetag size)))
              (map-objects-in-range
               #'visit
               (ash (sap-int physical-addr) (- n-fixnum-tag-bits))
               (ash (sap-int physical-end) (- n-fixnum-tag-bits))))
            (when (and (plusp (logior n-abs n-rel)) verbose)
              (format t "space @ ~10x: ~6d absolute + ~4d relative fixups~%"
                      logical-addr n-abs n-rel))
            (setq n-abs 0 n-rel 0)))))
    (when verbose
      (format t "total of ~D linker fixups affecting ~D/~D pages~%"
              (length fixups)
              (hash-table-count affected-pages)
              (/ (reduce #'+ (cdr spacemap) :key #'space-nbytes-aligned)
                 4096))))
  fixups)

;;;;

(defun read-core-header (input core-header verbose &aux (core-offset 0))
  (read-sequence core-header input)
  (cond ((= (%vector-raw-bits core-header 0) core-magic))
        (t ; possible embedded core
         (file-position input (- (file-length input)
                                 (* 2 n-word-bytes)))
         (aver (eql (read-sequence core-header input) (* 2 n-word-bytes)))
         (aver (= (%vector-raw-bits core-header 1) core-magic))
         (setq core-offset (%vector-raw-bits core-header 0))
         (when verbose
           (format t "~&embedded core starts at #x~x into input~%" core-offset))
         (file-position input core-offset)
         (read-sequence core-header input)
         (aver (= (%vector-raw-bits core-header 0) core-magic))))
  core-offset)

(defmacro do-core-header-entry (((id-var len-var ptr-var) buffer) &body body)
  `(let ((,ptr-var 1))
     (loop
       (let ((,id-var (%vector-raw-bits ,buffer ,ptr-var))
             (,len-var (%vector-raw-bits ,buffer (1+ ,ptr-var))))
         ;; (format t "~&entry type ~D @ ~d len ~d words~%" id ptr len)
         (incf ,ptr-var 2)
         (decf ,len-var 2)
         (when (= ,id-var end-core-entry-type-code)
           (aver (not (find 0 ,buffer :start (ash ,ptr-var word-shift) :test #'/=)))
           (return ,ptr-var))
         ,@body
         (incf ,ptr-var ,len-var)))))

(defmacro do-directory-entry (((index-var start-index input-nbytes) buffer) &body body)
  `(let ((words-per-dirent 5))
     (multiple-value-bind (n-entries remainder)
         (floor ,input-nbytes words-per-dirent)
       (aver (zerop remainder))
       (symbol-macrolet ((id        (%vector-raw-bits ,buffer index))
                         (nwords    (%vector-raw-bits ,buffer (+ index 1)))
                         (data-page (%vector-raw-bits ,buffer (+ index 2)))
                         (addr      (%vector-raw-bits ,buffer (+ index 3)))
                         (npages    (%vector-raw-bits ,buffer (+ index 4))))
         (do ((,index-var ,start-index (+ ,index-var words-per-dirent)))
             ((= ,index-var (+ ,start-index (* n-entries words-per-dirent))))
           ,@body)))))

(defmacro with-mapped-core ((sap-var start npages stream) &body body)
  `(let (,sap-var)
     (unwind-protect
          (progn
            (setq ,sap-var
                  (alien-funcall
                   (extern-alien "load_core_bytes"
                                 (function system-area-pointer
                                           int int unsigned unsigned int))
                   (sb-sys:fd-stream-fd ,stream)
                   (+ ,start +backend-page-bytes+) ; Skip the core header
                   0 ; place it anywhere
                   (* ,npages +backend-page-bytes+) ; len
                   0))
            ,@body)
       (when ,sap-var
         (alien-funcall
          (extern-alien "os_deallocate"
                        (function void system-area-pointer unsigned))
          ,sap-var (* ,npages +backend-page-bytes+))))))

(defun core-header-nwords (core-header &aux (sum 2))
  ;; SUM starts as 2, as the core's magic number occupies 1 word
  ;; and the ending tag of END-CORE-ENTRY-TYPE-CODE counts as 1.
  (do-core-header-entry ((id len ptr) core-header)
    ;; LEN as bound by the macro does not count 1 for the
    ;; the entry identifier or LEN itself so add them in.
    (incf sum (+ len 2)))
  sum)

(defun change-dynamic-space-size (core-header new-size) ; expressed in MiB
  (unless new-size
    (return-from change-dynamic-space-size core-header))
  (let ((new (copy-seq core-header)))
    ;; memsize options if present must immediately follow the core magic number
    ;; so it might require a byte-blt to move other entries over.
    (unless (= (%vector-raw-bits new 1) runtime-options-magic)
      ;; slide the header to right by 5 words
      (replace new core-header :start1 (* 6 n-word-bytes) :start2 (* 1 n-word-bytes))
      ;; see write_memsize_options for the format of this entry
      ;; All words have to be stored since we're creating it from nothing.
      (setf (%vector-raw-bits new 1) runtime-options-magic
            (%vector-raw-bits new 2) 5 ; number of words in this entry
            (%vector-raw-bits new 4) (extern-alien "thread_control_stack_size" unsigned)
            (%vector-raw-bits new 5) (extern-alien "dynamic_values_bytes" (unsigned 32))))
    (setf (%vector-raw-bits new 3) (* new-size 1024 1024))
    new))

;;; Given a native SBCL '.core' file, or one attached to the end of an executable,
;;; separate it into pieces.
;;; ASM-PATHNAME is the name of the assembler file that will hold all the Lisp code.
;;; The other two output pathnames are implicit: "x.s" -> "x.core" and "x-core.o"
;;; The ".core" file is a native core file used for starting a binary that
;;; contains the asm code using the "--core" argument.  The "-core.o" file
;;; is for linking in to a binary that needs no "--core" argument.
(defun split-core
    (input-pathname asm-pathname
     &key enable-pie (verbose nil) dynamic-space-size
     &aux (elf-core-pathname
           (merge-pathnames
            (make-pathname :name (concatenate 'string (pathname-name asm-pathname) "-core")
                           :type "o")
            asm-pathname))
          (core-header (make-array +backend-page-bytes+ :element-type '(unsigned-byte 8)))
          (original-total-npages 0)
          (core-offset 0)
          (page-adjust 0)
          (code-start-fixup-ofs 0) ; where to fixup the core header
          (space-list)
          (copy-actions)
          (fixedobj-range) ; = (START . SIZE-IN-BYTES)
          (relocs (make-array 100000 :adjustable t :fill-pointer 1)))

  (declare (ignorable fixedobj-range))
  ;; Remove old files
  (ignore-errors (delete-file asm-pathname))
  (ignore-errors (delete-file elf-core-pathname))
  ;; Ensure that all files can be opened
  (with-open-file (input input-pathname :element-type '(unsigned-byte 8))
    (with-open-file (asm-file asm-pathname :direction :output :if-exists :supersede)
      ;;(with-open-file (split-core split-core-pathname :direction :output
      ;;                            :element-type '(unsigned-byte 8) :if-exists :supersede)
      (let ((split-core nil))
        (setq core-offset (read-core-header input core-header verbose))
        (do-core-header-entry ((id len ptr) core-header)
          (case id
            (#.build-id-core-entry-type-code
             (when verbose
               (let ((string (make-string (%vector-raw-bits core-header ptr)
                                          :element-type 'base-char)))
                 (%byte-blt core-header (* (1+ ptr) n-word-bytes) string 0 (length string))
                 (format t "Build ID [~a]~%" string))))
            (#.directory-core-entry-type-code
             (do-directory-entry ((index ptr len) core-header)
               (incf original-total-npages npages)
               (push (make-space id addr data-page page-adjust nwords) space-list)
               (when verbose
                 (format t "id=~d page=~5x + ~5x addr=~10x words=~8x~:[~; (drop)~]~%"
                         id data-page npages addr nwords
                         (= id immobile-text-core-space-id)))
               (cond ((= id immobile-text-core-space-id)
                      (setq code-start-fixup-ofs (+ index 3))
                      ;; Keep this entry but delete the page count. We need to know
                      ;; where the space was supposed to be mapped and at what size.
                      ;; Subsequent core entries will need to adjust their start page
                      ;; downward (just the PTEs's start page now).
                      (setq page-adjust npages data-page 0 npages 0))
                     (t
                      ;; Keep track of where the fixedobj space wants to be.
                      (when (= id immobile-fixedobj-core-space-id)
                        (setq fixedobj-range (cons addr (ash nwords word-shift))))
                      (when (plusp npages) ; enqueue
                        (push (cons data-page (* npages +backend-page-bytes+))
                              copy-actions))
                      ;; adjust this entry's start page in the new core
                      (decf data-page page-adjust)))))
            (#.page-table-core-entry-type-code
             (aver (= len 4))
             (symbol-macrolet ((n-ptes (%vector-raw-bits core-header (+ ptr 1)))
                               (nbytes (%vector-raw-bits core-header (+ ptr 2)))
                               (data-page (%vector-raw-bits core-header (+ ptr 3))))
               (aver (= data-page original-total-npages))
               (aver (= (ceiling (space-nwords
                                  (find dynamic-core-space-id space-list :key #'space-id))
                                 (/ gencgc-page-bytes n-word-bytes))
                        n-ptes))
               (when verbose
                 (format t "PTE: page=~5x~40tbytes=~8x~%" data-page nbytes))
               (push (cons data-page nbytes) copy-actions)
               (decf data-page page-adjust)))))
        (let ((buffer (make-array +backend-page-bytes+
                                  :element-type '(unsigned-byte 8)))
              (filepos))
          ;; Write the new core file
          (when split-core
            (write-sequence core-header split-core))
          (dolist (action (reverse copy-actions)) ; nondestructive
            ;; page index convention assumes absence of core header.
            ;; i.e. data page 0 is the file page immediately following the core header
            (let ((offset (* (1+ (car action)) +backend-page-bytes+))
                  (nbytes (cdr action)))
              (when verbose
                (format t "File offset ~10x: ~10x bytes~%" offset nbytes))
              (setq filepos (+ core-offset offset))
              (cond (split-core
                     (file-position input filepos)
                     (copy-bytes input split-core nbytes buffer))
                    (t
                     (file-position input (+ filepos nbytes))))))
          ;; Trailer (runtime options and magic number)
          (let ((nbytes (read-sequence buffer input)))
            ;; expect trailing magic number
            (let ((ptr (floor (- nbytes n-word-bytes) n-word-bytes)))
              (aver (= (%vector-raw-bits buffer ptr) core-magic)))
            ;; File position of the core header needs to be set to 0
            ;; regardless of what it was
            (setf (%vector-raw-bits buffer 4) 0)
            (when verbose
              (format t "Trailer words:(~{~X~^ ~})~%"
                      (loop for i below (floor nbytes n-word-bytes)
                            collect (%vector-raw-bits buffer i))))
            (when split-core
              (write-sequence buffer split-core :end nbytes)
              (finish-output split-core)))
          ;; Sanity test
          (when split-core
            (aver (= (+ core-offset
                        (* page-adjust +backend-page-bytes+)
                        (file-length split-core))
                     (file-length input))))
          ;; Seek back to the PTE pages so they can be copied to the '.o' file
          (file-position input filepos)))

      ;; Map the original core file to memory
      (with-mapped-core (sap core-offset original-total-npages input)
        (let* ((data-spaces
                (delete immobile-text-core-space-id (reverse space-list)
                        :key #'space-id))
               (spacemap (cons sap (sort (copy-list space-list) #'> :key #'space-addr)))
               (pte-nbytes (cdar copy-actions)))
          (collect-relocations spacemap relocs enable-pie)
          (with-open-file (output elf-core-pathname
                                  :direction :output :if-exists :supersede
                                  :element-type '(unsigned-byte 8))
            ;; If we're going to write memory size options and they weren't already
            ;; present, then it will be inserted after the core magic,
            ;; and the rest of the header moves over by 5 words.
            (when (and dynamic-space-size
                       (/= (%vector-raw-bits core-header 1) runtime-options-magic))
              (incf code-start-fixup-ofs 5))
            (unless enable-pie
              ;; This fixup sets the 'address' field of the core directory entry
              ;; for code space. If PIE-enabled, we'll figure it out in the C code
              ;; because space relocation is going to happen no matter what.
              (setf (aref relocs 0)
                    `(,(ash code-start-fixup-ofs word-shift) 0 . ,R_X86_64_64)))
            (prepare-elf (+ (apply #'+ (mapcar #'space-nbytes-aligned data-spaces))
                            +backend-page-bytes+ ; core header
                            pte-nbytes)
                         relocs output enable-pie)
            (let ((new-header (change-dynamic-space-size core-header dynamic-space-size)))
              ;; This word will be fixed up by the system linker
              (setf (%vector-raw-bits new-header code-start-fixup-ofs)
                    (if enable-pie +code-space-nominal-address+ 0))
              (write-sequence new-header output))
            (force-output output)
            ;; ELF cores created from #-immobile-space cores use +required-foreign-symbols+.
            ;; But if #+immobile-space the alien-linkage-table values are computed
            ;; by 'ld' and we don't scan +required-foreign-symbols+.
            (when (get-space immobile-fixedobj-core-space-id spacemap)
              (let* ((sym (find-target-symbol (package-id "SB-VM")
                                              "+REQUIRED-FOREIGN-SYMBOLS+" spacemap :physical))
                     (vector (translate (symbol-global-value sym) spacemap)))
                (fill vector 0)
                (setf (%array-fill-pointer vector) 0)))
            ;; Change SB-C::*COMPILE-FILE-TO-MEMORY-SPACE* to :DYNAMIC
            ;; and SB-C::*COMPILE-TO-MEMORY-SPACE* to :AUTO
            ;; in case the resulting executable needs to compile anything.
            ;; (Call frame info will be missing, but at least it's something.)
            (dolist (item '(("*COMPILE-FILE-TO-MEMORY-SPACE*" . "DYNAMIC")
                            ("*COMPILE-TO-MEMORY-SPACE*" . "DYNAMIC")))
              (destructuring-bind (symbol . value) item
                (awhen (%find-target-symbol (package-id "SB-C") symbol spacemap)
                  (%set-symbol-global-value
                   it (find-target-symbol (package-id "KEYWORD") value spacemap :logical)))))
            ;;
            (dolist (space data-spaces) ; Copy pages from memory
              (let ((start (space-physaddr space spacemap))
                    (size (space-nbytes-aligned space)))
                (aver (eql (sb-unix:unix-write (sb-sys:fd-stream-fd output)
                                               start 0 size)
                           size))))
            (when verbose
              (format t "Copying ~d bytes (#x~x) from ptes = ~d PTEs~%"
                      pte-nbytes pte-nbytes (floor pte-nbytes 10)))
            (copy-bytes input output pte-nbytes)) ; Copy PTEs from input
          (let ((core (write-assembler-text spacemap asm-file enable-pie)))
            (format asm-file " .section .rodata~% .p2align 4~%lisp_fixups:~%")
            ;; Sort the hash-table in emit order.
            (dolist (x (sort (%hash-table-alist (core-new-fixups core)) #'< :key #'cdr))
              (output-bignum nil (car x) asm-file))
            (cond
              (t ; (get-space immobile-fixedobj-core-space-id spacemap)
               (format asm-file (if (member :darwin *features*)
                                 "~% .data~%"
                                 "~% .section .rodata~%"))
               (format asm-file " .globl ~A~%~:*~A:
 .quad ~d # ct~%"
                    (labelize "alien_linkage_values")
                    (length (core-linkage-symbols core)))
               ;; -1 (not a plausible function address) signifies that word
               ;; following it is a data, not text, reference.
               (loop for s across (core-linkage-symbols core)
                     do (format asm-file " .quad ~:[~;-1, ~]~a~%"
                                (consp s)
                                (if (consp s) (car s) s))))
              (t
               (format asm-file "~% .section .rodata~%")
               (format asm-file " .globl anchor_junk~%")
               (format asm-file "anchor_junk: .quad lseek_largefile, get_timezone, compute_udiv_magic32~%"))))))
      (when (member :linux *features*)
        (format asm-file "~% ~A~%" +noexec-stack-note+)))))

;;; Copy the input core into an ELF section without splitting into code & data.
;;; Also force a linker reference to each C symbol that the Lisp core mentions.
(defun copy-to-elf-obj (input-pathname output-pathname)
  ;; Remove old files
  (ignore-errors (delete-file output-pathname))
  ;; Ensure that all files can be opened
  (with-open-file (input input-pathname :element-type '(unsigned-byte 8))
    (with-open-file (output output-pathname :direction :output
                            :element-type '(unsigned-byte 8) :if-exists :supersede)
      (let* ((core-header (make-array +backend-page-bytes+
                                      :element-type '(unsigned-byte 8)))
             (core-offset (read-core-header input core-header nil))
             (space-list)
             (total-npages 0) ; excluding core header page
             (core-size 0))
        (do-core-header-entry ((id len ptr) core-header)
          (case id
            (#.directory-core-entry-type-code
             (do-directory-entry ((index ptr len) core-header)
               (incf total-npages npages)
               (when (plusp nwords)
                 (push (make-space id addr data-page 0 nwords) space-list))))
            (#.page-table-core-entry-type-code
             (aver (= len 4))
             (symbol-macrolet ((nbytes (%vector-raw-bits core-header (+ ptr 2)))
                               (data-page (%vector-raw-bits core-header (+ ptr 3))))
               (aver (= data-page total-npages))
               (setq core-size (+ (* total-npages +backend-page-bytes+) nbytes))))))
        (incf core-size +backend-page-bytes+) ; add in core header page
        ;; Map the core file to memory
        (with-mapped-core (sap core-offset total-npages input)
          (let* ((spacemap (cons sap (sort (copy-list space-list) #'> :key #'space-addr)))
                 (core (make-core spacemap
                                  (space-bounds immobile-text-core-space-id spacemap)
                                  (space-bounds immobile-fixedobj-core-space-id spacemap)))
                 (c-symbols (map 'list (lambda (x) (if (consp x) (car x) x))
                                 (core-linkage-symbols core)))
                 (sections `#((:str  ".strtab"         ,+sht-strtab+   0 0 0 1  0)
                              (:sym  ".symtab"         ,+sht-symtab+   0 1 1 8 ,sym-entry-size)
                              ;;             section with the strings -- ^ ^ -- 1+ highest local symbol
                              (:core "lisp.core"       ,+sht-progbits+ 0 0 0 ,core-align 0)
                              (:note ".note.GNU-stack" ,+sht-progbits+ 0 0 0 1  0)))
                 (string-table (string-table (append (map 'list #'second sections)
                                                     c-symbols)))
                 (packed-strings (cdr string-table))
                 (strings-start (+ ehdr-size (* (1+ (length sections)) shdr-size)))
                 (strings-end (+ strings-start (length packed-strings)))
                 (symbols-start (align-up strings-end 8))
                 (symbols-size (* (1+ (length c-symbols)) sym-entry-size))
                 (symbols-end (+ symbols-start symbols-size))
                 (core-start (align-up symbols-end 4096)))
            (write-elf-header ehdr-size sections output)
            (write-section-headers `((,strings-start . ,(length packed-strings))
                                     (,symbols-start . ,symbols-size)
                                     (,core-start    . ,core-size)
                                     (0 . 0))
                                   sections string-table output)
            (write-sequence packed-strings output)
            ;; Write symbol table
            (file-position output symbols-start)
            (write-sequence (make-elf64-sym 0 0) output)
            (dolist (sym c-symbols)
              (let ((name-ptr (cdr (assoc sym (car string-table)))))
                (write-sequence (make-elf64-sym name-ptr #x10) output)))
            ;; Copy core
            (file-position output core-start)
            (file-position input core-offset)
            (let ((remaining core-size))
              (loop (let ((n (read-sequence core-header input
                                            :end (min +backend-page-bytes+ remaining))))
                      (write-sequence core-header output :end n)
                      (unless (plusp (decf remaining n)) (return))))
              (aver (zerop remaining)))))))))

;; These will get set to 0 if the target is not using mark-region-gc
(defglobal *bitmap-bits-per-page* (/ gencgc-page-bytes (* cons-size n-word-bytes)))
(defglobal *bitmap-bytes-per-page* (/ *bitmap-bits-per-page* n-byte-bits))

(defstruct page
  words-used
  single-obj-p
  type
  scan-start
  bitmap)

(defun read-page-table (stream n-ptes nbytes data-page &optional (print nil))
  (declare (ignore nbytes))
  (let ((table (make-array n-ptes)))
    (file-position stream (* (1+ data-page) sb-c:+backend-page-bytes+))
    (dotimes (i n-ptes)
      (let* ((bitmap (make-array *bitmap-bits-per-page* :element-type 'bit))
             (temp (make-array *bitmap-bytes-per-page* :element-type '(unsigned-byte 8))))
        (when (plusp *bitmap-bits-per-page*)
          (read-sequence temp stream))
        (dotimes (i (/ (length bitmap) n-word-bits))
          (setf (%vector-raw-bits bitmap i) (%vector-raw-bits temp i)))
        (setf (aref table i) (make-page :bitmap bitmap))))
    ;; a PTE is a lispword and a uint16_t
    (let ((buf (make-array 10 :element-type '(unsigned-byte 8))))
      (with-pinned-objectS (buf)
        (dotimes (i n-ptes)
          (read-sequence buf stream)
          (let ((sso (sap-ref-word (vector-sap buf) 0))
                (words-used (sap-ref-16 (vector-sap buf) 8))
                (p (aref table i)))
            (setf (page-words-used p) (logandc2 words-used 1)
                  (page-single-obj-p p) (logand words-used 1)
                  (page-scan-start p) (logandc2 sso 7)
                  (page-type p) (logand sso 7))
            (when (and print (plusp (page-words-used p)))
              (format t "~4d: ~4x ~2x~:[~; -~x~]~%"
                      i (ash (page-words-used p) word-shift)
                      (page-type p)
                      (if (= (page-single-obj-p p) 0) nil 1)
                      (page-scan-start p)))))))
    table))

(defun decode-page-type (type)
  (ecase type
    (0 :free)
    (1 :unboxed)
    (2 :boxed)
    (3 :mixed)
    (4 :small-mixed)
    (5 :cons)
    (7 :code)))

(defun calc-page-index (vaddr space)
  (let ((vaddr (if (system-area-pointer-p vaddr) (sap-int vaddr) vaddr)))
    (floor (- vaddr (space-addr space)) gencgc-page-bytes)))
(defun calc-page-base (vaddr)
  (logandc2 vaddr (1- gencgc-page-bytes)))
(defun calc-object-index (vaddr)
  (ash (- vaddr (calc-page-base vaddr)) (- n-lowtag-bits)))

(defun page-bytes-used (index ptes)
  (ash (page-words-used (svref ptes index)) word-shift))

(defun find-ending-page (index ptes)
  ;; A page ends a contiguous block if it is not wholly used,
  ;; or if there is no next page,
  ;; or the next page starts its own contiguous block
  (if (or (< (page-bytes-used index ptes) gencgc-page-bytes)
          (= (1+ index) (length ptes))
          (zerop (page-scan-start (svref ptes (1+ index)))))
      index
      (find-ending-page (1+ index) ptes)))

(defun page-addr (index space) (+ (space-addr space) (* index gencgc-page-bytes)))

(defun walk-dynamic-space (page-type spacemap function)
  (do* ((space (get-space dynamic-core-space-id spacemap))
        (ptes (space-page-table space))
        (nptes (length ptes))
        (page-ranges)
        (first-page 0))
       ((>= first-page nptes) (nreverse page-ranges))
    #+gencgc
    (let* ((last-page (find-ending-page first-page ptes))
           (pte (aref (space-page-table space) first-page))
           (start-vaddr (page-addr first-page space))
           (end-vaddr (+ (page-addr last-page space) (page-bytes-used last-page ptes))))
      (when (and (plusp (page-type pte))
                 (or (null page-type) (eq page-type (decode-page-type (page-type pte)))))
        ;; Because gencgc has page-spanning objects, it's easiest to zero-fill later
        ;; if we track the range boundaries now.
        (push (list nil first-page last-page) page-ranges) ; NIL = no funcallable-instance
        (do ((vaddr (int-sap start-vaddr))
             (paddr (int-sap (translate-ptr start-vaddr spacemap))))
            ((>= (sap-int vaddr) end-vaddr))
          (let* ((word (sap-ref-word paddr 0))
                 (widetag (logand word widetag-mask))
                 (size (if (eq widetag filler-widetag)
                           (ash (ash word -32) word-shift) ; -> words -> bytes
                           (let* ((obj (reconstitute-object (%make-lisp-obj (sap-int paddr))))
                                  (size (primitive-object-size obj)))
                             ;; page types codes are never defined for Lisp
                             (when (eq page-type 7) ; KLUDGE: PAGE_TYPE_CODE
                               (aver (or (= widetag code-header-widetag)
                                         (= widetag funcallable-instance-widetag))))
                             (when (= widetag funcallable-instance-widetag)
                               (setf (caar page-ranges) t)) ; T = has funcallable-instance
                             (funcall function obj vaddr size :ignore)
                             size))))
            (setq vaddr (sap+ vaddr size)
                  paddr (sap+ paddr size)))))
      (setq first-page (1+ last-page)))
    #+mark-region-gc
    (let* ((vaddr (int-sap (+ (space-addr space) (* first-page gencgc-page-bytes))))
           (paddr (int-sap (translate-ptr (sap-int vaddr) spacemap)))
           (pte (aref (space-page-table space) first-page))
           (bitmap (page-bitmap pte)))
      (cond ((= (page-single-obj-p pte) 1)
             ;; last page is located by doing some arithmetic
             (let* ((obj (reconstitute-object (%make-lisp-obj (sap-int paddr))))
                    (size (primitive-object-size obj))
                    (last-page (calc-page-index (sap+ vaddr (1- size)) space)))
               #+nil (format t "~&Page ~4d..~4d ~A LARGE~%" first-page last-page (decode-page-type (page-type pte)))
               (funcall function obj vaddr size t)
               (setq first-page last-page)))
            ((plusp (page-type pte))
             #+nil (format t "~&Page ~4D : ~A~%" first-page (decode-page-type (page-type pte)))
             (when (or (null page-type) (eq page-type (decode-page-type (page-type pte))))
               (do ((object-offset-in-dualwords 0))
                   ((>= object-offset-in-dualwords *bitmap-bits-per-page*))
                 (let ((size
                        (cond ((zerop (sbit bitmap object-offset-in-dualwords))
                               (unless (and (zerop (sap-ref-word paddr 0))
                                            (zerop (sap-ref-word paddr 8)))
                                 (error "Unallocated object @ ~X: ~X ~X"
                                        vaddr (sap-ref-word paddr 0) (sap-ref-word paddr 8)))
                               (* 2 n-word-bytes))
                              (t
                               (let* ((obj (reconstitute-object (%make-lisp-obj (sap-int paddr))))
                                      (size (primitive-object-size obj)))
                                 (funcall function obj vaddr size nil)
                                 size)))))
                   (setq vaddr (sap+ vaddr size)
                         paddr (sap+ paddr size))
                   (incf object-offset-in-dualwords (ash size (- (1+ word-shift)))))))))
      (incf first-page))))

;;; Unfortunately the idea of using target features to decide whether to
;;; read a bitmap from PAGE_TABLE_CORE_ENTRY_TYPE_CODE falls flat,
;;; because we can't scan for symbols until the core is read, but we can't
;;; read the core until we decide whether there is a bitmap, which needs the
;;; feature symbols. Some possible solutions (and there are others too):
;;; 1) make a separate core entry for the bitmap
;;; 2) add a word to that core entry indicating that it has a bitmap
;;; 3) make a different entry type code for PTES_WITH_BITMAP
(defun detect-target-features (spacemap &aux result)
  (flet ((scan (symbol)
           (let ((list (symbol-global-value symbol))
                 (target-nil (compute-nil-object spacemap)))
             (loop
               (when (eq list target-nil) (return))
               (setq list (translate list spacemap))
               (let ((feature (translate (car list) spacemap)))
                 (aver (symbolp feature))
                 ;; convert keywords and only keywords into host keywords
                 (when (eq (symbol-package-id feature) (symbol-package-id :sbcl))
                   (let ((string (translate (symbol-name feature) spacemap)))
                     (push (intern string "KEYWORD") result))))
               (setq list (cdr list))))))
    (walk-dynamic-space
     nil
     spacemap
     (lambda (obj vaddr size large)
       (declare (ignore vaddr size large))
       (when (symbolp obj)
         (when (or (and (eq (symbol-package-id obj) #.(symbol-package-id 'sb-impl:+internal-features+))
                        (string= (translate (symbol-name obj) spacemap) "+INTERNAL-FEATURES+"))
                   (and (eq (symbol-package-id obj) #.(symbol-package-id '*features*))
                        (string= (translate (symbol-name obj) spacemap) "*FEATURES*")))
           (scan obj))))))
  ;;(format t "~&Target-features=~S~%" result)
  result)

(defun transport-dynamic-space-code (codeblobs spacemap new-space free-ptr)
  (do ((list codeblobs (cdr list))
       (offsets-vector-data (sap+ new-space (* 2 n-word-bytes)))
       (object-index 0 (1+ object-index)))
      ((null list))
    ;; FROM-VADDR is the original logical (virtual) address, and FROM-PADDR
    ;; is where the respective object is currently resident in memory now.
    ;; Similarly-named "TO-" values correspond to the location in new space.
    (destructuring-bind (from-vaddr . size) (car list)
      (let ((from-paddr (int-sap (translate-ptr (sap-int from-vaddr) spacemap)))
            (to-vaddr (+ +code-space-nominal-address+ free-ptr))
            (to-paddr (sap+ new-space free-ptr)))
        (setf (sap-ref-32 offsets-vector-data (ash object-index 2)) free-ptr)
        ;; copy to code space
        (%byte-blt from-paddr 0 new-space free-ptr size)
        (let* ((new-physobj
                (%make-lisp-obj (logior (sap-int to-paddr) other-pointer-lowtag)))
               (header-bytes (ash (code-header-words new-physobj) word-shift))
               (new-insts (code-instructions new-physobj)))
          ;; fix the jump table words which, if present, start at NEW-INSTS
          (let ((wordcount (code-jump-table-words new-physobj))
                (disp (- to-vaddr (sap-int from-vaddr))))
            (loop for i from 1 below wordcount
                  do (let ((w (sap-ref-word new-insts (ash i word-shift))))
                       (unless (zerop w)
                         (setf (sap-ref-word new-insts (ash i word-shift)) (+ w disp))))))
          ;; fix the simple-fun pointers
          (dotimes (i (code-n-entries new-physobj))
            (let ((fun-offs (%code-fun-offset new-physobj i)))
              ;; Assign the address that each simple-fun will have assuming
              ;; the object will reside at its new logical address.
              (setf (sap-ref-word new-insts (+ fun-offs n-word-bytes))
                    (+ to-vaddr header-bytes fun-offs (* 2 n-word-bytes))))))
        (incf free-ptr size)))))

(defun remap-to-quasi-static-code (val spacemap fwdmap)
  (when (is-lisp-pointer (get-lisp-obj-address val))
    (binding* ((translated (translate val spacemap))
               (vaddr (get-lisp-obj-address val))
               (code-base-addr
                (cond ((simple-fun-p translated)
                       ;; the code component has to be computed "by hand" because FUN-CODE-HEADER
                       ;; would return the physically mapped object, but we need
                       ;; to get the logical address of the code.
                       (- (- vaddr fun-pointer-lowtag)
                          (ash (ldb (byte 24 8)
                                    (sap-ref-word (int-sap (get-lisp-obj-address translated))
                                                  (- fun-pointer-lowtag)))
                               word-shift)))
                      ((code-component-p translated)
                       (- vaddr other-pointer-lowtag)))
                :exit-if-null)
               (new-code-offset (gethash code-base-addr fwdmap) :exit-if-null))
      (%make-lisp-obj (+ (if (functionp translated)
                             (- vaddr code-base-addr) ; function tag is in the difference
                             other-pointer-lowtag)
                         +code-space-nominal-address+
                         new-code-offset)))))

;;; It's not worth trying to use the host's DO-REFERENCED-OBJECT because it requires
;;; completely different behavior for INSTANCE and FUNCALLABLE-INSTANCE to avoid using
;;; the layout pointers as-is. And closures don't really work either. So unfortunately
;;; this is essentially a reimplementation. Thankfully we only have to deal with pointers
;;; that could possibly point to code.
(defun update-quasi-static-code-ptrs
    (obj spacemap fwdmap displacement &optional print
     &aux (sap (int-sap (logandc2 (get-lisp-obj-address obj) lowtag-mask))))
  (when print
    (format t "paddr ~X vaddr ~X~%" (get-lisp-obj-address obj)
            (+ (get-lisp-obj-address obj) displacement)))
  (macrolet ((visit (place)
               `(let* ((oldval ,place) (newval (remap oldval)))
                  (when newval
                    (setf ,place newval)))))
    (flet ((fun-entrypoint (fun)
             (+ (get-lisp-obj-address fun) (- fun-pointer-lowtag) (ash 2 word-shift)))
           (remap (x)
             (remap-to-quasi-static-code x spacemap fwdmap)))
      (cond
        ((listp obj) (visit (car obj)) (visit (cdr obj)))
        ((simple-vector-p obj)
         (dotimes (i (length obj)) (visit (svref obj i))))
        ((%instancep obj)
         (let ((type (truly-the layout (translate (%instance-layout obj) spacemap))))
           (do-layout-bitmap (i taggedp type (%instance-length obj))
             (when taggedp (visit (%instance-ref obj i))))))
        ((functionp obj)
         (let ((start
                (cond ((funcallable-instance-p obj)
                       ;; The trampoline points to the function itself (so is ignorable)
                       ;; and following that word are 2 words of machine code.
                       4)
                      (t
                       (aver (closurep obj))
                       (let ((fun (remap (%closure-fun obj))))
                         ;; there is no setter for closure-fun
                         (setf (sap-ref-word sap n-word-bytes) (fun-entrypoint fun)))
                       2))))
           (loop for i from start to (logior (get-closure-length obj) 1)
                 do (visit (sap-ref-lispobj sap (ash i word-shift))))))
        ((code-component-p obj)
         (loop for i from 2 below (code-header-words obj)
               do (visit (code-header-ref obj i))))
        ((symbolp obj)
         (visit (sap-ref-lispobj sap (ash symbol-value-slot word-shift))))
        ((weak-pointer-p obj)
         (visit (sap-ref-lispobj sap (ash weak-pointer-value-slot word-shift))))
        ((fdefn-p obj)
         (let ((raw (sap-ref-word sap (ash fdefn-raw-addr-slot word-shift))))
           (unless (in-bounds-p raw (space-bounds static-core-space-id spacemap))
             (awhen (remap (%make-lisp-obj (+ raw (ash -2 word-shift) fun-pointer-lowtag)))
               (setf (sap-ref-word sap (ash fdefn-raw-addr-slot word-shift))
                     (fun-entrypoint it)))))
         (visit (sap-ref-lispobj sap (ash fdefn-fun-slot word-shift))))
        ((= (%other-pointer-widetag obj) value-cell-widetag)
         (visit (sap-ref-lispobj sap (ash value-cell-value-slot word-shift))))))))

;;; Clear all the old objects.  Funcallable instances can be co-mingled with
;;; code, so a code page might not be empty but most will be. Free those pages.
(defun zerofill-old-code (spacemap codeblobs page-ranges)
  (declare (ignorable page-ranges))
  (with-alien ((memset (function void unsigned int unsigned) :extern))
    (flet ((reset-pte (pte)
             (setf (page-words-used pte) 0
                   (page-single-obj-p pte) 0
                   (page-type pte) 0
                   (page-scan-start pte) 0)))
      (let ((space (get-space dynamic-core-space-id spacemap)))
        #+gencgc
        (dolist (range page-ranges (aver (null codeblobs)))
          (destructuring-bind (in-use first last) range
            ;;(format t "~&Working on range ~D..~D~%" first last)
            (loop while codeblobs
                  do (destructuring-bind (vaddr . size) (car codeblobs)
                       (let ((page (calc-page-index vaddr space)))
                         (cond ((> page last) (return))
                               ((< page first) (bug "Incorrect sort"))
                               (t
                                (let ((paddr (translate-ptr (sap-int vaddr) spacemap)))
                                  (alien-funcall memset paddr 0 size)
                                  (when in-use ; store a filler widetag
                                    (let* ((nwords (ash size (- word-shift)))
                                           (header (logior (ash nwords 32) filler-widetag)))
                                      (setf (sap-ref-word (int-sap paddr) 0) header))))
                                (pop codeblobs))))))
            (unless in-use
              (loop for page-index from first to last
                    do (reset-pte (svref (space-page-table space) page-index))))))
        #+mark-region-gc
        (dolist (code codeblobs)
          (destructuring-bind (vaddr . size) code
            (alien-funcall memset (translate-ptr (sap-int vaddr) spacemap) 0 size)
            (let* ((page-index (calc-page-index vaddr space))
                   (pte (aref (space-page-table space) page-index))
                   (object-index (calc-object-index (sap-int vaddr))))
              (setf (sbit (page-bitmap pte) object-index) 0)
              (cond ((= (page-single-obj-p pte) 1)
                     ;(format t "~&Cleared large-object pages @ ~x~%" (sap-int vaddr))
                     (loop for p from page-index to (calc-page-index (sap+ vaddr (1- size)) space)
                           do (let ((pte (svref (space-page-table space) p)))
                                (aver (not (find 1 (page-bitmap pte))))
                                (reset-pte pte))))
                    ((not (find 1 (page-bitmap pte)))
                     ;; is the #+gencgc logic above actually more efficient?
                     ;;(format t "~&Code page ~D is now empty~%" page-index)
                     (reset-pte pte))))))))))

(defun parse-core-header (input core-header)
  (let ((space-list)
        (total-npages 0) ; excluding core header page
        (card-mask-nbits)
        (core-dir-start)
        (initfun))
    (do-core-header-entry ((id len ptr) core-header)
      (ecase id
        (#.directory-core-entry-type-code
         (setq core-dir-start (- ptr 2))
         (do-directory-entry ((index ptr len) core-header)
           (incf total-npages npages)
           (push (make-space id addr data-page 0 nwords) space-list)))
        (#.page-table-core-entry-type-code
         (aver (= len 4))
         (symbol-macrolet ((n-ptes (%vector-raw-bits core-header (+ ptr 1)))
                           (nbytes (%vector-raw-bits core-header (+ ptr 2)))
                           (data-page (%vector-raw-bits core-header (+ ptr 3))))
           (aver (= data-page total-npages))
           (setf card-mask-nbits (%vector-raw-bits core-header ptr))
           (format nil "~&card-nbits = ~D~%" card-mask-nbits)
           (let ((space (get-space dynamic-core-space-id (cons nil space-list))))
             (setf (space-page-table space) (read-page-table input n-ptes nbytes data-page)))))
        (#.build-id-core-entry-type-code
         (let ((string (make-string (%vector-raw-bits core-header ptr)
                                    :element-type 'base-char)))
           (%byte-blt core-header (* (1+ ptr) n-word-bytes) string 0 (length string))
           (format nil "Build ID [~a] len=~D ptr=~D actual-len=~D~%" string len ptr (length string))))
        (#.runtime-options-magic) ; ignore
        (#.initial-fun-core-entry-type-code
         (setq initfun (%vector-raw-bits core-header ptr)))))
    (values total-npages space-list card-mask-nbits core-dir-start initfun)))

(defconstant +lispwords-per-corefile-page+ (/ sb-c:+backend-page-bytes+ n-word-bytes))

(defun rewrite-core (directory spacemap card-mask-nbits initfun core-header offset output
                     &aux (dynamic-space (get-space dynamic-core-space-id spacemap)))
  (aver (= (%vector-raw-bits core-header offset) directory-core-entry-type-code))
  (let ((nwords (+ (* (length directory) 5) 2)))
    (setf (%vector-raw-bits core-header (incf offset)) nwords))
  (let ((page-count 0)
        (n-ptes (length (space-page-table dynamic-space))))
    (dolist (dir-entry directory)
      (setf (car dir-entry) page-count)
      (destructuring-bind (id paddr vaddr nwords) (cdr dir-entry)
        (declare (ignore paddr))
        (let ((npages (ceiling nwords +lispwords-per-corefile-page+)))
          (when (= id dynamic-core-space-id)
            (aver (= npages n-ptes)))
          (dolist (word (list id nwords page-count vaddr npages))
            (setf (%vector-raw-bits core-header (incf offset)) word))
          (incf page-count npages))))
    (let* ((sizeof-corefile-pte (+ n-word-bytes 2))
           (pte-bytes (align-up (* sizeof-corefile-pte n-ptes) n-word-bytes)))
      (dolist (word (list  page-table-core-entry-type-code
                           6 ; = number of words in this core header entry
                           card-mask-nbits
                           n-ptes (+ (* n-ptes *bitmap-bytes-per-page*) pte-bytes)
                           page-count))
        (setf (%vector-raw-bits core-header (incf offset)) word)))
    (dolist (word (list initial-fun-core-entry-type-code 3 initfun
                        end-core-entry-type-code 2))
      (setf (%vector-raw-bits core-header (incf offset)) word))
    (write-sequence core-header output)
    ;; write out the data from each space
    (dolist (dir-entry directory)
      (destructuring-bind (page id paddr vaddr nwords) dir-entry
        (declare (ignore id vaddr))
        (aver (= (file-position output) (* sb-c:+backend-page-bytes+ (1+ page))))
        (let* ((npages (ceiling nwords +lispwords-per-corefile-page+))
               (nbytes (* npages sb-c:+backend-page-bytes+))
               (wrote
                (sb-unix:unix-write (sb-impl::fd-stream-fd output) paddr 0 nbytes)))
          (aver (= wrote nbytes)))))
    (aver (= (file-position output) (* sb-c:+backend-page-bytes+ (1+ page-count))))
    #+mark-region-gc ; write the bitmap
    (dovector (pte (space-page-table dynamic-space))
      (let ((bitmap (page-bitmap pte)))
        (sb-sys:with-pinned-objects (bitmap)
          ;; WRITE-SEQUENCE on a bit vector would write one octet per bit
          (sb-unix:unix-write (sb-impl::fd-stream-fd output) bitmap 0 (/ (length bitmap) 8)))))
    ;; write the PTEs
    (let ((buffer (make-array 10 :element-type '(unsigned-byte 8))))
      (sb-sys:with-pinned-objects (buffer)
        (let ((sap (vector-sap buffer)))
          (dovector (pte (space-page-table dynamic-space))
            (setf (sap-ref-64 sap 0) (logior (page-scan-start pte) (page-type pte))
                  (sap-ref-16 sap 8) (logior (page-words-used pte) (page-single-obj-p pte)))
            (write-sequence buffer output)))
        (let* ((bytes-written (* 10 (length (space-page-table dynamic-space))))
               (diff (- (align-up bytes-written sb-vm:n-word-bytes)
                        bytes-written)))
          (fill buffer 0)
          (write-sequence buffer output :end diff))))
    ;; write the trailer
    (let ((buffer (make-array 16 :element-type '(unsigned-byte 8)
                                 :initial-element 0)))
      (sb-sys:with-pinned-objects (buffer)
        (setf (%vector-raw-bits buffer 0) 0
              (%vector-raw-bits buffer 1) core-magic)
        (write-sequence buffer output)))
    (force-output output)))

(defun walk-target-space (function space-id spacemap)
  (let* ((space (get-space space-id spacemap))
         (paddr (space-physaddr space spacemap)))
    (map-objects-in-range function
                          (%make-lisp-obj
                           (if (= space-id static-core-space-id)
                               ;; must not visit NIL, bad things happen
                               (translate-ptr (+ static-space-start sb-vm::static-space-objects-offset)
                                              spacemap)
                               (sap-int paddr)))
                          (%make-lisp-obj (sap-int (sap+ paddr (space-size space)))))))

(defun find-target-asm-code (spacemap)
  (walk-target-space (lambda (obj widetag size)
                       (declare (ignore size))
                       (when (= widetag code-header-widetag)
                         (return-from find-target-asm-code
                           (let* ((space (get-space static-core-space-id spacemap))
                                  (vaddr (space-addr space))
                                  (paddr (space-physaddr space spacemap)))
                             (%make-lisp-obj
                              (+ vaddr (- (get-lisp-obj-address obj)
                                          (sap-int paddr))))))))
                     static-core-space-id spacemap))

(defun move-dynamic-code-to-text-space (input-pathname output-pathname)
  ;; Remove old files
  (ignore-errors (delete-file output-pathname))
  ;; Ensure that all files can be opened
  (with-open-file (input input-pathname :element-type '(unsigned-byte 8))
    (with-open-file (output output-pathname :direction :output
                                            :element-type '(unsigned-byte 8) :if-exists :supersede)
      ;; KLUDGE: see comment above DETECT-TARGET-FEATURES
      #+gencgc (setq *bitmap-bits-per-page* 0 *bitmap-bytes-per-page* 0)
      (binding* ((core-header (make-array +backend-page-bytes+ :element-type '(unsigned-byte 8)))
                 (core-offset (read-core-header input core-header t))
                 ((npages space-list card-mask-nbits core-dir-start initfun)
                  (parse-core-header input core-header)))
        ;; Map the core file to memory
        (with-mapped-core (sap core-offset npages input)
          (let* ((spacemap (cons sap (sort (copy-list space-list) #'> :key #'space-addr)))
                 (target-features (detect-target-features spacemap))
                 (codeblobs nil)
                 (fwdmap (make-hash-table))
                 (n-objects)
                 (offsets-vector-size)
                 ;; We only need enough space to write C linkage call redirections from the
                 ;; assembler routine codeblob, because those are the calls which assume that
                 ;; asm code can directly call into the linkage space using "CALL rel32" form.
                 ;; Dynamic-space calls do not assume that - they use "CALL [ea]" form.
                 (c-linkage-reserved-words 12) ; arbitrary overestimate
                 (reserved-amount)
                 ;; text space will contain a copy of the asm code so it can use call rel32 form
                 (asm-code (find-target-asm-code spacemap))
                 (asm-code-size (primitive-object-size (translate asm-code spacemap)))
                 (freeptr asm-code-size)
                 (page-ranges
                  (walk-dynamic-space
                   :code spacemap
                   (lambda (obj vaddr size large)
                     (declare (ignore large))
                     (when (code-component-p obj)
                       (push (cons vaddr size) codeblobs)
                       ;; new object will be at FREEPTR bytes from new space start
                       (setf (gethash (sap-int vaddr) fwdmap) freeptr)
                       (incf freeptr size))))))
            ;; FIXME: this _still_ doesn't work, because if the buid has :IMMOBILE-SPACE
            ;; then the symbols CL:*FEATURES* and SB-IMPL:+INTERNAL-FEATURES+
            ;; are not in dynamic space.
            (when (member :immobile-space target-features)
              (error "Can't relocate code to text space since text space already exists"))
            (setq codeblobs
                  (acons (int-sap (logandc2 (get-lisp-obj-address asm-code) lowtag-mask))
                         asm-code-size
                         (nreverse codeblobs))
                  n-objects (length codeblobs))
            ;; Preceding the code objects are two vectors:
            ;; (1) a vector of uint32_t indicating the starting offset (from the space start)
            ;;    of each code object.
            ;; (2) a vector of uint64_t which embeds a JMP instruction to a C linkage table entry.
            ;;    These instructions are near enough to be called via 'rel32' form. (The ordinary
            ;;    alien linkage space is NOT near enough, after code is moved to text space)
            ;; The size of the new text space has to account for the sizes of the vectors.
            (let* ((n-vector1-data-words (ceiling n-objects 2)) ; two uint32s fit in a lispword
                   (vector1-size (ash (+ (align-up n-vector1-data-words 2) ; round to even
                                         vector-data-offset)
                                      word-shift))
                   (n-vector2-data-words c-linkage-reserved-words)
                   (vector2-size (ash (+ n-vector2-data-words vector-data-offset)
                                      word-shift)))
              (setf offsets-vector-size vector1-size
                    reserved-amount (+ vector1-size vector2-size))
              ;; Adjust all code offsets upward to avoid doing more math later
              (maphash (lambda (k v)
                         (setf (gethash k fwdmap) (+ v reserved-amount)))
                       fwdmap)
              (incf freeptr reserved-amount)
              (format nil "~&Code: ~D objects, ~D bytes~%" (length codeblobs) freeptr))
            (let* ((new-space-nbytes (align-up freeptr sb-c:+backend-page-bytes+))
                   (new-space (sb-sys:allocate-system-memory new-space-nbytes)))
              ;; Write header of "vector 1"
              (setf (sap-ref-word new-space 0) simple-array-unsigned-byte-32-widetag
                    (sap-ref-word new-space n-word-bytes) (fixnumize n-objects))
              ;; write header of "vector 2"
              (setf (sap-ref-word new-space offsets-vector-size) simple-array-unsigned-byte-64-widetag
                    (sap-ref-word new-space (+ offsets-vector-size n-word-bytes))
                    (fixnumize c-linkage-reserved-words))
              ;; Transport code contiguously into new space
              (transport-dynamic-space-code codeblobs spacemap new-space reserved-amount)
              ;; Walk static space and dynamic-space changing any pointers that
              ;; should point to new space.
              (dolist (space-id `(,dynamic-core-space-id ,static-core-space-id))
                (let* ((space (get-space space-id spacemap))
                       (vaddr (space-addr space))
                       (paddr (space-physaddr space spacemap))
                       (diff (+ (- (sap-int paddr)) vaddr)))
                  (format nil "~&Fixing ~A~%" space)
                  (walk-target-space
                    (lambda (object widetag size)
                      (declare (ignore widetag size))
                      (unless (and (code-component-p object) (= space-id dynamic-core-space-id))
                        (update-quasi-static-code-ptrs object spacemap fwdmap diff)))
                   space-id spacemap)))
              ;; Walk new space and fix pointers into itself
              (format nil "~&Fixing newspace~%")
              (map-objects-in-range
               (lambda (object widetag size)
                   (declare (ignore widetag size))
                   (update-quasi-static-code-ptrs object spacemap fwdmap 0))
                 (%make-lisp-obj (sap-int new-space))
                 (%make-lisp-obj (sap-int (sap+ new-space freeptr))))
              ;; don't zerofill asm code in static space
              (zerofill-old-code spacemap (cdr codeblobs) page-ranges)
              ;; Update the core header to contain newspace
              (let ((spaces (nreconc
                             (mapcar (lambda (space)
                                       (list 0 (space-id space)
                                             (int-sap (translate-ptr (space-addr space) spacemap))
                                             (space-addr space)
                                             (space-nwords space)))
                                     space-list)
                             `((0 ,immobile-text-core-space-id ,new-space
                                  ,+code-space-nominal-address+
                                  ,(ash freeptr (- word-shift)))))))
                (rewrite-core spaces spacemap card-mask-nbits initfun
                              core-header core-dir-start output)
                ))))))))

;;;;

(defun cl-user::elfinate (&optional (args (cdr *posix-argv*)))
  (cond ((string= (car args) "split")
         (pop args)
         (let (pie dss)
           (loop (cond ((string= (car args) "--pie")
                        (setq pie t)
                        (pop args))
                       ((string= (car args) "--dynamic-space-size")
                        (pop args)
                        (setq dss (parse-integer (pop args))))
                       (t
                        (return))))
           (destructuring-bind (input asm) args
             (split-core input asm :enable-pie pie
                                   :dynamic-space-size dss))))
        ((string= (car args) "copy")
         (apply #'copy-to-elf-obj (cdr args)))
        ((string= (car args) "extract")
         (apply #'move-dynamic-code-to-text-space (cdr args)))
        #+nil
        ((string= (car args) "relocate")
         (destructuring-bind (input output binary start-sym) (cdr args)
           (relocate-core
            input output binary (parse-integer start-sym :radix 16))))
        (t
         (error "Unknown command: ~S" args))))

;;; Processing a core without immobile-space

;;; This file provides a recipe which gets a little bit closer to being able to
;;; emulate #+immobile-space in so far as producing an ELF core is concerned.
;;; The recipe is a bit more complicated than I'd like, but it works.
;;; Let's say you want a core with contiguous text space containing the code
;;; of a quicklisp system.

;;; $ run-sbcl.sh
;;; * (ql:quickload :one-more-re-nightmare-tests)
;;; * (save-lisp-and-die "step1.core")
;;; $ run-sbcl.sh
;;; * (load "tools-for-build/editcore")
;;; * (sb-editcore:move-dynamic-code-to-text-space "step1.core" "step2.core")
;;; * (sb-editcore:redirect:text-space-calls "step2.core")
;;; Now "step2.core" has a text space, and all lisp-to-lisp calls bypass their FDEFN.
;;; The new core is strictly less featureful than #+immobie-space because global
;;; function redefinition does not work - REMOVE-STATIC-LINKS is missing.
;;; At this point split-core on "step2.core" can run in the manner of elfcore.test.sh

(defun get-code-segments (code vaddr spacemap)
  (let ((di (%code-debug-info code))
        (inst-base (+ vaddr (ash (code-header-words code) word-shift)))
        (result))
    (aver (%instancep di))
    (if (zerop (code-n-entries code)) ; assembler routines
        (dolist (entry (target-hash-table-alist di spacemap))
          (let* ((val (translate (undescriptorize (cdr entry)) spacemap))
                 ;; VAL is (start end . index)
                 (start (the fixnum (car val)))
                 (end (the fixnum (car (translate (cdr val) spacemap)))))
            (push (make-code-segment code start (- (1+ end) start)
                                     :virtual-location (+ inst-base start))
                  result)))
        (dolist (range (get-text-ranges code spacemap))
          (let ((car (car range)))
            (when (integerp car)
              (push (make-code-segment code car (- (cdr range) car)
                                       :virtual-location (+ inst-base car))
                    result)))))
    (sort result #'< :key #'sb-disassem:seg-virtual-location)))

(defstruct (range (:constructor make-range (labeled vaddr bytecount)))
  labeled vaddr bytecount)

(defun inst-vaddr (inst) (range-vaddr (car inst)))
(defun inst-length (inst) (range-bytecount (car inst)))
(defun inst-end (inst &aux (range (car inst)))
  (+ (range-vaddr range) (range-bytecount range)))

(defmethod print-object ((self range) stream)
  (format stream "~A~x,~x"
          (if (range-labeled self) "L:" "  ")
          (range-vaddr self)
          (range-bytecount self)))
(defun get-code-instruction-model (code vaddr spacemap)
  (let* ((segments (get-code-segments code vaddr spacemap))
         (insts-vaddr (+ vaddr (ash (code-header-words code) word-shift)))
         (dstate (sb-disassem:make-dstate))
         (fun-header-locs
          (loop for i from 0 below (code-n-entries code)
                collect (+ insts-vaddr (%code-fun-offset code i))))
         (labels))
    (sb-disassem:label-segments segments dstate)
    ;; are labels not already sorted?
    (setq labels (sort (sb-disassem::dstate-labels dstate) #'< :key #'car))
    (sb-int:collect ((result))
      (dolist (seg segments (coerce (result) 'vector))
        (setf (sb-disassem:dstate-segment dstate) seg
              (sb-disassem:dstate-segment-sap dstate)
              (funcall (sb-disassem:seg-sap-maker seg)))
        (setf (sb-disassem:dstate-cur-offs dstate) 0)
        (loop
          (when (eql (sb-disassem:dstate-cur-addr dstate) (car fun-header-locs))
            (incf (sb-disassem:dstate-cur-offs dstate) (* simple-fun-insts-offset n-word-bytes))
            (pop fun-header-locs))
          (let* ((pc (sb-disassem:dstate-cur-addr dstate))
                 (labeled (when (and labels (= pc (caar labels)))
                            (pop labels)
                            t))
                 (inst (sb-disassem:disassemble-instruction dstate))
                 (nbytes (- (sb-disassem:dstate-cur-addr dstate) pc)))
            (result (cons (make-range labeled pc nbytes) inst)))
          (when (>= (sb-disassem:dstate-cur-offs dstate) (sb-disassem:seg-length seg))
            (return)))))))

;; The extra copy of ASM routines, particularly C-calling trampolines, that now reside in text
;; space have to be modified to correctly reference their C functions. They assume that static
;; space is near alien-linkage space, and so they use this form:
;;   xxxx: E8A1F0EFFF  CALL #x50000060 ; alloc
;; which unforuntately means that after relocating to text space, that instruction refers
;; to random garbage, and more unfortunately there is no room to squeeze in an instruction
;; that encodes to 7 bytes.
;; So we have to create an extra jump "somewhere" that indirects through the linkage table
;; but is callable from the text-space code.
;;; I don't feel like programmatically scanning the asm code to determine these.
;;; Hardcoded is good enough (until it isn't)
(defparameter *c-linkage-redirects*
  (mapcar (lambda (x) (cons x (foreign-symbol-sap x)))
          '("switch_to_arena"
            "alloc"
            "alloc_list"
            "listify_rest_arg"
            "make_list"
            "alloc_funinstance"
            "allocation_tracker_counted"
            "allocation_tracker_sized")))

(defun get-text-space-asm-code-replica (space spacemap)
  (let* ((physaddr (sap-int (space-physaddr space spacemap)))
         (offsets-vector (%make-lisp-obj (logior physaddr other-pointer-lowtag)))
         (offset (aref offsets-vector 0)))
    (values (+ (space-addr space) offset)
            (%make-lisp-obj (+ physaddr offset other-pointer-lowtag)))))

(defun get-static-space-asm-code (space spacemap)
  (let ((found
         (block nil
           (sb-editcore::walk-target-space
            (lambda (x widetag size)
              (declare (ignore widetag size))
              (when (code-component-p x)
                (return x)))
            static-core-space-id spacemap))))
    (values (+ (- (get-lisp-obj-address found)
                  (sap-int (space-physaddr space spacemap))
                  other-pointer-lowtag)
               (space-addr space))
            found)))

(defun patch-assembly-codeblob (spacemap)
  (binding* ((static-space (get-space static-core-space-id spacemap))
             (text-space (get-space immobile-text-core-space-id spacemap))
             ((new-code-vaddr new-code) (get-text-space-asm-code-replica text-space spacemap))
             ((old-code-vaddr old-code) (get-static-space-asm-code static-space spacemap))
             (code-offsets-vector
              (%make-lisp-obj (logior (sap-int (space-physaddr text-space spacemap))
                                      other-pointer-lowtag)))
             (header-bytes (ash (code-header-words old-code) word-shift))
             (old-insts-vaddr (+ old-code-vaddr header-bytes))
             (new-insts-vaddr (+ new-code-vaddr header-bytes))
             (items *c-linkage-redirects*)
             (inst-buffer (make-array 8 :element-type '(unsigned-byte 8)))
             (code-offsets-vector-size (primitive-object-size code-offsets-vector))
             (c-linkage-vector-vaddr (+ (space-addr text-space) code-offsets-vector-size))
             (c-linkage-vector ; physical
              (%make-lisp-obj (logior (sap-int (sap+ (space-physaddr text-space spacemap)
                                                     code-offsets-vector-size))
                                      other-pointer-lowtag))))
    (aver (<= (length items) (length c-linkage-vector)))
    (with-pinned-objects (inst-buffer)
      (do ((sap (vector-sap inst-buffer))
           (item-index 0 (1+ item-index))
           (items items (cdr items)))
          ((null items))
        ;; Each new quasi-linkage-table entry takes 8 bytes to encode.
        ;; The JMP is 7 bytes, followed by a nop.
        ;; FF2425nnnnnnnn = JMP [ea]
        (setf (sap-ref-8 sap 0) #xFF
              (sap-ref-8 sap 1) #x24
              (sap-ref-8 sap 2) #x25
              (sap-ref-32 sap 3) (sap-int (sap+ (cdar items) 8))
              (sap-ref-8 sap 7) #x90) ; nop
        (setf (aref c-linkage-vector item-index) (%vector-raw-bits inst-buffer 0))))
    ;; Produce a model of the instructions. It doesn't really matter whether we scan
    ;; OLD-CODE or NEW-CODE since we're supplying the proper virtual address either way.
    (let ((insts (get-code-instruction-model old-code old-code-vaddr spacemap)))
;;  (dovector (inst insts) (write inst :base 16 :pretty nil :escape nil) (terpri))
      (dovector (inst insts)
        ;; Look for any call to a linkage table entry.
        (when (eq (second inst) 'call)
          (let ((operand (third inst)))
            (when (and (integerp operand)
                       (>= operand alien-linkage-table-space-start)
                       (< operand (+ alien-linkage-table-space-start
                                     alien-linkage-table-space-size)))
              (let* ((index (position (int-sap operand) *c-linkage-redirects*
                                      :key #'cdr :test #'sap=))
                     (branch-target (+ c-linkage-vector-vaddr
                                       (ash vector-data-offset word-shift)
                                       ;; each new linkage entry takes up exactly 1 word
                                       (* index n-word-bytes)))
                     (old-next-ip-abs (int-sap (inst-end inst))) ; virtual
                     (next-ip-rel (sap- old-next-ip-abs (int-sap old-insts-vaddr)))
                     (new-next-ip (+ new-insts-vaddr next-ip-rel)))
                (setf (signed-sap-ref-32 (code-instructions new-code) (- next-ip-rel 4))
                      (- branch-target new-next-ip))))))))))

(defun get-mov-src-constant (code code-vaddr inst ea spacemap)
  (let* ((next-ip (inst-end inst))
         ;; this is a virtual adrress
         (abs-addr (+ next-ip (machine-ea-disp ea))))
    (when (and (not (logtest abs-addr #b111)) ; lispword-aligned
               (>= abs-addr code-vaddr)
               (< abs-addr (+ code-vaddr (ash (code-header-words code) word-shift))))
      (let ((paddr (translate-ptr abs-addr spacemap)))
        (translate (sap-ref-lispobj (int-sap paddr) 0) spacemap)))))

(defun locate-const-move-to-rax (code vaddr insts start spacemap)
  ;; Look for a MOV to RAX from a code header constant
  ;; Technically this should fail if it finds _any_ instruction
  ;; that affects RAX before it finds the one we're looking for.
  (loop for i downfrom start to 1
        do (let ((inst (svref insts i)))
             (cond ((range-labeled (first inst)) (return)) ; labeled statement - fail
                   ((and (eq (second inst) 'mov)
                         (eq (third inst) (load-time-value (get-gpr :qword 0)))
                         (typep (fourth inst) '(cons machine-ea (eql :qword))))
                    (let ((ea (car (fourth inst))))
                      (when (and (eq (machine-ea-base ea) :rip)
                                 (minusp (machine-ea-disp ea)))
                        (return
                          (let ((const (get-mov-src-constant code vaddr inst ea spacemap)))
                            (when (fdefn-p const)
                              (let ((fun (fdefn-fun const)))
                                (when (simple-fun-p (translate fun spacemap))
                                  (values i fun)))))))))))))

(defun replacement-opcode (inst)
  (ecase (second inst) ; opcode
    (jmp #xE9)
    (call #xE8)))

(defun patch-fdefn-call (code vaddr insts inst i spacemap &optional print)
;;  (unless (= (%code-serialno code) #x6884) (return-from patch-fdefn-call))
  ;; START is the index into INSTS of the instructon that loads RAX
  (multiple-value-bind (start callee) (locate-const-move-to-rax code vaddr insts (1- i) spacemap)
    (when (and start
               (let ((text-space (get-space immobile-text-core-space-id spacemap)))
                 (< (space-addr text-space)
                    ;; CALLEE is an untranslated address
                    (get-lisp-obj-address callee)
                    (space-end text-space))))
      (when print
        (let ((addr (inst-vaddr (svref insts start))) ; starting address
              (end (inst-end inst)))
          (sb-c:dis (translate-ptr addr spacemap) (- end addr))))
      ;; Several instructions have to be replaced to make room for the new CALL
      ;; which is a longer than the old, but it's ok since a MOV is eliminated.
      (let* ((sum-lengths
              (loop for j from start to i sum (inst-length (svref insts j))))
             (new-bytes (make-array sum-lengths :element-type '(unsigned-byte 8)))
             (new-index 0))
        (loop for j from (1+ start) below i
              do (let* ((old-inst (svref insts j))
                        (ip (inst-vaddr old-inst))
                        (physaddr (int-sap (translate-ptr ip spacemap)))
                        (nbytes (inst-length old-inst)))
                   (dotimes (k nbytes)
                     (setf (aref new-bytes new-index) (sap-ref-8 physaddr k))
                     (incf new-index))))
        ;; insert padding given that the new call takes 5 bytes to encode
        (let* ((nop-len (- sum-lengths (+ new-index 5)))
               (nop-pattern (ecase nop-len
                              (5 '(#x0f #x1f #x44 #x00 #x00)))))
          (dolist (byte nop-pattern)
            (setf (aref new-bytes new-index) byte)
            (incf new-index)))
        ;; change the call
        (let* ((branch-target
                (simple-fun-entry-sap (translate callee spacemap)))
               (next-pc (int-sap (inst-end inst)))
               (rel32 (sap- branch-target next-pc)))
          (setf (aref new-bytes new-index) (replacement-opcode inst))
          (with-pinned-objects (new-bytes)
            (setf (signed-sap-ref-32 (vector-sap new-bytes) (1+ new-index)) rel32)
            (when print
              (format t "~&Replaced by:~%")
              (let ((s (sb-disassem::make-vector-segment new-bytes 0 sum-lengths
                                                         :virtual-location vaddr)))
                (sb-disassem::disassemble-segment
                 s *standard-output* (sb-disassem:make-dstate))))
            (let* ((vaddr (inst-vaddr (svref insts start)))
                   (paddr (translate-ptr vaddr spacemap)))
              (%byte-blt new-bytes 0 (int-sap paddr) 0 sum-lengths))))))))

(defun find-static-call-target-in-text-space (inst addr spacemap static-asm-code text-asm-code)
  (declare (ignorable inst))
  ;; this will (for better or for worse) find static fdefns as well as asm routines,
  ;; so we have to figure out which it is.
  (let ((asm-codeblob-size
         (primitive-object-size
          (%make-lisp-obj (logior (translate-ptr static-asm-code spacemap)
                                  other-pointer-lowtag)))))
    (cond ((<= static-asm-code addr (+ static-asm-code (1- asm-codeblob-size)))
           (let* ((offset-from-base (- addr static-asm-code))
                  (new-vaddr (+ text-asm-code offset-from-base)))
             (sap-ref-word (int-sap (translate-ptr new-vaddr spacemap)) 0)))
          (t
           (let* ((fdefn-vaddr (- addr (ash fdefn-raw-addr-slot word-shift)))
                  (fdefn-paddr (int-sap (translate-ptr fdefn-vaddr spacemap))))
             ;; Confirm it looks like a static fdefn
             (aver (= (logand (sap-ref-word fdefn-paddr 0) widetag-mask) fdefn-widetag))
             (let ((entrypoint (sap-ref-word fdefn-paddr (ash fdefn-raw-addr-slot word-shift))))
               ;; Confirm there is a simple-fun header where expected
               (let ((header
                      (sap-ref-word (int-sap (translate-ptr entrypoint spacemap))
                                    (- (ash simple-fun-insts-offset word-shift)))))
                 (aver (= (logand header widetag-mask) simple-fun-widetag))
                 ;; Return the entrypoint which already point to text space
                 entrypoint)))))))

;; Patch either a ca through a static-space fdefn or an asm routine indirect jump.
(defun patch-static-space-call (inst spacemap static-asm-code text-asm-code)
  (let* ((new-bytes (make-array 7 :element-type '(unsigned-byte 8)))
         (addr (machine-ea-disp (car (third inst))))
         (branch-target
          (find-static-call-target-in-text-space
           inst addr spacemap static-asm-code text-asm-code)))
    (when  branch-target
      (setf (aref new-bytes 0) #x66 (aref new-bytes 1) #x90) ; 2-byte NOP
      (setf (aref new-bytes 2) (replacement-opcode inst))
      (let ((next-ip (inst-end inst)))
        (with-pinned-objects (new-bytes)
          (setf (signed-sap-ref-32 (vector-sap new-bytes) 3) (- branch-target next-ip)))
        (%byte-blt new-bytes 0 (int-sap (translate-ptr (inst-vaddr inst) spacemap)) 0 7)))))

;;; Since dynamic-space code is pretty much relocatable,
;;; disassembling it at a random physical address is fine.
(defun patch-lisp-codeblob
    (code vaddr spacemap static-asm-code text-asm-code
     &aux (insts (get-code-instruction-model code vaddr spacemap)))
  (declare (simple-vector insts))
  (do ((i 0 (1+ i)))
      ((>= i (length insts)))
    (let* ((inst (svref insts i))
           (this-op (second inst)))
      (when (member this-op '(call jmp))
        ;; is it potentially a call via an fdefn or an asm code indirection?
        (let* ((operand (third inst))
               (ea (if (listp operand) (car operand))))
          (when (and (typep operand '(cons machine-ea (eql :qword)))
                     (or (and (eql (machine-ea-base ea) 0) ; [RAX-9]
                              (eql (machine-ea-disp ea) 9)
                              (not (machine-ea-index ea)))
                         (and (not (machine-ea-base ea))
                              (not (machine-ea-index ea))
                              (<= static-space-start (machine-ea-disp ea)
                                  (sap-int *static-space-free-pointer*)))))
            (if (eql (machine-ea-base ea) 0) ; based on RAX
                (patch-fdefn-call code vaddr insts inst i spacemap)
                (patch-static-space-call inst spacemap
                                         static-asm-code text-asm-code))))))))

(defun persist-to-file (spacemap core-offset stream)
  (aver (zerop core-offset))
  (dolist (space-id `(,static-core-space-id
                      ,immobile-text-core-space-id
                      ,dynamic-core-space-id))
    (let ((space (get-space space-id spacemap)))
      (file-position stream (* (1+ (space-data-page space)) +backend-page-bytes+))
      (sb-unix:unix-write (sb-impl::fd-stream-fd stream)
                          (space-physaddr space spacemap)
                          0
                          (align-up (* (space-nwords space) n-word-bytes)
                                    +backend-page-bytes+)))))

(defun redirect-text-space-calls (pathname)
  (with-open-file (stream pathname :element-type '(unsigned-byte 8)
                         :direction :io :if-exists :overwrite)
    (binding* ((core-header (make-array +backend-page-bytes+ :element-type '(unsigned-byte 8)))
               (core-offset (read-core-header stream core-header t))
               ((npages space-list card-mask-nbits core-dir-start initfun)
                (parse-core-header stream core-header)))
      (declare (ignore card-mask-nbits core-dir-start initfun))
      (with-mapped-core (sap core-offset npages stream)
        (let ((spacemap (cons sap (sort (copy-list space-list) #'> :key #'space-addr))))
          (patch-assembly-codeblob spacemap)
          (let* ((text-space (get-space immobile-text-core-space-id spacemap))
                 (offsets-vector (%make-lisp-obj (logior (sap-int (space-physaddr text-space spacemap))
                                                         lowtag-mask)))
                 (static-space-asm-code
                  (get-static-space-asm-code (get-space static-core-space-id spacemap) spacemap))
                 (text-space-asm-code
                  (get-text-space-asm-code-replica text-space spacemap)))
            (assert text-space)
            ;; offset 0 is the offset of the ASM routine codeblob which was already processed.
            (loop for j from 1 below (length offsets-vector)
                  do (let ((vaddr (+ (space-addr text-space) (aref offsets-vector j)))
                           (physobj (%make-lisp-obj
                                     (logior (sap-int (sap+ (space-physaddr text-space spacemap)
                                                            (aref offsets-vector j)))
                                             other-pointer-lowtag))))
                       ;; Assert that there are no fixups other than GC card table mask fixups
                       (let ((fixups (sb-vm::%code-fixups physobj)))
                         (unless (fixnump fixups)
                           (setq fixups (translate fixups spacemap))
                           (aver (typep fixups 'bignum)))
                         (multiple-value-bind (list1 list2 list3)
                             (sb-c::unpack-code-fixup-locs fixups)
                           (declare (ignore list3))
                           (aver (null list1))
                           (aver (null list2))))
                       (patch-lisp-codeblob physobj vaddr spacemap
                                            static-space-asm-code text-space-asm-code))))
          (persist-to-file spacemap core-offset stream))))))
;;;;

;; If loaded as a script, do this
(eval-when (:execute)
  (let ((args (cdr *posix-argv*)))
    (when args
      (let ((*print-pretty* nil))
        (format t "Args: ~S~%" args)
        (cl-user::elfinate args)))))
