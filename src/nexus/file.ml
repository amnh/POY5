let (-->) a b = b a 
(* A module to handle specifications of static homology characters and their
* occurrences in a terminal *)
type st_type = 
    | STOrdered
    | STUnordered
    | STSankoff of int array array  (* the cost matrix to use *)
    | STLikelihood of MlModel.model (* The ML model to use *)

type static_spec = {
    st_filesource : string; (* The file it came from *)
    st_name : string;       (* The name assigned to the character *)
    st_alph : Alphabet.a;   (* The set of potential character symbols *)
    st_observed : int list; (* The set of observed states *)
    st_labels : string list;(* The labels assigned to the states *)
    st_weight : float;      (* The character weight *)
    st_type : st_type;      (* The type of character *)
    st_equivalents : (string * string list) list;
                            (* Things that are the same in the input *)
    st_missing : string;    (* The character that represents missing data *)
    st_matchstate : string option; 
        (* The chaaracter that marks the same state as teh first taxon *)
    st_gap : string;        (* The gap representation *)
    st_eliminate : bool;    (* Whether or not the user wants to get rid of it *)
    st_case : bool;         (* Whether or not the user wants be case sensistive *)
    st_used_observed : (int, int) Hashtbl.t option;
    st_observed_used : (int, int) Hashtbl.t option;
}

type static_state = [ `Bits of BitSet.t | `List of int list ] option

let static_state_to_list x =
    match x with
    | `List x -> x
    | `Bits x -> BitSet.to_list x 

let generate_alphabet alph gap =
    let tbl = 
        let cntr = ref (-1) in
        let alph =
            (if List.exists (fun x -> x = gap) alph then alph
            else alph @ [gap])
        in
        List.map (fun x -> incr cntr; (x, !cntr, None)) alph
    in
    Alphabet.list_to_a tbl gap None Alphabet.Sequential

let spec_of_alph alphabet filename name = 
     {
        st_filesource = filename;
        st_name = name;
        st_alph = alphabet;
        st_observed = [];
        st_labels = [];
        st_weight = 1.0;
        st_type = STUnordered;
        st_equivalents = [];
        st_missing = "?";
        st_matchstate = Some ".";
        st_gap = "-";
        st_eliminate = false;
        st_case = false;
        st_used_observed = None;
        st_observed_used = None;
    }

let st_type_to_string = function
    | STOrdered -> "Additive"
    | STUnordered -> "Non Additive"
    | STSankoff _ -> "Sankoff"
    | STLikelihood _ -> "Likelihood"

let bool_to_string x = 
    if x then "true" else "false"

let to_string s =
    let separator = " -- " in
    s.st_filesource ^ separator ^ s.st_name ^ separator ^ 
    (* TODO Alphabet.to_string s.st_alph)*) " alphabet goes here " ^ separator ^ 
    (String.concat " " (List.map string_of_int s.st_observed)) ^ separator ^
    (String.concat " " s.st_labels) ^ separator ^ string_of_float s.st_weight ^
    st_type_to_string s.st_type ^ separator ^ 
    (String.concat " " (List.map (fun (a, b) ->
        a ^ "=(" ^ (String.concat " " b) ^ ")") s.st_equivalents)) ^ separator ^
    s.st_missing ^ (function None -> " " | Some x -> x) s.st_matchstate ^ 
    separator ^ s.st_gap ^ separator ^ bool_to_string s.st_eliminate ^ separator
    ^ bool_to_string s.st_case

