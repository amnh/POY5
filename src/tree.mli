(* POY 4.0 Beta. A phylogenetic analysis program using Dynamic Homologies.    *)
(* Copyright (C) 2007  Andr�s Var�n, Le Sy Vinh, Illya Bomash, Ward Wheeler,  *)
(* and the American Museum of Natural History.                                *)
(*                                                                            *)
(* This program is free software; you can redistribute it and/or modify       *)
(* it under the terms of the GNU General Public License as published by       *)
(* the Free Software Foundation; either version 2 of the License, or          *)
(* (at your option) any later version.                                        *)
(*                                                                            *)
(* This program is distributed in the hope that it will be useful,            *)
(* but WITHOUT ANY WARRANTY; without even the implied warranty of             *)
(* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the              *)
(* GNU General Public License for more details.                               *)
(*                                                                            *)
(* You should have received a copy of the GNU General Public License          *)
(* along with this program; if not, write to the Free Software                *)
(* Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301   *)
(* USA                                                                        *)

(** The Tree module that provides support for local search of phylogenetic
trees using SPR and TBR on unrooted trees. *)

type id = int

exception Invalid_Node_Id of int
exception Invalid_Handle_Id
exception Invalid_Edge
exception Invalid_End_Nodes
exception Node_Is_Handle


(** The nodes have the following form: NodeType(id, _...) where id is the 
   node id.. The Root nodes have left and right child ids. The 
   Interior and Leaf nodes are common to both rooted and unrooted trees.
   In rooted trees, these nodes store ids as 
   InteriorNode(id, parent_id, left_id, right_id), LeafNode(id, parent_id).
   Note that there is a directionality on the edges. 
   In unrooted trees, the locations of the tuples have no special
   significance. The nodes are interpreted as 
   InteriorNode(id, nbr1, nbr2, nbr3), LeafNode(id, nbr1). Here the
   edges are not directed. We distinguish between ordinary nodes and handles.
   This aids in the implementation of the break_edge and join_edge operations. 
   *)
type node =
  | Single of int
  | Leaf of int * int
  | Interior of (int * int * int * int)

(** In an rooted tree, edges are implicitly directed according to parent
_ child relationships. The edges in unrooted trees are directed based on
a DFS from a handle. These edges are used only by unrooted trees 
to represent the directionality imposed on an undirected edge when 
traversing from a handle. *)
type edge = Edge of (int * int)

(** A simple record to keep track of added and removed edges *)
type edge_delta = {
    added : edge list;
    removed : edge list;
}

val empty_ed : edge_delta

(** Status of traversal. *)
type t_status = 
    | Continue (** Continue the current traversal. *)
    | Skip (** Skip the subtree rooted at this node, for pre-order only *)
    | Break (** Stop traversal and return current val. *)

(** The edge comparator, allows comparison of edges so we
can create edge -> {% $\alpha$ %} maps. *)
module EdgeComparator :
  sig 
    type t = edge 
    val compare : edge -> edge -> int 
  end

(** The set of edges *)
module EdgeSet : Set.S with type elt = edge

(** The edge -> {% $\alpha$ %} map. *)
module EdgeMap : Map.S with type key = edge

(** summarizes what a tree break or join operation did to a side of the tree
    being created or broken *)
type side_delta =
        [ `Single of int * bool (** the code of the single, whether or not a
                                    handle was created/removed here *)
        | `Edge of int * int * int * int option ]
          (** l (the node created/destroyed), l1, l2,
              id of the handle created/removed, if any *)

(** Joining can be done at an edge or with a single isolated node *)
type join_jxn = 
    | Single_Jxn of id
    | Edge_Jxn of id * id

val string_of_jxn : join_jxn -> string

type reroot_delta = id list
(** Moving the root means changing the nodes in a path *)
type break_delta = side_delta * side_delta
(** A break operates on two sides of an edge *)
type join_delta = side_delta * side_delta * reroot_delta
(** A join joins two components, and removes a root on the right-hand
    component, resulting in a "rerooting" operation on that side *)

val get_side_anchor : side_delta -> id
(** [get_side_anchor delta] in case of a join returns the node on this side
    closest to the other side.  In case of a break, it returns the node on this
    side that was in the broken edge. *)
val side_to_jxn : side_delta -> join_jxn
(** [side_to_jxn delta] takes a side_delta from a break operation and returns a
    join junction usable to rejoin where the break occurred *)

val break_to_edge_delta : break_delta -> edge_delta
(** [break_to_edge_delta delta] returns the set of edges created and removed by
    a break operation *)
val join_to_edge_delta : join_delta -> edge_delta
(** [join_to_edge_delta delta] returns the set of edges created and removed by
    a join operation *)

(** The unrooted tree. Just as the rooted tree, the un-rooted 
    tree's topology is represented as a node_id -> node map. 
    [d_edges] are the directed edges imposed by handles in each
    of the connected components (when the tree is not fully connected). 
    There is one handle per connected component in the tree. *)
