module type E =
  sig
    type bit = Zero | One
    type encoding = bit list
    type natural
    val to_nat : int -> natural
    val of_nat : natural -> int
    val l : natural -> natural
    val binary : natural -> encoding
    val e : natural -> natural -> encoding
    val e_2 : natural -> encoding
    val hat : natural -> encoding
    val decode : encoding -> natural
    val huffman :
      ('a * float) list -> (encoding -> 'a list) * ('a list -> encoding)
    val huffman_tree : ('a * float) list -> 'a option Parser.Tree.t
  end
module Encodings : E
val ( --> ) : 'a -> ('a -> 'b) -> 'b
module SK :
  sig
    type primitives = [`S | `K | `Label of string | `Node of primitives list ]
    type sk = [`String of string | `Processed of primitives]
    exception Illegal_Expression of string Parser.Tree.t list

    val universe : (string, expression) Hashtbl.t
    val of_string : string -> [> `Processed of primitives ]
    val expand_labels : 
        ?except:string list -> sk -> [> `Processed of primitives ]
    val to_string : sk -> string
    val sk_define : string -> sk -> unit
    val simplify : sk -> primitives list
    val reduce : sk -> [> `Processed of primitives ]
    val evaluate : string -> [> `Processed of primitives ]
    val test : sk list -> sk
    val s_encode : sk -> Encodings.bit list
    val s_decode : Encodings.bit list -> [> `Processed of primitives ]
    val sk_define_interpreted : string -> string list -> sk -> unit
    val create : sk -> string list -> sk
  end
module SK_f :
  sig
    val s : ('a -> 'b -> 'c) -> ('a -> 'b) -> 'a -> 'c
    val k : 'a -> 'b -> 'a
    val falso : 'a -> 'b -> 'a
    val verda : ('a -> 'b) -> 'a -> 'a
  end