let to_formatter s =
    let module T = Xml.Characters in
    let lst tag ls = (PXML -[tag] {set ls} --) in
    let observed_states = 
        let res = 
            List.map (fun x -> PXML -[T.item] {`Int x} --) s.st_observed 
        in
        lst T.observed res
    and equivalencies =
        let res =
            List.map (fun (a, b) -> 
                PXML -[T.equivalent] 
                    ([T.from] = [`String a])
                    ([T.towards] = [`String (String.concat " " b)]) --)
            s.st_equivalents 
        in
        lst T.equivalencies res
    and states = 
        let res = 
            List.map (fun x -> 
                PXML -[T.label] {`String x}--) s.st_labels 
        in
        lst T.labels res
    in
    let ch_type =
        match s.st_type with
        | STUnordered -> T.nonadditive
        | STOrdered -> T.additive
        | STSankoff _ -> T.sankoff
        | STLikelihood _ -> T.likelihood
    in
    (RXML -[ch_type] 
        ([T.source] = [`String s.st_filesource])
        ([T.name] = [`String s.st_name])
        ([T.weight] = [`Float s.st_weight])
        ([T.missing_symbol] = [`String s.st_missing])
        ([T.matchstate_symbol] = 
            [match s.st_matchstate with 
            | None -> `String "" | Some x -> `String x])
        ([T.gap_symbol] = [`String s.st_gap])
        ([T.ignore] = [`Bool s.st_eliminate])
        ([T.case] = [`Bool s.st_case])
        { single Alphabet.to_formatter s.st_alph }
        { states }
        { observed_states }
        { equivalencies } --)

type taxon = string

type nexus = {
    char_cntr : int ref;
    taxa : string option array;
    characters : static_spec array;
    matrix : static_state array array;
    csets : (string, P.charset list) Hashtbl.t;
    unaligned : (float * int option * (string * int array array) option * 
                 Alphabet.a * MlModel.model option *
                 (Sequence.s list list list * taxon) list)
                list;
    trees : (string option * Tree.Parse.tree_types list) list;
    branches : (string, (string, (string , float) Hashtbl.t) Hashtbl.t) Hashtbl.t;
    assumptions : (string, string array * float array array) Hashtbl.t;
}

let empty_parsed () = {
    char_cntr = ref 0;
    taxa = [||];
    characters = [||];
    matrix = [||];
    csets = Hashtbl.create 27;
    unaligned = [];
    trees = [];
    branches = Hashtbl.create 27;
    assumptions = Hashtbl.create 27;
}

let get_something find filter default form =
    try filter (List.find find form) with
    | Not_found -> default

let get_missing =
    get_something (function P.FMissing _ -> true | _ -> false) 
    (function P.FMissing x -> x | _ -> assert false) 
    "?"

let parse_symbols str = 
    let rec mk pos lst =
        if pos < 0 then lst 
        else
            match str.[pos] with
            | ' ' | '\010' | '\012' | '\013' | '\014' ->
                    mk (pos - 1) lst
            | x -> 
                    mk (pos - 1) ((String.make 1 x) :: lst)
    in
    mk ((String.length str) - 1) []

let parse_equate str =
    let rec create_list pos items str =
        if pos < 0 then items
        else
            match str.[pos] with
            | ' ' | '\010' | '\011' | '\012' | '\013' | '\014' -> 
                    create_list (pos - 1) items str
            | x -> create_list (pos - 1) ((String.make 1 x) :: items) str
    in
    (* TODO add support for the equate command *)
    let buf = Lexing.from_string str in 
    let res = 
        let res = ref [] in
        try while true do
            let n = Grammar.symbol_pair Lexer.token buf in
            res := n :: !res;
        done;
        []
        with
        | Failure "lexing: empty token" -> 
                List.rev !res
    in
    List.map (fun (a, b) ->
        let res = 
            List.map (fun x -> create_list ((String.length x) - 1) [] x) b 
        in
        (a, List.flatten res)) res

let get_symbols =
    get_something (function P.Symbols _ -> true | _ -> false)
    (function P.Symbols x -> parse_symbols x | _ -> assert false)
    ["0"; "1"; "2"; "3"; "4"; "5"; "6"; "7"; "8"; "9"]
    
let get_equate =
    get_something (function P.Equate _ -> true | _ -> false)
    (function P.Equate x -> parse_equate x | _ -> assert false)
    []

let get_true_false x =
    get_something (fun y -> y = x) (function _ -> true) false

let get_transposed = get_true_false P.Transpose

let get_interleaved = get_true_false P.Interleave

let get_labels =
    get_something (function P.Labels _ -> true | _ -> false) 
    (function P.Labels x -> x | _ -> assert false)
    true

let get_token =
    get_something (function P.Tokens _ -> true | _ -> false)
    (function P.Tokens x -> x | _ -> assert false)
    false

let get_gap =
    get_something (function P.Gap _ -> true | _ -> false)
    (function P.Gap x -> x | _ -> assert false)
    "-"

let get_respect_case =
    get_something (function P.RespectCase -> true | _ -> false)
    (function _ -> true)
    false

let get_matchchar =
    get_something (function P.MatchChar _ -> true | _ -> false)
    (function P.MatchChar x -> Some x | _ -> assert false)
    None

let get_datatype = 
    get_something (function P.Datatype x -> true | _ -> false)
    (function P.Datatype x -> x | _ -> assert false) 
    P.DStandard

let table_of_alphabets = Hashtbl.create 1667 

let make_symbol_alphabet gap symbols more_equates form =
    let index = (gap, symbols, form) in
    if Hashtbl.mem table_of_alphabets index then
        Hashtbl.find table_of_alphabets index
    else
        let r =
            match get_datatype form with
            | P.Protein ->
                    Alphabet.list_to_a
                    ([("A", 0, None); 
                    ("C", 1, None); 
                    ("D", 2, None); 
                    ("E", 3, None); 
                    ("F", 4, None); 
                    ("G", 5, None); 
                    ("H", 6, None); 
                    ("I", 7, None); 
                    ("K", 8, None); 
                    ("L", 9, None); 
                    ("M", 10, None); 
                    ("N", 11, None); 
                    ("P", 12, None); 
                    ("Q", 13, None); 
                    ("R", 14, None); 
                    ("S", 15, None); 
                    ("T", 16, None); 
                    ("V", 17, None); 
                    ("W", 18, None); 
                    ("Y", 19, None); 
                    ("*", 20, None);
                    (gap, 21, None);])
                    gap None Alphabet.Sequential,
                    [("B", ["D"; "N"]); ("Z", ["E"; "Q"])] @ more_equates
            | P.Rna ->
                    Alphabet.list_to_a 
                    ([("A", 0, None); ("C", 1, None); ("G", 2, None); ("U", 3,
                    None); (gap, 4, None)] )
                    gap None Alphabet.Sequential,
                    [("R", ["A"; "G"]);
                    ("Y", ["C"; "U"]);
                    ("M", ["A"; "C"]);
                    ("K", ["G"; "U"]);
                    ("S", ["C"; "U"]);
                    ("W", ["A"; "U"]);
                    ("H", ["A"; "C"; "U"]);
                    ("B", ["C"; "G"; "U"]);
                    ("V", ["A"; "C"; "G"]);
                    ("D", ["A"; "G"; "U"]);
                    ("N", ["A"; "C"; "G"; "U"]);
                    ("X", ["A"; "C"; "G"; "U"])] @ more_equates
            | P.Nucleotide | P.Dna ->
                    Alphabet.list_to_a 
                    ([("A", 0, None); ("C", 1, None); ("G", 2, None); ("T", 3,
                    None); (gap, 4, None)] )
                    gap None Alphabet.Sequential,
                    [("R", ["A"; "G"]);
                    ("Y", ["C"; "T"]);
                    ("M", ["A"; "C"]);
                    ("K", ["G"; "T"]);
                    ("S", ["C"; "T"]);
                    ("W", ["A"; "T"]);
                    ("H", ["A"; "C"; "T"]);
                    ("B", ["C"; "G"; "T"]);
                    ("V", ["A"; "C"; "G"]);
                    ("D", ["A"; "G"; "T"]);
                    ("N", ["A"; "C"; "G"; "T"]);
                    ("X", ["A"; "C"; "G"; "T"])] @ more_equates
            | P.DStandard ->
                let cnt = ref (-1) in
                let alph = List.map (fun x -> 
                    incr cnt;
                    x, !cnt, None) (symbols @ [gap])
                in
                Alphabet.list_to_a alph gap None Alphabet.Sequential,
                (get_equate form) @ more_equates
            | P.Continuous ->
                    failwith "We don't support continuous characters ..."
        in
        let () = Hashtbl.add table_of_alphabets index r in
        r

let default_static char_cntr file form pos =
    let missing = get_missing form 
    and symbols = get_symbols form 
    and gap = get_gap form
    and respect_case = get_respect_case form 
    and _ = incr char_cntr in
    let alph, equate = make_symbol_alphabet gap symbols [] form in
    { st_filesource = file;
      st_name = file ^ ":" ^ string_of_int !char_cntr;
    st_alph = alph;
    st_observed = [];
    st_labels = [];
    st_weight = 1.0;
    st_type = STUnordered;
    st_equivalents = equate;
    st_missing = missing; 
    st_matchstate = get_matchchar form;
    st_gap = gap;
    st_eliminate = false;
    st_case = respect_case;
    st_used_observed = None;
    st_observed_used = None;}

let find_position error comparator vector =
    let pos = ref 0 in
    try
        for i = 0 to (Array.length vector) - 1 do
            if comparator vector.(i) then begin
                pos := i;
                raise Exit
            end;
        done;
        failwith error
    with
    | Exit -> !pos

let find_character chars name =
    let error = Printf.sprintf "Character (%s) not found" name in
    find_position error (fun x -> name = x.st_name) chars

let rec general_apply_on_character_set find set_table characters f x =
    let last = (Array.length characters) - 1 in
    match x with
    | P.Range (a, b, step) ->
            let a = int_of_string a
            and b = 
                match b with
                | None -> last
                | Some b ->  int_of_string b 
            in
            let rec loop i = 
                if i > b then ()
                else begin 
                    f (i - 1);
                    loop (i + step);
                end;
            in
            loop a
    | P.Single v  -> f ((int_of_string v) - 1);
    | P.Name name ->
            if Hashtbl.mem set_table (String.uppercase name) then
                List.iter 
                    (general_apply_on_character_set find set_table characters f)
                    (Hashtbl.find set_table (String.uppercase name))
            else begin
                match String.uppercase name with
                | "ALL" ->
                    general_apply_on_character_set find set_table characters f 
                        (P.Range ("1", (Some (string_of_int last)), 1))
                | "."   ->
                    f (last - 1)
                | name  ->
                    f (find characters name)
            end

let apply_on_character_set = general_apply_on_character_set find_character

let apply_on_unaligned_set = general_apply_on_character_set
                                (fun _ _ -> failwith "UNALIGNED blocks can't have a name")
                                (Hashtbl.create 1)

(* get the character names for different set types *)
let rec get_character_names chars sets : P.charset -> string list = function
    | P.Range (lo,hi,step) ->
        let a = int_of_string lo
        and b = match hi with
            | None -> (Array.length chars) - 1
            | Some b -> int_of_string b
        in
        let rec loop acc i = 
            if i > b then acc
            else loop (chars.(i-1).st_name :: acc) (i + step)
        in
        loop [] a
    | P.Name name ->
        begin try chars.(find_character chars name).st_name :: []
        with | _ ->
            try
                let name = String.uppercase name in
                List.flatten
                    (List.map (get_character_names chars sets) (Hashtbl.find sets name))
            with | _ -> 
                failwith (Printf.sprintf "Cannot find character set %s of sets" name)
        end
    | P.Single num ->
        chars.((int_of_string num) - 1).st_name :: []

let find_taxon taxa name =
    let error = Printf.sprintf "Taxon (%s) not found" name in
    try find_position error (function None -> false | Some x -> name = x) taxa
    with | Failure _ -> 
        let pos = 
            find_position error (function None -> true | Some _ -> false) taxa 
        in
        taxa.(pos) <- Some name;
        pos

let update_labels_as_alphabet chars start =
    for i = start to (Array.length chars) - 1 do
        let spec = chars.(i) in
        let labels = 
            let cnt = ref 0 in
            List.map (fun x ->
                incr cnt;
                (x, !cnt, None)) 
            spec.st_labels
        in
        let alph = 
            Alphabet.list_to_a labels spec.st_gap None Alphabet.Sequential 
        in
        chars.(i) <- { spec with st_alph = alph };
    done;
    ()

let uninterleave for_fasta data = 
    let remove_quotes str = 
        let r = Str.string_match (Str.regexp "['\"]\\(.*?\\)['\"]") str 0 in
        if r then Str.matched_group 1 str else str
    in
    (* The data is a string right now, but I suppose this is not really
    * convenient as we set a hard constraint on the size of the input. We
    * have to change this for a stream, but that will also require changes
    * in the nexusLexer.mll and nexusParser.mly *)
    let hstbl = Hashtbl.create 97 in
    let stream = new FileStream.string_reader data in
    let input_order = ref [] in
    let started_adding = ref false in
    try while true do
        let line = stream#read_line in
        let line = 
            let line =  Str.split (Str.regexp "[ \t]+") line in
            List.filter (function "" -> false | _ -> true) line
        in
        match line with
        | taxon :: sequence ->
                let taxon = remove_quotes taxon in
                let adder buf x = 
                    Buffer.add_string buf x; 
                    Buffer.add_string buf " "
                in
                if Hashtbl.mem hstbl taxon then begin
                    started_adding := true;
                    let buf = Hashtbl.find hstbl taxon in
                    List.iter (adder buf) sequence
                end else begin
                    if !started_adding then 
                        failwith
                        ("There appears to be a name mismatch in your \
                        interleaved format. I could not find " ^ 
                        taxon);
                    input_order := taxon :: !input_order;
                    let buf = Buffer.create 1511 in
                    List.iter (adder buf) sequence;
                    Buffer.add_string buf " ";
                    Hashtbl.add hstbl taxon buf
                end
        | [] -> ()
    done;
    ""
    with
    | End_of_file -> 
            let input_order = List.rev !input_order in
            let prepend = if for_fasta then "\n\n>" else " " in
            let separator = if for_fasta then "\n" else " " in
            let buf = Buffer.create 1511 in
            List.iter (fun name ->
                let str = Hashtbl.find hstbl name in
                Buffer.add_string buf prepend;
                Buffer.add_string buf name;
                Buffer.add_string buf separator;
                Buffer.add_buffer buf str) input_order;
            Buffer.contents buf

let do_on_list f char list =
    let char = String.make 1 char in
    f (fun (x, _) -> 
        char = x) list

let has_equate = do_on_list List.exists
    
let find_equate = do_on_list List.find

let fill_observed characters matrix =
    let max_ch = (Array.length characters) - 1 
    and max_ta = (Array.length matrix) - 1 in
    for i = 0 to max_ch do
        let observed = ref All_sets.Integers.empty in
        for j = 0 to max_ta do
            match matrix.(j).(i) with
            | None -> ()
            | Some lst ->
                    let lst = 
                        match lst with
                        | `List l -> l
                        | `Bits s -> BitSet.to_list s
                    in
                    List.iter (fun x ->
                        observed := All_sets.Integers.add x !observed)
                    lst;
        done;
        let obsv = 
            let obsv = All_sets.Integers.elements !observed in
            List.sort compare obsv
        in
        characters.(i) <- { characters.(i) with st_observed = obsv }
    done


let remove_comments string = 
    let len = String.length string in
    let b = Buffer.create len in
    let rec in_comment pos =
        let start = ref pos in
        try while !start < len do
            incr start;
            begin match string.[!start] with
            | ']' -> raise Exit
            | '[' -> 
                    start := in_comment !start;
                    ()
            | _ -> ()
            end;
        done;
        failwith "Finished string and the comments are still there!"
        with
        | Exit -> !start
    in
    let start = ref 0 in
    while !start < len do
        begin match string.[!start] with
        | '[' -> 
            (match string.[1+(!start)],string.[2+(!start)] with
             | '&','p' | '&','P' ->
                start := !start + 2;
                Buffer.add_char b '['
             | _ -> start := in_comment (!start + 1)
            ) 
        | x -> Buffer.add_char b x
        end;
        incr start;
    done;
    Buffer.contents b


let process_matrix labels style matrix taxa characters get_row_number assign_item data =
    let concat lst = 
        match style with
        | `None -> String.concat "" lst
        | `Hennig -> "[" ^ String.concat " " lst ^ "]"
        | `Nexus -> "{" ^ String.concat " " lst ^ "}"
    in
    let table = Hashtbl.create 1667 in
    let generate_alphabet item = 
        if Hashtbl.mem table (item.st_case, item.st_alph) then 
            Hashtbl.find table (item.st_case, item.st_alph)
        else
            let f = 
                Alphabet.Lexer.make_simplified_lexer style item.st_case true
                item.st_alph 
            in
            let res = fun x -> `List (f x) in
            let () = Hashtbl.add table (item.st_case, item.st_alph) res in
            res
    in
    let parsers = Array.map generate_alphabet characters in
    let stream = Stream.of_string data in
    let n_chars = Array.length characters in
    let first_taxon = ref (-1) in 

    let compress_ss (olst:static_state list option):static_state =
        let union (oa:static_state) (ob:static_state) =
            match oa,ob with
            | None, _ -> ob
            | _, None -> oa
            | Some a,Some b ->
                let a = match a with
                    | `Bits s -> BitSet.to_list s
                    | `List s -> s in
                let b = match b with
                    | `Bits s -> BitSet.to_list s
                    | `List s -> s in
                let b = List.filter (fun x -> not (List.mem x a)) b in
                Some (`List (a@b))
        in
        match olst with
        | None -> failwith "What do you want from my life?"
        | Some lst -> List.fold_right union lst None
    in

    (* A function that takes a parser, a spec and a  stream and gets the
    * necessary element for the matrix *)
    let rec process_position alph_parser alph_spec stream position stack =
        match Stream.peek stream with
        | None -> failwith "Short NEXUS matrix?"
        | Some x ->
                match x with
                | ' ' | '\001' .. '\032' -> Stream.junk stream;
                        process_position alph_parser alph_spec stream position stack
                | '[' when style = `Hennig -> Stream.junk stream;
                        process_position alph_parser alph_spec stream position (Some [])
                | '{' when style = `Nexus -> Stream.junk stream;
                        process_position alph_parser alph_spec stream position (Some [])
                | ']' when style = `Hennig -> Stream.junk stream; 
                        compress_ss stack
                | '}' when style = `Nexus -> Stream.junk stream;
                        compress_ss stack
                | x -> 
                    let x = 
                        if not alph_spec.st_case then Char.uppercase x 
                        else x
                    in
                    let next =
                        if x = alph_spec.st_missing.[0] then begin
                            Stream.junk stream;
                            None
                        end else if has_equate x alph_spec.st_equivalents
                        then
                            let _, eqts  = 
                                find_equate x alph_spec.st_equivalents 
                            in
                            let _ = Stream.junk stream in
                            match eqts with
                                | [] -> None
                                | _ ->  Some (alph_parser (Stream.of_string (concat eqts)))
                        else 
                            try
                                match alph_spec.st_matchstate with
                                | None -> Some (alph_parser stream)
                                | Some first ->
                                        if x = first.[0] then begin
                                            Stream.junk stream;
                                            matrix.(!first_taxon).(position)
                        end else Some (alph_parser stream)
                                with
                                | err ->
                                        raise err
                    in
                    match stack with 
                    | None -> next
                    | Some lst -> process_position alph_parser alph_spec 
                                        stream position (Some (next::lst))
    in
    let is_space stream =
        match Stream.peek stream with
        | None -> false
        | Some x -> 
                match x with
                | ' '| '\001' .. '\031' ->
                        true
                | x -> 
                        false
    in
    let consume_spaces stream =
        let found = ref false in
        while is_space stream do
            found := true;
            Stream.junk stream
        done;
        !found
    in
    let get_name =
        let taxa_len = Array.length taxa in
        if not labels then 
            let cntr = ref (-1) in
            (fun stream -> incr cntr; 
                let pre_spaced = consume_spaces stream in
                if not pre_spaced then
                    Status.user_message Status.Warning
                        ("Taxon Code "^(string_of_int !cntr)^" may be read"
                         ^" wrong; check the previous taxons character length.");
                if !cntr = taxa_len then 
                    (* If we are at the end of the stream, we are just
                    * fine, so we attempt to provoque an End of File
                    , so we attempt to provoque an End of File error* error *)
                    let _ = Stream.next stream in
                    let _ = Status.user_message Status.Error
                    ("Your@ input@ matrix@ declares@ fewer@ " ^
                    "terminals@ than@ there@ are@ on@ it.") in
                    failwith "Illegal input file"
                else
                match taxa.(!cntr) with
                | Some x -> x
                | None -> failwith "Taxon undefined")
        else 
            (fun stream ->
                let pre_spaced = consume_spaces stream in
                let b = Buffer.create 13 in
                while not (is_space stream) do
                    Buffer.add_char b (Stream.next stream)
                done;
                let name = Buffer.contents b in
                if not pre_spaced then
                    Status.user_message Status.Warning
                        ("Taxon "^name^" may be read wrong; "
                         ^"check the previous taxons character length.");
                name)
    in
    let rec taxon_processor x position =
        match x with
        | None -> (* We are gathering the taxon name first *)
            begin try (* the taxon position *)
                let x = get_row_number (get_name stream) in 
                let () =
                    match !first_taxon with
                    | (-1) -> first_taxon := x
                    | _ -> ()
                in
                ignore (consume_spaces stream);
                taxon_processor (Some x) 0
            with
            | Stream.Failure 
            | End_of_file -> ()
            end
        | Some x' ->
            if position = n_chars then taxon_processor None 0
            else begin
                let state = 
                    process_position parsers.(position) 
                    characters.(position) stream position None
                in
                assign_item x' position state;
                taxon_processor x (position + 1)
            end
    in
    taxon_processor None 0;
    (* Time to check what is being used on each column, update the
    * corresponding specification, and fill the missing data *)
    fill_observed characters matrix

let add_all_taxa taxa new_taxa =
    let old_taxa = Array.to_list taxa in
    let new_taxa = 
        List.filter (fun x -> 
            not (List.exists 
            (function None -> false | Some y -> x = y) 
            old_taxa)) 
        new_taxa 
    in
    let new_taxa = List.map (fun x -> Some x) new_taxa in
    Array.append taxa (Array.of_list new_taxa)

let add_prealigned_characters file chars (acc:nexus) = 
    let form = chars.P.char_format in
    let start_position = !(acc.char_cntr) in
    let taxa = 
        match chars.P.char_taxon_dimensions with
        | None -> acc.taxa
        | Some v -> 
                Array.append acc.taxa (Array.make (int_of_string v) None) 
    in
    let acc = { acc with taxa = taxa } in

    let nchars = int_of_string chars.P.char_char_dimensions in
    let characters = 
        Array.append acc.characters 
        (Array.init nchars (default_static acc.char_cntr file form))
    and matrix = 
        let matrix = 
            if 0 < Array.length acc.matrix then
                let tlen = Array.length taxa in
                if tlen <= Array.length acc.matrix then
                    acc.matrix
                else 
                    let len = Array.length (acc.matrix.(0)) in
                    Array.append acc.matrix
                    (Array.init tlen (fun _ -> Array.make len None))
            else Array.map (fun _ -> [||]) acc.taxa
        in
        Array.map 
        (fun x -> Array.append x (Array.init nchars (fun _ -> None))) 
        matrix
    in
    let () =
        (* We first update the names of the characters *)
        let cnt = ref start_position in
        List.iter 
            (fun x ->
                let spec = characters.(!cnt) in
                characters.(!cnt) <-  { spec with st_name = x };
                incr cnt) 
            chars.P.char_charlabels
    in
    let () = 
        (* Now we update the states labels *)
        List.iter (fun (position, labels) ->
            let position = (int_of_string position) - 1 in
            characters.(position) <- 
                { characters.(position) with st_labels = labels }) 
        chars.P.char_charstates
    in
    let () =
        (* The next thing we do, is that we update states and labels
        * together *)
        List.iter 
            (fun (position, name, labels) ->
                let position = (int_of_string position) - 1 in
                characters.(position) <-
                    { characters.(position) with 
                        st_labels = labels;
                        st_name = name })
        chars.P.char_statelabels
    in
    let () =
        if get_token form then
            update_labels_as_alphabet characters start_position
        else ()
    in
    let () =
        (* We are ready now to fill the contents of the matrix *)
        let chars = remove_comments chars.P.chars in
        let data =
            if get_interleaved form then uninterleave false chars
            else chars
        and remove_quotes str = 
            let r = Str.string_match (Str.regexp "['\"]\\(.*?\\)['\"]") str 0 in
            if r then Str.matched_group 1 str else str
        in
        let get_row_number, assign_item =
            if get_transposed form then
                (fun name -> find_character characters name),
                (fun x y v -> matrix.(y).(x) <- v)
            else
                (fun name -> find_taxon taxa (remove_quotes name)),
                (fun x y v -> 
                    try matrix.(x).(y) <- v with
                    | err ->
                            Printf.printf "Failed in %d, %d" x y;
                            raise err)
        in
        process_matrix (get_labels form) `Nexus matrix taxa characters 
        get_row_number assign_item data
    in
    let () =
        (* Eliminate the characters that the person doesn't really want *)
        match chars.P.char_eliminate with
        | None -> ()
        | Some x -> 
            apply_on_character_set acc.csets acc.characters
                (fun i -> characters.(i) <- { characters.(i) with st_eliminate = true })
                x
    in
    { acc with 
        characters = characters; matrix = matrix }

let make_ordered_matrix obsv = 
    let rec tail lst = 
        match lst with
        | [h] -> h
        | _ :: tl -> tail tl
        | [] -> failwith "empty list?"
    in
    let b = tail obsv in
    Array.init b (fun x ->
        Array.init b (fun y -> abs (x - y)))

let create_cost_type x =
    let do_irreversible updown x =
        (* TODO the following function and update the 
        * codes of the characters to be consecutive numbers
        * *)
        let mtx = make_ordered_matrix x.st_observed in
        let len = Array.length mtx in
        for i = 1 to (len - 1) do
            for j = 0 to i - 1 do
                match updown with
                | `DOWN -> mtx.(i).(j) <- max_int;
                | `UP -> mtx.(j).(i) <- max_int;
                    done;
            done;
            { x with st_type = STSankoff mtx } 
    in
    match String.uppercase x with
    | "UNORD" -> 
            (fun x -> { x with st_type =
                STUnordered })
    | "ORD" -> 
            (fun x -> { x with st_type =
                STOrdered })
    | "IRREV.DOWN"
    | "IRREV" ->
            do_irreversible `DOWN
    | "IRREV.UP" ->
            do_irreversible `UP
    | x -> 
            failwith 
            ("POY@ does@ not@ support@ the@ " ^
            x ^ "@ character@ type@ requested.")

let table_of_sankoff_matrices = Hashtbl.create 97
let generate_substitution_table extend_to_alphabet_size 
                                ((labels, cost_matrix) as input) alphabet =
    if Hashtbl.mem table_of_sankoff_matrices input then 
        Hashtbl.find table_of_sankoff_matrices input
    else begin
        let resulting_cost_matrix = 
            if not extend_to_alphabet_size then 
                Array.map (Array.map int_of_float) cost_matrix
            else
            let len = Array.length labels in
            let permutation_array =
                let labels = Array.init len (fun x ->
                    Alphabet.match_base labels.(x) alphabet, x) in
                Array.sort (fun (a, _) (b, _) -> a - b) labels;
                Array.map fst labels
            in
            let maximum = 1 + (Array.fold_left max (-1) permutation_array) in
            let resulting_cost_matrix = 
                Array.make_matrix maximum maximum (max_int / 4) in
            for i = 0 to len - 1 do
                for j = 0 to len - 1 do
                   resulting_cost_matrix.(permutation_array.(i)).(permutation_array.(j))
                   <- int_of_float cost_matrix.(i).(j);
                done;
            done;
            for i = 0 to maximum - 1 do
                resulting_cost_matrix.(i).(i) <- 0
            done;
            resulting_cost_matrix
        in
        Hashtbl.add table_of_sankoff_matrices input 
            resulting_cost_matrix;
        resulting_cost_matrix
    end

let produce_cost_type_function input character =
    let cm = generate_substitution_table true input character.st_alph in
    { character with st_type = STSankoff cm }

let update_assumptions cost_table (acc:nexus) item = 
    match item with
    | P.Options (default, polytcount, gapmode) ->
            let _ = match default with
                | None -> ()
                | Some x ->
                        for i = 0 to (Array.length acc.characters) - 1 do
                            acc.characters.(i) <- create_cost_type x acc.characters.(i)
                        done
            in
            let _ =
                match polytcount with
                | P.MinSteps -> ()
                | P.MaxSteps -> 
                        Status.user_message Status.Error
                        ("POY@ will@ ignore@ the@ MaxSteps@ command@ " ^
                        "in@ your@ nexus@ file")
            in
            let _ =
                match gapmode with
                | P.Missing -> 
                        let ntax = (Array.length acc.matrix) - 1 
                        and nchar = (Array.length acc.characters) - 1 in
                        let gaps = 
                            Array.map (fun spec ->
                                let gap = spec.st_gap in 
                                Some (`List [(Alphabet.match_base gap spec.st_alph)])
                                    ) acc.characters 
                        in
                        for i = 0 to ntax do
                            for j = 0 to nchar do
                                if acc.matrix.(i).(j) = gaps.(j) then
                                    acc.matrix.(i).(j) <- None
                            done;
                        done;
                | P.NewState -> ()
            in
            ()
    | P.UserType (name, x) ->
            let _ =
                match x with
                | P.StepMatrix (size, stepmtx) ->
                        let stepmtx = String.concat " " stepmtx in
                        let size = int_of_string size in
                        let stepmtx = remove_comments stepmtx in
                        let stepmtx = 
                            ref 
                            (Str.split 
                            (Str.regexp "[ \010\011\012\013\014\015]+")
                            stepmtx)
                        in
                        let headers = 
                            Array.init size (fun _ -> 
                                match !stepmtx with
                                | h :: t->
                                        stepmtx := t;
                                        h
                                | [] -> failwith "Invalid nexus matrix?")
                        in
                        let mtx = Array.init size (fun _ ->
                            Array.init size (fun _ ->
                                match !stepmtx with
                                | "i" :: t ->
                                        stepmtx := t;
                                        max_float
                                | "." :: t ->
                                        stepmtx := t;
                                        0.
                                | x :: t ->
                                        stepmtx := t;
                                        float_of_string x
                                | [] -> failwith "Insufficient matrix?"))
                        in
                        let name = String.uppercase name in
                        Hashtbl.add cost_table name (headers, mtx)
                | P.CSTree _ -> 
                        failwith 
                        ("POY@ does@ not@ support@ CSTreess@ from@ " ^
                        "NEXUS@ files")
            in
            ()
    | P.WeightDef (has_star, name, has_token, set) ->
            if not has_star then ()
            else begin
                let set_item weight x =
                    let x = x - 1 in
                    acc.characters.(x) <- 
                            { acc.characters.(x) with st_weight = weight }
                in
                let _ = match set with
                | P.Standard items ->
                    let process_item = function
                        | P.Code (v, who) ->
                            let weight = float_of_string v in
                            List.iter 
                                (apply_on_character_set acc.csets acc.characters 
                                    (set_item weight))
                                who 
                        | P.IName _ -> failwith "Unexpected name"
                    in
                    List.iter process_item items
                | P.Vector items ->
                    let _ =
                        List.fold_left 
                            (fun pos x -> set_item (float_of_string x) pos;pos+1)
                            0 items
                    in 
                    ()
                in
                ()
            end
    | P.TypeDef (has_star, name, has_token, set) ->
            let set_typedef clas x =
                let clas = String.uppercase clas in
                let new_def = 
                    match clas with
                    | "ORD" 
                    | "UNORD"
                    | "IRREV"
                    | "IRREV.UP"
                    | "IRREV.DOWN" -> create_cost_type clas
                    | name ->
                            produce_cost_type_function 
                            (Hashtbl.find cost_table name)
                in
                acc.characters.(x) <- new_def acc.characters.(x)
            in
            let _ =
                match set with
                | P.Standard items ->
                    let process_item = function
                        | P.Code (v, who)
                        | P.IName (v, who) ->
                            List.iter 
                                (apply_on_character_set acc.csets acc.characters 
                                                        (set_typedef v))
                                who
                    in
                    List.iter process_item items
                | P.Vector items ->
                    let _ = 
                        List.fold_left 
                            (fun pos x -> set_typedef x pos; pos + 1) 
                            0 items
                    in
                    ()
            in
            ()
    | _ -> ()


