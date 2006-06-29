open Printer
open Util
open Term
open Termops 
open Names 
open Declarations
open Pp
open Entries
open Hiddentac
open Evd
open Tacmach
open Proof_type
open Tacticals
open Tactics
open Indfun_common
open Libnames

let msgnl = Pp.msgnl

let do_observe () = 
  Tacinterp.get_debug () <> Tactic_debug.DebugOff  


let observe strm =
  if do_observe ()
  then Pp.msgnl strm
  else ()

let observennl strm =
  if do_observe ()
  then begin Pp.msg strm;Pp.pp_flush () end
  else ()




let do_observe_tac s tac g =
 try let v = tac g in (* msgnl (goal ++ fnl () ++ (str s)++(str " ")++(str "finished")); *) v
 with e ->
   let goal = begin try (Printer.pr_goal (sig_it g)) with _ -> assert false end in
   msgnl (str "observation "++ s++str " raised exception " ++ 
	    Cerrors.explain_exn e ++ str " on goal " ++ goal ); 
   raise e;;


let observe_tac s tac g =
  if do_observe ()
  then do_observe_tac (str s) tac g
  else tac g


let tclTRYD tac = 
  if  !Options.debug  || do_observe ()
  then (fun g -> try (* do_observe_tac ""  *)tac g with _ -> tclIDTAC g)
  else tac


