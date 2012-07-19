(* POY 5.0 Alpha. A phylogenetic analysis program using Dynamic Homologies.   *)
(* Copyright (C) 2011 Andrés Varón, Lin Hong, Nicholas Lucaroni, Ward Wheeler,*)
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

let () = SadmanOutput.register "ModelSelection" "$Revision"

let (-->) b a = a b
let failwithf format = Printf.ksprintf failwith format
let fst_trp (a,_,_) = a and snd_trp (_,a,_) = a and trd_trp (_,_,a) = a


module type S = sig

    type a
    type b
    type tree = (a,b) Ptree.p_tree

    type model_diff =
        { subst : MlModel.subst_model;
          rates : MlModel.site_var;
          prior : MlModel.priors; }

    type models = model_diff list

    type ic = | AIC | AICC | BIC

    type tree_stats =
        { tree : tree; lk : float; ic : float * float * float; }

    type stats =
        { tree_stats : tree_stats array; type_ic : ic; min_ic : int * float; }
    
    val all_specs : tree -> Data.bool_characters -> bool -> models

    val aic  : int -> int -> float -> float
    val aicc : int -> int -> float -> float
    val bic  : int -> int -> float -> float
    
    val best_model : stats -> tree 
    val stats_of_models : models -> ic -> Data.bool_characters -> tree -> stats
    val merge_stats : stats list -> stats
    val report_stats : stats -> Data.bool_characters -> unit
    val model_averaged_parameter : 
        (MlModel.model -> float option) -> stats -> Data.bool_characters -> float * float
end

module Make (Node : NodeSig.S with type other_n = Node.Standard.n)
            (Edge : Edge.EdgeSig with type n = Node.n) 
            (TreeOps : Ptree.Tree_Operations with type a = Node.n with type b = Edge.e) : S =