let process_tree (tree:string):P.tree = 
    let tree = remove_comments tree in
    let lex = Lexing.from_string tree in
    Grammar.tree Lexer.tree_tokens lex

let generate_parser_friendly (translations:(string*string) list)
                             (taxa: string option array)
                             ((name,tree):P.tree) : string option *
                             Tree.Parse.tree_types list =
    let rec process_name name =
        try process_name (List.assoc name translations)
        with | Not_found -> 
            try match taxa.(find_taxon taxa name) with
                | None -> name
                | Some x -> x
            with | _ ->
                try match taxa.(int_of_string name) with
                    | None -> name
                    | Some x -> x
                with | _ -> name
    in
    let rec translate_branch = function
        | P.Leaf (name, d) -> 
                Tree.Parse.Leafp (process_name name,d)
        | P.Node (a, n, d) ->
                Tree.Parse.Nodep (List.map translate_branch a, ("",d))
    in
    let tree = Tree.Parse.post_process (translate_branch tree,"") in
    (Some name, [tree])


let apply_gap_opening character_set acc = 
        let unaligned = Array.of_list (List.rev (acc.unaligned)) in
        let assign_gap_opening v pos =
            let (w, _, x, m, y, z) = unaligned.(pos) in
            unaligned.(pos) <- (w, (Some v), x, m , y , z)
        in
        List.iter 
            (function 
                | P.Code (gap_opening, who) ->
                    let gap_opening = truncate (float_of_string gap_opening) in
                    List.iter (apply_on_unaligned_set unaligned 
                                    (assign_gap_opening gap_opening))
                              who
                | P.IName (_, _) ->
                    failwith "GAPOPENING must be an integer value")
            character_set;
        let unaligned = List.rev (Array.to_list unaligned) in
        { acc with unaligned = unaligned; }