type u_tree = {
    tree_name : string option;
    u_topo : node All_sets.IntegerMap.t; (** Stores the tree topology as node
                                             records *)
    d_edges : EdgeSet.t;                (** Set of edges *)
    handles : All_sets.Integers.t;      (** Set of handle ids *)
    avail_ids : id list;                (** Unused ids available for reuse *)
    new_ids : id;                       (** Where to start numbering new ids *)
}

val get_break_handles : break_delta -> u_tree -> id * id
(** [get_break_handles delta tree] returns the ids of the handles of the left
    and right components of a tree after a break *)

type break_jxn = id * id
(** The junctions where a tree can be broken to create two subtrees. *)


(** The empty u_tree. *)
val empty : unit -> u_tree

(** [get_id n] get node id from node; the first int in the tuple *)
val get_id : node -> int

(** [int_of_id i] transform an id to an integer; identity function here *)
val int_of_id : id -> int 

(** [is_handle i] checks if i is a handle in the tree *)
val is_handle : int -> u_tree -> bool

(** [is_edge e t] checks if e is an edge in t *)
val is_edge : edge -> u_tree -> bool

(** [normalized_edge e t] flips elements of the edge to ensure that it is
    contained in the tree,t *)
val normalize_edge : edge -> u_tree -> edge

