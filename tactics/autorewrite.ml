(************************************************************************)
(*         *   The Coq Proof Assistant / The Coq Development Team       *)
(*  v      *         Copyright INRIA, CNRS and contributors             *)
(* <O___,, * (see version control and CREDITS file for authors & dates) *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

open Equality
open Names
open Pp
open Constr
open Termops
open CErrors
open Util
open Mod_subst
open Locus

(* Rewriting rules *)
type rew_rule = { rew_lemma: constr;
                  rew_type: types;
                  rew_pat: constr;
                  rew_ctx: Univ.ContextSet.t;
                  rew_l2r: bool;
                  rew_tac: Genarg.glob_generic_argument option }

module RewRule =
struct
  type t = rew_rule
  let rew_lemma r = (r.rew_ctx, r.rew_lemma)
  let rew_l2r r = r.rew_l2r
  let rew_tac r = r.rew_tac
end

let subst_hint subst hint =
  let cst' = subst_mps subst hint.rew_lemma in
  let typ' = subst_mps subst hint.rew_type in
  let pat' = subst_mps subst hint.rew_pat in
  let t' = Option.Smart.map (Genintern.generic_substitute subst) hint.rew_tac in
    if hint.rew_lemma == cst' && hint.rew_type == typ' && hint.rew_tac == t' then hint else
      { hint with
        rew_lemma = cst'; rew_type = typ';
        rew_pat = pat';	rew_tac = t' }

module HintIdent =
struct
  type t = int * rew_rule

  let compare (i, t) (j, t') = i - j

  let constr_of (i,t) = t.rew_pat
end

(* Representation/approximation of terms to use in the dnet:
 *
 * - no meta or evar (use ['a pattern] for that)
 *
 * - [Rel]s and [Sort]s are not taken into account (that's why we need
 *   a second pass of linear filterin on the results - it's not a perfect
 *   term indexing structure)
 *)

module DTerm =
struct

  type 't t =
    | DRel
    | DSort
    | DRef    of GlobRef.t
    | DProd
    | DLet
    | DLambda of 't * 't
    | DApp    of 't * 't (* binary app *)
    | DCase   of case_info * 't * 't * 't array
    | DFix    of int array * int * 't array * 't array
    | DCoFix  of int * 't array * 't array
    | DInt    of Uint63.t
    | DFloat  of Float64.t
    | DArray  of 't array * 't * 't

  let compare_ci ci1 ci2 =
    let c = Ind.CanOrd.compare ci1.ci_ind ci2.ci_ind in
    if c = 0 then
      let c = Int.compare ci1.ci_npar ci2.ci_npar in
      if c = 0 then
        let c = Array.compare Int.compare ci1.ci_cstr_ndecls ci2.ci_cstr_ndecls in
        if c = 0 then
          Array.compare Int.compare ci1.ci_cstr_nargs ci2.ci_cstr_nargs
        else c
      else c
    else c

  let compare cmp t1 t2 = match t1, t2 with
  | DRel, DRel -> 0
  | DRel, _ -> -1 | _, DRel -> 1
  | DSort, DSort -> 0
  | DSort, _ -> -1 | _, DSort -> 1
  | DRef gr1, DRef gr2 -> GlobRef.CanOrd.compare gr1 gr2
  | DRef _, _ -> -1 | _, DRef _ -> 1

  | DProd, DProd -> 0
  | DProd, _ -> -1 | _, DProd -> 1

  | DLet, DLet -> 0
  | DLet, _ -> -1 | _, DLet -> 1

  | DLambda (tl1, tr1), DLambda (tl2, tr2)
  | DApp (tl1, tr1), DApp (tl2, tr2) ->
    let c = cmp tl1 tl2 in
    if c = 0 then cmp tr1 tr2 else c
  | DLambda _, _ -> -1 | _, DLambda _ -> 1
  | DApp _, _ -> -1 | _, DApp _ -> 1

  | DCase (ci1, c1, t1, p1), DCase (ci2, c2, t2, p2) ->
    let c = cmp c1 c2 in
    if c = 0 then
      let c = cmp t1 t2 in
      if c = 0 then
        let c = Array.compare cmp p1 p2 in
        if c = 0 then compare_ci ci1 ci2
        else c
      else c
    else c
  | DCase _, _ -> -1 | _, DCase _ -> 1

  | DFix (i1, j1, tl1, pl1), DFix (i2, j2, tl2, pl2) ->
    let c = Int.compare j1 j2 in
    if c = 0 then
      let c = Array.compare Int.compare i1 i2 in
      if c = 0 then
        let c = Array.compare cmp tl1 tl2 in
        if c = 0 then Array.compare cmp pl1 pl2
        else c
      else c
    else c
  | DFix _, _ -> -1 | _, DFix _ -> 1

  | DCoFix (i1, tl1, pl1), DCoFix (i2, tl2, pl2) ->
    let c = Int.compare i1 i2 in
    if c = 0 then
      let c = Array.compare cmp tl1 tl2 in
      if c = 0 then Array.compare cmp pl1 pl2
      else c
    else c
  | DCoFix _, _ -> -1 | _, DCoFix _ -> 1

  | DInt i1, DInt i2 -> Uint63.compare i1 i2

  | DInt _, _ -> -1 | _, DInt _ -> 1

  | DFloat f1, DFloat f2 -> Float64.total_compare f1 f2

  | DFloat _, _ -> -1 | _, DFloat _ -> 1

  | DArray(t1,def1,ty1), DArray(t2,def2,ty2) ->
    let c =  Array.compare cmp t1 t2 in
    if c = 0 then
      let c = cmp def1 def2 in
      if c = 0 then
      cmp ty1 ty2
      else c
    else c

  let dummy_cmp () () = 0

  let compare t1 t2 = compare dummy_cmp t1 t2

end

(*
 * Terms discrimination nets
 * Uses the general dnet datatype on DTerm.t
 * (here you can restart reading)
 *)

module HintDN :
sig
  type t
  type ident = HintIdent.t

  val empty : t

  (** [add c i dn] adds the binding [(c,i)] to [dn]. [c] can be a
     closed term or a pattern (with untyped Evars). No Metas accepted *)
  val add : constr -> ident -> t -> t

  (*
   * High-level primitives describing specific search problems
   *)

  (** [search_pattern dn c] returns all terms/patterns in dn
     matching/matched by c *)
  val search_pattern : t -> constr -> ident list

  (** [find_all dn] returns all idents contained in dn *)
  val find_all : t -> ident list

end
=
struct
  module Ident = HintIdent
  module PTerm =
  struct
    type t = unit DTerm.t
    let compare = DTerm.compare
  end
  module TDnet = Dn.Make(PTerm)(Ident)

  type t = TDnet.t

  type ident = HintIdent.t

  open DTerm
  open TDnet

  let pat_of_constr c : (unit DTerm.t * Constr.t list) option =
    let open GlobRef in
    let rec pat_of_constr c = match Constr.kind c with
    | Rel _          -> Some (DRel, [])
    | Sort _         -> Some (DSort, [])
    | Var i          -> Some (DRef (VarRef i), [])
    | Const (c,u)    -> Some (DRef (ConstRef c), [])
    | Ind (i,u)      -> Some (DRef (IndRef i), [])
    | Construct (c,u)-> Some (DRef (ConstructRef c), [])
    | Meta _         -> assert false
    | Evar (i,_)     -> None
    | Case (ci,u1,pms1,c1,_iv,c2,ca)     ->
      let f_ctx (_, p) = p in
      Some (DCase(ci, (), (), [||]), [f_ctx c1; c2] @ Array.map_to_list f_ctx ca)
    | Fix ((ia,i),(_,ta,ca)) ->
      Some (DFix(ia,i,[||],[||]), Array.to_list ta @ Array.to_list ca)
    | CoFix (i,(_,ta,ca))    ->
      Some (DCoFix(i, [||], [||]), Array.to_list ta @ Array.to_list ca)
    | Cast (c,_,_)   -> pat_of_constr c
    | Lambda (_,t,c) -> Some (DLambda ((), ()), [t; c])
    | Prod (_, t, u) -> Some (DProd, [t; u])
    | LetIn (_, c, t, u) -> Some (DLet, [c; t; u])
    | App (f,ca)     ->
      let len = Array.length ca in
      let a = ca.(len - 1) in
      let ca = Array.sub ca 0 (len - 1) in
      Some (DApp ((), ()), [mkApp (f, ca); a])
    | Proj (p,c) -> pat_of_constr (mkApp (mkConst (Projection.constant p), [|c|]))
    | Int i -> Some (DInt i, [])
    | Float f -> Some (DFloat f, [])
    | Array (_u,t,def,ty) ->
      Some (DArray ([||], (), ()), Array.to_list t @ [def ; ty])
    in
    pat_of_constr c

  (*
   * Basic primitives
   *)

  let empty = TDnet.empty

  let add (c:constr) (id:Ident.t) (dn:t) =
    (* We used to consider the types of the product as well, but since the dnet
       is only computing an approximation rectified by [filtering] we do not
       anymore. *)
    let (ctx, c) = Term.decompose_prod_assum c in
    let c = TDnet.pattern pat_of_constr c in
    TDnet.add dn c id

(* App(c,[t1,...tn]) -> ([c,t1,...,tn-1],tn)
   App(c,[||]) -> ([],c) *)
let split_app sigma c = match EConstr.kind sigma c with
    App(c,l) ->
      let len = Array.length l in
      if Int.equal len 0 then ([],c) else
        let last = Array.get l (len-1) in
        let prev = Array.sub l 0 (len-1) in
        c::(Array.to_list prev), last
  | _ -> assert false

exception CannotFilter

let filtering env sigma cv_pb c1 c2 =
  let open EConstr in
  let open Vars in
  let evm = ref Evar.Map.empty in
  let define cv_pb e1 ev c1 =
    try let (e2,c2) = Evar.Map.find ev !evm in
    let shift = e1 - e2 in
    if Termops.constr_cmp sigma cv_pb c1 (lift shift c2) then () else raise CannotFilter
    with Not_found ->
      evm := Evar.Map.add ev (e1,c1) !evm
  in
  let rec aux env cv_pb c1 c2 =
    match EConstr.kind sigma c1, EConstr.kind sigma c2 with
      | App _, App _ ->
        let ((p1,l1),(p2,l2)) = (split_app sigma c1),(split_app sigma c2) in
        let () = aux env cv_pb l1 l2 in
        begin match p1, p2 with
        | [], [] -> ()
        | (h1 :: p1), (h2 :: p2) ->
          aux env cv_pb (applist (h1, p1)) (applist (h2, p2))
        | _ -> assert false
        end
      | Prod (n,t1,c1), Prod (_,t2,c2) ->
          aux env cv_pb t1 t2;
          aux (env + 1) cv_pb c1 c2
      | _, Evar (ev,_) -> define cv_pb env ev c1
      | Evar (ev,_), _ -> define cv_pb env ev c2
      | _ ->
          if Termops.compare_constr_univ sigma
          (fun pb c1 c2 -> aux env pb c1 c2; true) cv_pb c1 c2 then ()
          else raise CannotFilter
          (* TODO: le reste des binders *)
  in
  try let () = aux env cv_pb c1 c2 in true with CannotFilter -> false

let align_prod_letin sigma c a =
  let open Termops in
  let (lc,_) = EConstr.decompose_prod_assum sigma c in
  let (l,a) = EConstr.decompose_prod_assum sigma a in
  let lc = List.length lc in
  let n = List.length l in
  if n < lc then invalid_arg "align_prod_letin";
  let l1 = CList.firstn lc l in
  n - lc, it_mkProd_or_LetIn a l1

  let decomp pat = match pat_of_constr pat with
  | None -> Dn.Everything
  | Some (lbl, args) -> Dn.Label (lbl, args)

  let search_pattern dn cpat =
    let _dctx, dpat = Term.decompose_prod_assum cpat in
    let whole_c = EConstr.of_constr cpat in
    List.sort (fun x y -> HintIdent.compare y x) @@ List.fold_left
      (fun acc id ->
         let c_id = EConstr.of_constr @@ Ident.constr_of id in
         let (ctx,wc) =
           try align_prod_letin Evd.empty whole_c c_id (* FIXME *)
           with Invalid_argument _ -> 0, c_id in
        if filtering ctx Evd.empty Reduction.CUMUL whole_c wc then id :: acc
        else acc
      ) (TDnet.lookup dn decomp dpat) []

  let find_all dn = List.sort HintIdent.compare (TDnet.lookup dn (fun () -> Everything) ())

end

(* Summary and Object declaration *)
let rewtab =
  Summary.ref (String.Map.empty : HintDN.t String.Map.t) ~name:"autorewrite"

let raw_find_base bas = String.Map.find bas !rewtab

let find_base bas =
  try raw_find_base bas
  with Not_found ->
    user_err
      (str "Rewriting base " ++ str bas ++ str " does not exist.")

let find_rewrites bas =
  List.rev_map snd (HintDN.find_all (find_base bas))

let find_matches bas pat =
  let base = find_base bas in
  let res = HintDN.search_pattern base pat in
  List.map snd res

let print_rewrite_hintdb bas =
  let env = Global.env () in
  let sigma = Evd.from_env env in
  (str "Database " ++ str bas ++ fnl () ++
           prlist_with_sep fnl
           (fun h ->
             str (if h.rew_l2r then "rewrite -> " else "rewrite <- ") ++
               Printer.pr_lconstr_env env sigma h.rew_lemma ++ str " of type " ++ Printer.pr_lconstr_env env sigma h.rew_type ++
               Option.cata (fun tac -> str " then use tactic " ++
               Pputils.pr_glb_generic env sigma tac) (mt ()) h.rew_tac)
           (find_rewrites bas))

type raw_rew_rule = (constr Univ.in_universe_context_set * bool * Genarg.raw_generic_argument option) CAst.t

(* Applies all the rules of one base *)
let one_base general_rewrite_maybe_in tac_main bas =
  let lrul = find_rewrites bas in
  let try_rewrite dir ctx c tc =
  Proofview.Goal.enter begin fun gl ->
    let sigma = Proofview.Goal.sigma gl in
    let subst, ctx' = UnivGen.fresh_universe_context_set_instance ctx in
    let c' = Vars.subst_univs_level_constr subst c in
    let sigma = Evd.merge_context_set Evd.univ_flexible sigma ctx' in
    Proofview.tclTHEN (Proofview.Unsafe.tclEVARS sigma)
    (general_rewrite_maybe_in dir c' tc)
  end in
  let open Proofview.Notations in
  Proofview.tclProofInfo [@ocaml.warning "-3"] >>= fun (_name, poly) ->
  let lrul = List.map (fun h ->
  let tac = match h.rew_tac with
  | None -> Proofview.tclUNIT ()
  | Some (Genarg.GenArg (Genarg.Glbwit wit, tac)) ->
    let ist = { Geninterp.lfun = Id.Map.empty
              ; poly
              ; extra = Geninterp.TacStore.empty } in
    Ftactic.run (Geninterp.interp wit ist tac) (fun _ -> Proofview.tclUNIT ())
  in
    (h.rew_ctx,h.rew_lemma,h.rew_l2r,tac)) lrul in
    Tacticals.tclREPEAT_MAIN (Proofview.tclPROGRESS (List.fold_left (fun tac (ctx,csr,dir,tc) ->
      Tacticals.tclTHEN tac
        (Tacticals.tclREPEAT_MAIN
            (Tacticals.tclTHENFIRST (try_rewrite dir ctx csr tc) tac_main)))
      (Proofview.tclUNIT()) lrul))

(* The AutoRewrite tactic *)
let autorewrite ?(conds=Naive) tac_main lbas =
  Tacticals.tclREPEAT_MAIN (Proofview.tclPROGRESS
    (List.fold_left (fun tac bas ->
       Tacticals.tclTHEN tac
        (one_base (fun dir c tac ->
          let tac = (tac, conds) in
            general_rewrite ~where:None ~l2r:dir AllOccurrences ~freeze:true ~dep:false ~with_evars:false ~tac (EConstr.of_constr c, Tactypes.NoBindings))
          tac_main bas))
      (Proofview.tclUNIT()) lbas))

let autorewrite_multi_in ?(conds=Naive) idl tac_main lbas =
  Proofview.Goal.enter begin fun gl ->
 (* let's check at once if id exists (to raise the appropriate error) *)
  let _ = List.map (fun id -> Tacmach.pf_get_hyp id gl) idl in
  let general_rewrite_in id dir cstr tac =
    let cstr = EConstr.of_constr cstr in
    general_rewrite ~where:(Some id) ~l2r:dir AllOccurrences ~freeze:true ~dep:false ~with_evars:false ~tac:(tac, conds) (cstr, Tactypes.NoBindings)
  in
 Tacticals.tclMAP (fun id ->
  Tacticals.tclREPEAT_MAIN (Proofview.tclPROGRESS
    (List.fold_left (fun tac bas ->
       Tacticals.tclTHEN tac (one_base (general_rewrite_in id) tac_main bas)) (Proofview.tclUNIT()) lbas)))
   idl
 end

let autorewrite_in ?(conds=Naive) id = autorewrite_multi_in ~conds [id]

let gen_auto_multi_rewrite conds tac_main lbas cl =
  let try_do_hyps treat_id l =
    autorewrite_multi_in ~conds (List.map treat_id l) tac_main lbas
  in
  if not (Locusops.is_all_occurrences cl.concl_occs) &&
     cl.concl_occs != NoOccurrences
  then
    let info = Exninfo.reify () in
    Tacticals.tclZEROMSG ~info (str"The \"at\" syntax isn't available yet for the autorewrite tactic.")
  else
    let compose_tac t1 t2 =
      match cl.onhyps with
        | Some [] -> t1
        | _ ->      Tacticals.tclTHENFIRST t1 t2
    in
    compose_tac
        (if cl.concl_occs != NoOccurrences then autorewrite ~conds tac_main lbas else Proofview.tclUNIT ())
        (match cl.onhyps with
           | Some l -> try_do_hyps (fun ((_,id),_) -> id) l
           | None ->
                 (* try to rewrite in all hypothesis
                    (except maybe the rewritten one) *)
               Proofview.Goal.enter begin fun gl ->
                 let ids = Tacmach.pf_ids_of_hyps gl in
                 try_do_hyps (fun id -> id)  ids
               end)

let auto_multi_rewrite ?(conds=Naive) lems cl =
  Proofview.wrap_exceptions (fun () -> gen_auto_multi_rewrite conds (Proofview.tclUNIT()) lems cl)

let auto_multi_rewrite_with ?(conds=Naive) tac_main lbas cl =
  let onconcl = match cl.Locus.concl_occs with NoOccurrences -> false | _ -> true in
  match onconcl,cl.Locus.onhyps with
    | false,Some [_] | true,Some [] | false,Some [] ->
        (* autorewrite with .... in clause using tac n'est sur que
           si clause represente soit le but soit UNE hypothese
        *)
        Proofview.wrap_exceptions (fun () -> gen_auto_multi_rewrite conds tac_main lbas cl)
    | _ ->
      let info = Exninfo.reify () in
      Tacticals.tclZEROMSG ~info
        (strbrk "autorewrite .. in .. using can only be used either with a unique hypothesis or on the conclusion.")

(* Functions necessary to the library object declaration *)
let cache_hintrewrite (rbase,lrl) =
  let base = try raw_find_base rbase with Not_found -> HintDN.empty in
  let max = try fst (Util.List.last (HintDN.find_all base)) with Failure _ -> 0 in
  let fold i accu r = HintDN.add r.rew_pat (i + max + 1, r) accu in
  let base = List.fold_left_i fold 0 base lrl in
  rewtab := String.Map.add rbase base !rewtab

let subst_hintrewrite (subst,(rbase,list as node)) =
  let list' = List.Smart.map (fun h -> subst_hint subst h) list in
    if list' == list then node else
      (rbase,list')

(* Declaration of the Hint Rewrite library object *)
let inGlobalHintRewrite : string * rew_rule list -> Libobject.obj =
  let open Libobject in
  declare_object @@ superglobal_object_nodischarge "HINT_REWRITE_GLOBAL"
    ~cache:cache_hintrewrite
    ~subst:(Some subst_hintrewrite)

let inExportHintRewrite : string * rew_rule list -> Libobject.obj =
  let open Libobject in
  declare_object @@ global_object_nodischarge ~cat:Hints.hint_cat "HINT_REWRITE_EXPORT"
    ~cache:cache_hintrewrite
    ~subst:(Some subst_hintrewrite)

type hypinfo = {
  hyp_ty : EConstr.types;
  hyp_pat : EConstr.constr;
}

let decompose_applied_relation env sigma c ctype left2right =
  let find_rel ty =
    (* FIXME: this is nonsense, we generate evars and then we drop the
       corresponding evarmap. This sometimes works because [Term_dnet] performs
       evar surgery via [Termops.filtering]. *)
    let sigma, ty = Clenv.make_evar_clause env sigma ty in
    let (_, args) = Termops.decompose_app_vect sigma ty.Clenv.cl_concl in
    let len = Array.length args in
    if 2 <= len then
      let c1 = args.(len - 2) in
      let c2 = args.(len - 1) in
      Some (if left2right then c1 else c2)
    else None
  in
    match find_rel ctype with
    | Some c -> Some { hyp_pat = c; hyp_ty = ctype }
    | None ->
        let ctx,t' = Reductionops.splay_prod_assum env sigma ctype in (* Search for underlying eq *)
        let ctype = it_mkProd_or_LetIn t' ctx in
        match find_rel ctype with
        | Some c -> Some { hyp_pat = c; hyp_ty = ctype }
        | None -> None

let find_applied_relation ?loc env sigma c left2right =
  let ctype = Retyping.get_type_of env sigma (EConstr.of_constr c) in
    match decompose_applied_relation env sigma c ctype left2right with
    | Some c -> c
    | None ->
        user_err ?loc
                    (str"The type" ++ spc () ++ Printer.pr_econstr_env env sigma ctype ++
                       spc () ++ str"of this term does not end with an applied relation.")

let warn_deprecated_hint_rewrite_without_locality =
  CWarnings.create ~name:"deprecated-hint-rewrite-without-locality" ~category:"deprecated"
    (fun () -> strbrk "The default value for rewriting hint locality is currently \
    \"local\" in a section and \"global\" otherwise, but is scheduled to change \
    in a future release. For the time being, adding rewriting hints outside of sections \
    without specifying an explicit locality attribute is therefore deprecated. It is \
    recommended to use \"export\" whenever possible. Use the attributes \
    #[local], #[global] and #[export] depending on your choice. For example: \
    \"#[export] Hint Rewrite foo : bar.\" This is supported since Coq 8.14.")

let default_hint_rewrite_locality () =
  if Global.sections_are_opened () then Hints.Local
  else
    let () = warn_deprecated_hint_rewrite_without_locality () in
    Hints.SuperGlobal

(* To add rewriting rules to a base *)
let add_rew_rules ~locality base lrul =
  let env = Global.env () in
  let sigma = Evd.from_env env in
  let ist = Genintern.empty_glob_sign (Global.env ()) in
  let intern tac = snd (Genintern.generic_intern ist tac) in
  let map {CAst.loc;v=((c,ctx),b,t)} =
    let sigma = Evd.merge_context_set Evd.univ_rigid sigma ctx in
    let info = find_applied_relation ?loc env sigma c b in
    let pat = EConstr.Unsafe.to_constr info.hyp_pat in
    { rew_lemma = c; rew_type = EConstr.Unsafe.to_constr info.hyp_ty;
      rew_pat = pat; rew_ctx = ctx; rew_l2r = b;
      rew_tac = Option.map intern t }
  in
  let lrul = List.map map lrul in
  let open Hints in
  match locality with
  | Local -> cache_hintrewrite (base,lrul)
  | SuperGlobal ->
    let () =
      if Global.sections_are_opened () then
      CErrors.user_err Pp.(str
        "This command does not support the global attribute in sections.");
    in
    Lib.add_leaf (inGlobalHintRewrite (base,lrul))
  | Export ->
    let () =
      if Global.sections_are_opened () then
        CErrors.user_err Pp.(str
          "This command does not support the export attribute in sections.");
    in
    Lib.add_leaf (inExportHintRewrite (base,lrul))