let apply_weight character_set acc = 
        let unaligned = Array.of_list (List.rev acc.unaligned) in
        let assign_weight weight pos =
            let (_, w, x, m, y, z) = unaligned.(pos) in
            unaligned.(pos) <- (weight, w, x, m, y, z)
        in
        List.iter 
            (function 
                | P.Code (weight, who) ->
                    let weight = float_of_string weight in
                    List.iter (apply_on_unaligned_set unaligned 
                                    (assign_weight weight))
                              who
                | P.IName (matrix, who) ->
                    failwith ("WTSET in the POY block must assign numbers"^
                              "to the gap opening parameter"))
            character_set;
        let unaligned = List.rev (Array.to_list unaligned) in
        { acc with unaligned = unaligned; }


let apply_tcm character_set acc = 
        let unaligned = Array.of_list (List.rev acc.unaligned) in
        let assign_tcm name v pos =
            let (w, x, _, y, m, z) = unaligned.(pos) in
            let v = generate_substitution_table false v y in
            unaligned.(pos) <- (w, x , (Some (name, v)), y , m , z)
        in
        List.iter 
            (function 
                | P.Code (_, _) ->
                    failwith ("TCM must assign a matrix defined in the "^
                              "ASSUMPTIONS block, not a code.");
                | P.IName (matrix, who) ->
                    if Hashtbl.mem acc.assumptions matrix then 
                        let table = Hashtbl.find acc.assumptions matrix in
                        List.iter (apply_on_unaligned_set unaligned 
                                        (assign_tcm matrix table))
                                  who
                    else
                        failwith ("TCM must assign a matrix defined in the"^
                                  "ASSUMPTIONS block. I couldn't find the "^
                                  " table " ^ matrix))
            character_set;
        let unaligned = List.rev (Array.to_list unaligned) in
        { acc with unaligned = unaligned; }