let list_chop ?(msg="") n l = 
  try 
    list_chop n l 
  with Failure (msg') -> 
    failwith (msg ^ msg')
  

let make_refl_eq type_of_t t  =
  let refl_equal_term = Lazy.force refl_equal in
  mkApp(refl_equal_term,[|type_of_t;t|])


type pte_info = 
    { 
      proving_tac : (identifier list ->  Tacmach.tactic);
      is_valid : constr -> bool
    }

type ptes_info = pte_info Idmap.t

type 'a dynamic_info = 
    { 
      nb_rec_hyps : int;
      rec_hyps : identifier list ; 
      eq_hyps : identifier list;
      info : 'a
    }

type body_info = constr dynamic_info 
      

let finish_proof dynamic_infos g = 
  observe_tac "finish" 
    ( h_assumption)
    g
	  

let refine c = 
  Tacmach.refine_no_check c

let thin l = 
  Tacmach.thin_no_check l
  

let cut_replacing id t tac :tactic= 
  tclTHENS (cut t)
    [ tclTHEN (thin_no_check [id]) (introduction_no_check id);
      tac 
    ]

let intro_erasing id = tclTHEN (thin [id]) (introduction id)



let rec_hyp_id = id_of_string "rec_hyp"

let is_trivial_eq t = 
  match kind_of_term t with 
    | App(f,[|_;t1;t2|]) when eq_constr f (Lazy.force eq) -> 
	eq_constr t1 t2
    | _ -> false 


let rec incompatible_constructor_terms t1 t2 = 
  let c1,arg1 = decompose_app t1 
  and c2,arg2 = decompose_app t2 
  in 
  (not (eq_constr t1 t2)) &&
    isConstruct c1 && isConstruct c2 && 
    (
      not (eq_constr c1 c2) || 
	List.exists2 incompatible_constructor_terms arg1 arg2
    )

let is_incompatible_eq t = 
  match kind_of_term t with 
    | App(f,[|_;t1;t2|]) when eq_constr f (Lazy.force eq) -> 
	incompatible_constructor_terms t1 t2
    | _ -> false 

let change_hyp_with_using msg hyp_id t tac : tactic = 
  fun g -> 
    let prov_id = pf_get_new_id hyp_id g in 
    tclTHENS
      (observe_tac msg (forward (Some  (tclCOMPLETE tac)) (Genarg.IntroIdentifier prov_id) t))
      [tclTHENLIST 
      [	
	observe_tac "change_hyp_with_using thin" (thin [hyp_id]);
	observe_tac "change_hyp_with_using rename " (h_rename prov_id hyp_id)
      ]] g

exception TOREMOVE


let prove_trivial_eq h_id context (type_of_term,term) = 
  let nb_intros = List.length context in 
  tclTHENLIST
    [
      tclDO nb_intros intro; (* introducing context *)
      (fun g -> 
	 let context_hyps =  
	   fst (list_chop ~msg:"prove_trivial_eq : " nb_intros (pf_ids_of_hyps g)) 
	 in
	 let context_hyps' = 
	   (mkApp(Lazy.force refl_equal,[|type_of_term;term|]))::
	     (List.map mkVar context_hyps)
	 in
	 let to_refine = applist(mkVar h_id,List.rev context_hyps') in 
	 refine to_refine g
      )
    ]


let isAppConstruct t = 
  if isApp t 
  then isConstruct (fst (destApp t))
  else false 

let nf_betaiotazeta = (* Reductionops.local_strong Reductionops.whd_betaiotazeta  *)
  let clos_norm_flags flgs env sigma t =
    Closure.norm_val (Closure.create_clos_infos flgs env) (Closure.inject (Reductionops.nf_evar sigma t)) in
  clos_norm_flags Closure.betaiotazeta  Environ.empty_env Evd.empty
    

let change_eq env sigma hyp_id (context:Sign.rel_context) x t end_of_type  = 
  let nochange msg  = 
    begin 
(*       observe (str ("Not treating ( "^msg^" )") ++ pr_lconstr t    ); *)
      failwith "NoChange"; 
    end
  in    
  if not (noccurn 1 end_of_type)
  then nochange "dependent"; (* if end_of_type depends on this term we don't touch it  *)
    if not (isApp t) then nochange "not an equality";
    let f_eq,args = destApp t in
    if not (eq_constr f_eq (Lazy.force eq)) then nochange "not an equality";
    let t1 = args.(1) 
    and t2 = args.(2) 
    and t1_typ = args.(0)
    in 
    if not (closed0 t1) then nochange "not a closed lhs";    
    let rec compute_substitution sub t1 t2 = 
      if isRel t2 
      then 
	let t2 = destRel t2  in 
	begin 
	  try 
	    let t1' = Intmap.find t2 sub in 
	    if not (eq_constr t1 t1') then nochange "twice bound variable";
	    sub
	  with Not_found -> 
	    assert (closed0 t1);
	    Intmap.add t2 t1 sub
	end
      else if isAppConstruct t1 && isAppConstruct t2 
      then 
	begin
	  let c1,args1 = destApp t1 
	  and c2,args2 = destApp t2 
	  in 
	  if not (eq_constr c1 c2) then anomaly "deconstructing equation";
	  array_fold_left2 compute_substitution sub args1 args2
	end
      else 
	if (eq_constr t1 t2) then sub else nochange "cannot solve"
    in
    let sub = compute_substitution Intmap.empty t1 t2 in 
    let end_of_type_with_pop = pop end_of_type in (*the equation will be removed *) 
    let new_end_of_type = 
      (* Ugly hack to prevent Map.fold order change between ocaml-3.08.3 and ocaml-3.08.4 
	 Can be safely replaced by the next comment for Ocaml >= 3.08.4
      *)
      let sub' = Intmap.fold (fun i t acc -> (i,t)::acc) sub [] in 
      let sub'' = List.sort (fun (x,_) (y,_) -> Pervasives.compare x y) sub' in 
      List.fold_left (fun end_of_type (i,t)  -> lift 1 (substnl  [t] (i-1) end_of_type))
	end_of_type_with_pop
	sub''
    in
    let old_context_length = List.length context + 1 in
    let witness_fun = 
      mkLetIn(Anonymous,make_refl_eq t1_typ t1,t,
	       mkApp(mkVar hyp_id,Array.init old_context_length (fun i -> mkRel (old_context_length - i)))
	      )
    in
    let new_type_of_hyp,ctxt_size,witness_fun = 
      list_fold_left_i 
	(fun i (end_of_type,ctxt_size,witness_fun) ((x',b',t') as decl) -> 
	   try 
	     let witness = Intmap.find i sub in 
	     if b' <> None then anomaly "can not redefine a rel!";
	     (pop end_of_type,ctxt_size,mkLetIn(x',witness,t',witness_fun))
	   with Not_found  -> 
	     (mkProd_or_LetIn decl end_of_type, ctxt_size + 1, mkLambda_or_LetIn decl witness_fun)
	)
	1 
	(new_end_of_type,0,witness_fun)
	context
    in
    let new_type_of_hyp = Reductionops.nf_betaiota  new_type_of_hyp in 
    let new_ctxt,new_end_of_type = 
      Sign.decompose_prod_n_assum ctxt_size new_type_of_hyp 
    in 
    let prove_new_hyp : tactic = 
      tclTHEN
	(tclDO ctxt_size intro)
	(fun g ->
	   let all_ids = pf_ids_of_hyps g in 
	   let new_ids,_  = list_chop ctxt_size all_ids in 
	   let to_refine = applist(witness_fun,List.rev_map mkVar new_ids) in 
	   refine to_refine g
	)
    in
    let simpl_eq_tac = 
      change_hyp_with_using "prove_pattern_simplification" hyp_id new_type_of_hyp prove_new_hyp
    in
(*     observe (str "In " ++ Ppconstr.pr_id hyp_id ++  *)
(* 	       str "removing an equation " ++ fnl ()++  *)
(* 	       str "old_typ_of_hyp :=" ++ *)
(* 	       Printer.pr_lconstr_env *)
(* 	       env *)
(* 	       (it_mkProd_or_LetIn ~init:end_of_type ((x,None,t)::context)) *)
(* 	     ++ fnl () ++ *)
(* 	       str "new_typ_of_hyp := "++  *)
(* 	       Printer.pr_lconstr_env env new_type_of_hyp ++ fnl () *)
(* 	     ++ str "old context := " ++ pr_rel_context env context ++ fnl ()  *)
(* 	     ++ str "new context := " ++ pr_rel_context env new_ctxt ++ fnl ()  *)
(* 	     ++ str "old type  := " ++ pr_lconstr end_of_type ++ fnl ()  *)
(* 	     ++ str "new type := " ++ pr_lconstr new_end_of_type ++ fnl ()  *)
(* ); *)
    new_ctxt,new_end_of_type,simpl_eq_tac


let is_property ptes_info t_x full_type_of_hyp = 
  if isApp t_x 
  then 
    let pte,args = destApp t_x in 
    if isVar pte && array_for_all closed0 args 
    then 
      try 
	let info = Idmap.find (destVar pte) ptes_info in 
	info.is_valid full_type_of_hyp	  
      with Not_found -> false 
    else false 
  else false 

let isLetIn t = 
  match kind_of_term t with 
    | LetIn _ -> true 
    | _ -> false 


let h_reduce_with_zeta = 	 
  h_reduce 
    (Rawterm.Cbv
       {Rawterm.all_flags 
	with Rawterm.rDelta = false; 		 
       })
  


let rewrite_until_var arg_num eq_ids : tactic =
  let test_var g = 
    let _,args = destApp (pf_concl g) in 
    not (isConstruct args.(arg_num))
  in
  let rec do_rewrite eq_ids g  = 
    if test_var g 
    then tclIDTAC g
    else
      match eq_ids with 
	| [] -> anomaly "Cannot find a way to prove recursive property";
	| eq_id::eq_ids -> 
	    tclTHEN 
	      (tclTRY (Equality.rewriteRL (mkVar eq_id)))
	      (do_rewrite eq_ids)
	      g
  in
  do_rewrite eq_ids


let rec_pte_id = id_of_string "Hrec" 
let clean_hyp_with_heq ptes_infos eq_hyps hyp_id env sigma = 
  let coq_False = Coqlib.build_coq_False () in 
  let coq_True = Coqlib.build_coq_True () in 
  let coq_I = Coqlib.build_coq_I () in 
  let rec scan_type  context type_of_hyp : tactic = 
    if isLetIn type_of_hyp then 
      let real_type_of_hyp = it_mkProd_or_LetIn ~init:type_of_hyp context in
      let reduced_type_of_hyp = nf_betaiotazeta real_type_of_hyp in 
      (* length of context didn't change ? *)
      let new_context,new_typ_of_hyp = 
	 Sign.decompose_prod_n_assum (List.length context) reduced_type_of_hyp
      in
        tclTHENLIST 
	[
	  h_reduce_with_zeta
	    (Tacticals.onHyp hyp_id)
	  ;
	  scan_type new_context new_typ_of_hyp 
	  
	]
    else if isProd type_of_hyp 
    then 
      begin 
	let (x,t_x,t') = destProd type_of_hyp in	
	let actual_real_type_of_hyp = it_mkProd_or_LetIn ~init:t' context in 
	if is_property ptes_infos t_x actual_real_type_of_hyp then
	  begin
	    let pte,pte_args =  (destApp t_x) in 
	    let (* fix_info *) prove_rec_hyp = (Idmap.find (destVar pte) ptes_infos).proving_tac in 
	    let popped_t' = pop t' in 
	    let real_type_of_hyp = it_mkProd_or_LetIn ~init:popped_t' context in 
	    let prove_new_type_of_hyp = 
	      let context_length = List.length context in 
	      tclTHENLIST
		[ 
		  tclDO context_length intro; 
		  (fun g ->  
		     let context_hyps_ids = 
		       fst (list_chop ~msg:"rec hyp : context_hyps"
			      context_length (pf_ids_of_hyps g))
		     in
		     let rec_pte_id = pf_get_new_id rec_pte_id g in 
		     let to_refine = 
		       applist(mkVar hyp_id,
			       List.rev_map mkVar (rec_pte_id::context_hyps_ids)
			      )
		     in
		     observe_tac "rec hyp "
		       (tclTHENS
		       (assert_as true (Genarg.IntroIdentifier rec_pte_id) t_x)
		       [observe_tac "prove rec hyp" (prove_rec_hyp eq_hyps);
			observe_tac "prove rec hyp"
			  (refine to_refine)
		       ])
		       g
		  )
		]
	    in
	    tclTHENLIST 
	      [
		observe_tac "hyp rec" 
		  (change_hyp_with_using "rec_hyp_tac" hyp_id real_type_of_hyp prove_new_type_of_hyp);
		scan_type context popped_t'
	      ]
	  end
	else if eq_constr t_x coq_False then 
	  begin
(* 	    observe (str "Removing : "++ Ppconstr.pr_id hyp_id++  *)
(* 		       str " since it has False in its preconds " *)
(* 		    ); *)
	    raise TOREMOVE;  (* False -> .. useless *)
	  end
	else if is_incompatible_eq t_x then raise TOREMOVE (* t_x := C1 ... =  C2 ... *) 
	else if eq_constr t_x coq_True  (* Trivial => we remove this precons *)
	then 
(* 	    observe (str "In "++Ppconstr.pr_id hyp_id++  *)
(* 		       str " removing useless precond True" *)
(* 		    );  *)
	  let popped_t' = pop t' in
	  let real_type_of_hyp = 
	    it_mkProd_or_LetIn ~init:popped_t' context 
	  in 
	  let prove_trivial =  
	    let nb_intro = List.length context in 
	    tclTHENLIST [
	      tclDO nb_intro intro;
	      (fun g -> 
		 let context_hyps = 
		   fst (list_chop ~msg:"removing True : context_hyps "nb_intro (pf_ids_of_hyps g))
		 in
		 let to_refine = 
		   applist (mkVar hyp_id,
			    List.rev (coq_I::List.map mkVar context_hyps)
			   )
		 in
		 refine to_refine g
	      )
	    ]
	  in
	  tclTHENLIST[
	    change_hyp_with_using "prove_trivial" hyp_id real_type_of_hyp 
	      (observe_tac "prove_trivial" prove_trivial);
	    scan_type context popped_t'
	  ]
	else if is_trivial_eq t_x 
	then (*  t_x :=  t = t   => we remove this precond *) 
	  let popped_t' = pop t' in
	  let real_type_of_hyp =
	    it_mkProd_or_LetIn ~init:popped_t' context
	  in
	  let _,args = destApp t_x in
	  tclTHENLIST
	    [
	      change_hyp_with_using
		"prove_trivial_eq"
		hyp_id
		real_type_of_hyp
		(observe_tac "prove_trivial_eq" (prove_trivial_eq hyp_id context (args.(0),args.(1))));
	      scan_type context popped_t'
	    ] 
	else 
	  begin
	    try 
	      let new_context,new_t',tac = change_eq env sigma hyp_id context x t_x t' in 
	      tclTHEN
		tac 
		(scan_type new_context new_t')
	    with Failure "NoChange" -> 
	      (* Last thing todo : push the rel in the context and continue *) 
	      scan_type ((x,None,t_x)::context) t'
	  end
      end
    else
      tclIDTAC
  in 
  try 
    scan_type [] (Typing.type_of env sigma (mkVar hyp_id)), [hyp_id]
  with TOREMOVE -> 
    thin [hyp_id],[]


let clean_goal_with_heq ptes_infos continue_tac dyn_infos  = 
  fun g -> 
    let env = pf_env g 
    and sigma = project g 
    in
    let tac,new_hyps = 
      List.fold_left ( 
	fun (hyps_tac,new_hyps) hyp_id ->
	  let hyp_tac,new_hyp = 
	    clean_hyp_with_heq ptes_infos dyn_infos.eq_hyps hyp_id env sigma 
	  in
	  (tclTHEN hyp_tac hyps_tac),new_hyp@new_hyps
      )
	(tclIDTAC,[])
	dyn_infos.rec_hyps
    in
    let new_infos = 
      { dyn_infos with 
	  rec_hyps = new_hyps; 
	  nb_rec_hyps  = List.length new_hyps
      }
    in
    tclTHENLIST 
      [
	tac ;
	(continue_tac new_infos)
      ]
      g    

let heq_id = id_of_string "Heq"

let treat_new_case ptes_infos nb_prod continue_tac term dyn_infos = 
  fun g -> 
    let heq_id = pf_get_new_id heq_id g in 
    let nb_first_intro = nb_prod - 1 - dyn_infos.nb_rec_hyps in
    tclTHENLIST
      [ 
	(* We first introduce the variables *) 
	tclDO nb_first_intro (intro_avoiding dyn_infos.rec_hyps);
	(* Then the equation itself *)
	introduction_no_check heq_id;
	(* Then the new hypothesis *) 
	tclMAP introduction_no_check dyn_infos.rec_hyps;
	observe_tac "after_introduction" (fun g' -> 
	   (* We get infos on the equations introduced*)
	   let new_term_value_eq = pf_type_of g' (mkVar heq_id) in 
	   (* compute the new value of the body *)
	   let new_term_value =
	     match kind_of_term new_term_value_eq with
	       | App(f,[| _;_;args2 |]) -> args2
	       | _ ->
		   observe (str "cannot compute new term value : " ++ pr_gls g' ++ fnl () ++ str "last hyp is" ++
			      pr_lconstr_env (pf_env g') new_term_value_eq
			   );
		   anomaly "cannot compute new term value"
	   in
	 let fun_body =
	   mkLambda(Anonymous,
		    pf_type_of g' term,
		    replace_term term (mkRel 1) dyn_infos.info
		   )
	 in
	 let new_body = pf_nf_betaiota g' (mkApp(fun_body,[| new_term_value |])) in
	 let new_infos = 
	   {dyn_infos with 
	      info = new_body;
	      eq_hyps = heq_id::dyn_infos.eq_hyps
	   }
	 in 
	 clean_goal_with_heq ptes_infos continue_tac new_infos  g'
      )
    ]
      g


let my_orelse tac1 tac2 g = 
  try 
    tac1 g 
  with e -> 
(*     observe (str "using snd tac since : " ++ Cerrors.explain_exn e); *)
    tac2 g 

let instanciate_hyps_with_args (do_prove:identifier list -> tactic) hyps args_id = 
  let args = Array.of_list (List.map mkVar  args_id) in 
  let instanciate_one_hyp hid = 
    my_orelse
      ( (* we instanciate the hyp if possible  *)
	fun g -> 
	  let prov_hid = pf_get_new_id hid g in
	  tclTHENLIST[
	    forward None (Genarg.IntroIdentifier prov_hid) (mkApp(mkVar hid,args));
	    thin [hid];
	    h_rename prov_hid hid
	  ] g
      )
      ( (*
	  if not then we are in a mutual function block 
	  and this hyp is a recursive hyp on an other function.
	  
	  We are not supposed to use it while proving this 
	  principle so that we can trash it 
	  
	*)
	(fun g -> 
(* 	   observe (str "Instanciation: removing hyp " ++ Ppconstr.pr_id hid); *)
	   thin [hid] g
	)
      )
  in
  if args_id = []  
  then 
    tclTHENLIST [
      tclMAP (fun hyp_id -> h_reduce_with_zeta (Tacticals.onHyp hyp_id)) hyps;
      do_prove hyps
    ]
  else
    tclTHENLIST
      [
	tclMAP (fun hyp_id -> h_reduce_with_zeta (Tacticals.onHyp hyp_id)) hyps;
	tclMAP instanciate_one_hyp hyps;
	(fun g ->  
	   let all_g_hyps_id = 
	     List.fold_right Idset.add (pf_ids_of_hyps g) Idset.empty
	   in 
	   let remaining_hyps = 
	     List.filter (fun id -> Idset.mem id all_g_hyps_id) hyps
	   in
	   do_prove remaining_hyps g
	  )
      ]

let build_proof 
    (interactive_proof:bool)
    (fnames:constant list)
    ptes_infos
    dyn_infos
    : tactic =
  let rec build_proof_aux do_finalize dyn_infos : tactic = 
    fun g -> 
      
(*      observe (str "proving on " ++ Printer.pr_lconstr_env (pf_env g) term);*)
	match kind_of_term dyn_infos.info with 
	  | Case(_,_,t,_) -> 
	      let g_nb_prod = nb_prod (pf_concl g) in
	      let type_of_term = pf_type_of g t in
	      let term_eq =
		make_refl_eq type_of_term t
	      in
	      tclTHENSEQ
		[
		  h_generalize (term_eq::(List.map mkVar dyn_infos.rec_hyps));
		  thin dyn_infos.rec_hyps;
		  pattern_option [[-1],t] None;
		  h_simplest_case t;
		  (fun g' -> 
		     let g'_nb_prod = nb_prod (pf_concl g') in 
		     let nb_instanciate_partial = g'_nb_prod - g_nb_prod in 
		     observe_tac "treat_new_case" 
		       (treat_new_case  
		       ptes_infos
		       nb_instanciate_partial 
		       (build_proof do_finalize) 
		       t 
		       dyn_infos)
		       g'
		  )
		  
		] g
	  | Lambda(n,t,b) ->
	      begin
		match kind_of_term( pf_concl g) with
		  | Prod _ ->
		      tclTHEN
			intro
			(fun g' ->
			   let (id,_,_) = pf_last_hyp g' in
			   let new_term = 
			     pf_nf_betaiota g' 
			       (mkApp(dyn_infos.info,[|mkVar id|])) 
			   in
			   let new_infos = {dyn_infos with info = new_term} in
			   let do_prove new_hyps = 
			     build_proof do_finalize 
			       {new_infos with
			       	  rec_hyps = new_hyps; 
				  nb_rec_hyps  = List.length new_hyps
			       }
			   in 
			   observe_tac "Lambda" (instanciate_hyps_with_args do_prove new_infos.rec_hyps [id]) g'
			     (* 			   build_proof do_finalize new_infos g' *)
			) g
		  | _ ->
		      do_finalize dyn_infos g 
	      end
	  | Cast(t,_,_) -> 
	      build_proof do_finalize {dyn_infos with info = t} g
	  | Const _ | Var _ | Meta _ | Evar _ | Sort _ | Construct _ | Ind _ ->
	      do_finalize dyn_infos g
	  | App(_,_) ->
	      let f,args = decompose_app dyn_infos.info in
	      begin
		match kind_of_term f with
		  | App _ -> assert false (* we have collected all the app in decompose_app *)
		  | Var _ | Construct _ | Rel _ | Evar _ | Meta _  | Ind _ | Sort _ | Prod _ ->
		      let new_infos = 
			{ dyn_infos with 
			    info = (f,args)
			}
		      in
		      build_proof_args do_finalize new_infos  g
		  | Const c when not (List.mem c fnames) ->
		      let new_infos = 
			{ dyn_infos with 
			    info = (f,args)
			}
		      in
(* 		      Pp.msgnl (str "proving in " ++ pr_lconstr_env (pf_env g) dyn_infos.info); *)
		      build_proof_args do_finalize new_infos g
		  | Const _ ->
		      do_finalize dyn_infos  g
		  | Lambda _ -> 
		      let new_term = Reductionops.nf_beta dyn_infos.info in 
		      build_proof do_finalize {dyn_infos with info = new_term} 
			g
		  | LetIn _ -> 
		      let new_infos = 
			{ dyn_infos with info = nf_betaiotazeta dyn_infos.info } 
		      in 

		      tclTHENLIST 
			[tclMAP 
			   (fun hyp_id -> h_reduce_with_zeta (Tacticals.onHyp hyp_id)) 
			   dyn_infos.rec_hyps;
			 h_reduce_with_zeta Tacticals.onConcl;
			 build_proof do_finalize new_infos
			] 
			g
		  | Cast(b,_,_) -> 
		      build_proof do_finalize {dyn_infos with info = b } g
		  | Case _ | Fix _ | CoFix _ ->
		      let new_finalize dyn_infos = 
			let new_infos = 
			  { dyn_infos with 
			      info = dyn_infos.info,args
			  }
			in 
			build_proof_args do_finalize new_infos 
		      in 
		      build_proof new_finalize {dyn_infos  with info = f } g
	      end
	  | Fix _ | CoFix _ ->
	      error ( "Anonymous local (co)fixpoints are not handled yet")

	  | Prod _ -> error "Prod" 
	  | LetIn _ -> 
	      let new_infos = 
		{ dyn_infos with 
		    info = nf_betaiotazeta dyn_infos.info 
		}
	      in 

	      tclTHENLIST 
		[tclMAP 
		   (fun hyp_id -> h_reduce_with_zeta (Tacticals.onHyp hyp_id)) 
		   dyn_infos.rec_hyps;
		 h_reduce_with_zeta Tacticals.onConcl;
		 build_proof do_finalize new_infos
		] g
	  | Rel _ -> anomaly "Free var in goal conclusion !" 
  and build_proof do_finalize dyn_infos g =
(*     observe (str "proving with "++Printer.pr_lconstr dyn_infos.info++ str " on goal " ++ pr_gls g); *)
     (build_proof_aux do_finalize dyn_infos) g
  and build_proof_args do_finalize dyn_infos (* f_args'  args *) :tactic =
    fun g ->
(*      if Tacinterp.get_debug () <> Tactic_debug.DebugOff  *)
(*      then msgnl (str "build_proof_args with "  ++  *)
(* 		   pr_lconstr_env (pf_env g) f_args' *)
(* 		); *)
      let (f_args',args) = dyn_infos.info in 
      let tac : tactic =
	fun g -> 
	match args with
	  | []  ->
	      do_finalize {dyn_infos with info = f_args'} g 
	  | arg::args ->
(* 		observe (str "build_proof_args with arg := "++ pr_lconstr_env (pf_env g) arg++ *)
(* 			fnl () ++  *)
(* 			pr_goal (Tacmach.sig_it g) *)
(* 			); *)
	      let do_finalize dyn_infos =
		let new_arg = dyn_infos.info in 
		(* 		tclTRYD *)
		(build_proof_args
		   do_finalize
		   {dyn_infos with info = (mkApp(f_args',[|new_arg|])), args}
		)
	      in
	      build_proof do_finalize 
		{dyn_infos with info = arg }
		g
      in
      observe_tac "build_proof_args" (tac ) g
   in
   let do_finish_proof dyn_infos = 
     (* tclTRYD *) (clean_goal_with_heq 
      ptes_infos
      finish_proof dyn_infos)
  in
  observe_tac "build_proof"
    (build_proof do_finish_proof dyn_infos) 












(* Proof of principles from structural functions *) 
let is_pte_type t =
  isSort (snd (decompose_prod t))
    
let is_pte (_,_,t) = is_pte_type t




type static_fix_info = 
    {
      idx : int;
      name : identifier;
      types : types;
      offset : int;
      nb_realargs : int;
      body_with_param : constr;
      num_in_block : int 
    }



let prove_rec_hyp_for_struct fix_info = 
      (fun  eq_hyps -> tclTHEN 
	(rewrite_until_var (fix_info.idx) eq_hyps)
	(fun g -> 
	   let _,pte_args = destApp (pf_concl g) in 
	   let rec_hyp_proof = 
	     mkApp(mkVar fix_info.name,array_get_start pte_args) 
	   in
	   refine rec_hyp_proof g
	))

let prove_rec_hyp fix_info  =
  { proving_tac = prove_rec_hyp_for_struct fix_info
  ;
    is_valid = fun _ -> true 
  }


exception Not_Rec
    
let generalize_non_dep hyp g = 
(*   observe (str "rec id := " ++ Ppconstr.pr_id hyp); *)
  let hyps = [hyp] in 
  let env = Global.env () in 
  let hyp_typ = pf_type_of g (mkVar hyp) in 
  let to_revert,_ = 
    Environ.fold_named_context_reverse (fun (clear,keep) (hyp,_,_ as decl) ->
      if List.mem hyp hyps
	or List.exists (occur_var_in_decl env hyp) keep
	or occur_var env hyp hyp_typ
	or Termops.is_section_variable hyp (* should be dangerous *) 
      then (clear,decl::keep)
      else (hyp::clear,keep))
      ~init:([],[]) (pf_env g)
  in
(*   observe (str "to_revert := " ++ prlist_with_sep spc Ppconstr.pr_id to_revert); *)
  tclTHEN 
    (observe_tac "h_generalize" (h_generalize  (List.map mkVar to_revert) ))
    (observe_tac "thin" (thin to_revert))
    g
  
let id_of_decl (na,_,_) =  (Nameops.out_name na)
let var_of_decl decl = mkVar (id_of_decl decl)
let revert idl = 
  tclTHEN 
    (generalize (List.map mkVar idl)) 
    (thin idl)

let generate_equation_lemma fnames f fun_num nb_params nb_args rec_args_num =
(*   observe (str "nb_args := " ++ str (string_of_int nb_args)); *)
(*   observe (str "nb_params := " ++ str (string_of_int nb_params)); *)
(*   observe (str "rec_args_num := " ++ str (string_of_int (rec_args_num + 1) )); *)
  let f_def = Global.lookup_constant (destConst f) in
  let eq_lhs = mkApp(f,Array.init (nb_params + nb_args) (fun i -> mkRel(nb_params + nb_args - i))) in
  let f_body =
    force (out_some f_def.const_body)
  in
  let params,f_body_with_params = decompose_lam_n nb_params f_body in
  let (_,num),(_,_,bodies) = destFix f_body_with_params in
  let fnames_with_params =
    let params = Array.init nb_params (fun i -> mkRel(nb_params - i)) in
    let fnames = List.rev (Array.to_list (Array.map (fun f -> mkApp(f,params)) fnames)) in
    fnames
  in
(*   observe (str "fnames_with_params " ++ prlist_with_sep fnl pr_lconstr fnames_with_params); *)
(*   observe (str "body " ++ pr_lconstr bodies.(num)); *)
  let f_body_with_params_and_other_fun  = substl fnames_with_params bodies.(num) in
(*   observe (str "f_body_with_params_and_other_fun " ++  pr_lconstr f_body_with_params_and_other_fun); *)
  let eq_rhs = nf_betaiotazeta (mkApp(compose_lam params f_body_with_params_and_other_fun,Array.init (nb_params + nb_args) (fun i -> mkRel(nb_params + nb_args - i)))) in
(*   observe (str "eq_rhs " ++  pr_lconstr eq_rhs); *)
  let type_ctxt,type_of_f = Sign.decompose_prod_n_assum (nb_params + nb_args) f_def.const_type in
  let eqn = mkApp(Lazy.force eq,[|type_of_f;eq_lhs;eq_rhs|]) in
  let lemma_type = it_mkProd_or_LetIn ~init:eqn type_ctxt in
  let f_id = id_of_label (con_label (destConst f)) in
  let prove_replacement =
    tclTHENSEQ
      [
	tclDO (nb_params + rec_args_num + 1) intro;
	observe_tac "" (fun g ->
	   let rec_id = pf_nth_hyp_id g 1 in
	   tclTHENSEQ
	     [observe_tac "generalize_non_dep in generate_equation_lemma" (generalize_non_dep rec_id);
	      observe_tac "h_case" (h_case(mkVar rec_id,Rawterm.NoBindings));
	      intros_reflexivity] g
	)
      ]
  in
  Command.start_proof
    (mk_equation_id f_id)
    (Decl_kinds.Global,(Decl_kinds.Proof Decl_kinds.Theorem))
    lemma_type
    (fun _ _ -> ());
  Pfedit.by (prove_replacement);
  Command.save_named false



  
let do_replace params rec_arg_num rev_args_id f fun_num all_funs g =
  let f_id = id_of_label (con_label (destConst f)) in 
  let equation_lemma_id = (mk_equation_id f_id) in 
  let equation_lemma = 
    try 
      Tacinterp.constr_of_id (pf_env g) equation_lemma_id 
    with Not_found -> 
      generate_equation_lemma all_funs f fun_num (List.length params) (List.length rev_args_id) rec_arg_num;
      Tacinterp.constr_of_id (pf_env g) equation_lemma_id
  in
(*   observe (Ppconstr.pr_id equation_lemma_id ++ str " has type " ++ pr_lconstr_env (pf_env g) (pf_type_of g equation_lemma)); *)
  let nb_intro_to_do = nb_prod (pf_concl g) in
    tclTHEN
      (tclDO nb_intro_to_do intro)
      (
	fun g' -> 
	  let just_introduced = nLastHyps nb_intro_to_do g' in 
	  let just_introduced_id = List.map (fun (id,_,_) -> id) just_introduced in 
	  tclTHEN (Equality.rewriteLR equation_lemma) (revert just_introduced_id) g'
      )
      g

let prove_princ_for_struct interactive_proof fun_num fnames all_funs _nparams : tactic =
  fun g -> 
    let princ_type = pf_concl g in 
    let princ_info = compute_elim_sig princ_type in 
    let fresh_id = 
      let avoid = ref (pf_ids_of_hyps g) in 
      (fun na -> 
	 let new_id = 
	   match na with 
	       Name id -> fresh_id !avoid (string_of_id id) 
	     | Anonymous -> fresh_id !avoid "H"
	 in
	 avoid := new_id :: !avoid; 
	 (Name new_id)
      )
    in
    let fresh_decl = 
      (fun (na,b,t) -> 
	 (fresh_id na,b,t)
      )
    in
    let princ_info : elim_scheme = 
      { princ_info with 
	  params = List.map fresh_decl princ_info.params;
	  predicates = List.map fresh_decl princ_info.predicates; 
	  branches = List.map fresh_decl princ_info.branches; 
	  args = List.map fresh_decl princ_info.args
      }
    in
    let get_body const =
      match (Global.lookup_constant const ).const_body with
	| Some b ->
	     let body = force b in
	     Tacred.cbv_norm_flags
	       (Closure.RedFlags.mkflags [Closure.RedFlags.fZETA])
	       (Global.env ())
	       (Evd.empty)
	       body
	| None -> error ( "Cannot define a principle over an axiom ")
    in
    let fbody = get_body fnames.(fun_num) in
    let f_ctxt,f_body = decompose_lam fbody in 
    let f_ctxt_length = List.length f_ctxt in 
    let diff_params = princ_info.nparams - f_ctxt_length in 
    let full_params,princ_params,fbody_with_full_params = 
      if diff_params > 0
      then 
	let princ_params,full_params = 
	  list_chop  diff_params princ_info.params 
	in 
	(full_params, (* real params *)
	 princ_params, (* the params of the principle which are not params of the function *)
	 substl (* function instanciated with real params *)
	   (List.map var_of_decl full_params)
	   f_body
	)
      else
	let f_ctxt_other,f_ctxt_params = 
	  list_chop (- diff_params) f_ctxt in 
	let f_body = compose_lam f_ctxt_other f_body in 
	(princ_info.params, (* real params *)
	 [],(* all params are full params *)
	 substl (* function instanciated with real params *)
	   (List.map var_of_decl princ_info.params)
	   f_body
	)
    in
(*     observe (str "full_params := " ++  *)
(* 	       prlist_with_sep spc (fun (na,_,_) -> Ppconstr.pr_id (Nameops.out_name na)) *)
(* 	       full_params *)
(* 	    );  *)
(*     observe (str "princ_params := " ++  *)
(* 	       prlist_with_sep spc (fun (na,_,_) -> Ppconstr.pr_id (Nameops.out_name na)) *)
(* 	       princ_params *)
(* 	    );  *)
(*     observe (str "fbody_with_full_params := " ++  *)
(* 	       pr_lconstr fbody_with_full_params *)
(* 	    );  *)
    let all_funs_with_full_params = 
      Array.map (fun f -> applist(f, List.rev_map var_of_decl full_params)) all_funs
    in
    let fix_offset = List.length princ_params in 
    let ptes_to_fix,infos = 
      match kind_of_term fbody_with_full_params with 
	| Fix((idxs,i),(names,typess,bodies)) -> 
	    let bodies_with_all_params = 
	      Array.map 
		(fun body -> 
		   Reductionops.nf_betaiota 
		     (applist(substl (List.rev (Array.to_list all_funs_with_full_params)) body,
			      List.rev_map var_of_decl princ_params))
		)
		bodies
	    in
	    let info_array = 
	      Array.mapi 
		(fun i types -> 
		   let types = prod_applist types (List.rev_map var_of_decl princ_params) in
		   { idx = idxs.(i)  - fix_offset;
		     name = Nameops.out_name (fresh_id names.(i));
		     types = types; 
		     offset = fix_offset;
		     nb_realargs = 
		       List.length 
			 (fst (decompose_lam bodies.(i))) - fix_offset;
		     body_with_param = bodies_with_all_params.(i);
		     num_in_block = i
		   }
		)
		typess
	    in
	    let pte_to_fix,rev_info = 
	      list_fold_left_i 
		(fun i (acc_map,acc_info) (pte,_,_) -> 
		   let infos = info_array.(i) in 
		   let type_args,_ = decompose_prod infos.types in 
		   let nargs = List.length type_args in 
		   let f = applist(mkConst fnames.(i), List.rev_map var_of_decl princ_info.params) in
		   let first_args = Array.init nargs (fun i -> mkRel (nargs -i)) in
		   let app_f = mkApp(f,first_args) in
		   let pte_args = (Array.to_list first_args)@[app_f] in 
		   let app_pte = applist(mkVar (Nameops.out_name pte),pte_args) in 
		   let body_with_param,num = 
		     let body = get_body fnames.(i) in 
		     let body_with_full_params = 
		       Reductionops.nf_betaiota (
			 applist(body,List.rev_map var_of_decl full_params))
		     in
		     match kind_of_term body_with_full_params with 
		       | Fix((_,num),(_,_,bs)) -> 
			       Reductionops.nf_betaiota
				 (
				   (applist
				      (substl 
					 (List.rev 
					    (Array.to_list all_funs_with_full_params)) 
					 bs.(num),
				       List.rev_map var_of_decl princ_params))
				 ),num
			 | _ -> error "Not a mutual block"
		   in
		   let info = 
		     {infos with 
			types = compose_prod type_args app_pte;
			 body_with_param = body_with_param;
			 num_in_block = num
		     }
		   in 
(* 		   observe (str "binding " ++ Ppconstr.pr_id (Nameops.out_name pte) ++  *)
(* 			      str " to " ++ Ppconstr.pr_id info.name); *)
		   (Idmap.add (Nameops.out_name pte) info acc_map,info::acc_info)
		   )
		0 
		(Idmap.empty,[]) 
		(List.rev princ_info.predicates)
	    in
	    pte_to_fix,List.rev rev_info
	| _ -> Idmap.empty,[]
    in
    let mk_fixes : tactic = 
      let pre_info,infos = list_chop fun_num infos in 
      match pre_info,infos with 
	| [],[] -> tclIDTAC
	| _, this_fix_info::others_infos -> 
	    let other_fix_infos =
	      List.map
		(fun fi -> fi.name,fi.idx + 1 ,fi.types) 
		(pre_info@others_infos)
	    in 
	    if other_fix_infos = [] 
	    then
	      observe_tac ("h_fix") (h_fix (Some this_fix_info.name) (this_fix_info.idx +1))
	    else
	      h_mutual_fix this_fix_info.name (this_fix_info.idx + 1)
		other_fix_infos
	| _ -> anomaly "Not a valid information"
    in
    let first_tac : tactic = (* every operations until fix creations *)
      tclTHENSEQ 
	[ observe_tac "introducing params" (intros_using (List.rev_map id_of_decl princ_info.params)); 
	  observe_tac "introducing predictes" (intros_using (List.rev_map id_of_decl princ_info.predicates)); 
	  observe_tac "introducing branches" (intros_using (List.rev_map id_of_decl princ_info.branches)); 
	  observe_tac "building fixes" mk_fixes;
	]
    in
    let intros_after_fixes : tactic = 
      fun gl -> 
	let ctxt,pte_app =  (Sign.decompose_prod_assum (pf_concl gl)) in
	let pte,pte_args = (decompose_app pte_app) in
	try
	  let pte = try destVar pte with _ -> anomaly "Property is not a variable"  in 
	  let fix_info = Idmap.find  pte ptes_to_fix in
	  let nb_args = fix_info.nb_realargs in 
	  tclTHENSEQ
	    [
	      observe_tac ("introducing args") (tclDO nb_args intro);
	      (fun g -> (* replacement of the function by its body *)
		 let args = nLastHyps nb_args g in 
		 let fix_body = fix_info.body_with_param in
(* 		 observe (str "fix_body := "++ pr_lconstr_env (pf_env gl) fix_body); *)
		 let args_id = List.map (fun (id,_,_) -> id) args in
		 let dyn_infos = 
		   {
		     nb_rec_hyps = -100;
		     rec_hyps = [];
		     info = 
		       Reductionops.nf_betaiota 
			 (applist(fix_body,List.rev_map mkVar args_id));
		     eq_hyps = []
		   }
		 in
		 tclTHENSEQ
		   [
		     observe_tac "do_replace" 
		       (do_replace 
			  full_params 
			  (fix_info.idx + List.length princ_params) 
			  (args_id@(List.map (fun (id,_,_) -> Nameops.out_name id ) princ_params))
			  (all_funs.(fix_info.num_in_block)) 
			  fix_info.num_in_block 
			  all_funs
		       );
(* 		     observe_tac "do_replace"  *)
(* 		       (do_replace princ_info.params fix_info.idx args_id *)
(* 			  (List.hd (List.rev pte_args)) fix_body); *)
		     let do_prove = 
		       build_proof 
			 interactive_proof
			 (Array.to_list fnames) 
			 (Idmap.map prove_rec_hyp ptes_to_fix)
		     in
		     let prove_tac branches  = 
		       let dyn_infos = 
			 {dyn_infos with 
			    rec_hyps = branches;
			    nb_rec_hyps = List.length branches
			 }
		       in
		       observe_tac "cleaning" (clean_goal_with_heq
			 (Idmap.map prove_rec_hyp ptes_to_fix) 
			 do_prove 
			 dyn_infos)
		     in
(* 		     observe (str "branches := " ++ *)
(* 				prlist_with_sep spc (fun decl -> Ppconstr.pr_id (id_of_decl decl)) princ_info.branches ++  fnl () ++ *)
(* 			   str "args := " ++ prlist_with_sep spc Ppconstr.pr_id  args_id *)
			   
(* 			   ); *)
		     observe_tac "instancing" (instanciate_hyps_with_args prove_tac 
		       (List.rev_map id_of_decl princ_info.branches) 
		       (List.rev args_id))
		   ]
		   g
	      );
	    ] gl
	with Not_found ->
	  let nb_args = min (princ_info.nargs) (List.length ctxt) in
	  tclTHENSEQ
	    [
	      tclDO nb_args intro;
	      (fun g -> (* replacement of the function by its body *)
		 let args = nLastHyps nb_args g in 
		 let args_id = List.map (fun (id,_,_) -> id) args in
		 let dyn_infos = 
		   {
		     nb_rec_hyps = -100;
		     rec_hyps = [];
		     info = 
		       Reductionops.nf_betaiota 
			 (applist(fbody_with_full_params,
				  (List.rev_map var_of_decl princ_params)@
				    (List.rev_map mkVar args_id)
				 ));
		     eq_hyps = []
		   }
		 in
		 let fname = destConst (fst (decompose_app (List.hd (List.rev pte_args)))) in
		 tclTHENSEQ
		   [unfold_in_concl [([],Names.EvalConstRef fname)];
		    let do_prove = 
		      build_proof 
			interactive_proof
			(Array.to_list fnames) 
			 (Idmap.map prove_rec_hyp ptes_to_fix)
		    in
		    let prove_tac branches  = 
		      let dyn_infos = 
			 {dyn_infos with 
			    rec_hyps = branches;
			    nb_rec_hyps = List.length branches
			 }
		      in
		       clean_goal_with_heq
			 (Idmap.map prove_rec_hyp ptes_to_fix) 
			 do_prove 
			 dyn_infos
		    in
		    instanciate_hyps_with_args prove_tac 
		       (List.rev_map id_of_decl princ_info.branches) 
		      (List.rev args_id)
		   ]
		   g
	      )
	    ] 
	  gl
    in
    tclTHEN 
      first_tac
      intros_after_fixes
      g
	    





(* Proof of principles of general functions *) 
let h_id = Recdef.h_id
and hrec_id = Recdef.hrec_id
and acc_inv_id = Recdef.acc_inv_id
and ltof_ref = Recdef.ltof_ref
and acc_rel = Recdef.acc_rel
and well_founded = Recdef.well_founded
and delayed_force = Recdef.delayed_force
and h_intros = Recdef.h_intros
and list_rewrite = Recdef.list_rewrite
and evaluable_of_global_reference = Recdef.evaluable_of_global_reference

let prove_with_tcc tcc_lemma_constr eqs : tactic =
  match !tcc_lemma_constr with
    | None -> anomaly "No tcc proof !!"
    | Some lemma ->
	fun gls ->
	  let hid = next_global_ident_away true h_id (pf_ids_of_hyps gls) in
	  tclTHENSEQ
	    [
	      generalize [lemma];
	      h_intro hid;
	      Elim.h_decompose_and (mkVar hid);
	      tclTRY(list_rewrite true eqs);
	      Eauto.gen_eauto false (false,5) [] (Some [])
	    ]
	    gls


let backtrack_eqs_until_hrec hrec eqs : tactic = 
  fun gls -> 
    let rewrite = 
      tclFIRST (List.map Equality.rewriteRL eqs )
    in 
    let _,hrec_concl  = decompose_prod (pf_type_of gls (mkVar hrec)) in 
    let f_app = array_last (snd (destApp hrec_concl)) in 
    let f =  (fst (destApp f_app)) in 
    let rec backtrack : tactic = 
      fun g -> 
	let f_app = array_last (snd (destApp (pf_concl g))) in 
	match kind_of_term f_app with 
	  | App(f',_) when eq_constr f' f -> tclIDTAC g
	  | _ -> tclTHEN rewrite backtrack g
    in
    backtrack gls

    
    
  

let new_prove_with_tcc is_mes acc_inv hrec tcc_lemma_constr eqs : tactic = 
  match !tcc_lemma_constr with 
    | None -> tclIDTAC_MESSAGE (str "No tcc proof !!")
    | Some lemma -> 
	fun gls ->
	  let hid = next_global_ident_away true Recdef.h_id (pf_ids_of_hyps gls) in 
	    (tclTHENSEQ 
	    [
	      generalize [lemma];
	      h_intro hid;
	      Elim.h_decompose_and (mkVar hid); 
	      backtrack_eqs_until_hrec hrec eqs;
	      tclCOMPLETE (tclTHENS  (* We must have exactly ONE subgoal !*)
		(apply (mkVar hrec))
		[ tclTHENSEQ 
		    [
			 thin [hrec];
			 apply (Lazy.force acc_inv);
			 (fun g -> 
			    if is_mes 
			    then 
			      unfold_in_concl [([], evaluable_of_global_reference (delayed_force ltof_ref))] g 
			    else tclIDTAC g
			 );
			 tclTRY(Recdef.list_rewrite true eqs);
			 observe_tac "finishing"  (tclCOMPLETE (Eauto.gen_eauto false (false,5) [] (Some [])))
		       ]
		]
			  )
	    ])
	    gls


let is_valid_hypothesis predicates_name =
  let predicates_name = List.fold_right Idset.add predicates_name Idset.empty in
  let is_pte typ =
    if isApp typ
    then
      let pte,_ = destApp typ in
      if isVar pte
      then Idset.mem (destVar pte) predicates_name
      else false
    else false
  in
  let rec is_valid_hypothesis typ =
    is_pte typ ||
      match kind_of_term typ with 
	| Prod(_,pte,typ') -> is_pte pte && is_valid_hypothesis typ'
	| _ -> false 
  in
  is_valid_hypothesis 

let fresh_id avoid na = 
  let id =  
    match na with 
      | Name id -> id 
      | Anonymous -> h_id 
  in 
  next_global_ident_away true id avoid


let prove_principle_for_gen
    (f_ref,functional_ref,eq_ref) tcc_lemma_ref is_mes
    rec_arg_num rec_arg_type relation = 
  fun g -> 
    let type_of_goal = pf_concl g in 
    let goal_ids = pf_ids_of_hyps g in 
    let goal_elim_infos = compute_elim_sig type_of_goal in 
    let params_names,ids = List.fold_left 
      (fun (params_names,avoid) (na,_,_) -> 
	 let new_id = fresh_id avoid na in 
	 (new_id::params_names,new_id::avoid)
      )
      ([],goal_ids)
      goal_elim_infos.params
    in
    let predicates_names,ids = 
      List.fold_left 
	(fun (predicates_names,avoid) (na,_,_) -> 
	   let new_id = fresh_id avoid na in 
	   (new_id::predicates_names,new_id::avoid)
	)
	([],ids)
	goal_elim_infos.predicates
    in
    let branches_names,ids = 
      List.fold_left 
	(fun (branches_names,avoid) (na,_,_) -> 
	   let new_id = fresh_id avoid na in 
	   (new_id::branches_names,new_id::avoid)
	)
	([],ids)
	goal_elim_infos.branches
    in
    let to_intro = params_names@predicates_names@branches_names in 
    let nparams = List.length params_names in 
    let rec_arg_num = rec_arg_num - nparams in 
    let tac_intro_static = h_intros to_intro in 
    let args_info = ref None in 
    let arg_tac g =  (* introducing args *)
      let ids = pf_ids_of_hyps g in 
      let func_body = def_of_const (mkConst functional_ref) in
      (* 	      let _ = Pp.msgnl (Printer.pr_lconstr func_body) in  *)
      let (f_name, _, body1) = destLambda func_body in
      let f_id =
	match f_name with
	  | Name f_id -> next_global_ident_away true f_id ids
	  | Anonymous -> anomaly "anonymous function"
      in
      let n_names_types,_ = decompose_lam body1 in 
      let n_ids,ids = 
	List.fold_left 
	  (fun (n_ids,ids) (n_name,_) -> 
	     match n_name with 
	       | Name id -> 
		   let n_id = next_global_ident_away true id ids in 
		   n_id::n_ids,n_id::ids
	       | _ -> anomaly "anonymous argument"
	  )
	  ([],(f_id::ids))
	  n_names_types
      in
      let rec_arg_id = List.nth n_ids (rec_arg_num - 1 ) in
      let args_ids = snd (list_chop nparams n_ids) in
      args_info := Some (ids,args_ids,rec_arg_id);
      h_intros args_ids g
    in
    let wf_tac = 
      if is_mes 
      then 
	Recdef.tclUSER_if_not_mes 
      else fun _ -> prove_with_tcc tcc_lemma_ref []
    in
    let start_tac g = 
      let ids,args_ids,rec_arg_id = out_some !args_info in
      let nargs = List.length args_ids in 
      let pre_rec_arg = 
	List.rev_map 
	  mkVar 
	  (fst (list_chop (rec_arg_num - 1) args_ids))
      in
      let args_before_rec = pre_rec_arg@(List.map mkVar params_names) in
      let relation = substl args_before_rec relation in 
      let input_type = substl args_before_rec rec_arg_type in 
      let wf_thm = next_global_ident_away true (id_of_string ("wf_R")) ids in 
      let wf_rec_arg = 
	next_global_ident_away true 
	  (id_of_string ("Acc_"^(string_of_id rec_arg_id)))
	  (wf_thm::ids) 
      in 
      let hrec = next_global_ident_away true hrec_id (wf_rec_arg::wf_thm::ids) in 
      let acc_inv = 
	lazy (
	  mkApp (
	    delayed_force acc_inv_id,
	    [|input_type;relation;mkVar rec_arg_id|]
	  )
	)
      in
      (tclTHENS
	   (observe_tac 
	      "first assert" 
	      (assert_tac 
		 true (* the assert thm is in first subgoal *)
		 (Name wf_rec_arg) 
		 (mkApp (delayed_force acc_rel,
			 [|input_type;relation;mkVar rec_arg_id|])
		 )
	      )
	   )
	   [
	     (* accesibility proof *) 
	     tclTHENS 
	       (observe_tac 
		  "second assert" 
		  (assert_tac 
		     true 
		     (Name wf_thm)
		     (mkApp (delayed_force well_founded,[|input_type;relation|]))
		  )
	       )
	       [ 
		 (* interactive proof of the well_foundness of the relation *) 
		 wf_tac is_mes;
		 (* well_foundness -> Acc for any element *)
		 observe_tac 
		   "apply wf_thm" 
		   (h_apply ((mkApp(mkVar wf_thm,
				    [|mkVar rec_arg_id |])),Rawterm.NoBindings)
		   )
	       ]
	     ;
	     (* rest of the proof *)
	     tclTHENSEQ
	       [
		 observe_tac "generalize" (fun g -> 
		    let to_thin = 
		      fst (list_chop ( nargs + 1) (pf_ids_of_hyps g))
		    in
		    let to_thin_c = List.rev_map mkVar to_thin in 
		    tclTHEN (generalize to_thin_c) (observe_tac "thin" (h_clear false to_thin)) g
		 );
		 observe_tac "h_fix" (h_fix (Some hrec) (nargs+1));
		h_intros args_ids;
		h_intro wf_rec_arg;
		Equality.rewriteLR (mkConst eq_ref);
		(fun g' -> 
		   let body = 
		     let _,args = destApp (pf_concl g') in 
		     array_last args
		   in
		   let body_info rec_hyps = 
		     {
		       nb_rec_hyps = List.length rec_hyps;
		       rec_hyps = rec_hyps;
		       eq_hyps = [];
		       info = body
		     }
		   in 
		   let acc_inv = lazy (mkApp(Lazy.force acc_inv, [|mkVar  wf_rec_arg|]) )  in
		   let pte_info = 
		     { proving_tac =
			 (fun eqs -> 
			    observe_tac "prove_with_tcc" 
			      (new_prove_with_tcc is_mes acc_inv hrec  tcc_lemma_ref (List.map mkVar eqs))
			 );
		       is_valid = is_valid_hypothesis predicates_names 
		     }
		   in
		   let ptes_info : pte_info Idmap.t = 
		     List.fold_left
		       (fun map pte_id -> 
			  Idmap.add pte_id 
			    pte_info			       
			    map
		       )
		       Idmap.empty
		       predicates_names
		   in
		   let make_proof rec_hyps = 
		     build_proof 
		       false 
		       [f_ref]
		       ptes_info
		       (body_info rec_hyps)
		   in
		   instanciate_hyps_with_args 
		     make_proof
		     branches_names
		     args_ids
		     g'
		     
		) 
	       ]
	   ]
	   g
      )
      in
      tclTHENSEQ 
	[tac_intro_static;
	 arg_tac;
	 start_tac
	] g