struct

    type a = Node.n
    type b = Edge.e
    type tree = (a, b) Ptree.p_tree 

    (** {6 Types for collection of data and defining what type of IC to use *)

    (** Defines the properties of a model to update **)
    type model_diff =
        { subst : MlModel.subst_model;
          rates : MlModel.site_var;
          prior : MlModel.priors;}

    (** Define a list/subset of models to use in the particular IC *)
    type models = model_diff list

    (** Types of Information Criterias used in the tree-stats *)
    type ic = | AIC | AICC | BIC

    (** Define stats for a tree; likelihood, aic, and bic *)
    type tree_stats =
        {   tree : tree;
              lk : float;
                 (* IC, delta_IC, IC_weight *)
              ic : float * float * float; }

    (** Define a collection of models for information testing *)
    type stats =
        { tree_stats : tree_stats array;
             type_ic : ic;
              min_ic : int * float; }


    (** {6 Helper functions for determining model properties *)

    (** [all_specs] A list of all the specifications of models w/ and w/out
         gamma parameter based on a candidate spec --to define gap + optimality *)
    let all_specs tree chars gap =
        let est_prior = 
            let chars = Data.get_chars_codes_comp tree.Ptree.data chars in
            MlModel.Estimated (Data.compute_priors tree.Ptree.data chars gap)
        in
        let all_subst =
            [(MlModel.JC69,MlModel.Equal); (MlModel.F81,est_prior);
             (MlModel.K2P None,MlModel.Equal); (MlModel.F84 None,est_prior);
             (MlModel.HKY85 None,est_prior); (MlModel.TN93 None,est_prior);
             (MlModel.GTR None,est_prior)]
        and all_vari  = [ MlModel.Constant; MlModel.Gamma (4,0.1) ] in
        List.fold_left
            (fun acc (x,y) ->
                List.fold_left
                    (fun acc z ->
                        ( { subst = x; rates = z; prior = y; } ) :: acc )
                    acc all_vari)
            [] all_subst

    (** [parameter_cardinality] Helper function to determine the total number of
        parameters in the model; this includes branches, model rates, gamma, and
        for each character set if there are more than one. *)
    let parameter_cardinality tree chars : int =
        let sets =
            Data.categorize_likelihood_chars_by_model chars tree.Ptree.data in
        let model_params =
            List.fold_left
                (fun acc xs ->
                    let model = Data.get_likelihood_model tree.Ptree.data xs in
                    let num   = MlModel.count_parameters model in
                    acc + num)
                0 sets
        and branch_params = (* un-rooted; for branch lengths *)
            (List.length sets) * (Tree.EdgeSet.cardinal tree.Ptree.tree.Tree.d_edges)
        in
                        
        model_params + branch_params

    (** [sample_size] return the size of [n] in methods; this is to abstract the
        methodology used to determine [n] *)
    let sample_size tree chars : int =
        chars --> Data.get_chars_codes_comp tree.Ptree.data
              --> List.length

    (** [negative_loglikelihood] return the negative log-likelihood of a tree *)
    let negative_loglikelihood tree chars : float =
        Ptree.get_cost `Adjusted tree

    (** [update_model] updates a model with a new model *)
    let update_model old_model new_spec =
        MlModel.create old_model.MlModel.alph 
                       { old_model.MlModel.spec with
                            MlModel.substitution   = new_spec.subst;
                            MlModel.base_priors    = new_spec.prior;
                            MlModel.iterate_model  = true;
                            MlModel.iterate_alpha  = true;
                            MlModel.site_variation = Some new_spec.rates; }

    (** [apply_model_to_data] apply the model specification to a set of chars *)
    let apply_model_to_data new_spec chars data : Data.d = 
        let sets = Data.categorize_likelihood_chars_by_model chars data in
        List.fold_left
            (fun d xs ->
                let model = Data.get_likelihood_model d xs in
                let model = update_model model new_spec in
                Data.apply_likelihood_model_on_chars d xs model)
            data
            sets

    (** [diagnose_tree_with_model] determine the maximum likelihood value for
        the tree and model. Return the ML parameters and negative log-likelihood *)
    let diagnose_tree_with_model tree chars spec : tree =
        let data, nodes =
            tree.Ptree.data
                --> apply_model_to_data spec chars
                --> Data.categorize
                --> Node.load_data
        in
        let node_data =
            List.fold_left
                (fun acc x -> All_sets.IntegerMap.add (Node.taxon_code x) x acc)
                All_sets.IntegerMap.empty
                nodes
        in
        { tree with Ptree.node_data = node_data; Ptree.data = data; }
            --> TreeOps.downpass
            --> TreeOps.uppass


    (** {6 General Information Metrics for Model Selection *)

    (** [aic] is defined as, AIC = 2 * k - 2 (ln L_max), where n is
        the number of observations, k are the number of parameters, and L_max is the
        log-likelihood of the model under the data. *)
    let aic k _ nl_max =
        (2.0 *. (float_of_int k)) +. 2.0 *. nl_max

    (** [aicc] is defined as AICc = AIC + (2 k (k -1)) / (n-k-1); this criteria is the
        same as AIC as n -> inf (since n is in the denominator), as is a stricter
        parameter penalized version AIC. *)
    let aicc k n nl_max =
        let aic = aic k n nl_max and n = float_of_int n and k = float_of_int k in
        let c   = (2.0 *. k *. ( k +. 1.0)) /. (n -. k -. 1.0) in
        aic +. c

    (** [bic is defined as, BIC = ln(n) * k - 2 * ln(L_max), where n is the number
        of observations, k are the number of parameters, and L_max is the
        log-likelihood of the model under the data. *)
    let bic k n nl_max =
        let k = float_of_int k and n = float_of_int n in
        ((log n) *. k) +. 2.0 *. nl_max


    (** {6 Building the stats for Model Selection *)

    (** [model_averaged_parameter] return the model average parameter for a
        function that access the given parameter. This uses the ic weight to
        weight the value of the parameter, divided by the sum of the weights.
        The function should return "None" if the model should be excluded from
        the model averaging. *)
    let model_averaged_parameter f_get_param stats chars =
        let w_sum,p_sum =
            Array.fold_left
                (fun ((w_sum,p_sum) as acc) tstat ->
                    let chars =
                        Data.get_chars_codes_comp tstat.tree.Ptree.data chars in
                    let model =
                        Data.get_likelihood_model tstat.tree.Ptree.data chars in
                    match f_get_param model with
                    | None   -> acc
                    | Some x ->
                        let weight = trd_trp tstat.ic in
                        ((w_sum +. weight), (p_sum +. (weight *. x))) )
                (0.0,0.0)
                (stats.tree_stats)
        in
        p_sum /. w_sum, w_sum

    (** [best_model] return the optimial tree from stats *)
    let best_model stats =
        stats.tree_stats.( fst stats.min_ic ).tree

    (** [stats_of_tree] fill stats, minus decision theory and hlrt, of
        information criteria tests from a ML tree *)
    let stats_of_tree ic chars tree =
        let k = parameter_cardinality tree chars in
        let n = sample_size tree chars in
        let l = negative_loglikelihood tree chars in
        let ic = match ic with
            | AIC  -> aic k n l
            | AICC -> aicc k n l
            | BIC  -> bic k n l
        in
        tree, ic

    (** [stats_of_models] fills and calculates the *IC stats for a set of
        models, used as a basis for all *IC methods. *)
    let stats_of_models specs ic chars tree =
        assert ( match specs with | [] -> false | _ -> true );
        let () = match chars with
            | `All -> ()
            | char ->
                failwithf ("Currently using %s as a subset of characters is "^^
                           "not supported. Only all is allowed")
                          (Data.string_of_characters char)
        in
        let tree_stats = 
            specs --> Array.of_list
                  --> Array.map (diagnose_tree_with_model tree chars)
                  --> Array.map (stats_of_tree ic chars)
        in
        let _,min_ic =
            Array.fold_left
                (fun (i,((_,ma) as aa)) (_,ca) ->
                    let acc = if ma < ca then aa else (i,ca) in
                    (i+1,acc))
                (0,(~-1,max_float))
                (tree_stats)
        in
        let tree_stats, sum_ic =
            Array.fold_right
                (fun (t,ic) (data,sum_ic) ->
                    let d_ic = ic -. (snd min_ic) in
                    let w_ic  = exp (~-. d_ic /. 2.0) in
                    ((t,ic,d_ic,w_ic)::data), sum_ic +. w_ic)
                (tree_stats)
                ([],0.0)
        in
        let tree_stats =
            List.map
                (fun (t,ic,d_ic,w_ic) ->
                    let w_ic = w_ic /. sum_ic in
                    { tree = t;
                        lk = negative_loglikelihood t chars;
                        ic = (ic, d_ic, w_ic); })
                tree_stats
            --> Array.of_list
        in
        assert( (fst_trp tree_stats.(fst min_ic).ic) = (snd min_ic) );
        { tree_stats = tree_stats; min_ic = min_ic; type_ic = ic; }


    (** [merge_stats] merges stats together; this is to allow multiple trees to
        be analyzed under a single criteria; allowing additional models to be
        added to the criteria; et cetera *)
    let merge_stats stats_list = match stats_list with
        | []  -> assert false
        | [x] -> x
        | (x::_) as xs  ->
            assert( List.fold_left (fun b c -> b && (c.type_ic = x.type_ic)) true xs );
            let stats  = Array.concat (List.map (fun x -> x.tree_stats) xs) in
            let _,min_ic =
                Array.fold_left
                    (fun (i,minic) curr ->
                        if (snd minic) < (fst_trp curr.ic)
                            then (i+1,minic)
                            else (i+1,(i,fst_trp curr.ic)))
                    (0,x.min_ic)
                    stats
            in
            let tree_stats,sum_ic =
                Array.fold_left
                    (fun (data,sum_ic) curr ->
                        let d_ic = (fst_trp curr.ic) -. (snd min_ic) in
                        let w_ic  = exp (~-. d_ic /. 2.0) in
                        let ndata =
                            { curr with 
                                ic = (fst_trp curr.ic,d_ic,w_ic); }
                        in
                        ndata :: data, sum_ic +. w_ic)
                    ([],0.0)
                    (stats)
            in
            let tree_stats =
                List.map
                    (fun c -> 
                        {c with
                            ic = (fst_trp c.ic, snd_trp c.ic, (trd_trp c.ic) /. sum_ic); })
                    tree_stats
                --> Array.of_list
            in
            assert( (fst_trp tree_stats.(fst min_ic).ic) = (snd min_ic) );
            { tree_stats = tree_stats; min_ic = min_ic; type_ic = x.type_ic; }

    (** [report_stats] currently a debug function for reporting information *)
    let report_stats stats chars : unit =
        let () =
            Array.sort
                (fun x y -> Pervasives.compare (fst_trp x.ic) (fst_trp y.ic))
                stats.tree_stats
        and ic_to_string =
            function | AIC -> "AIC" | AICC -> "AICC" | BIC -> "BIC"
        in
        let ic_name = ic_to_string stats.type_ic in
        Printf.printf "Model \t lk \t\t K \t %s \t\t delta \t\t weight \t cum(w)\n%!" ic_name;

        Printf.printf "-----------------------------------------------------------------------------------------\n%!";
        Array.fold_left
            (fun w_cum s ->
                let charn = Data.get_chars_codes_comp s.tree.Ptree.data chars in
                let model = Data.get_likelihood_model s.tree.Ptree.data charn in
                let short = MlModel.short_name model in
                let num_k = parameter_cardinality s.tree chars in
                let (ic,d_ic,w_ic) = s.ic in
                Printf.printf "%s \t %f \t %d \t %f \t %f \t %f \t %f\n%!"
                              short s.lk num_k ic d_ic w_ic (w_ic +. w_cum);
                w_cum +. w_ic)
            0.0
            stats.tree_stats
        --> ignore
end

module IC = Make (AllDirNode.AllDirF) (Edge.LazyEdge) (AllDirChar.F)

(** Test against the scripting module Phylo; we use magic to transform the
    types, they are the same so this is okay, if not a terrible thing to do *)
let test file =
    let phylo_to_ic : (Phylo.a, Phylo.b) Ptree.p_tree -> (IC.a, IC.b) Ptree.p_tree = Obj.magic in
    Status.set_verbosity `None;
    let ()    = (POY run ([file])) in
    Methods.cost := `Iterative (`ThreeD None);
    let stats = 
        List.fold_left
            (fun acc t ->
                let t = phylo_to_ic t in
                let specs = IC.all_specs t `All false in
                let stats = IC.stats_of_models specs IC.AIC `All t in
                let () = IC.report_stats stats `All in
                stats :: acc)
            []
            (Phylo.Runtime.trees ())
    in
    if (List.length stats) > 1 then 
        let stat = IC.merge_stats stats in
        IC.report_stats stat `All
    else
        ()
