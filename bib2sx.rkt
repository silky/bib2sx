#lang racket


; bib2sx: A Racket script for converting a bibtex .bib file to S-Expressions

; Copyright (C) 2015 Matthew Might

; This program is free software: you can redistribute it and/or modify
; it under the terms of the GNU General Public License as published by
; the Free Software Foundation, either version 3 of the License, or
; (at your option) any later version.

; This program is distributed in the hope that it will be useful,
; but WITHOUT ANY WARRANTY; without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
; GNU General Public License for more details.

; You should have received a copy of the GNU General Public License
; along with this program.  If not, see <http://www.gnu.org/licenses/>.

; TODO:

; + Define input grammar
; + Add flag (--hash) output #hash instead of AST
; + Add special handling for month codes


; Output bibtex AST grammar:

; <bibtex-ast> ::= (<item> ...)

; <item> ::= (<item-type> <id> <attr> ...)

; <attr> ::= (<name> <expr> ...)

; <expr> ::= <string>
;         |  '<expr>
;         |  '(<expr> ...)
;         |  <id>

; <name> ::= <id>

; <item-type> ::= inproceedings | article | ...



(require parser-tools/lex)
(require (prefix-in : parser-tools/lex-sre))
(require parser-tools/yacc)



; helpers:
(define (symbol-downcase s)
  (string->symbol (string-downcase (symbol->string s))))



