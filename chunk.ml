type item_desc =
  | Definition of Parsetree.structure_item Location.loc
  | Module_opening of Location.t * string Location.loc * Parsetree.module_expr
  | Module_closing of Parsetree.structure_item Location.loc * History.offset

type item = Outline.sync * item_desc
type sync = item History.sync
type t = item History.t

exception Malformed_module
exception Invalid_chunk

let eof_lexer _ = Chunk_parser.EOF
let fail_lexer _ = failwith "lexer ended"
let fallback_lexer = eof_lexer

let line x = (x.Location.loc.Location.loc_start.Lexing.pos_lnum)

let dump_chunk = List.map
  begin function
  | Definition d -> ("definition", line d)
  | Module_opening (l,s,_) -> ("opening " ^ s.Location.txt, line s)
  | Module_closing (d,offset) -> ("closing after " ^ string_of_int offset, line d)
  end

let fake_tokens tokens f =
  let tokens = ref tokens in
  fun lexbuf ->
    match !tokens with
      | (t, sz) :: ts ->
          let open Lexing in
          lexbuf.lex_start_p <- lexbuf.lex_curr_p;
          lexbuf.lex_curr_p <- { lexbuf.lex_curr_p with pos_cnum = lexbuf.lex_curr_p.pos_cnum + sz };
          tokens := ts;
          t
      | _ -> f lexbuf

let sync_step outline tokens t =
  match outline with
    | Outline_utils.Enter_module ->
        let lexer = History.wrap_lexer (ref (History.of_list tokens))
          (fake_tokens [Chunk_parser.END, 3; Chunk_parser.EOF, 0] fallback_lexer)
        in
        let open Parsetree in
        begin match 
          (Chunk_parser.top_structure_item lexer (Lexing.from_string "")).Location.txt
        with
          | { pstr_desc = (Pstr_module (s,m)) ; pstr_loc } ->
              Some (Module_opening (pstr_loc, s, m))
          | _ -> assert false
        end
    | Outline_utils.Definition ->
        (* run structure_item parser on tokens, appending EOF *)
        let lexer = History.wrap_lexer (ref (History.of_list tokens))
          (fake_tokens [Chunk_parser.EOF, 0] fallback_lexer)
        in
        let lexer = Chunk_parser_utils.print_tokens ~who:"chunk" lexer in
        let def = Chunk_parser.top_structure_item lexer (Lexing.from_string "") in
        Some (Definition def)

    | Outline_utils.Done | Outline_utils.Unterminated | Outline_utils.Exception _ -> None
    | Outline_utils.Rollback -> raise Invalid_chunk

    | Outline_utils.Leave_module ->
        (* reconstitute module from t *)
        let rec rewind_defs defs t =
          match History.backward t with
          | Some ((_,Definition d), t') -> rewind_defs (d.Location.txt :: defs) t'
          | Some ((_,Module_closing (d,offset)), t') ->
              rewind_defs (d.Location.txt :: defs) (History.seek_offset offset t')
          | Some ((_,Module_opening (loc,s,m)), t') -> loc,s,m,defs,t'
          | None -> raise Malformed_module
        in
        let loc,s,m,defs,t = rewind_defs [] t in
        let open Parsetree in
        let rec subst_structure e =
          let pmod_desc = match e.pmod_desc with
            | Pmod_structure _ ->
                Pmod_structure defs
            | Pmod_functor (s,t,e) ->
                Pmod_functor (s,t,subst_structure e)
            | Pmod_constraint (e,t) ->
                Pmod_constraint (subst_structure e, t)
            | Pmod_apply  _ | Pmod_unpack _ | Pmod_ident  _ -> assert false
          in
          { e with pmod_desc }
        in
        let loc = match tokens with
            | (_,_,p) :: _ -> { loc with Location.loc_end = p }
            | [] -> loc
        in
        Some (Module_closing (
                Location.mkloc {
                  pstr_desc = Pstr_module (s, subst_structure m);
                  pstr_loc  = loc
                } loc,
                History.offset t
             ))

let sync outlines chunks =
  (* Find last synchronisation point *)
  let outlines, chunks = History.Sync.rewind fst outlines chunks in
  (* Drop out of sync items *)
  let chunks = History.cutoff chunks in
  (* Process last items *) 
  let rec aux outlines chunks =
    match History.forward outlines with
      | None -> chunks
      | Some ((filter,outline,data,exns),outlines') ->
          (*prerr_endline "SYNC PARSER";*)
          match
            try 
              match sync_step outline data chunks with
                | Some chunk -> Some (History.insert (History.Sync.at outlines', chunk) chunks)
                | None -> None
            with Syntaxerr.Error _ -> None
          with              
            | Some chunks -> aux outlines' chunks
            | None -> aux outlines' chunks
  in
  aux outlines chunks
