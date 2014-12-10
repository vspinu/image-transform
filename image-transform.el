;;; image-transform.el --- Support for image transformations  -*- lexical-binding: t -*-
;;
;; Copyright (C) 2014 Free Software Foundation, Inc.
;;
;; Author: Vitalie Spinu <spinuvit@gmail.com>
;; Keywords: multimedia
;; Package: emacs
;;
;; This file is part of GNU Emacs.
;;
;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.
;;
;;; Commentary:
;;
;;  Documentation is in `image-transform` and `image-transform-backends`
;;
;;; TODO:
;;
;;  Make `image-tranform:convert' operate on :data
;; 
;;  Allow multi-image transformations by allowing IMAGE argument to
;;  `image-transform' to be a list of images.
;;
;;; Code:

(require 'image)
(require 'pcase)
(eval-when-compile
  (require 'cl-macs))

(defcustom image-transform-backends '(native convert)
  "List of backends which are tried in turn by `image-transform'.

The `native' backend uses internal Emacs ImageMagick support;
`convert' backed uses external ImageMagick 'convert' utility.  If
Emacs was not compiled with ImageMagick support `native' backend
is ignored.

Each backend 'BACKEND' consists of the following components:

 1) Transformation function 'image-transform:BACKEND' that takes as
    input an image and transform specs.  Currently implemented
    functions are `image-transform:native' and
    `image-transform:convert'.
 
 2) Supported transforms for each backend are stored in
    'image-transform-features:BACKEND' list of lists of of the
    form (FEATURE DOC TYPE), where:

    - FEATURE is a keyword naming a transformation.
   
    - DOC is a string describing the feature.
   
    - TYPE is a symbol such that 'image-transform-spec:TYPE'
      is a declared function that accepts KEY and VALUE arguments
      and returns a list of one or more canonical pairs (NEWKEY
      NEWVALUE) to be passed to the appropriate backend.  NEWVALUE
      is a string that can be passed directly to ImageMagick
      'convert' program.  For a complete list, see
      http://www.imagemagick.org/script/command-line-options.php

      Most common examples of normalizers are
      `image-transform-spec:number' and
      `image-transform-spec:geometry'.

    See `image-transform-features:native' and
    `image-transform-features:convert' for available features."
  :group 'image
  :type '(repeat symbol))

(defcustom image-transform-convert-program (executable-find "convert")
  "Path to \"convert\" program."
  :group 'image
  :type 'string)

(put 'next-backend 'error-conditions '(error next-backend))


;;; Internal Utilities

(defun image-tr--delete-properties (list props)
  "Remove PROPS from LIST destructively.
LIST is like plist, but possibly with repeated keys. Return
transformed LIST."
  (let ((p list))
    (while p
      (if (member (cadr p) props)
          (setcdr p (nthcdr 3 p))
        (setq p (cdr p))))
    list))

(defun image-tr--delete-transforms (image transforms)
  "Remove TRANSFORMS from IMAGE destructively."
  (image-tr--delete-properties (plist-get (cdr image) :transforms) transforms)
  image)

;; (defun image-tr--add (trlist key value)
;;   (if (not (null trlist))
;;       (let ((lcdr (nthcdr (1- (length trlist)) trlist)))
;;         (setcdr lcdr (list key value)))
;;     (push value trlist)
;;     (push key trlist))
;;   trlist)

(defun image-tr--osize (image)
  (let ((osize (plist-get (cdr image) :osize)))
    (unless osize
      (setq osize (image-size image t))
      (plist-put (cdr image) :osize osize))
    osize))

(defun image-tr--rescale (image sw &optional sh)
  ;; used by native backend
  (setq sh (or sh sw))
  (unless (and (= sw 100)
               (= sh 100))
    (let ((sw (/ sw 100.0))
          (sh (/ sh 100.0))
          (uw (plist-get (cdr image) :width))
          (uh (plist-get (cdr image) :height)))
      (let ((size (image-tr--osize image)))
        (if (or uw uh)
            (if (= sw sh)
                ;; only one could have been supplied, keep it
                (progn (when uw
                         (plist-put (cdr image)
                                    :width (floor (* sw uw))))
                       (when uh
                         (plist-put (cdr image)
                                    :height (floor (* sh uh)))))
              (plist-put (cdr image)
                         :width (floor (* sw (or uw
                                                 (* (/ (car size) (float (cdr size))) uh)))))
              (plist-put (cdr image)
                         :height (floor (* sh (or uh
                                                  (* (/ (cdr size) (float (car size))) uw))))))
          (plist-put (cdr image) :width (floor (* sw (car size))))
          (when (/= sw sh)
            (plist-put (cdr image) :height (floor (* sh (cdr size))))))))))

(defvar image-tr--right-angle-fudge 0.0001
  "Snap distance to a multiple of a right angle.
There's no deep theory behind the default value, it should just
be somewhat larger than ImageMagick's MagickEpsilon.")

;; These two functions are slightly adapted from the old image-mode.el and were
;; authored by by Wolfgang Jenkner <wjenkner@inode.at>
(defsubst image-tr--get-rotated-width (width height rotation)
  "Return the bounding box width of a rotated WIDTH x HEIGHT rectangle.
ROTATION is the rotation angle in  degrees."
  (let ((angle (degrees-to-radians rotation)))
    ;; Assume, w.l.o.g., that the vertices of the rectangle have the
    ;; coordinates (+-w/2, +-h/2) and that (0, 0) is the center of the
    ;; rotation by the angle A.  The projections onto the first axis
    ;; of the vertices of the rotated rectangle are +- (w/2) cos A +-
    ;; (h/2) sin A, and the difference between the largest and the
    ;; smallest of the four values is the expression below.
    (+ (* width (abs (cos angle))) (* height (abs (sin angle))))))

;; The following comment and code snippet are from
;; ImageMagick-6.7.4-4/magick/distort.c

;;    /* Set the output image geometry to calculated 'best fit'.
;;       Yes this tends to 'over do' the file image size, ON PURPOSE!
;;       Do not do this for DePolar which needs to be exact for virtual tiling.
;;    */
;;    if ( fix_bounds ) {
;;      geometry.x = (ssize_t) floor(min.x-0.5);
;;      geometry.y = (ssize_t) floor(min.y-0.5);
;;      geometry.width=(size_t) ceil(max.x-geometry.x+0.5);
;;      geometry.height=(size_t) ceil(max.y-geometry.y+0.5);
;;    }

;; Other parts of the same file show that here the origin is in the
;; left lower corner of the image rectangle, the center of the
;; rotation is the center of the rectangle and min.x and max.x
;; (resp. min.y and max.y) are the smallest and the largest of the
;; projections of the vertices onto the first (resp. second) axis.
(defun image-tr--get-rotated-size (width height length &optional rotation)
  "Return (w . h) so that a rotated w x h image has exactly width LENGTH.
The ROTATION angle defaults 0.

Write W for WIDTH and H for HEIGHT.  Then the w x h rectangle is
an \"approximately uniformly\" scaled W x H rectangle, which
currently means that w is one of floor(s W) + {0, 1, -1} and h is
floor(s H), where s is a scale factor. The value of ROTATION may
be replaced by a slightly different angle.  Currently this is
done for values close to a multiple of 90, see
`image-tr--right-angle-fudge'."
  (setq rotation (or rotation 0.0))
  (cond ((< (abs (- (mod (+ rotation 90) 180) 90))
            image-tr--right-angle-fudge)
         (cl-assert (not (zerop width)) t)
         (cons length nil))
        ((< (abs (- (mod (+ rotation 45) 90) 45))
            image-tr--right-angle-fudge)
         (cl-assert (not (zerop height)) t)
         (cons nil length))
        (t
         (let (scale)
           (cl-assert (not (and (zerop width) (zerop height))) t)
           (setq scale
                 (/ (float (1- length))
                    (image-tr--get-rotated-width width height rotation)))
           ;; Assume we have a w x h image and an angle A, and let l =
           ;; l(w, h)) = w |cos A| + h |sin A|, which is the actual width
           ;; of the bounding box of the rotated image, as calculated by
           ;; `image-tr--get-rotated-width'.  The code snippet quoted above
           ;; means that ImageMagick puts the rotated image in
           ;; a bounding box of width L = 2 ceil((w+l+1)/2) - w.
           ;; Elementary considerations show that this is equivalent to
           ;; L - w being even and L-3 < l(w, h) <= L-1.  In our case, L is
           ;; the given `length' parameter and our job is to determine
           ;; reasonable values for w and h which satisfy these
           ;; conditions.
           (let ((w (floor (* scale width)))
                 (h (floor (* scale height))))
             ;; Let w and h as bound above.  Then l(w, h) <= l(s W, s H)
             ;; = L-1 < l(w+1, h+1) = l(w, h) + l(1, 1) <= l(w, h) + 2,
             ;; hence l(w, h) > (L-1) - 2 = L-3.
             (cons
              (cond ((= (mod w 2) (mod length 2))
                     w)
                    ;; l(w+1, h) >= l(w, h) > L-3, but does l(w+1, h) <=
                    ;; L-1 hold?
                    ((<= (image-tr--get-rotated-width (1+ w) h rotation)
                         (1- length))
                     (1+ w))
                    ;; No, it doesn't, but this implies that l(w-1, h) =
                    ;; l(w+1, h) - l(2, 0) >= l(w+1, h) - 2 > (L-1) -
                    ;; 2 = L-3.  Clearly, l(w-1, h) <= l(w, h) <= L-1.
                    (t
                     (1- w)))
              h))))))


;;; Parsers
;; Parser converts a 'convert' style string specification into a meaningful
;; elisp representation.

(defun image-transform-parse:number (str)
  "Parse a numeric string STR.
String can contain leading or trailing spaces.  If STR is a number
simply return it."
  (if (numberp str)
      str
    (when (string-match "^ *\\([+-]?[0-9.]+\\) *$" str)
      (string-to-number (match-string 1 str)))))

(defun image-transform-parse:scale (str)
  "Parse a numeric string STR as scale.
Like `image-transform-parse:number' but expects % at the end of
the number."
  (if (numberp str)
      str
    (when (string-match "^ *\\([0-9.]+\\)% *$" str)
      (string-to-number (match-string 1 str)))))

(defun image-transform-parse:geometry (geom)
  "Parse ImageMagick geometry specification.

X can be either \"x\",\"X\" or \" \" (space).

scale%  	Height and width both scaled by specified percentage.
xscaleXyscale% 	Height and width individually scaled by specified percentages.
width   	Width given, height automagically selected to preserve aspect ratio.
Xheight 	Height given, width automagically selected to preserve aspect ratio.
widthXheight 	Maximum values of height and width given, aspect ratio preserved.
widthXheight^ 	Minimum values of width and height given, aspect ratio preserved.
widthXheight! 	Width and height emphatically given, original aspect ratio ignored.
widthXheight> 	Shrinks an image with dimension(s) larger than the width and height arguments.
widthXheight< 	Enlarges an image with dimension(s) smaller than the width and height arguments.
area@   	Resize image to have specified area in pixels. Aspect ratio is preserved.

Return a list of the form (W H o) where o is an operator giving
an additional meaning to W and H. Can be ^ ! > < or @.

Offset geometry from \"convert\" specifications is not yet
supported. See http://www.imagemagick.org/script/command-line-processing.php#geometry"
  (when (and (stringp geom)
             (string-match
              "^ *\\([0-9.]+\\)?[xX ]?\\([0-9.]+\\)?\\([@><^!%]\\)? *$"
              geom))
    (let ((W (match-string 1 geom))
          (H (match-string 2 geom))
          (o (match-string 3 geom)))
      (list (and W (string-to-number W))
            (and H (string-to-number H))
            o))))


;;; Normalizers

;; convert backend can accept a multitude of string inputs. 
(defvar image-transform-accept-unparsed nil
  "Non-nil when numeric writers should accepts non passable strings as a valid input.")

(defun image-transform-spec:number (key value)
  "Basic processor of numeric transform specifications.

KEY names the transformation.  VALUE must be a number or a string
that could be converted into a number.  If the conversion has
failed and `image-transform-accept-unparsed' is nil, signal
'next-backend."
  (setq value
        (pcase value
          ((or (pred null)
               (pred numberp)) value)
          ((pred stringp)
           (or (image-transform-parse:number value)
               (if image-transform-accept-unparsed
                   value
                 (signal 'next-backend
                         (list (format "Cannot parse %s value" key))))))
          (_ (signal 'next-backend
                     (list (format "Invalid type of argument %s" key))))))
  (list key (if (numberp value)
                (number-to-string value)
              value)))

(defalias 'image-transform-spec:degrees 'image-transform-spec:number)
(defalias 'image-transform-spec:value 'image-transform-spec:number)

(defun image-transform-spec:scale (tr value)
  "Process scale argument of transformation TR.
VALUE must be a number or string of the form \"N%\" where N is a
number, giving the percentage by which to scale the image.

For \"convert\" backend scale can take additional geometry
specifications."
  (setq value
        (pcase value
          ((or (pred null)
               (pred numberp)) value)
          ((pred stringp)
           (or (image-transform-parse:scale value)
               (if image-transform-accept-unparsed
                   value
                 (signal 'next-backend
                         (list (format "Cannot parse %s value" tr))))))
          (_ (signal 'next-backend
                     (list (format "Invalid type of argument %s" tr))))))
  (list tr (if (numberp value)
                (concat (number-to-string value) "%")
              value)))

(defun image-transform-spec:boolean (key value)
  "Simply return (KEY VALUE) list."
  (list key value))

(defun image-transform-spec:geometry (tr value)
  "Normalize geometry VALUE for transformation TR.

VALUE can be

 - numeric - interpreted as width.

 - string - interpreted as \"convert\" program specification. It
   is parsed by `image-transform-parse:geometry' for 'native'
   backend and is passed as is to 'convert' backend.

 - cons (W . H) or list (W H) - rescale the image maximally such
   that new image fits into (W . H) box. Aspect ratio
   preserved. Equivalent to WxH \"convert\" specification.

 - list (W H o) - Similar to \"WxHo\" convert geometry
   specification where 'o' can be \"!\",\"%\",\"^\",\"@\",\">\"
   or \"<\".

For example, to force the new dimensions of the image you should
supply (list W H \"!\")."

  ;; If `image-transform-accept-unparsed' is non-nil, accepts strings that
  ;; don't match the above pattern. Otherwise pass to next backend by
  ;; signaling 'next-backend.

  (setq value
        (pcase value
          ((pred null) value)
          ((pred numberp) (number-to-string value))
          (`(,w ,h ,o . nil) (concat (and w (number-to-string w)) "x"
                                     (and h (number-to-string h)) o))
          ;; (`(,w . nil) (number-to-string w))
          ((or `(,w ,h . nil) `(,w . ,h))
           (concat (and w (number-to-string w)) "x"
                   (and h (number-to-string h))))
          ((pred stringp)
           (if (or (image-transform-parse:geometry value)
                   image-transform-accept-unparsed)
               value
             (signal 'next-backend
                     (list (format "Cannot parse %s geometry argument" tr)))))
          (_ (signal 'next-backend
                     (list (format "Invalid %s geometry specification" tr))))))
  (list tr value))

(defun image-transform-spec:choice (TR value &rest choices)
  "For transformation TR, check if VALUE is in CHOICES list.
Return '(TR value) if true, and signal 'next-backend error
otherwise."
  (if (member value choices)
      (list TR value)
    (signal 'next-backend
            (list (format "%s is not a valid value of option %s" value TR)))))



;;; Transform API utilities

(defun image-tr--unsupported-features (specs backend)
  "Return unsupported features from SPECS by BACKEND.
SPECS are as in `image-transform'.  BACKEND is a symbol or a
string."
  (let ((features (cl-loop for s in specs if (keywordp s) collect s))
        (available (symbol-value
                    (intern (concat "image-transform-features:"
                                    (if (symbolp backend)
                                        (symbol-name backend)
                                      backend))))))
    (cl-loop for f in features
             unless (assoc f available)
             collect f)))

(defun image-tr--check-unsupported-features (image newspecs backend)
  "Signal 'next-backend if any of IMAGE's specs or NEWSPECS are unsupported by BACKEND.
NEWSPECS are as SPECS in `image-transform'."
  (let* ((trlist (image-get-transforms image))
         (un-specs (image-tr--unsupported-features newspecs backend))
         (un-tr (image-tr--unsupported-features (cdr trlist) backend)))
    (when un-specs
      (signal 'next-backend
              (list (format "Unsupported features: %s" un-specs))))
    (when un-tr
      (signal 'next-backend
              (list (format "Unsupported existing transforms: %s" un-tr))))))

(defun image-tr--normalize-boolean-specs (specs backend)
  "Insert missing boolean values into SPECS given BACKEND's features.
SPECS are as in `image-transform'."
  (let ((p specs)
        (features (symbol-value (intern (format "image-transform-features:%s" backend)))))
    (while p
      (when (and (keywordp (car p))
                 (or (keywordp (cadr p))
                     (eq 1 (length p))))
        (if (eq 'boolean (nth 2 (assoc (car p) features)))
            (setcdr p (push t (cdr p)))
          (signal 'next-backend (list "Missing value for non-boolean %s" (car p)))))
      (setq p (cdr p)))
    specs))

(defun image-tr--normalize-specs (specs backend)
  "Normalize SPECS given the spec types declared in the BACKEND."
  (cl-loop for s on specs by 'cddr append
           (let* ((el (assoc (car s)
                             (symbol-value
                              (intern (concat "image-transform-features:"
                                              (symbol-name backend))))))
                  (read-type (nth 2 el))
                  (reader (intern (concat "image-transform-spec:"
                                          (if (listp read-type)
                                              (symbol-name (car read-type))
                                            (symbol-name read-type))))))
             (unless el
               (error "No reader for %s in %s backend" (car s) backend))
             (if (fboundp reader)
                 (if (listp read-type)
                     (apply reader (car s) (cadr s) (cdr read-type))
                   (funcall reader (car s) (cadr s)))
               (list (car s) (cadr s))))))

(defun image-tr--add-transforms (trs newtrs)
  "Destructively populate TRS with NEWTRS transforms.
Return new TRS.  Both TRS and NEWTRS are list of pairs :TR VALUE,
with possibly repeated keys.  If VALUE is nil, all :TR key-values
are removed from TRS."
  (cl-loop for s on newtrs  by 'cddr do
           (let ((kwd (car s))
                 (val (cadr s)))
             (if (null val)
                 ;; API: remove null properties 
                 (image-tr--delete-properties trs (list kwd))
               (setq trs (append trs (list kwd val))))))
  trs)

(defun image-tr--adjust-specs-for-fit (image newspecs)
  "Adjust IMAGE's specs by processing :resize spec from NEWSPECS.
Return a transformed NEWSPECS list."
  (let ((resize (cadr (memq :resize newspecs))) )
    (when (and resize
               (symbolp resize))
      (let* ((rotate (cadr (memq :rotate newspecs)))
             (orot (plist-get (cdr image) :rotation))
             (win (or (cadr (memq :window newspecs))
                      (selected-window)))
             ;; Note: `image-size' looks up and thus caches the
             ;; untransformed image. There's no easy way to prevent
             ;; that. VS[17-07-2013]: This seems not to be true
             ;; anymore, `image-size' does return the size of
             ;; transformed image.
             (size (image-tr--osize image))
             ;; user-size
             (usize (cons (plist-get (cdr image) :width)
                          (plist-get (cdr image) :height)))
             (newrot (float (mod (+ (or rotate 0.0) (or orot 0.0)) 360)))
             (newsize (cons (image-tr--get-rotated-width
                             (car size) (cdr size) newrot)
                            (image-tr--get-rotated-width
                             (cdr size) (car size) newrot))))

        (unless (member resize '(nil fit fit-if-large fit-width
                                     fit-height fit-stretch))
          (error "Invalid :resize argument"))
        
        (plist-put newspecs :resize
                   (let* ((wedges (window-inside-pixel-edges win))
                          (wsize (cons (- (nth 2 wedges)
                                          (nth 0 wedges))
                                       (- (nth 3 wedges)
                                          (nth 1 wedges))))
                          (resize (if (and (eq resize 'fit-if-large)
                                           (or (> (car newsize) (car wsize))
                                               (> (cdr newsize) (cdr wsize))))
                                      'fit
                                    resize))
                          (resize (if (eq resize 'fit)
                                      (if (< (/ (float (car wsize)) (cdr wsize))
                                             (/ (float (car newsize)) (cdr newsize)))
                                          'fit-width
                                        'fit-height)
                                    resize)))

                     (cond
                      ((eq resize 'fit-stretch)
                       (let ((res (image-tr--get-rotated-size
                                   (car wsize) (cdr wsize) (car wsize) newrot)))
                         ;; fixme: stretching doesn't work correctly with rotation
                         (when (null (car res))
                           (setcar res (car wsize)))
                         (when (null (cdr res))
                           (setcdr res (cdr wsize)))
                         (list (car res) (cdr res) "!")))
                      ((eq resize 'fit-width)
                       (let ((res (image-tr--get-rotated-size
                                   (car size) (cdr size) (car wsize) newrot)))
                         ;; don't provide both W and H unnecessarily
                         (list (car res) (unless (car res) (cdr res)))))
                      ((eq resize 'fit-height)
                       (let ((res (image-tr--get-rotated-size
                                   (cdr size) (car size) (cdr wsize) newrot)))
                         (list (unless (car res) (cdr res)) (car res))))))))))
  newspecs)



;;; Transform API

;;;###autoload
(defun image-transform (image &rest specs)
  "Transform IMAGE by applying transformation SPECS.

Transformation backends listed in `image-transform-backends' are
tried in turn and the first suitable backend is applied.  If none
of the backends can be applied an error is thrown.

SPECS is a list of key-value pairs giving the name and parameters
of the transformation.  See `image-transform-features:native'
and `image-transform-features:convert' for lists of supported
features.  Boolean specs can miss the value, in which case t is
assumed.

Specs's values are either strings encoded with image 'convert'
conventions or elisp objects that are normalized to canonical
string form with `image-transform-spec:TYPE' functions, where
TYPE is the type of the spec.  Examples of normalizers are
`image-transform-spec:geometry', `image-transform-spec:number',
`image-transform-spec:scale' and `image-transform-spec:choice'.

All the transformations applied so far are stored as part of the
Emacs image data structure.  Each time a new transformation is
applied, the whole transformation chain is re-applied to the
original image.  This ensures that internal optimization of the
'convert' backend can be used and the image doesn't unnecessarily
loose quality on repeated transformation.

This function acts destructively.  Use `copy-list' to avoid
modifying existing images.

Several specs are treated specially or are pre-processed before
being dispatched to the backend functions:

  :backend - enforce a specific backend.

  :resize can be:
   - a number, giving new width of the image
   - a cons, giving the size (w x h) in pixels.
   - a symbol:
     *`fit' - maximally scale IMAGE to fit into WIN.
     *`fit-height' - fit the image to WIN's height.
     *`fit-width' - fit the image to WIN's width.
     *`fit-stretch' - stretch the image to fit to both height and
      width of WIN.

  :save-to-file - save the transformed image into file and
  replace the current image specification with the new file (not
  implemented yet)
 
  :window - a window to be used when :resize is a
  symbol.  Defaults to the selected window.

Examples:

  (image-transform img :resize 'fit-width)
  (image-transform img :resize 'fit-height)
  (image-transform img :resize 'fit)
  (image-transform img :resize 'fit :backend 'convert)
  (image-transform img :resize 'fit :rotate 45)
  (image-transform img :resize 'fit-height :rotate 60)

  (image-transform img :resize 200)
  (image-transform img :resize '(500 . 500))
  (image-transform img :resize '(500 500 \"!\"))

  (image-transform img :background \"pink\")
  (image-transform img :background \"pink\" :flatten :backend 'convert)"
  ;;cannot use plist-get to extract :backend, because of boolean specs
  (let* ((force-backend (cl-loop for val on specs 
				 if (eq (car val) :backend)
				 return (cadr val)))
         (backends (if (null force-backend)
                       (copy-sequence image-transform-backends)
                     (setq specs (image-tr--delete-properties specs '(:backend)))
                     (list force-backend)))
         (bknd-errors "")
         out bknd bknd-specs)

    (image-tr--osize image) ;; side effect of caching :osize
    ;; adjust for 'fit 'fit-width etc
    (setq specs (image-tr--adjust-specs-for-fit image specs))
    
    (while (and (null out)
                (setq bknd (pop backends)))
      
      (let ((bknd-fun (intern (concat "image-transform:"
                                  (symbol-name bknd)))))
        (condition-case data
	    (progn 
	      (setq bknd-specs (image-tr--normalize-boolean-specs (copy-list specs) bknd))
	      (image-tr--check-unsupported-features image bknd-specs bknd)
	      (setq out (apply bknd-fun image bknd-specs)))
          (next-backend
           (setq bknd-errors (format "%s\n%s: %s"
                                 bknd-errors bknd (cadr data)))))))
    (unless out
      (error "All backends failed with the following errors: %s" bknd-errors))
    out))

(defun image-transform-interactive (&optional image &rest specs)
  "Like `image-transform' but also refresh window display.
Intended to be used for user level commands.  IMAGE defaults to
`image-at-point'.  SPECS is as in `image-transform'."
  (let ((image (or image (image-at-point))))
    (unless image
      (error "No image at point"))
    (prog1 (apply 'image-transform image specs)
      (force-window-update (selected-window)))))


;;;; Native Backend

(defvar image-transform-features:native
  '((:background "Background for images with transparent background")
    (:resize "Resize the image" geometry)
    (:rotate "Rotation in degrees" degrees)
    (:scale "Scale in percent. Can be a number or numeric string." scale)
    (:flatten "Does nothing. It's here for compatibility with 'convert' backend only." boolean))
  "Alist of supported features by 'native' backend.
Each element is a list of the form (FEATURE DOC READER-TYPE).
See `image-transform-backends' for a full description.")

(defun image-transform:native (image &rest specs)
  "Emacs's native ImageMagick transform backend.
IMAGE and SPECS are as in `image-transform'.

See `image-transform-features:native' for transform
specifications accepted by this backend."

  (unless (image-type-available-p 'imagemagick)
    (signal 'next-backend '("Emacs wasn't built with ImageMagick support")))
  
  (let* ((newtrs (image-tr--normalize-specs specs 'native))
         (trlist (image-tr--add-transforms
                  (image-get-transforms image) newtrs)))

    (plist-put (cdr image) :transforms trlist)
    
    ;; reset imagemagick properties 
    (image-tr--delete-properties image '(:width :height :rotation :background))

    ;; reset convert specs if any
    (when (plist-get (cdr image) :ofile)
      (image-tr--delete-properties (cdr image) '(:data))
      (plist-put (cdr image) :file (plist-get (cdr image) :ofile)))
    
    ;; now apply the transforms
    (cl-loop for s on (cdr trlist) by 'cddr do
             ;; fixme: image might have been transformed by convert before?
             (when (assoc (car s) image-transform-features:native)
               (pcase (cons (car s) (cadr s))
                 (`(:resize . ,resize)
                  (pcase (image-transform-parse:geometry resize)
                    (`(,scale nil "%") (image-tr--rescale image scale))
                    (`(,sW ,sH "%") (image-tr--rescale image sW sH))
                    (`(,area "@") (error "Area geometry is not implemented yet"))
                    (`(,W nil nil)
                     (plist-put (cdr image) :width W)
                     (image-tr--delete-properties image '(:height)))
                    (`(nil ,H nil)
                     (plist-put (cdr image) :height H)
                     (image-tr--delete-properties image '(:width)))
                    ;; fixme: collapse following cases into one?  
                    (`(,W ,H nil)
                     ;; Maximum values of height and width given, aspect ratio preserved.
                     (let ((osize (image-tr--osize image)))
                       (if (> (/ (float (car osize)) (cdr osize))
                              (/ (float W) H))
                           (progn (plist-put (cdr image) :width W)
                                  (image-tr--delete-properties image '(:height)))
                         (plist-put (cdr image) :height H)
                         (image-tr--delete-properties image '(:width)))))
                    (`(,W ,H "^")
                     ;; Minimum values of width and height given,
                     ;; aspect ratio preserved. fixme: is this
                     ;; correct computation?
                     (let ((osize (image-tr--osize image)))
                       (if (< (/ (float (car osize)) (cdr osize))
                              (/ (float W) H))
                           (progn (plist-put (cdr image) :width W)
                                  (image-tr--delete-properties image '(:height)))
                         (plist-put (cdr image) :height H)
                         (image-tr--delete-properties image '(:width)))))
                    (`(,W ,H ">") (error "> operator is not implemented yet"))
                    (`(,W ,H "<") (error "< operator is not implemented yet"))
                    (`(,W ,H "!")
                     (if W
                         (plist-put (cdr image) :width W)
                       (image-tr--delete-properties image '(:width)))
                     (if H
                         (plist-put (cdr image) :height H)
                       (image-tr--delete-properties image '(:height))))
                    (`(,W ,H ,x)
                     ;; This should not happen, validity checks are
                     ;; in the geometry reader.
                     (error "Invalid geometry operator %s", x))))
                 (`(:rotate . ,rot)
                  (plist-put (cdr image) :rotation
                             (mod (+ (or (plist-get (cdr image) :rotation) 0.0)
                                     (image-transform-parse:number rot))
                                  360)))
                 (`(:scale . ,scale)
                  (image-tr--rescale image (image-transform-parse:scale scale)))
                 (`(:background . ,val)
                  (plist-put (cdr image) :background val))
		 (`(:flatten . ,val))
                 ;; should never reach this place
                 (_ (error "Incorrect specification in 'native' backend")))))

    (plist-put (cdr image) :transform-backend 'native)
    (plist-put (cdr image) :type 'imagemagick)
    image))


;;;; Convert Backend

(defvar image-transform-features:convert 
  '((:-- "Image Settings")
    ;; (:adjoin boolean 	"join images into a single multi-image file")
    ;; (:affine 'matrix	"affine transform matrix")
    (:antialias "remove pixel-aliasing" boolean )
    (:authenticate "decrypt image with this password" value )
    (:background "background color" color )
    (:bias "add bias when convolving an image" value )
    (:black-point-compensation "use black point compensation" boolean )
    (:blue-primary "chromaticity blue primary point" point )
    (:bordercolor "border color" color )
    (:caption "assign a caption to an image" string )
    (:cdl "color correct with a color decision list" filename )
    (:channel "apply option to select image channels" type )
    (:colors "preferred number of colors in the image" value )
    (:colorspace "alternate image colorspace"
                 (choice CMY CMYK Gray HCL HCLp HSB HSI HSL HSV
                         HWB Lab LCHab LCHuv LMS Log Luv OHTA
                         Rec601YCbCr Rec709YCbCr RGB scRGB sRGB
                         Transparent XYZ YCbCr YCC YDbDr YIQ
                         YPbPr YUV))
    (:comment "annotate image with comment" string )
    (:compose "set image composite operator" operator )
    (:compress "type of pixel compression when writing the image"
               (choice None BZip Fax Group4 JPEG JPEG2000 Lossless LZW RLE or Zip))
    (:decipher "convert cipher pixels to plain pixels" filename )
    (:define "define one or more image format options" format-option )
    (:delay "display the next image after pausing" value )
    (:density "horizontal and vertical density of the image" geometry )
    (:depth "image depth" value )
    (:direction "render text right-to-left or left-to-right" type )
    (:display "get image or font from this X server" server )
    (:dispose "layer disposal method" method )
    (:dither "apply error diffusion to image" method )
    (:encipher "convert plain pixels to cipher pixels" filename )
    (:encoding "text encoding type"
               (choice None BZip Fax Group4 JPEG JPEG2000 Lossless LZW RLE or Zip))
    (:endian "endianness (MSB or LSB) of the image"
             (choice MSB LSB))
    (:family "render text with this font family" name )
    (:features "analyze image features (e.g. contrast, correlation" distance )
    (:fill "color to use when filling a graphic primitive" color )
    (:filter "use this filter when resizing an image"
             (choice Point Hermite Cubic Box Gaussian Catrom
                     Triangle Quadratic Mitchell))
    (:flatten "flatten a sequence of images" boolean )
    (:font "render text with this font" name )
    (:format "output formatted image characteristics" string )
    (:fuzz "colors within this distance are considered equal" distance )
    (:gravity "horizontal and vertical text placement"
              (choice Point Hermite Cubic Box Gaussian Catrom
                      Triangle Quadratic Mitchell))
    (:green-primary "chromaticity green primary point" point )
    (:intent "type of rendering intent when managing the image color"
             (choice Absolute Perceptual Relative Saturation))
    (:interlace "type of image interlacing scheme"
                (choice none line plane partition JPEG GIF PNG))
    (:interpolate "pixel color interpolation method"
                  (choice integer nearest-neighbor average
                          bilinear mesh bicubic spline filter ))
    (:kerning "set the space between two letters" value )
    (:label "assign a label to an image" string )
    (:limit "pixel cache resource limit" type-value )
    (:loop "add Netscape loop extension to your GIF animation" iterations )
    (:mask "associate a mask with the image" filename )
    (:matte "store matte channel if the image has one" boolean )
    (:mattecolor "frame color" color )
    (:monitor "monitor progress" boolean )
    (:orient "image orientation"
             (choice bottom-left bottom-right left-bottom
                     left-top right-bottom right-top top-left
                     top-right undefined))
    (:origin "image origin" geometry )
    (:page "size and location of an image canvas (setting)" geometry )
    (:ping "efficiently determine image attributes" boolean )
    (:pointsize "font point size" value )
    (:preview "image preview type"
              (choice Rotate Shear Roll Hue Saturation Brightness
                      Gamma Spiff Dull Grayscale Quantize
                      Despeckle ReduceNoise Add Noise Sharpen
                      Blur Threshold EdgeDetect Spread Shade
                      Raise Segment Solarize Swirl Implode Wave
                      OilPaint CharcoalDrawing JPEG))
    (:quality "JPEG/MIFF/PNG compression level" value )
    (:quiet "suppress all warning messages" boolean )
    (:red-primary "chromaticity red primary point" point )
    (:regard-warnings "pay attention to warning messages" boolean )
    (:sampling-factor "horizontal and vertical sampling factor" geometry )
    (:scene "image scene number" value )
    (:seed "seed a new sequence of pseudo-random numbers" value )
    (:size "width and height of image" geometry )
    (:statistic	"replace each pixel with corresponding statistic from the neighborhood"
                (choice Gradient Maximum Minimum Mean Median Mode
                        Nonpeak ))
    (:stretch "render text with this font stretch"
              (choice Any Condensed Expanded ExtraCondensed
                      ExtraExpanded Normal SemiCondensed
                      SemiExpanded UltraCondensed UltraExpanded))
    (:stroke "graphic primitive stroke color" color )
    (:strokewidth "graphic primitive stroke width" value )
    (:style "render text with this font style"
            (choice Any Italic Normal Oblique))
    (:support "resize support: > 1.0 is blurry, < 1.0 is sharp" factor )
    (:synchronize "synchronize image to storage device" boolean )
    (:taint "declare the image as modified" boolean )
    (:texture "name of texture to tile onto the image background" filename )
    (:tile-offset "tile offset" geometry )
    (:treedepth "color tree depth" value )
    (:transparent-color "transparent color" color )
    (:undercolor "annotation bounding box color" color )
    (:units "the units of image resolution"
            (choice  Undefined PixelsPerInch PixelsPerCentimeter) )
    (:verbose "print detailed information about the image" boolean )
    (:view "FlashPix viewing transforms" boolean )
    (:virtual-pixel "virtual pixel access method" method )
    (:weight "render text with this font weight"
             (choice Undefined PixelsPerInch PixelsPerCentimeter))
    (:white-point "chromaticity white point" point )

    (:-- "Image Operators")
    (:adaptive-blur "adaptively blur pixels, decrease effect near edges" geometry )
    (:adaptive-resize "adaptively resize image with data dependent triangulation" geometry )
    (:adaptive-sharpen "adaptively sharpen pixels, increase effect near edges" geometry )
    (:annotate 	"annotate the image with text" geometry-text ) ;;??
    (:auto-orient "automatically orient image" boolean )
    (:black-threshold "force all pixels below the threshold into black" value )
    (:blur "reduce image noise and reduce detail levels" geometry )
    (:border "surround image with a border of color" geometry )
    (:charcoal "simulate a charcoal drawing" radius )
    (:chop "remove pixels from the image interior" geometry )
    (:clip "clip along the first path from the 8BIM profile" boolean )
    (:clip-mask "associate a clip mask with the image" filename )
    (:clip-path "clip along a named path from the 8BIM profile" id )
    (:colorize "colorize the image with the fill color" value )
    (:color-matrix "apply color correction to the image" matrix )
    (:contrast "enhance the image contrast" boolean)
    (:+contrast "reduce the image contrast" boolean)
    (:contrast-stretch "improve contrast by `stretching the intensity range" geometry )
    (:convolve "apply a convolution kernel to the image" coefficients )
    (:cycle "cycle the image colormap" amount )
    (:despeckle "reduce the speckles within an image" boolean )
    (:draw "annotate the image with a graphic primitive" string )
    (:edge "apply a filter to detect edges in the image" radius )
    (:emboss "emboss an image" radius )
    (:enhance "apply a digital filter to enhance a noisy image" boolean )
    (:equalize "perform histogram equalization to an image" boolean )
    (:evaluate "evaluate an arithmetic, relational, or logical expression" value-operator ) ;;??
    (:extent "set the image size" geometry )
    (:extract "extract area from image" geometry )
    (:fft "implements the discrete Fourier transform (DFT)" boolean )
    (:flip "flip image vertically" boolean )
    (:floodfill "floodfill the image with color" geometry-color ) ;??
    (:flop "flop image horizontally" boolean )
    (:frame "surround image with an ornamental border" geometry )
    (:function "apply a function to the image" name )
    (:gamma "level of gamma correction" value )
    (:gaussian-blur "reduce image noise and reduce detail levels" geometry )
    (:geometry "preferred size or location of the image" geometry )
    (:identify "identify the format and characteristics of the image" boolean )
    (:ift "implements the inverse discrete Fourier transform (DFT)" boolean )
    (:implode "implode image pixels about the center" amount )
    (:lat "local adaptive thresholding" geometry )
    (:layers "optimize or compare image layers" method )
    (:level "adjust the level of image contrast" value )
    (:linear-stretch "improve contrast by `stretching with saturation the intensity range" geometry )
    (:median "apply a median filter to the image" geometry )
    (:mode "make each pixel the predominant color of the neighborhood" geometry )
    (:modulate "vary the brightness, saturation, and hue" value )
    (:monochrome "transform image to black and white" boolean )
    (:morphology "apply a morphology method to the image" method-kernel ) ;;??
    (:motion-blur "simulate motion blur" geometry )
    (:negate "replace each pixel with its complementary color" boolean )
    (:noise "add or reduce noise in an image" geometry )
    (:normalize "transform image to span the full range of colors" boolean )
    (:opaque "change this color to the fill color" color )
    (:ordered-dither "add a noise pattern to the image with specific amplitudes" NxN )
    (:paint "simulate an oil painting" radius )
    (:polaroid "simulate a Polaroid picture" angle )
    (:posterize "reduce the image to a limited number of color levels" levels )
    (:print "interpret string and print to console" string )
    (:profile "add, delete, or apply an image profile" filename )
    (:quantize "reduce colors in this colorspace" colorspace )
    (:radial-blur "radial blur the image" angle )
    (:raise "lighten/darken image edges to create a 3-D effect" value )
    (:random-threshold "random threshold the image" low,high )
    (:region "apply options to a portion of the image" geometry )
    (:render "render vector graphics" boolean )
    (:repage "size and location of an image canvas" geometry )
    (:resample "change the resolution of an image" geometry )
    (:resize "resize the image" geometry )
    (:roll "roll an image vertically or horizontally" geometry )
    (:rotate "apply Paeth rotation to the image" degrees )
    (:sample "scale image with pixel sampling" geometry )
    (:scale "scale the image" scale)
    (:segment "segment an image" values )
    (:selective-blur "selectively blur pixels within a contrast threshold" geometry )
    (:sepia-tone "simulate a sepia-toned photo" threshold )
    (:set "set an image property" property-value ) ;??
    (:shade "shade the image using a distant light source" degrees )
    (:shadow "simulate an image shadow" geometry )
    (:sharpen "sharpen the image" geometry )
    (:shave "shave pixels from the image edges" geometry )
    (:shear "slide one edge of the image along the X or Y axis" geometry )
    (:sigmoidal-contrast "lightness rescaling using sigmoidal contrast enhancement" geometry )
    (:sketch "simulate a pencil sketch" geometry )
    (:solarize "negate all pixels above the threshold level" threshold )
    (:splice "splice the background color into the image" geometry )
    (:spread "displace image pixels by a random amount" amount )
    (:strip "strip image of all profiles and comments" boolean )
    (:swirl "swirl image pixels about the center" degrees )
    (:threshold "threshold the image" value )
    (:thumbnail "create a thumbnail of the image" geometry )
    (:tile "tile image when filling a graphic primitive" filename )
    (:tint "tint the image with the fill color" value )
    (:transform "affine transform image" boolean )
    (:transparent "make this color transparent within the image" color )
    (:transpose "flip image vertically and rotate 90 degrees" boolean )
    (:transverse "flop image horizontally and rotate 270 degrees" boolean )
    (:trim "trim image edges" boolean )
    ;; (:type "image type" type ) ; tothink: put this back?
    (:unique-colors "discard all but one of any pixel color" boolean )
    (:unsharp "sharpen the image" geometry )
    (:vignette "soften the edges of the image in vignette style" geometry )
    (:wave "alter an image along a sine wave" geometry )
    (:white-threshold "force all pixels above the threshold into white" value )

    (:-- "Image Sequence Operators")
    (:affinity "transform image colors to match this set of colors" filename )
    (:append "append an image sequence top to bottom (use +append for left to right)" boolean )
    (:clut "apply a color lookup table to the image" boolean )
    (:coalesce "merge a sequence of images" boolean )
    (:combine "combine a sequence of images" boolean )
    (:composite "composite image" boolean )
    (:crop "cut out a rectangular region of the image" geometry )
    (:deconstruct "break down an image sequence into constituent parts" boolean )
    (:evaluate-sequence "evaluate an arithmetic, relational, or logical expression" operator )
    (:flatten "flatten a sequence of images" boolean )
    (:fx "apply mathematical expression to an image channel(s)" expression )
    (:hald-clut "apply a Hald color lookup table to the image" boolean )
    (:morph "morph an image sequence" value )
    (:mosaic "create a mosaic from an image sequence" boolean )
    (:process "process the image with a custom image filter" arguments )
    (:separate "separate an image channel into a grayscale image" boolean )
    (:smush "smush an image sequence together" geometry )
    (:write "write images to this file" filename )

    (:-- "Image Stack Operators")
    (:clone "clone an image" indexes )
    (:delete "delete the image from the image sequence" indexes )
    (:duplicate "duplicate an image one or more times" count,indexes )
    (:insert "insert last image into the image sequence" index )
    (:swap "swap two images in the image sequence" indexes )

    ;; (:-- "Miscellaneous Options")
    ;; (:debug "display copious debugging information" events )
    ;; (:help "print program options" boolean )
    ;; (:log "format of debugging information" format )
    ;; (:list "print a list of supported option arguments" type )
    ;; (:version "print version information" boolean )
    )
  "Alist of supported features by \"convert\" backend.
Each element is a list of the form (FEATURE DOC READ-TYPE)

See `image-transform-backends' for a full description.

http://www.imagemagick.org/script/command-line-processing.php")

(defun image-tr--convert-args (&optional image concat)
  "Get from IMAGE a list of transform arguments suitable for `call-process'.
If CONCAT is non-nil, also concatenate arguments and return a
string instead of a list."
  (setq image (or image (image-at-point)))
  (let* ((transforms (cdr (plist-get (cdr image) :transforms)))
         args)
    (setq args
          (append
           (cl-loop for s on transforms by 'cddr
                    append
                    (let ((type (nth 2 (assoc (car s) image-transform-features:convert)))
                          (opt (symbol-name (car s))))
                      (list (concat (if (string-match-p "^:\\+" opt) "" "-")
                                    (substring opt 1))
                            (unless (eq 'boolean type)
                              ;; could be symbol, number etc
                              (format "%s" (cadr s))))))
           '("-")))
    
    (setq args (delq nil args))
    (if concat
        (mapconcat 'identity args " ")
      args)))

(defun image-tr--process-convert-transforms (image)
  "Call \"convert\" on IMAGE and insert transformed data as :data image spec.
IMAGE is modified destructively. Currently, only images loaded
from a file are handled by this backend."
  ;; fixme: shell quoting is likely necessary for some convert specs
  (let* ((specs (cdr image))
         (buf (get-buffer-create "*image-tr-output*"))
	 (file (plist-get specs :file))
         (ofile (or (plist-get specs :ofile)
		    file
		    (signal 'next-backend "Image is not associated with a file")))
         (type (plist-get specs :type))
         (log-file (expand-file-name ".image-transform.log")) ; debug only
         (args (image-tr--convert-args image)))

    (when (or (eq type 'imagemagick)
              (null type))
      (setq type
            (if file
                (image-type ofile)
              (image-type (plist-get (cdr image) :data) nil t))))
    
    (plist-put specs :ofile ofile)
    
    (plist-put specs :data
               (with-current-buffer buf
                 (erase-buffer)
                 (set-buffer-multibyte nil)
                 (when (/= 0 (apply 'process-file image-transform-convert-program
                                    nil (list t log-file) nil (expand-file-name ofile) args))
                   (erase-buffer)
		   (insert (format "COMMAND: %s %s %s\n\n"
				   image-transform-convert-program
				   (expand-file-name ofile)
				   (combine-and-quote-strings args)))
                   (insert-file-contents log-file)
                   (signal 'next-backend (list (format "convert error: %s" (buffer-string)))))
                 (buffer-string)))

    (message "command: %s %s %s\n\n"
	     image-transform-convert-program
	     (expand-file-name ofile)
	     (combine-and-quote-strings args))
    
    ;; (delete-file log-file)
    (image-tr--delete-properties image '(:file))
    (plist-put specs :type type)
    
    image))

(defun image-transform:convert (image &rest specs)
  "ImageMagick Convert backend.
Convert IMAGE through a call to \"convert\" program and pass
transforms in SPECS.  SPECS are as in `image-transform'. See
`image-transform-features:convert' for transforms accepted by
this backend."
  (let* ((image-transform-accept-unparsed t) ; pass directly to convert
         (newtrs (image-tr--normalize-specs specs 'convert))
         (trlist (image-tr--add-transforms
                  (image-get-transforms image) newtrs)))
    (plist-put (cdr image) :transforms trlist)
    (plist-put (cdr image) :transform-backend 'convert)
    (image-tr--process-convert-transforms image)))

(defvar image-tr--describe-hist nil)
(defun image-transform-describe-convert-option (&optional option)
  "Display an online documentation of \"convert\" OPTION."
  (interactive)
  (let* ((opts (delete "--"
                       (mapcar (lambda (x)
                                 (substring (symbol-name (car x)) 1))
                               image-transform-features:convert)))
         (O (completing-read "Convert option: " (append '("*ALL*") opts)
                             nil t nil 'image-tr--describe-hist)))
    (browse-url (if (equal O "*ALL*")
                    "http://www.imagemagick.org/script/convert.php"
                  (format "http://www.imagemagick.org/script/command-line-options.php#%s" O)))))



;;; Transform UI

(defvar image-tr--add-transform-hist nil)

;;;###autoload
(defun image-add-transform (&optional image)
  "Interactively add transform to IMAGE.
IMAGE defaults to `image-at-point'.  Don't use this function in
programs, use `image-transform' instead."
  (interactive)
  (let* ((allopts (delete ":--"
                          (mapcan (lambda (b)
                                    (let ((b (intern (format "image-transform-features:%s" b))))
                                      (mapcar (lambda (x)
                                                (let ((x (symbol-name (car x))))
                                                  (propertize x 'backend b)))
                                              (symbol-value b))))
                                  image-transform-backends)))
         (tr (completing-read "Transform: " allopts nil t nil 'image-tr--add-transform-hist))
         (tr-symb (intern tr))
         (type (nth 2 (assoc tr-symb
                             (symbol-value (get-text-property 1 'backend tr)))))
         (prompt (format "%s: " tr))
         (value (pcase type
                  (`boolean t)
                  (`(choice . ,opts) (completing-read prompt opts))
                  (`number (read-number prompt))
                  (`filename (read-file-name prompt))
                  (_ (read-string prompt)))))
    (image-transform-interactive image tr-symb value)))

;;;###autoload
(defun image-list-transforms (&optional image)
  "Print all transforms associated with IMAGE.
IMAGE defaults to `image-at-point'."
  (interactive)
  (message "%s" (cdr (image-get-transforms image))))

;;;###autoload
(defun image-delete-transform (&optional image transform)
  "Remove from IMAGE the TRANSFORM.
IMAGE defaults to `image-at-point'.  Don't use this function in
programs, use `image-tr--delete-transforms' instead."
  (interactive)
  (setq image (or image (image-at-point)))
  (let* ((trs (cl-loop for el in (image-get-transforms image)
		       if (keywordp el) collect (symbol-name el)))
         (tr (if trs
                 (completing-read "Delete transform: " (append '("*ALL*") trs) nil t)
               (message "No transforms for current image")
               nil)))
    (when tr
      (if (equal tr "*ALL*")
          (plist-put (cdr image) :transforms '(tr))
        (image-tr--delete-transforms image (list (intern tr)))))
    (image-transform image)))

(provide 'image-transform)

(provide 'image-transform)

;;; image-transform.el ends here
