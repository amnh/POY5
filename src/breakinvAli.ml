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

let () = SadmanOutput.register "BreakinvAli" "$Revision: 911 $"

(** The implementation of funtions to calculate the cost, alignments and medians
    between general sequences where both point mutations and rearrangement operations
    are considered *)

let fprintf = Printf.fprintf


type breakinv_t = {
    seq : Sequence.s;

    alied_med : Sequence.s;
    alied_seq1 : Sequence.s;
    alied_seq2 : Sequence.s;

    ref_code : int;
    ref_code1 : int;
    ref_code2 : int;
    cost1 : int;
    cost2 : int;
    recost1 : int;
    recost2 : int;
}


let swap_med m = {
    m with alied_seq1 = m.alied_seq2;
        alied_seq2 = m.alied_seq1;
        ref_code1 = m.ref_code2;
        ref_code2 = m.ref_code1;
        cost1 = m.cost2;
        cost2 = m.cost1;
        recost1 = m.recost2;
        recost2 = m.recost1
}


(** Parameters used to align two general character sequences *)
type breakinvPam_t = {
    re_meth : Data.re_meth_t;
    keep_median : int;
    circular : int;
    swap_med : int;
    symmetric : bool;
}

let breakinvPam_default = {
    re_meth = `Breakpoint 10;
    keep_median = 1;
    circular = 0;
    swap_med = 1;
    symmetric = false;
}


let init seq = 
    {        
        seq = seq;  
        alied_med = UtlPoy.get_empty_seq ();
        alied_seq1 = UtlPoy.get_empty_seq ();
        alied_seq2 = UtlPoy.get_empty_seq ();

        ref_code = Utl.get_new_chrom_ref_code ();
        ref_code1 = -1;
        ref_code2 = -1;
        cost1 = 0;
        cost2 = 0;
        recost1 = 0;
        recost2 = 0;
    }

let get_breakinv_pam user_breakinv_pam = 
    let chrom_pam = breakinvPam_default in  
    let chrom_pam = 
        match user_breakinv_pam.Data.re_meth with
        | None -> chrom_pam
        | Some re_meth -> {chrom_pam with re_meth = re_meth}
    in 

    let chrom_pam = 
        match user_breakinv_pam.Data.circular with
        | None -> chrom_pam
        | Some circular -> {chrom_pam with circular = circular}
    in 

    let chrom_pam = 
        match user_breakinv_pam.Data.keep_median with
        | None -> chrom_pam
        | Some keep_median -> {chrom_pam with keep_median = keep_median}
    in 
    
    let chrom_pam = 
        match user_breakinv_pam.Data.swap_med with
        | None -> chrom_pam
        | Some swap_med -> {chrom_pam with swap_med = swap_med}
    in 


    let chrom_pam = 
        match user_breakinv_pam.Data.symmetric with
        | None -> chrom_pam
        | Some sym -> {chrom_pam with symmetric = sym}
    in 

    chrom_pam

        
(** Given two sequences of general characters [med1] and [med2], compute 
 * the total cost between them which is comprised of editing cost and 
 * rearrangement cost *)
let cmp_cost med1 med2 gen_cost_mat pure_gen_cost_mat alpha breakinv_pam = 
    let ali_pam = get_breakinv_pam breakinv_pam in     
    let len1 = Sequence.length med1.seq in 
    let len2 = Sequence.length med2.seq in 
    if (len1 < 1) || (len2 < 1) then 0, (0, 0)
    else begin
        match ali_pam.symmetric with
        | true ->
              let cost12, recost12, _, _ =
                  GenAli.create_gen_ali `Breakinv med1.seq med2.seq gen_cost_mat pure_gen_cost_mat
                      alpha ali_pam.re_meth ali_pam.swap_med ali_pam.circular 
              in 
              let cost21, recost21, _, _ = 
                  GenAli.create_gen_ali `Breakinv med2.seq med1.seq gen_cost_mat pure_gen_cost_mat
                      alpha ali_pam.re_meth ali_pam.swap_med ali_pam.circular 
              in  
              if cost12 <= cost21 then cost12, recost12
              else cost21, recost21
        | false ->
              let cost, recost, _, _ = 
                  if Sequence.compare med1.seq med2.seq < 0 then                       
                      GenAli.create_gen_ali `Breakinv med1.seq med2.seq gen_cost_mat pure_gen_cost_mat
                          alpha ali_pam.re_meth ali_pam.swap_med ali_pam.circular 
                  else 
                      GenAli.create_gen_ali `Breakinv med2.seq med1.seq gen_cost_mat pure_gen_cost_mat
                          alpha ali_pam.re_meth ali_pam.swap_med ali_pam.circular 
              in               
              cost , recost
    end 
        


(** Given two sequences of general characters [med1] and [med2], 
 * find all median sequences between [med1] and [med2]. Rearrangements are allowed *) 
let find_simple_med2_ls med1 med2 gen_cost_mat pure_gen_cost_mat alpha ali_pam =  
    let len1 = Sequence.length med1.seq in 
    let len2 = Sequence.length med2.seq in 

    if len1 < 1 then 0, (0, 0), [med2]
    else if len2 < 1 then 0, (0, 0), [med1] 
    else begin        
        let total_cost, (recost1, recost2), alied_gen_seq1, alied_gen_seq2 = 
            GenAli.create_gen_ali `Breakinv med1.seq med2.seq gen_cost_mat pure_gen_cost_mat
                alpha ali_pam.re_meth ali_pam.swap_med ali_pam.circular 
        in 
    
        let re_seq2 =
            Utl.filterArr (Sequence.to_array alied_gen_seq2) (fun code2 -> code2 != Alphabet.get_gap alpha)
        in    
    
        
        let all_order_ls =  [(re_seq2, recost1, recost2)]  in 
    
        
        let med_ls = List.fold_left 
            (fun med_ls (re_seq2, recost1, recost2) ->
                 let med_seq = Sequence.init 
                     (fun index ->
                          if re_seq2.(index) > 0 then re_seq2.(index)
                          else 
                              if re_seq2.(index) mod 2  = 0 then -re_seq2.(index) - 1
                              else -re_seq2.(index) + 1
                     ) (Array.length re_seq2)
                 in 
                 let med = 
                     {seq = med_seq; 
                      alied_med = alied_gen_seq2;
                      alied_seq1 = alied_gen_seq1;
                      alied_seq2 = alied_gen_seq2;

                      ref_code = Utl.get_new_chrom_ref_code ();
                      ref_code1 = med1.ref_code;
                      ref_code2 = med2.ref_code;
                      cost1 = total_cost - recost2;
                      cost2 = total_cost - recost1;
                      recost1 = recost1;
                      recost2 = recost2}
                 in    
                 med::med_ls
            ) [] all_order_ls 
        in
    
        total_cost, (recost1, recost2), med_ls
    end




(** Given two sequences of general characters [med1] and [med2], 
 * find all median sequences between [med1] and [med2]. Rearrangements are allowed *) 
let find_med2_ls med1 med2 gen_cost_mat pure_gen_cost_mat alpha breakinv_pam =  
    let ali_pam = get_breakinv_pam breakinv_pam in          
    match ali_pam.symmetric with 
    | true ->
          let cost12, recost12, med12_ls = find_simple_med2_ls med1 med2
              gen_cost_mat pure_gen_cost_mat alpha ali_pam in
          let cost21, recost21, med21_ls = find_simple_med2_ls med2 med1
              gen_cost_mat pure_gen_cost_mat alpha ali_pam in
          if cost12 <= cost21 then cost12, recost12, med12_ls
          else begin 
              let med12_ls = List.map swap_med med21_ls in 
              cost21, recost21, med12_ls
          end 

    | false ->
          let med1, med2, swaped = 
              match Sequence.compare med1.seq med2.seq < 0 with 
              | true ->  med1, med2, false
              | false -> med2, med1, true
          in 

          let cost, recost, med_ls = find_simple_med2_ls med1 med2 
              gen_cost_mat pure_gen_cost_mat alpha ali_pam in

          let med_ls = 
              match swaped with
              | false -> med_ls
              | true -> List.map swap_med med_ls 
          in 
          cost, recost, med_ls


let get_costs med child_ref = 
    match child_ref = med.ref_code1 with
    | true -> med.cost1, med.recost1
    | false -> med.cost2, med.recost2