; Token types:
(define-empty-tokens PUNCT (@ |{| |}| |"| |#| |,| =))
(define-empty-tokens EOF (EOF))

(define-tokens WHITESPACE (SPACE))
(define-tokens EXPR (ID STRING))



(define-lex-abbrev bibtex-id 
  (:+ (char-complement (char-set " \t\r\n{}@#,\\\""))))


(define (bibtex-lexer port [nesting 0] [in-quotes? #f])
  
  (define (lex port) 
    (bibtex-lexer port nesting in-quotes?))
  
  (define (lex+1 port) 
    (bibtex-lexer port (+ nesting 1) in-quotes?))
  
  (define (lex-1 port) 
    (bibtex-lexer port (- nesting 1) in-quotes?))
  
  (define (lex-quotes port)
    (bibtex-lexer port nesting (not in-quotes?)))
  
  (define (not-quotable?) 
    (and (not in-quotes?) (< nesting 2)))
  
  {(lexer
   [(eof)
    empty-stream]
    
   [(:+ whitespace)
    (if (not-quotable?)
        (lex input-port)
        (stream-cons (token-SPACE lexeme)
                     (lex input-port)))]
   
   ["#"
    (stream-cons (if (not-quotable?) 
                     (token-#) (token-STRING lexeme))
                 (lex input-port))]
   
   ["@"
    (stream-cons (if (not-quotable?) 
                     (token-@) (token-STRING lexeme))
                 (lex input-port))]
   
   ["="
    (stream-cons (if (not-quotable?) 
                     (token-=) (token-STRING lexeme))
                 (lex input-port))]
   
   [","
    (stream-cons (if (not-quotable?) 
                     (|token-,|) (token-STRING lexeme))
                 (lex input-port))]

   [#\"
    (cond
      [in-quotes?        
       ;=>
       ; pretend we're closing a {}-string
       (stream-cons (|token-}|)
                    (lex-quotes input-port))]
      
      [(and (not in-quotes?) (= nesting 1))
       ;=>
       ; pretend we're opening a {}-string
       (stream-cons (|token-{|)
                    (lex-quotes input-port))]
      
      [(and (not in-quotes?) (>= nesting 2))
       ;=>
       (stream-cons (token-STRING lexeme)
                    (lex input-port))])]
   
   ["\\"
    (stream-cons (token-STRING "{")
                 (lex input-port))]
   
   ["\\{"
    (stream-cons (token-STRING "{")
                 (lex input-port))]
   
   ["\\}"
    (stream-cons (token-STRING "}")
                 (lex input-port))]
   
   [(:: "{" (:* whitespace))
    (begin
      (stream-cons (|token-{|)
                   (if (and (<= nesting 1) (not in-quotes?))
                       (lex+1 input-port)
                       (if (= (string-length lexeme) 1)
                           (lex+1 input-port)
                           (stream-cons (token-SPACE (substring lexeme 1))
                                        (lex+1 input-port))))))]
   
   [(:: (:* whitespace) "}")
    (begin
      (stream-cons (|token-}|)
                   (if (and (<= nesting 2) (not in-quotes?))
                       (lex-1 input-port)
                       (if (= (string-length lexeme) 1)
                           (lex-1 input-port)
                           (stream-cons (token-SPACE (substring lexeme 0 (- (string-length lexeme) 1)))
                                        (lex-1 input-port))))))]
   
   [bibtex-id
    (stream-cons (if (not-quotable?) (token-ID (string->symbol lexeme)) (token-STRING lexeme))
                 (lex input-port))])
   
   port})




(define (generate-token-generator port)
  (define tokens (bibtex-lexer port))
  (λ ()
    (if (stream-empty? tokens)
        (token-EOF)
        (let
          ([tok (stream-first tokens)])
          (set! tokens (stream-rest tokens))
          tok))))

  
(define (flatten-top-level-quotes value)
  (match value
    ['()
     '()]
    
    [(cons `(quote ,values) rest)
     (append values (flatten-top-level-quotes rest))]
    
    [(cons hd tl)
     (cons hd (flatten-top-level-quotes tl))]))

(define (simplify-quotes value)
  (match value
    ['()
     '()]
    
    [`(',substring . ,tl)
     (define reduced (simplify-quotes substring))
     (when (and (list? reduced) (= (length reduced) 1))
       (set! reduced (car reduced)))
     (cons `(quote ,reduced)
           (simplify-quotes tl))]
    
    [`(,(and a (? string?)) ,(and b (? string?)) . ,rest)
     (simplify-quotes (cons (string-append a b) rest))]
    
    [(cons hd tl)
     (cons hd (simplify-quotes tl))]))


(define (flatten+simplify value)
  (simplify-quotes (flatten-top-level-quotes value)))


(define bibtex-parse
  (parser
   [grammar 
    (itemlist [{item itemlist}  (cons $1 $2)]
              [{}               '()]
              
              ; TODO: Ignore all non-@ items:
              [{ID   itemlist}  $2]
              [{|,|  itemlist}  $2])
    
    (item [{|@| ID |{| taglist |}|} 
           ; =>
           (cons (symbol-downcase $2) $4)])

    (tag [{ID}           $1]
         [{ID = expr}    (cons (symbol-downcase $1)
                               (flatten+simplify $3))])
             
    (expr [{atom |#| expr}       (cons $1 $3)]
          [{atom}                (list $1)])
    
    (atom  [{ID}                  (symbol-downcase $1)]
           [{STRING}              $1]
           [{SPACE}               $1]
           [{ |{| atomlist |}| }  (list 'quote $2)])
    
    (atomlist [{atom atomlist}    (cons $1 $2)]
              [{}                 '()])
    
    (taglist [{tag |,| taglist}   (cons $1 $3)]
             [{tag}               (list $1)]
             [{}                 '()])]
              
   
   [tokens PUNCT EOF WHITESPACE EXPR]
   
   [start itemlist]
   
   [end EOF]
   
   [error (lambda (tok-ok? tok-name tok-value)
            (error (format "parsing error: ~a ~a ~a"
                           tok-ok? tok-name tok-value)))]))
   

#;(define (stream-take s i)
  (if (<= i 0)
      '()
      (cons (stream-first s)
            (stream-take (stream-rest s) (- i 1)))))


(define bibtex-default-strings
  #hasheq((jan . ("January"))
          (feb . ("February"))
          (mar . ("March"))
          (apr . ("April"))
          (may . ("May"))
          (jun . ("June"))
          (jul . ("July"))
          (aug . ("August"))
          (sep . ("September"))
          (oct . ("October"))
          (nov . ("November"))
          (dec . ("December"))))


(define (bibtex-inline-strings
         items 
         [env bibtex-default-strings])
  
  (define ((replace env) expr)
    (if (symbol? expr)
        (hash-ref env expr (λ () (list "")))
        (list expr)))
  
  (define (inline exprs [env env])
    (apply append (map (replace env) exprs)))
  
  (define (extend* env names exprs)
    (for/fold 
     ([env env])
     ([n names]
      [e exprs])
      (hash-set env n (inline e env))))
  
  (match items
    
    ['()
     '()]
    
    ; TODO: Add handling for @preamble and @comment
    
    ; Pick up more bindings:
    [(cons `(string (,names . ,exprs) ...) rest)
     ;=>
     (bibtex-inline-strings rest (extend* env names exprs))]
    
    [(cons `(,item-type ,key (,names . ,exprs) ...) rest)
     ;=>
     (cons `(,item-type ,key ,@(map cons names (map inline exprs)))
           (bibtex-inline-strings rest env))]
    
    ))
     

(define (bibtex-exprs->string exprs)
  
  (match exprs
    
    [(list (or 'jan 'feb 'mar 'apr 'may 'jun 'jul 'aug 'sep 'oct 'nov 'dec))
     (symbol->string (car exprs))]
    
    [else
     ;=>
     (define (escape str)
       (set! str (string-replace str "{" "\\{"))
       (set! str (string-replace str "}" "\\}"))
       str)
     
     (define (expr->string-list expr)
       (match expr
         [(? string?)         (list (escape expr))]
         [(? symbol?)         (list " } # " (symbol->string expr) " # { ")]
         [`(quote ,(and s (? string?)))
          ; =>
          (list "{" s "}")]
         [`(quote (,s ...))
          ; =>
          (list "{" (bibtex-exprs->string s) "}")]))
     
     (string-append "{ " (apply string-append (apply append (map expr->string-list exprs))) " }")]))



(define (bibtex-item->string item)
  (match item
    [`(,item-type ,key (,names . ,exprs) ...)
     (string-append
      "@" (symbol->string item-type) "{" (symbol->string key) ",\n"
      (apply string-append (for/list ([n names]
                                      [e exprs])
                             (format "  ~a = ~a ,\n" n (bibtex-exprs->string e))))
      "}\n")]))


(define (item->hash item)
  (match item 
    [`(,item-type ,key (,names . ,exprs) ...)
     ; TODO: make 'type and 'key fields
     ; turn all other n ames to strings
     (error "not finished")]))
     




(define bibtex-input-port (current-input-port))
(define bibtex-output-format 'ast)

(define inline? #f)

(define lex-only? #f)

(define (parse-options! args)
  (match args
    ['()
     (void)]
    
    [(cons "--drracket" rest)
     (set! bibtex-input-port (open-input-file "mattmight.bib"))
     (parse-options! rest)]
    
    ; just lexically analyze; don't parse:
    [(cons "--lex" rest)
     (set! lex-only? #t)
     (parse-options! rest)]
    
    ; inline all @string declarations:
    [(cons "--inline" rest)
     (set! inline? #t)
     (parse-options! rest)]
        
    [(cons "--hash" rest)
     (set! bibtex-output-format 'hash)
     (parse-options! rest)]
    
    [(cons "--bib" rest)
     (set! bibtex-output-format 'bib)
     (parse-options! rest)]
    
    [(cons filename rest)
     (set! bibtex-input-port (open-input-file filename))
     (parse-options! rest)]
    
    ))

(parse-options! (vector->list (current-command-line-arguments)))
    

(when lex-only?
  (define tokens (bibtex-lexer bibtex-input-port))
  (pretty-write (stream->list tokens))
  (exit))


(define token-generator (generate-token-generator bibtex-input-port))


(define bibtex-ast (bibtex-parse token-generator))

(when inline?
  (set! bibtex-ast (bibtex-inline-strings bibtex-ast)))


(match bibtex-output-format
  ['ast     (pretty-write bibtex-ast)]
  ['bib     (for ([item bibtex-ast])
              (display (bibtex-item->string item))
              (newline) (newline))]
  ['hash    (error "--hash not yet implemented")])
  

; (require (prefix-in scribble- scriblib/bibtex))

;(define raw (scribble-bibdb-raw (scribble-bibtex-parse (open-input-file "mattmight.bib"))))


    