let add_branch_data (trees,chars,bls) acc =
    let current = acc.branches in
    (* small function to create/return a table in a table *)
    let const = 27 in
    let get_create_tbl main_tbl name =
        try Hashtbl.find main_tbl name 
        with | Not_found ->
            let t = Hashtbl.create const in
            Hashtbl.add main_tbl name t; t
    in
    (* get all the names *)
    let chars = 
        List.flatten
            (List.map
                (get_character_names acc.characters acc.csets)
                chars)
    in
    (* add each name to the table *)
    List.iter
        (fun tree_name ->
            let tree_name = String.uppercase tree_name in
            let tree_tbl = get_create_tbl current tree_name in
            List.iter
                (fun char_name -> (* do not uppercase, since
                    * it's generated from the actual names *)
                    List.iter 
                        (fun (node_name,length) ->
                            let node_name = String.uppercase node_name in
                            let node_tbl = get_create_tbl tree_tbl node_name in
                            Hashtbl.replace node_tbl char_name length)
                        bls)
                chars)
        trees;
    acc

let compute_static_priors alph u_gap (priors,count,gcount) inverse state =
    let size = Array.length priors in
    let gap_char = Alphabet.get_gap alph in
    let when_no_data_is_loaded () =
        incr gcount;
        for i = 0 to size - 1 do
            priors.(i) <- priors.(i) +. inverse;
        done
    in
    match state with
    | None     -> when_no_data_is_loaded ()
    | Some lst -> 
        let lst = match lst with
            | `List x -> x
            | `Bits x -> BitSet.to_list x
        in
        if ((List.exists (fun x -> x = gap_char) lst) && not u_gap) || (lst = []) then
            when_no_data_is_loaded ()
        else begin
            incr count;
            let inverse = 1. /. (float_of_int (List.length lst)) in
            List.iter (fun x -> priors.(x) <- priors.(x) +.  inverse) lst
        end

let static_priors_of_nexus (n:nexus) (gap) (chars) : float array =
    let verify_static_alphabet chars = 
        let first_alph = ref None in
        List.iter
            (apply_on_character_set 
                n.csets 
                n.characters
                (fun i -> match !first_alph with
                    | None -> first_alph := Some n.characters.(i).st_alph;
                    | Some a -> assert( a = n.characters.(i).st_alph )))
            (chars);
        match !first_alph with
        | Some a -> a
        | None   -> failwith "No characters selected for likelihood model"
    in
    let u_gap = match String.uppercase (fst gap) with (* put in MLModel?? *)
                | "" | "MISSING" -> false 
                | "COUPLED" | "INDEPENDENT" -> true
                | x -> failwith ("Invalid gap property: "^x)
    in
    let alph = verify_static_alphabet chars in
    let size = if u_gap then Alphabet.size alph else (Alphabet.size alph)-1 in
    (* set up some references for manipulation *)
    let priors = Array.make size 0.0
    and inverse = 1.0 /. (float_of_int size)
    and count = ref 0 
    and gcount = ref 0 in
    List.iter
        (apply_on_character_set 
            n.csets 
            n.characters
            (fun c -> 
                for t = 0 to ((Array.length n.matrix)-1) do
                    compute_static_priors 
                        alph u_gap (priors,count,gcount) inverse n.matrix.(t).(c);
                done;))
        (chars);
    MlModel.compute_priors (alph,u_gap) priors (!count,!gcount) []

let unaligned_priors_of_seq alph xsssts =
    let size = Alphabet.size alph in
    let priors = Array.make size 0.0 in
    let counter = ref 0 in
    let lengths = 
        List.map
            (fun (xsss,t) ->
                let total = ref 0 in
                List.iter (List.iter (List.iter (fun x ->
                    total := (Sequence.length x) - 1 + !total;
                    counter := (Sequence.length x) - 1 + !counter;
                    for i = 1 (* skip initial gap *) to (Sequence.length x) - 1 do
                        let lst = BitSet.Int.list_of_packed (Sequence.get x i) in
                        let inv = 1.0 /. (float_of_int (List.length lst)) in
                        List.iter (fun x -> priors.(x) <- priors.(x) +. inv) lst
                    done))) xsss;
                !total)
            xsssts
    in
    MlModel.compute_priors (alph,true) priors (!counter,0) lengths


let apply_likelihood_model params acc =
    let proc_model (((name,((kind,site,alpha,invar) as var),
                        param,lst,gap,cst,file) as model), chars) = function
        | P.Model name       -> ((name,var,param,lst,gap,cst,file),chars)
        | P.Parameters param -> ((name,var,param,lst,gap,cst,file),chars)
        | P.Chars chars      -> (model,chars)
        | P.Given_Priors lst -> ((name,var,param,`Given lst,gap,cst,file),chars)
        | P.Cost_Mode cst    -> ((name,var,param,lst,gap,cst,file),chars)
        | P.Gap_Mode gap     -> ((name,var,param,lst,gap,cst,file),chars)
        | P.Variation kind ->
                ((name,(kind,site,alpha,invar),param,lst,gap,cst,file),chars)
        | P.Variation_Sites site ->
                ((name,(kind,site,alpha,invar),param,lst,gap,cst,file),chars)
        | P.Variation_Alpha alpha ->
                ((name,(kind,site,alpha,invar),param,lst,gap,cst,file),chars)
        | P.Variation_Invar invar ->
                ((name,(kind,site,alpha,invar),param,lst,gap,cst,file),chars)
        | P.Files name ->
                ((name,var,param,lst,gap,cst,(Some name)),chars)
        (* Either Estimate or Equal *)
        | P.Other_Priors str ->
            begin match String.uppercase str with
                | "ESTIMATE" | "EST"   -> ((name,var,param,`Estimate None,gap,cst,file),chars)
                | "EQUAL" | "CONSTANT" -> ((name,var,param,`Equal,gap,cst,file),chars)
                | x -> failwith ("Prior option "^x^" is unknown")
            end
    in
    let ((a,b,c,pi,gap,f,g) as str_spec),characters_to_modify =
        List.fold_left proc_model (MlModel.empty_str_spec,[]) params
    in
    let convert_static char xs : unit =
        if (Array.length acc.characters) = 0 then
            ()
        else begin
            let m = (* estimate priors if necessary *)
                let str_spec = match pi with
                    | `Equal | `Given _ ->
                        (a,b,c,pi,gap,f,g)
                    | `Consistent _ ->
                        (* we calculate; and throw away if under jc69/k80 in
                         * model processing functions. *)
                        let priors =
                            static_priors_of_nexus acc gap characters_to_modify
                        in
                        (a,b,c,`Consistent (Some priors),gap,f,g)
                    | `Estimate _ ->
                        let priors =
                            static_priors_of_nexus acc gap characters_to_modify
                        in
                        (a,b,c,`Estimate (Some priors),gap,f,g)
                in
                STLikelihood
                    (str_spec --> MlModel.convert_string_spec
                              --> MlModel.create acc.characters.(0).st_alph)
            in
            List.iter
                (apply_on_character_set
                    acc.csets
                    acc.characters
                    (fun i ->
                        acc.characters.(i) <- { acc.characters.(i) with st_type = m; }))
                    xs;
            ()
        end
    and convert_unaligned lst = 
        List.map 
            (fun (z,w,x,alph,_,xsssts) ->
                Printf.printf "Converting Unaligned Characters to Likelihood!\n%!";
                let str_spec = match pi with
                    | `Equal | `Given _ -> str_spec
                    | `Consistent _ ->
                        let priors = unaligned_priors_of_seq alph xsssts in
                        (a,b,c,`Consistent (Some priors),gap,f,g)
                    | `Estimate _ ->
                        let priors = unaligned_priors_of_seq alph xsssts in
                        (a,b,c,`Estimate (Some priors),gap,f,g)
                in
                let m = str_spec --> MlModel.convert_string_spec
                                 --> MlModel.create alph
                in
                (z,w,x,alph,Some m,xsssts))
            lst
    in
    (* apply spec to each character *)
    match characters_to_modify with
        | [] ->
            let () = convert_static acc.characters [P.Name "all"] in
            { acc with unaligned = convert_unaligned acc.unaligned; }
        | xs ->
            let () = convert_static acc.characters xs in
            { acc with unaligned = convert_unaligned acc.unaligned; }


let process_parsed_elm file (acc:nexus) parsed : nexus = match parsed with
    | P.Taxa (number, taxa_list) ->
            let cnt = int_of_string number in
            let taxa =
                if cnt <> List.length taxa_list then
                    failwith ("Illegal NEXUS file: the number of taxa does " ^
                    "not match the DIMENSIONS value of the TAXA block")
                else add_all_taxa acc.taxa taxa_list
            in
            { acc with taxa = taxa }
    | P.Characters chars -> 
            add_prealigned_characters file chars acc
    | P.Error block ->
            Status.user_message Status.Error
                ("There@ is@ a@ parsing@ error@ in@ the@ block@ " ^
                 StatusCommon.escape block ^ ". I@ have@ rules@ to@ parse@ " ^
                 "this@ kind@ of@ block@ but@ something@ is@ wrong@ " ^
                 "with@ it.@ I@ will@ ignore@ the@ block@ and@ " ^
                 "continue@ with@ the@ rest@ of@ the@ file,@ but@ I@ " ^
                 "advice@ you@ to@ verify@ the@ cause@ of@ the@ error.");
            acc
    | P.Assumptions lst ->
            let table = Hashtbl.create 37 in
            List.iter (update_assumptions table acc) lst;
            acc
    | P.Trees (translations, newtrees) ->
            let handle_tree tree = 
                tree --> process_tree
                     --> generate_parser_friendly translations acc.taxa
            in
            let newtrees = List.map handle_tree newtrees in
            {acc with trees = acc.trees @ newtrees }
    | P.Unaligned data ->
            Printf.printf "Adding Unaligned data\n%!";
            let char_spec = 
                default_static acc.char_cntr file data.P.unal_format 0
            in
            let unal = uninterleave true data.P.unal in
            let alph = 
                (* We override whatever choice for the unaligned
                * sequences alphabet is, if we are dealing with our
                * core, known, alphabets *)
                match get_datatype data.P.unal_format with
                | P.Dna | P.Rna | P.Nucleotide ->
                        Alphabet.nucleotides
                | P.Protein -> Alphabet.aminoacids
                | P.DStandard -> char_spec.st_alph
                | P.Continuous -> 
                        failwith "POY can't handle continuous types"
            in
            let res = Fasta.of_string (FileContents.AlphSeq alph) unal in
            { acc with unaligned = (1.,None,None,alph,None,res) :: acc.unaligned;};
    | P.Sets data -> 
            List.iter (fun (name, set) ->
                match set with
                | P.CharacterSet set ->
                        (try 
                            let _ = find_character acc.characters name in
                            failwith 
                            ("Illegal character set name: " ^ name ^ 
                            " already exists as a character.")
                        with
                        | _ -> (* This is the normal path *)
                                let prepend acc item = item :: acc in
                                let set = List.fold_left prepend [] set in
                                Hashtbl.add acc.csets (String.uppercase name) set)
                | _ -> Status.user_message Status.Warning
                        ("I will ignore the set " ^ name ^ 
                         " defined in the NEXUS file.")) data;
            acc
    | P.Poy block ->
        Printf.printf "Adding POY data\n%!";
        List.fold_left
            (fun acc -> function
                | P.CharacterBranch (trees,chars,bls) ->
                    add_branch_data (trees,chars,bls) acc
                | P.GapOpening (true, name, character_set) ->
                    apply_gap_opening character_set acc
                | P.DynamicWeight (true, name, character_set) ->
                    apply_weight character_set acc
                | P.Tcm (true, name, character_set) ->
                    apply_tcm character_set acc
                | P.Likelihood params ->
                    apply_likelihood_model params acc
                | P.DynamicWeight (false, _ , _ )
                | P.Tcm (false, _ , _ )
                | P.GapOpening (false, _ , _ ) -> acc)
            acc
            block
    | (P.Distances _ | P.Ignore _ |P.Notes _ ) -> acc

let process_parsed file parsed : nexus =
    (* Some blocks require others to perform properly/efficently (without
       changing a large section of the code-base, or delaying computation in
       inappropriate sections of the code). Following are the current
       dependencies,

                   | depends on      | because 
        -----------+-----------------+---------------------
        POY        | Characters      | calculating priors
        POY        | Unaligned       | calculating priors 

        Note: the processing is done by a fold_left, thus the ordering needs to
        be backwards (this is to keep the function tail-recursive as well).
    *)
    let sorter a b = match a,b with
        | P.Characters _, P.Poy _ -> ~-1
        | P.Poy _, P.Characters _ ->   1
        | P.Unaligned _, P.Poy _  -> ~-1
        | P.Poy _, P.Unaligned _  ->   1
        | _, _                    ->   0 (* keep everything else in the same order *)
    in
    List.fold_left (process_parsed_elm file)
                   (empty_parsed ())
                   (List.stable_sort sorter parsed)


let of_channel ch file =
    (* Parse the file *)
    let parsed =
        let res = ref [] in
        let lex = Lexing.from_channel ch in
        try
            let () = Grammar.header Lexer.token lex in
            while true do
                let block = Grammar.block Lexer.token lex in
                res := block :: !res;
            done;
            []
        with
        | Lexer.Eof -> List.rev !res
    in
    let ret =
        let a = process_parsed file parsed in
        (* Now it is time to correct the order of the terminals to 
        * guarantee the default rooting of the tree. *)
        let tlen = Array.length a.taxa
        and mlen = Array.length a.matrix in
        assert (tlen >= mlen);
        let taxa = Array.init tlen (fun x -> a.taxa.(tlen - x - 1))
        and matrix = Array.init mlen (fun x -> a.matrix.(mlen - x - 1)) in
        { a with taxa = taxa; matrix = matrix; }
    in
    ret