(** [get_node_id i t] get node id from it's integer; ensures that it is valid  **)
val get_node_id : int -> u_tree -> id

(** [get_handle_id i t] get handle id from it's integer; ensures that it is valid  **)
val get_handle_id : int -> u_tree -> id

(** [get_handle_id i t] gets the handle attached to the subtree containing i *)
val handle_of : id -> u_tree -> id

(** [get_handles t] get the set of handles for the tree *)
val get_handles : u_tree -> All_sets.Integers.t

(** [handle_list t] get the list of handles in t *)
val handle_list : u_tree -> int list

(** [get_nodes t] get list of nodes *)
val get_nodes : u_tree -> node list

(** [get_node_ids t] get the integer keys of the nodes *)
val get_node_ids : u_tree -> int list

(** [get_node i t] get the node for i; neighbors information *)
val get_node : int -> u_tree -> node

(** [get_all_leaves t] return all the leaf nodes *)
val get_all_leaves : u_tree -> id list

(** [is_leaf i t] return if i is a Leaf(i,_) *)
val is_leaf : int -> u_tree -> bool

(** [is_single i t] return if i is a Single(i) *)
val is_single : int -> u_tree -> bool
val get_edge : int * int -> u_tree -> edge
val get_parent : int -> u_tree -> int
val get_child_leaves : u_tree -> int -> int list
val other_two_nbrs : int -> node -> int * int
val get_path_to_handle : int -> u_tree -> int * edge list
val break : break_jxn -> u_tree -> u_tree * break_delta
val join : join_jxn -> join_jxn -> u_tree -> u_tree * join_delta
val make_disjoint_tree : int list -> u_tree
val random : int list -> u_tree
val move_handle : int -> u_tree -> u_tree * int list
val edge_map : (edge -> 'a) -> u_tree -> (edge * 'a) list
val pre_order_edge_map : (edge -> 'a) -> int -> u_tree -> 
                         (edge * 'a) list
val pre_order_edge_iter : (edge -> unit) -> int -> u_tree -> unit
val pre_order_edge_visit_with_depth :
    (edge -> 'a -> t_status * 'a) -> int -> u_tree -> 'a -> int -> 'a

val pre_order_edge_visit :
    (edge -> 'a -> t_status * 'a) -> int -> u_tree -> 'a -> 'a
val pre_order_node_visit :
  (int option -> int -> 'a -> t_status * 'a) ->
  int -> u_tree -> 'a -> 'a
val post_order_node_with_edge_visit :
    (int -> int -> 'a -> 'a) -> (int -> int -> 'a -> 'a -> 'a) ->
        edge -> u_tree -> 'a -> 'a * 'a

val post_order_node_with_edge_visit_simple :
    (int -> int -> 'a -> 'a) -> edge -> u_tree -> 'a -> 'a

val pre_order_node_with_edge_visit_simple :
    (int -> int -> 'a -> 'a) -> edge -> u_tree -> 'a -> 'a

(* adds a function to apply to edge a,b, and excludes a and b from the traversal *)
val pre_order_node_with_edge_visit_simple_root :
    (int -> int -> 'a -> 'a) -> edge -> u_tree -> 'a -> 'a

val post_order_node_visit :
  (int option -> int -> 'a -> t_status * 'a) ->
  int -> u_tree -> 'a -> 'a
val get_pre_order_edges : int -> u_tree -> edge list
val get_edges_tree : u_tree -> edge list
val print_edge : edge -> unit
val print_break_jxn : int * int -> unit
val print_join_1_jxn : join_jxn -> unit
val print_join_2_jxn : join_jxn -> unit
val print_tree : int -> u_tree -> unit
val print_forest : u_tree -> unit

val verify_edge : edge -> u_tree -> bool

(* Create two sets defining the partition accross an edge *)
val create_partition : u_tree -> edge -> All_sets.Integers.t * All_sets.Integers.t

(* Calculate the Robinson Foulds distance between two trees *)
val robinson_foulds : u_tree -> u_tree -> int

(** Module to fingerprint trees and compare them *)
module Fingerprint : sig
    type t
    val fingerprint : u_tree -> t
    val compare : t -> t -> int
end

(** [CladeFP] implements fingerprinting of clades.  All clades with the same
    set of terminal nodes will have the same fingerprint.  This is the same
    scheme as !Hash_tbl. *)
module CladeFP :
sig
    type fp = All_sets.Integers.t
    type t

    module Ordered : Map.OrderedType with type t = fp

    (* A module of sets of clades *)
    module CladeSet : Set.S with type elt = fp

    (** [fpcompare] compares two fingerprints *)
    val fpcompare : fp -> fp -> int

    (** [calc tree] calculates the set of fingerprints for [tree] *)
    val calc : u_tree -> t

    (* [sets t] Returns the set of all the clades contained in [t]. *)
    val sets : u_tree -> CladeSet.t

    (** [query edge fps] retrieves the fingerprint for [edge] *)
    val query : edge -> t -> fp

    val num_leaves : fp -> int

    val fold : (edge -> fp -> 'a -> 'a) -> t -> 'a -> 'a
end

module CladeFPMap : (Map.S with type key = CladeFP.fp)

val get_vertices_to_handle :  int -> u_tree -> int list
val fix_handle_neighbor : int -> int -> u_tree -> u_tree

(******* Tree Fusing *)

val source_to_target :
    u_tree * int ->
    u_tree * int -> u_tree

type 'a fuse_locations = ('a * u_tree * edge) list Sexpr.t

val fuse_cladesize : min:int -> max:int -> 'a * int -> bool

val fuse_locations :
    ?filter:(CladeFP.fp * int -> bool) ->
    ('a * u_tree) list ->
    ('a * u_tree) ->
    'a fuse_locations

val fuse_all_locations :
    ?filter:(CladeFP.fp * int -> bool) ->
    ('a * u_tree) list ->
    'a fuse_locations

val fuse :
    source:u_tree * edge -> target:u_tree * edge -> u_tree

val test_tree :
    u_tree -> unit

val depths : u_tree -> int All_sets.TupleMap.t

val reroot : (int * int) -> u_tree -> u_tree

val choose_leaf : u_tree -> (int * int)

val cannonize_on_edge : (int * int) -> u_tree -> u_tree

val cannonize_on_leaf : int -> u_tree -> u_tree

val compare_cannonical : u_tree -> u_tree -> bool

val get_unique : ('a * u_tree) list -> ('a * u_tree) list

val exchange_codes : int -> int -> u_tree -> u_tree

val replace_codes : (int -> int) -> u_tree -> u_tree

val destroy_component : int -> u_tree -> u_tree

val copy_component : int -> u_tree -> u_tree -> u_tree

module Parse : sig
    (** Parser for tree in format (a (b c)) *)

    type 'a t = Leafp of 'a | Nodep of 'a t list * 'a

    type tree_types =
        | Flat of string t
        | Annotated of (tree_types * string)
        | Branches of ((string * float option) t)
        | Characters of ((string * string option) t)

    val remove_annotations : tree_types -> tree_types

    (** [print_tree t] prints a tree **)
    val print_tree : string option -> tree_types -> unit

    (** [of_string x] given a string x of a tree in the form (a (b c)), returns
    * its representation as an internal t type. If an error occurs, an
    * Illegal_tree_format error is raised. *)
    val of_string : string -> tree_types list list

    (** [of_channel x] creates a list of all the trees contained in the input
    * channel x in ascii format. Each tree should be in a single line. In case
    * of error the function raises Illegal_molecular_format. *)
    val of_channel : in_channel -> tree_types list list

    (** [of_file] is a shortcut of [of_channel], when the channel is an opened
    * file. *)
    val of_file : FileStream.f -> tree_types list list

    (** [stream_of_file f] produces a function that returns on each call one of
    * the trees in the input file [f]. If no more trees are found, an
    * End_of_file exception is raised. The function _requires_ that the trees be
    * separated with associated information, semicolons, or stars.*)
    val stream_of_file : bool -> FileStream.f -> ((unit -> tree_types) * (unit -> unit))

    val cannonic_order : tree_types -> tree_types

    exception Illegal_argument
    exception Illegal_tree_format of string

    (** [cleanup ~newroot f t] removes from the tree [t] the leaves that contain
    * infromation [x] such that [f x = true]. If there is the need for a new
    * root, then [newroot] must be provided. If the [newroot] is required and
    * not provided, the function raises an [Illegal_argument] exception. *)
    val cleanup : ?newroot:string  -> (string -> bool) -> tree_types -> tree_types option

    (** [post_process t] takes a basic tree and converts it to Flat,Branches or
     * Annotated based on it's properties. *)
    val post_process : (string * (float option * string option)) t * string -> tree_types

    val map : ('a -> 'b) -> 'a t -> 'b t
    val map_tree : (string -> string) -> tree_types -> tree_types

    val strip_tree : tree_types -> string t
    val maximize_tree : tree_types -> (string * string option) t
    val convert_to : string option * tree_types list -> (string -> int) -> int -> u_tree
end
