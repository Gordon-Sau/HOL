(* Copyright (c) 2009-2011 Tjark Weber. All rights reserved. *)

(* Proof reconstruction for Z3: replaying Z3's proofs in HOL *)

structure Z3_ProofReplay =
struct

local

  open boolLib
  fun profile name f x =
    Profile.profile_with_exn_name name f x

  open Z3_Proof

  val ERR = Feedback.mk_HOL_ERR "Z3_ProofReplay"
  val WARNING = Feedback.HOL_WARNING "Z3_ProofReplay"

  val ALL_DISTINCT_NIL = HolSmtTheory.ALL_DISTINCT_NIL
  val ALL_DISTINCT_CONS = HolSmtTheory.ALL_DISTINCT_CONS
  val NOT_MEM_NIL = HolSmtTheory.NOT_MEM_NIL
  val NOT_MEM_CONS = HolSmtTheory.NOT_MEM_CONS
  val AND_T = HolSmtTheory.AND_T
  val T_AND = HolSmtTheory.T_AND
  val F_OR = HolSmtTheory.F_OR
  val CONJ_CONG = HolSmtTheory.CONJ_CONG
  val NOT_NOT_ELIM = HolSmtTheory.NOT_NOT_ELIM
  val NOT_FALSE = HolSmtTheory.NOT_FALSE
  val NNF_CONJ = HolSmtTheory.NNF_CONJ
  val NNF_DISJ = HolSmtTheory.NNF_DISJ
  val NNF_NOT_NOT = HolSmtTheory.NNF_NOT_NOT
  val NEG_IFF_1_1 = HolSmtTheory.NEG_IFF_1_1
  val NEG_IFF_1_2 = HolSmtTheory.NEG_IFF_1_2
  val NEG_IFF_2_1 = HolSmtTheory.NEG_IFF_2_1
  val NEG_IFF_2_2 = HolSmtTheory.NEG_IFF_2_2
  val DISJ_ELIM_1 = HolSmtTheory.DISJ_ELIM_1
  val DISJ_ELIM_2 = HolSmtTheory.DISJ_ELIM_2
  val IMP_DISJ_1 = HolSmtTheory.IMP_DISJ_1
  val IMP_DISJ_2 = HolSmtTheory.IMP_DISJ_2
  val IMP_FALSE = HolSmtTheory.IMP_FALSE
  val AND_IMP_INTRO_SYM = HolSmtTheory.AND_IMP_INTRO_SYM
  val VALID_IFF_TRUE = HolSmtTheory.VALID_IFF_TRUE

  (* a simplification prover that deals with function (i.e., array)
     updates when the indices are integer or word literals *)
  val SIMP_PROVE_UPDATE = simpLib.SIMP_PROVE (simpLib.&& (simpLib.++
    (intSimps.int_ss, simpLib.std_conv_ss {name = "word_EQ_CONV",
      pats = [``(x :'a word) = y``], conv = wordsLib.word_EQ_CONV}),
    [combinTheory.UPDATE_def, boolTheory.EQ_SYM_EQ])) []

  (***************************************************************************)
  (* functions that manipulate/access "global" state                         *)
  (***************************************************************************)

  type state = {
    (* keeps track of assumptions; (only) these may remain in the
       final theorem *)
    asserted_hyps : Term.term HOLset.set,
    (* keeps track of definitions introduced by Z3; these get added during the
       proof and are deleted at the end, just before returning the final theorem.
       all of them should be of the form: ``name = term`` *)
    definition_hyps : Term.term HOLset.set,
    (* stores certain theorems (proved by 'rewrite' or 'th_lemma') for
       later retrieval, to avoid re-reproving them *)
    thm_cache : Thm.thm Net.net,
    (* contains all of the variables that Z3 has defined *)
    var_set : Term.term HOLset.set
  }

  fun state_assert (s : state) (t : Term.term) : state =
    {
      asserted_hyps = HOLset.add (#asserted_hyps s, t),
      definition_hyps = #definition_hyps s,
      thm_cache = #thm_cache s,
      var_set = #var_set s
    }

  fun state_define (s : state) (terms : Term.term list) : state =
    {
      asserted_hyps = #asserted_hyps s,
      definition_hyps = HOLset.addList (#definition_hyps s, terms),
      thm_cache = #thm_cache s,
      var_set = #var_set s
    }

  fun state_cache_thm (s : state) (thm : Thm.thm) : state =
    {
      asserted_hyps = #asserted_hyps s,
      definition_hyps = #definition_hyps s,
      thm_cache = Net.insert (Thm.concl thm, thm) (#thm_cache s),
      var_set = #var_set s
    }

  fun state_inst_cached_thm (s : state) (t : Term.term) : Thm.thm =
    Lib.tryfind  (* may fail *)
      (fn thm => Drule.INST_TY_TERM (Term.match_term (Thm.concl thm) t) thm)
      (Net.match t (#thm_cache s))

  (***************************************************************************)
  (* auxiliary functions                                                     *)
  (***************************************************************************)

  (* |- l1 \/ l2 \/ ... \/ ln \/ t   |- ~l1   |- ~l2   |- ...   |- ~ln
     -----------------------------------------------------------------
                                  |- t

     The input clause (including "t") is really treated as a set of
     literals: the resolvents need not be in the correct order, "t"
     need not be the rightmost disjunct (and if "t" is a disjunction,
     its disjuncts may even be spread throughout the input clause).
     Note also that "t" may be F, in which case it need not be present
     in the input clause.

     We treat all "~li" as atomic, even if they are negated
     disjunctions. *)
  fun unit_resolution (thms, t) =
  let
    val _ = if List.null thms then
        raise ERR "unit_resolution" ""
      else ()
    fun disjuncts dict (disj, thm) =
    let
      val (l, r) = boolSyntax.dest_disj disj
      (* |- l \/ r ==> ... *)
      val thm = Thm.DISCH disj thm
      val l_imp_concl = Thm.MP thm (Thm.DISJ1 (Thm.ASSUME l) r)
      val r_imp_concl = Thm.MP thm (Thm.DISJ2 l (Thm.ASSUME r))
    in
      disjuncts (disjuncts dict (l, l_imp_concl)) (r, r_imp_concl)
    end
    handle Feedback.HOL_ERR _ =>
      Redblackmap.insert (dict, disj, thm)
    fun prove_from_disj dict disj =
      Redblackmap.find (dict, disj)
      handle Redblackmap.NotFound =>
        let
          val (l, r) = boolSyntax.dest_disj disj
          val l_th = prove_from_disj dict l
          val r_th = prove_from_disj dict r
        in
          Thm.DISJ_CASES (Thm.ASSUME disj) l_th r_th
        end
    val dict = disjuncts (Redblackmap.mkDict Term.compare) (t, Thm.ASSUME t)
    (* derive 't' from each negated resolvent *)
    val dict = List.foldl (fn (th, dict) =>
      let
        val lit = Thm.concl th
        val (is_neg, neg_lit) = (true, boolSyntax.dest_neg lit)
          handle Feedback.HOL_ERR _ =>
            (false, boolSyntax.mk_neg lit)
        (* |- neg_lit ==> F *)
        val th = if is_neg then
            Thm.NOT_ELIM th
          else
            Thm.MP (Thm.SPEC lit NOT_FALSE) th
        (* neg_lit |- t *)
        val th = Thm.CCONTR t (Thm.MP th (Thm.ASSUME neg_lit))
      in
        Redblackmap.insert (dict, neg_lit, th)
      end) dict (List.tl thms)
    (* derive 't' from ``F`` (just in case ``F`` is a disjunct) *)
    val dict = Redblackmap.insert
      (dict, boolSyntax.F, Thm.CCONTR t (Thm.ASSUME boolSyntax.F))
    val clause = Thm.concl (List.hd thms)
    val clause_imp_t = prove_from_disj dict clause
  in
    Thm.MP (Thm.DISCH clause clause_imp_t) (List.hd thms)
  end

  (* e.g.,   "(A --> B) --> C --> D" acc   ==>   [A, B, C, D] @ acc *)
  fun strip_fun_tys ty acc =
    let
      val (dom, rng) = Type.dom_rng ty
    in
      strip_fun_tys dom (strip_fun_tys rng acc)
    end
    handle Feedback.HOL_ERR _ => ty :: acc

  (* approximate: only descends into combination terms and function types *)
  fun term_contains_real_ty tm =
    let val (rator, rand) = Term.dest_comb tm
    in
      term_contains_real_ty rator orelse term_contains_real_ty rand
    end
    handle Feedback.HOL_ERR _ =>
      List.exists (Lib.equal realSyntax.real_ty)
        (strip_fun_tys (Term.type_of tm) [])

  (* returns "|- l = r", provided 'l' and 'r' are conjunctions that can be
     obtained from each other using associativity, commutativity and
     idempotence of conjunction, and identity of "T" wrt. conjunction.

     If 'r' is "F", 'l' must either contain "F" as a conjunct, or 'l'
     must contain both a literal and its negation. *)
  fun rewrite_conj (l, r) =
    let
      val Tl = boolSyntax.mk_conj (boolSyntax.T, l)
      val Tr = boolSyntax.mk_conj (boolSyntax.T, r)
      val Tl_eq_Tr = Drule.CONJUNCTS_AC (Tl, Tr)
    in
      Thm.MP (Drule.SPECL [l, r] T_AND) Tl_eq_Tr
    end
    handle Feedback.HOL_ERR _ =>
      if Feq r then
        let
          val l_imp_F = Thm.DISCH l (Library.gen_contradiction (Thm.ASSUME l))
        in
          Drule.EQF_INTRO (Thm.NOT_INTRO l_imp_F)
        end
      else
        raise ERR "rewrite_conj" ""

  (* returns "|- l = r", provided 'l' and 'r' are disjunctions that can be
     obtained from each other using associativity, commutativity and
     idempotence of disjunction, and identity of "F" wrt. disjunction.

     If 'r' is "T", 'l' must contain "T" as a disjunct, or 'l' must contain
     both a literal and its negation. *)
  fun rewrite_disj (l, r) =
    let
      val Fl = boolSyntax.mk_disj (boolSyntax.F, l)
      val Fr = boolSyntax.mk_disj (boolSyntax.F, r)
      val Fl_eq_Fr = Drule.DISJUNCTS_AC (Fl, Fr)
    in
      Thm.MP (Drule.SPECL [l, r] F_OR) Fl_eq_Fr
    end
    handle Feedback.HOL_ERR _ =>
      if Teq r then
        Drule.EQT_INTRO (Library.gen_excluded_middle l)
      else
        raise ERR "rewrite_disj" ""

  (* |- r1 /\ ... /\ rn = ~(s1 \/ ... \/ sn)

     Note that q <=> p may be negated to p <=> ~q.  Also, p <=> ~q may
     be negated to p <=> q. *)
  fun rewrite_nnf (l, r) =
  let
    val disj = boolSyntax.dest_neg r
    val conj_ths = Drule.CONJUNCTS (Thm.ASSUME l)
    (* transform equivalences in 'l' into equivalences as they appear
       in 'disj' *)
    val conj_dict = List.foldl (fn (th, dict) => Redblackmap.insert
      (dict, Thm.concl th, th)) (Redblackmap.mkDict Term.compare) conj_ths
    (* we map over equivalences in 'disj', possibly obtaining the
       negation of each one by forward reasoning from a suitable
       theorem in 'conj_dict' *)
    val iff_ths = List.mapPartial (Lib.total (fn t =>
      let
        val (p, q) = boolSyntax.dest_eq t  (* may fail *)
        val neg_q = boolSyntax.mk_neg q  (* may fail (because of type) *)
      in
        let
          val th = Redblackmap.find (conj_dict, boolSyntax.mk_eq (p, neg_q))
        in
          (* l |- ~(p <=> q) *)
          Thm.MP (Drule.SPECL [p, q] NEG_IFF_2_1) th
        end
        handle Redblackmap.NotFound =>
          let
            val q = boolSyntax.dest_neg q  (* may fail *)
            val th = Redblackmap.find (conj_dict, boolSyntax.mk_eq (q, p))
          in
            (* l |- ~(p <=> ~q) *)
            Thm.MP (Drule.SPECL [p, q] NEG_IFF_1_1) th
          end
      end)) (boolSyntax.strip_disj disj)
    (* [l, disj] |- F *)
    val F_th = unit_resolution (Thm.ASSUME disj :: conj_ths @ iff_ths,
      boolSyntax.F)
    fun disjuncts dict (thmfun, concl) =
    let
      val (l, r) = boolSyntax.dest_disj concl  (* may fail *)
    in
      disjuncts (disjuncts dict (fn th => thmfun (Thm.DISJ1 th r), l))
        (fn th => thmfun (Thm.DISJ2 l th), r)
    end
    handle Feedback.HOL_ERR _ =>  (* 'concl' is not a disjunction *)
      let
        (* |- concl ==> disjunction *)
        val th = Thm.DISCH concl (thmfun (Thm.ASSUME concl))
        (* ~disjunction |- ~concl *)
        val th = Drule.UNDISCH (Drule.CONTRAPOS th)
        val th = Thm.MP (Thm.SPEC (boolSyntax.dest_neg concl) NOT_NOT_ELIM) th
          handle Feedback.HOL_ERR _ => th
        val t = Thm.concl th
        val dict = Redblackmap.insert (dict, t, th)
      in
        (* if 't' is a negated equivalence, we check whether it can be
           transformed into an equivalence that is present in 'l' *)
        let
          val (p, q) = boolSyntax.dest_eq (boolSyntax.dest_neg t) (* may fail *)
          val neg_q = boolSyntax.mk_neg q  (* may fail (because of type) *)
        in
          let
            val _ = Redblackmap.find (conj_dict, boolSyntax.mk_eq (p, neg_q))
            (* ~disjunction |- p <=> ~q *)
            val th1 = Thm.MP (Drule.SPECL [p, q] NEG_IFF_2_2) th
            val dict = Redblackmap.insert (dict, Thm.concl th1, th1)
          in
            let
              val q = boolSyntax.dest_neg q  (* may fail *)
              val _ = Redblackmap.find (conj_dict, boolSyntax.mk_eq (q, p))
              (* ~disjunction |- q <=> p *)
              val th1 = Thm.MP (Drule.SPECL [p, q] NEG_IFF_1_2) th
            in
              Redblackmap.insert (dict, Thm.concl th1, th1)
            end
            handle Redblackmap.NotFound => dict
                 | Feedback.HOL_ERR _ => dict
          end
          handle Redblackmap.NotFound =>
            (* p <=> ~q is not a conjunction in 'l', so we skip
               deriving it; but we possibly still need to derive
               q <=> p *)
            let
              val q = boolSyntax.dest_neg q  (* may fail *)
              val _ = Redblackmap.find (conj_dict, boolSyntax.mk_eq (q, p))
              (* ~disjunction |- q <=> p *)
              val th1 = Thm.MP (Drule.SPECL [p, q] NEG_IFF_1_2) th
            in
              Redblackmap.insert (dict, Thm.concl th1, th1)
            end
            handle Redblackmap.NotFound => dict
                 | Feedback.HOL_ERR _ => dict
        end
        handle Feedback.HOL_ERR _ =>  (* 't' is not an equivalence *)
          dict
      end  (* disjuncts *)
    val dict = disjuncts (Redblackmap.mkDict Term.compare) (Lib.I, disj)
    (* derive ``T`` (just in case ``T`` is a conjunct) *)
    val dict = Redblackmap.insert (dict, boolSyntax.T, boolTheory.TRUTH)
    (* proves a conjunction 'conj', provided each conjunct is proved
      in 'dict' *)
    fun prove_conj dict conj =
      Redblackmap.find (dict, conj)
      handle Redblackmap.NotFound =>
        let
          val (l, r) = boolSyntax.dest_conj conj
        in
          Thm.CONJ (prove_conj dict l) (prove_conj dict r)
        end
    val r_imp_l = Thm.DISCH r (prove_conj dict l)
    val l_imp_r = Thm.DISCH l (Thm.NOT_INTRO (Thm.DISCH disj F_th))
  in
    Drule.IMP_ANTISYM_RULE l_imp_r r_imp_l
  end

  (* returns |- ~MEM x [a; b; c] = x <> a /\ x <> b /\ x <> c; fails
     if not applied to a term of the form ``~MEM x [a; b; c]`` *)
  fun NOT_MEM_CONV tm =
  let
    val (x, list) = listSyntax.dest_mem (boolSyntax.dest_neg tm)
  in
    let
      val (h, t) = listSyntax.dest_cons list
      (* |- ~MEM x (h::t) = (x <> h) /\ ~MEM x t *)
      val th1 = Drule.ISPECL [x, h, t] NOT_MEM_CONS
      val (neq, notmem) = boolSyntax.dest_conj (boolSyntax.rhs
        (Thm.concl th1))
      (* |- ~MEM x t = rhs *)
      val th2 = NOT_MEM_CONV notmem
      (* |- (x <> h) /\ ~MEM x t = (x <> h) /\ rhs *)
      val th3 = Thm.AP_TERM (Term.mk_comb (boolSyntax.conjunction, neq)) th2
      (* |- ~MEM x (h::t) = (x <> h) /\ rhs *)
      val th4 = Thm.TRANS th1 th3
    in
      if Teq (boolSyntax.rhs (Thm.concl th2)) then
        Thm.TRANS th4 (Thm.SPEC neq AND_T)
      else
        th4
    end
    handle Feedback.HOL_ERR _ =>  (* 'list' is not a cons *)
      if listSyntax.is_nil list then
        (* |- ~MEM x [] = T *)
        Drule.ISPEC x NOT_MEM_NIL
      else
        raise ERR "NOT_MEM_CONV" ""
  end

  (* returns "|- ALL_DISTINCT [x; y; z] = (x <> y /\ x <> z) /\ y <>
     z" (note the parentheses); fails if not applied to a term of the
     form ``ALL_DISTINCT [x; y; z]`` *)
  fun ALL_DISTINCT_CONV tm =
  let
    val list = listSyntax.dest_all_distinct tm
  in
    let
      val (h, t) = listSyntax.dest_cons list
      (* |- ALL_DISTINCT (h::t) = ~MEM h t /\ ALL_DISTINCT t *)
      val th1 = Drule.ISPECL [h, t] ALL_DISTINCT_CONS
      val (notmem, alldistinct) = boolSyntax.dest_conj
        (boolSyntax.rhs (Thm.concl th1))
      (* |- ~MEM h t = something *)
      val th2 = NOT_MEM_CONV notmem
      val something = boolSyntax.rhs (Thm.concl th2)
      (* |- ALL_DISTINCT t = rhs *)
      val th3 = ALL_DISTINCT_CONV alldistinct
      val rhs = boolSyntax.rhs (Thm.concl th3)
      val th4 = Drule.SPECL [notmem, something, alldistinct, rhs] CONJ_CONG
      (* |- ~MEM h t /\ ALL_DISTINCT t = something /\ rhs *)
      val th5 = Thm.MP (Thm.MP th4 th2) th3
      (* |- ALL_DISTINCT (h::t) = something /\ rhs *)
      val th6 = Thm.TRANS th1 th5
    in
      if Teq rhs then Thm.TRANS th6 (Thm.SPEC something AND_T)
      else th6
    end
    handle Feedback.HOL_ERR _ =>  (* 'list' is not a cons *)
      (* |- ALL_DISTINCT [] = T *)
      Thm.INST_TYPE [{redex = Type.alpha, residue = listSyntax.dest_nil list}]
        ALL_DISTINCT_NIL
  end

  (* returns |- (x = y) = (y = x), provided ``y = x`` is LESS than ``x
     = y`` wrt. Term.compare; fails if applied to a term that is not
     an equation; may raise Conv.UNCHANGED *)
  fun REORIENT_SYM_CONV tm =
  let
    val tm' = boolSyntax.mk_eq (Lib.swap (boolSyntax.dest_eq tm))
  in
    if Term.compare (tm', tm) = LESS then
      Conv.SYM_CONV tm
    else
      raise Conv.UNCHANGED
  end

  (* returns |- ALL_DISTINCT ... /\ T = ... *)
  fun rewrite_all_distinct (l, r) =
  let
    fun ALL_DISTINCT_AND_T_CONV t =
      ALL_DISTINCT_CONV t
        handle Feedback.HOL_ERR _ =>
          let
            val all_distinct = Lib.fst (boolSyntax.dest_conj t)
            val all_distinct_th = ALL_DISTINCT_CONV all_distinct
          in
            Thm.TRANS (Thm.SPEC all_distinct AND_T) all_distinct_th
          end
    val REORIENT_CONV = Conv.ONCE_DEPTH_CONV REORIENT_SYM_CONV
    (* since ALL_DISTINCT may be present in both 'l' and 'r', we
       normalize both 'l' and 'r' *)
    val l_eq_l' = Conv.THENC (ALL_DISTINCT_AND_T_CONV, REORIENT_CONV) l
    val r_eq_r' = Conv.THENC (fn t => ALL_DISTINCT_AND_T_CONV t
      handle Feedback.HOL_ERR _ => raise Conv.UNCHANGED, REORIENT_CONV) r
      handle Conv.UNCHANGED => Thm.REFL r
    (* get rid of parentheses *)
    val l'_eq_r' = Drule.CONJUNCTS_AC (boolSyntax.rhs (Thm.concl l_eq_l'),
      boolSyntax.rhs (Thm.concl r_eq_r'))
  in
    Thm.TRANS (Thm.TRANS l_eq_l' l'_eq_r') (Thm.SYM r_eq_r')
  end

  (* replaces distinct if-then-else terms by distinct variables;
     returns the generalized term and a map from ite-subterms to
     variables (treating anything but combinations as atomic, i.e.,
     this function does NOT descend into lambda-abstractions) *)
  fun generalize_ite t =
  let
    fun aux (dict, t) =
      if boolSyntax.is_cond t then (
        case Redblackmap.peek (dict, t) of
          SOME var =>
          (dict, var)
        | NONE =>
          let
            val var = Term.genvar (Term.type_of t)
          in
            (Redblackmap.insert (dict, t, var), var)
          end
      ) else (
        let
          val (l, r) = Term.dest_comb t
          val (dict, l) = aux (dict, l)
          val (dict, r) = aux (dict, r)
        in
          (dict, Term.mk_comb (l, r))
        end
        handle Feedback.HOL_ERR _ =>
          (* 't' is not a combination *)
          (dict, t)
      )
  in
    aux (Redblackmap.mkDict Term.compare, t)
  end

  (* Returns a proof of `t` given a list of theorems as inputs. It relies on
     `metisLib.METIS_TAC` to find a proof. The returned theorem will have as
     hypotheses all the hypotheses of all the input theorems. *)
  fun metis_prove (thms, t) =
  let
    (* Gather all the hypotheses of all theorems together into a set of
       assumptions *)
    fun join_fn (thm, asm_set) = HOLset.union (asm_set, Thm.hypset thm)
    val asms = List.foldl join_fn Term.empty_tmset thms
  in
    Tactical.TAC_PROOF ((HOLset.listItems asms, t), metisLib.METIS_TAC thms)
  end

  (***************************************************************************)
  (* implementation of Z3's inference rules                                  *)
  (***************************************************************************)

  (* The Z3 documentation is rather outdated (as of version 2.11) and
     imprecise with respect to the semantics of Z3's inference rules.
     Ultimately, the most reliable way to determine the semantics is
     by observation: I applied Z3 to a large collection of SMT-LIB
     benchmarks, and from the resulting proofs I inferred what each
     inference rule does.  Therefore the implementation below may not
     cover rare corner cases that were not exercised by any benchmark
     in the collection. *)

  fun z3_and_elim (state, thm, t) =
    (state, Library.conj_elim (thm, t))

  fun z3_asserted (state, t) =
    (state_assert state t, Thm.ASSUME t)

  fun z3_commutativity (state, t) =
  let
    val (x, y) = boolSyntax.dest_eq (boolSyntax.lhs t)
  in
    (state, Drule.ISPECL [x, y] boolTheory.EQ_SYM_EQ)
  end

  (* Instances of Tseitin-style propositional tautologies:
     (or (not (and p q)) p)
     (or (not (and p q)) q)
     (or (and p q) (not p) (not q))
     (or (not (or p q)) p q)
     (or (or p q) (not p))
     (or (or p q) (not q))
     (or (not (iff p q)) (not p) q)
     (or (not (iff p q)) p (not q))
     (or (iff p q) (not p) (not q))
     (or (iff p q) p q)
     (or (not (ite a b c)) (not a) b)
     (or (not (ite a b c)) a c)
     (or (ite a b c) (not a) (not b))
     (or (ite a b c) a (not c))
     (or (not (not a)) (not a))
     (or (not a) a)

     Also
     (or p (= x (ite p y x)))

     Also
     ~ALL_DISTINCT [x; y; z] \/ (x <> y /\ x <> z /\ y <> z)
     ~(ALL_DISTINCT [x; y; z] /\ T) \/ (x <> y /\ x <> z /\ y <> z)

     There is a complication: 't' may contain arbitarily many
     irrelevant (nested) conjuncts/disjuncts, i.e.,
     conjunction/disjunction in the above tautologies can be of
     arbitrary arity.

     For the most part, 'z3_def_axiom' could be implemented by a
     single call to TAUT_PROVE.  The (partly less general)
     implementation below, however, is considerably faster.
  *)
  fun z3_def_axiom (state, t) =
    (state, Z3_ProformaThms.prove Z3_ProformaThms.def_axiom_thms t)
    handle Feedback.HOL_ERR _ =>
    (* or (or ... p ...) (not p) *)
    (* or (or ... (not p) ...) p *)
    (state, Library.gen_excluded_middle t)
    handle Feedback.HOL_ERR _ =>
    (* (or (not (and ... p ...)) p) *)
    let
      val (lhs, rhs) = boolSyntax.dest_disj t
      val conj = boolSyntax.dest_neg lhs
      (* conj |- rhs *)
      val thm = Library.conj_elim (Thm.ASSUME conj, rhs)  (* may fail *)
    in
      (* |- lhs \/ rhs *)
      (state, Drule.IMP_ELIM (Thm.DISCH conj thm))
    end
    handle Feedback.HOL_ERR _ =>
    (* ~ALL_DISTINCT [x; y; z] \/ x <> y /\ x <> z /\ y <> z *)
    (* ~(ALL_DISTINCT [x; y; z] /\ T) \/ x <> y /\ x <> z /\ y <> z *)
    let
      val (l, r) = boolSyntax.dest_disj t
      val all_distinct = boolSyntax.dest_neg l
      val all_distinct_th = ALL_DISTINCT_CONV all_distinct
        handle Feedback.HOL_ERR _ =>
          let
            val all_distinct = Lib.fst (boolSyntax.dest_conj all_distinct)
            val all_distinct_th = ALL_DISTINCT_CONV all_distinct
          in
            Thm.TRANS (Thm.SPEC all_distinct AND_T) all_distinct_th
          end
      (* get rid of parentheses *)
      val l_eq_r = Thm.TRANS all_distinct_th (Drule.CONJUNCTS_AC
        (boolSyntax.rhs (Thm.concl all_distinct_th), r))
    in
      (state, Drule.IMP_ELIM (Lib.fst (Thm.EQ_IMP_RULE l_eq_r)))
    end

  (* (!x. ?y. !z. P) = P *)
  fun z3_elim_unused (state, t) =
  let
    val (lhs, rhs) = boolSyntax.dest_eq t
    fun get_forall_thms term : term * thm * thm =
    let
      val (var, body) = boolSyntax.dest_forall term
      val th1 = Thm.DISCH term (Thm.SPEC var (Thm.ASSUME term))
      val th2 = Thm.DISCH body (Thm.GEN var (Thm.ASSUME body))
    in
      (body, th1, th2)
    end
    fun get_exists_thms term : term * thm * thm =
    let
      val (var, body) = boolSyntax.dest_exists term
      val th1 = Thm.DISCH term (Thm.CHOOSE (var, Thm.ASSUME term)
        (Thm.ASSUME body))
      val th2 = Thm.DISCH body (Thm.EXISTS (term, var) (Thm.ASSUME body))
    in
      (body, th1, th2)
    end
    fun strip_some_quants term =
    let
      val (body, th1, th2) =
        if boolSyntax.is_forall term then
          get_forall_thms term
        else
          get_exists_thms term
      val strip_th = Drule.IMP_ANTISYM_RULE th1 th2
    in
      if body ~~ rhs then
        strip_th  (* stripped enough quantifiers *)
      else
        Thm.TRANS strip_th (strip_some_quants body)
      end
  in
    (state, strip_some_quants lhs)
  end

  (* introduces a local hypothesis (which must be discharged by
     'z3_lemma' at some later point in the proof) *)
  fun z3_hypothesis (state, t) =
    (state, Thm.ASSUME t)

  (*   ... |- p
     ------------
     ... |- p = T *)
  fun z3_iff_true (state, thm, _) =
    (state, Thm.MP (Thm.SPEC (Thm.concl thm) VALID_IFF_TRUE) thm)

  (* `intro-def` introduces a name for a term.

     `t` will be in one of the following schematic forms:

     1. name = term

     2. ~name \/ term

     3. (name \/ ~term) /\ (~name \/ term)

     ... or, when the term is of the form `if cond then t1 else t2`:

     4. (~cond \/ (name = t1)) /\ (cond \/ (name = t2))

     We then instantiate the following theorem:

     name = term |- t

     The introduced assumption is added to a set of hypotheses (i.e. the set
     of introduced definitions) stored in `state`. Since the variable names
     used in these definitions are local names introduced by Z3 for the
     purposes of completing the proof and should not otherwise be relevant in
     either the remaining hypotheses or the conclusion of the final theorem,
     we can remove all such definitions at the end of the proof.

     We must take an additional precaution: if `term` is a Z3-defined variable
     and it is "smaller" than `name`, then we must actually return the theorem:

     term = name |- t

     This is done to avoid ending up with circular definitions in the final
     theorem. *)

  fun z3_intro_def (state, t) =
  let
    val thm = List.hd (Net.match t Z3_ProformaThms.intro_def_thms)
    val substs = Term.match_term (Thm.concl thm) t
    val term_substs = Lib.fst substs
    (* Check if the hypothesis should be changed from `name = term` to
       `term = name`. Note that `name` and `term` are actually called `n` and
       `t` in `intro_def_thms`, except for the 4th schematic form which doesn't
       have `t` (nor does it need to be oriented). *)
    fun is_varname s tm = Lib.fst (Term.dest_var tm) = s
    val name = Option.valOf (Lib.subst_assoc (is_varname "n") term_substs)
    val term_opt = Lib.subst_assoc (is_varname "t") term_substs
    val is_oriented =
      case term_opt of
        NONE => true (* `term_opt` will be NONE in the 4th schematic form *)
      | SOME term => Library.is_def_oriented (#var_set state) (name, term)
    (* Orient the hypothesis if necessary *)
    val thm = if is_oriented then thm else
      Conv.HYP_CONV_RULE (fn _ => true) Conv.SYM_CONV thm
    val inst_thm = Drule.INST_TY_TERM substs thm
    val asl = Thm.hyp inst_thm
  in
    (state_define state asl, inst_thm)
  end

  (*  [l1, ..., ln] |- F
     --------------------
     |- ~l1 \/ ... \/ ~ln

     'z3_lemma' could be implemented (essentially) by a single call to
     'TAUT_PROVE'.  The (less general) implementation below, however,
     is considerably faster. *)
  fun z3_lemma (state, thm, t) =
  let
    fun prove_literal maybe_no_hyp (th, lit) =
    let
      val (is_neg, neg_lit) = (true, boolSyntax.dest_neg lit)
        handle Feedback.HOL_ERR _ => (false, boolSyntax.mk_neg lit)
    in
      if maybe_no_hyp orelse HOLset.member (Thm.hypset th, neg_lit) then
        let
          val concl = Thm.concl th
          val th1 = Thm.DISCH neg_lit th
        in
          if is_neg then (
            if Feq concl then
              (* [...] |- ~neg_lit *)
              Thm.NOT_INTRO th1
            else
              (* [...] |- ~neg_lit \/ concl *)
              Thm.MP (Drule.SPECL [neg_lit, concl] IMP_DISJ_1) th1
          ) else
            if Feq concl then
              (* [...] |- lit *)
              Thm.MP (Thm.SPEC lit IMP_FALSE) th1
            else
              (* [...] |- lit \/ concl *)
              Thm.MP (Drule.SPECL [lit, concl] IMP_DISJ_2) th1
        end
      else
        raise ERR "z3_lemma" ""
    end
    fun prove (th, disj) =
      prove_literal false (th, disj)
        handle Feedback.HOL_ERR _ =>
          let
            val (l, r) = boolSyntax.dest_disj disj
          in
            (* We do NOT break 'l' apart recursively (because that would be
               slightly tricky to implement, and require associativity of
               disjunction).  Thus, 't' must be parenthesized to the right
               (e.g., "l1 \/ (l2 \/ l3)"). *)
            prove_literal true (prove (th, r), l)
          end
  in
    (state, prove (thm, t))
  end

  (* |- l1 = r1  ...  |- ln = rn
     ----------------------------
     |- f l1 ... ln = f r1 ... rn *)
  fun z3_monotonicity (state, thms, t) =
  let
    val l_r_thms = List.map
      (fn thm => (boolSyntax.dest_eq (Thm.concl thm), thm)) thms
    fun make_equal (l, r) =
      Thm.ALPHA l r
      handle Feedback.HOL_ERR _ =>
        Lib.tryfind (fn ((l', r'), thm) =>
          Thm.TRANS (Thm.ALPHA l l') (Thm.TRANS thm (Thm.ALPHA r' r))
            handle Feedback.HOL_ERR _ =>
              Thm.TRANS (Thm.ALPHA l r')
                (Thm.TRANS (Thm.SYM thm) (Thm.ALPHA l' r))) l_r_thms
      handle Feedback.HOL_ERR _ =>
        let
          val (l_op, l_arg) = Term.dest_comb l
          val (r_op, r_arg) = Term.dest_comb r
        in
          Thm.MK_COMB (make_equal (l_op, r_op), make_equal (l_arg, r_arg))
        end
    val (l, r) = boolSyntax.dest_eq t
    val thm = make_equal (l, r)
      handle Feedback.HOL_ERR _ =>
        (* surprisingly, 'l' is sometimes of the form ``x /\ y ==> z``
           and must be transformed into ``x ==> y ==> z`` before any
           of the theorems in 'thms' can be applied - this is arguably
           a bug in Z3 (2.11) *)
        let
          val (xy, z) = boolSyntax.dest_imp l
          val (x, y) = boolSyntax.dest_conj xy
          val th1 = Drule.SPECL [x, y, z] AND_IMP_INTRO_SYM
          val l' = Lib.snd (boolSyntax.dest_eq (Thm.concl th1))
        in
          Thm.TRANS th1 (make_equal (l', r))
        end
  in
    (state, thm)
  end

  fun z3_mp (state, thm1, thm2, t) =
    (state, Thm.MP thm2 thm1 handle Feedback.HOL_ERR _ => Thm.EQ_MP thm2 thm1)

  (* `z3_mp_eq` implements the inference rule corresponding to `Thm.EQ_MP` *)
  fun z3_mp_eq (state, thm1, thm2, t) =
    (state, Thm.EQ_MP thm2 thm1)

  (* `z3_nnf_neg` creates a proof for a negative NNF step.

     For the initial implementation, we rely on metisLib.METIS_TAC to find a
     proof. However, if it becomes a bottleneck, a more specialized proof
     handler could be implemented to improve performance. *)
  fun z3_nnf_neg (state, thms, t) =
    (state, metis_prove (thms, t))

  (* `z3_nnf_pos` creates a proof for a positive NNF step.

     For the initial implementation, we rely on metisLib.METIS_TAC to find a
     proof. However, if it becomes a bottleneck, a more specialized proof
     handler could be implemented to improve performance. *)
  fun z3_nnf_pos (state, thms, t) =
    (state, metis_prove (thms, t))

  (* ~(... \/ p \/ ...)
     ------------------
             ~p         *)
  fun z3_not_or_elim (state, thm, t) =
  let
    val (is_neg, neg_t) = (true, boolSyntax.dest_neg t)
      handle Feedback.HOL_ERR _ =>
        (false, boolSyntax.mk_neg t)
    val disj = boolSyntax.dest_neg (Thm.concl thm)
    (* neg_t |- disj *)
    val th1 = Library.disj_intro (Thm.ASSUME neg_t, disj)
    (* |- ~disj ==> ~neg_t *)
    val th1 = Drule.CONTRAPOS (Thm.DISCH neg_t th1)
    (* |- ~neg_t *)
    val th1 = Thm.MP th1 thm
  in
    (state, if is_neg then th1 else Thm.MP (Thm.SPEC t NOT_NOT_ELIM) th1)
  end

  (*
     ------------------------------------------  QUANT_INST [u1,...,un]
       |- ~(!x1...xn. t) \/ t[u1/x1]...[un/xn]
  *)
  fun z3_quant_inst (state, terms, t) =
  let
    val t1 = Lib.fst (boolSyntax.dest_disj t)
    val t2 = boolSyntax.dest_neg t1
    val p_term = Term.mk_var ("p", Type.bool)
    val thm1 = Thm.INST [{redex = p_term, residue = t2}] HolSmtTheory.NOT_P_OR_P
    val thm2 = Thm.ASSUME t1
    val thm3_quant = Thm.ASSUME t2
    val thm3 = Drule.SPECL terms thm3_quant
    val thm = Drule.DISJ_CASES_UNION thm1 thm2 thm3
    (* The following is a quick workaround for the following Z3 issue:
       https://github.com/Z3Prover/z3/issues/7154
       The fix seems to be scheduled to be released in the Z3 version after
       v4.12.6. *)
    val thm' =
      if Thm.concl thm !~ t then
        metis_prove ([thm], t)
      else
        thm
  in
    (state, thm')
  end

  (*                     P = Q
     ---------------------------------------------
     (!x. ?y. !z. P x y z) = (!a. ?b. !c. Q a b c) *)
  fun z3_quant_intro (state, thm, t) =
  let
    (* Removes the outer quantifier and returns a function that inserts it into
       a theorem on both sides of an quality, and the term without the
       quantifier. *)
    fun dest_quant term : ((thm -> thm) * term) option =
      if boolSyntax.is_forall term then
        SOME (Lib.apfst Drule.FORALL_EQ (boolSyntax.dest_forall term))
      else if boolSyntax.is_exists term then
        SOME (Lib.apfst Drule.EXISTS_EQ (boolSyntax.dest_exists term))
      else
        NONE
    (* Removes all quantifiers and returns a list of functions that insert them
       back into a theorem, and the term without the quantifiers *)
    fun strip_quant term acc : (thm -> thm) list * term =
      case dest_quant term of
        NONE => (List.rev acc, term)
      | SOME (f, t) => strip_quant t (f :: acc)

    val (lhs, rhs) = boolSyntax.dest_eq t
    val (quantfs, _) = strip_quant lhs []
    (* P may be a quantified proposition itself; only retain *new*
       quantifiers *)
    val (P, _) = boolSyntax.dest_eq (Thm.concl thm)
    val quantfs = List.take (quantfs, List.length quantfs -
      List.length (Lib.fst (strip_quant P [])))
    (* P and Q in the conclusion may require variable renaming to match
       the premise -- we only look at P and hope Q will come out right *)
    fun strip_some_quants 0 term = term
      | strip_some_quants n term =
          strip_some_quants (n - 1) (Lib.snd (Option.valOf (dest_quant term)))
    val len = List.length quantfs
    val (tmsubst, _) = Term.match_term P (strip_some_quants len lhs)
    val thm = Thm.INST tmsubst thm
    (* add quantifiers (on both sides) *)
    val thm = List.foldr (fn (quantf, th) => quantf th)
      thm quantfs
    (* rename variables on rhs if necessary *)
    val (_, intermediate_rhs) = boolSyntax.dest_eq (Thm.concl thm)
    val thm = Thm.TRANS thm (Thm.ALPHA intermediate_rhs rhs)
  in
    (state, thm)
  end

  (* A proof for `R t t`, where R is a reflexive relation. The only `R` that are
     used are equivalence modulo namings, equality and equivalence, i.e. `~`,
     `=` or `iff`, all represented in HOL4 terms as `boolSyntax.mk_eq`. *)
  fun z3_refl (state, t) =
  let
    val (lhs, rhs) = boolSyntax.dest_eq t
  in
    (state, Thm.ALPHA lhs rhs)
  end

  fun z3_rewrite (state, t) =
  let
    val (l, r) = boolSyntax.dest_eq t
  in
    if l ~~ r then
      (state, Thm.REFL l)
    else
      (* proforma theorems *)
      (state, profile "rewrite(01)(proforma)"
        (Z3_ProformaThms.prove Z3_ProformaThms.rewrite_thms) t)
    handle Feedback.HOL_ERR _ =>

    (* cached theorems *)
    (state, profile "rewrite(02)(cache)" (state_inst_cached_thm state) t)
    handle Feedback.HOL_ERR _ =>

    (* re-ordering conjunctions and disjunctions *)
    profile "rewrite(04)(conj/disj)" (fn () =>
      if boolSyntax.is_conj l then
        (state, profile "rewrite(04.1)(conj)" rewrite_conj (l, r))
      else if boolSyntax.is_disj l then
        (state, profile "rewrite(04.2)(disj)" rewrite_disj (l, r))
      else
        raise ERR "" "") ()
    handle Feedback.HOL_ERR _ =>

    (* |- r1 /\ ... /\ rn = ~(s1 \/ ... \/ sn) *)
    (state, profile "rewrite(05)(nnf)" rewrite_nnf (l, r))
    handle Feedback.HOL_ERR _ =>

    (* at this point, we should have dealt with all propositional
       tautologies (i.e., 'tautLib.TAUT_PROVE t' should fail here) *)

    (* |- ALL_DISTINCT ... /\ T = ... *)
    (state, profile "rewrite(06)(all_distinct)" rewrite_all_distinct (l, r))
    handle Feedback.HOL_ERR _ =>

    let
      val thm = profile "rewrite(07)(SIMP_PROVE_UPDATE)" SIMP_PROVE_UPDATE t
        handle Feedback.HOL_ERR _ =>

        profile "rewrite(08)(WORD_DP)" (wordsLib.WORD_DP
          (bossLib.SIMP_CONV (bossLib.++ (bossLib.++ (bossLib.arith_ss,
            wordsLib.WORD_ss), wordsLib.WORD_EXTRACT_ss)) [])
          (Drule.EQT_ELIM o (bossLib.SIMP_CONV bossLib.arith_ss []))) t
        handle Feedback.HOL_ERR _ =>

        profile "rewrite(09)(WORD_ARITH_CONV)" (fn () =>
          Drule.EQT_ELIM (wordsLib.WORD_ARITH_CONV t)
            handle Conv.UNCHANGED => raise ERR "" "") ()
        handle Feedback.HOL_ERR _ =>

        profile "rewrite(10)(BBLAST)" blastLib.BBLAST_PROVE t
        handle Feedback.HOL_ERR _ =>

        if profile "rewrite(11.0)(contains_real)" term_contains_real_ty t then
          profile "rewrite(11.1)(REAL_ARITH)" RealField.REAL_ARITH t
        else
          profile "rewrite(11.2)(ARITH_PROVE)" intLib.ARITH_PROVE t
    in
      (state_cache_thm state thm, thm)
    end

    handle Feedback.HOL_ERR _ =>

    (* If nothing worked, let's try unifying terms.
       As a motivating example, when proving `(if x < y then x else y) <= x`,
       Z3 v4.12.4 asks us to prove the following rewrite as one of the proof
       steps:

       ~(x + -1 * (if x + -1 * y >= 0 then y else x) >= 0) <=>
       ~(x + -1 * $var$(z3name!0) >= 0)

       ... where z3name!0 is a variable declared by Z3 at the beginning of its
       proof certificate, but which we know nothing about at this point.

       We use the following function to unify both sides of the equality such
       that we obtain instantiations for these variables invented by Z3 (i.e. in
       this example, we'll obtain ``z3name!0 = if x + -1 * y >= 0 then y else x``):

       > Unify.simp_unify_terms [] ``<lhs>`` ``<rhs>``;

       val it = [{redex = ``$var$(z3name!0)``, residue =
         ``if x + -1 * y >= 0 then y else x``}]: (term, term) subst

       We then prove the theorem by substituting the variable(s) and add
       ``z3name!0 = if ... then y else x`` to the list of Z3-provided
       definitions (as in the `z3_intro_def` handler), to make sure it gets
       removed from the set of hypotheses of the final theorem. *)

    let
      val (lhs, rhs) = boolSyntax.dest_eq t
      val thm = profile "rewrite(12)(unification)" Library.gen_instantiation
        (lhs, rhs, #var_set state)
      val asl = Thm.hyp thm
    in
      (state_define (state_cache_thm state thm) asl, thm)
    end
  end

  (* |- ~(!x. P x y) <=> ~(P (sk y) y)
     |- (?x. P x y) <=> P (sk y) y *)
  fun z3_skolem (state, t) =
  let
    val lhs = Lib.fst (boolSyntax.dest_eq t)
    val thm1 =
      if boolSyntax.is_exists lhs then
        HolSmtTheory.SKOLEM_EXISTS
      else
        HolSmtTheory.SKOLEM_FORALL
    val thm2 = Drule.SELECT_RULE thm1
    val thm3 = Conv.HO_REWR_CONV thm2 lhs
    val substs = Term.match_term t (Thm.concl thm3)
    val {redex, residue} = List.hd (Lib.fst substs)
    val thm4 = Thm.SYM (Thm.ASSUME (boolSyntax.mk_eq (redex, residue)))
    val thm5 = Drule.SUBST_CONV [{redex = redex, residue = thm4}] t
      (Thm.concl thm3)
    val thm = Thm.EQ_MP thm5 thm3
    val asl = Thm.hyp thm
  in
    (state_define state asl, thm)
  end

  fun z3_symm (state, thm, t) =
    (state, Thm.SYM thm)

  fun th_lemma_wrapper (name : string)
    (th_lemma_implementation : state * Term.term -> state * Thm.thm)
    (state, thms, t) : state * Thm.thm =
  let
    val t' = boolSyntax.list_mk_imp (List.map Thm.concl thms, t)
    val (state, thm) = (state,
      (* proforma theorems *)
      profile ("th_lemma[" ^ name ^ "](1)(proforma)")
        (Z3_ProformaThms.prove Z3_ProformaThms.th_lemma_thms) t'
      handle Feedback.HOL_ERR _ =>
        (* cached theorems *)
        profile ("th_lemma[" ^ name ^ "](2)(cache)")
          (state_inst_cached_thm state) t')
      handle Feedback.HOL_ERR _ =>
        (* do actual work to derive the theorem *)
        th_lemma_implementation (state, t')
  in
    (state, Drule.LIST_MP thms thm)
  end

  val z3_th_lemma_arith = th_lemma_wrapper "arith" (fn (state, t) =>
    let
      val (dict, t') = generalize_ite t
      val thm = if term_contains_real_ty t' then
          (* this is just a heuristic - it is quite conceivable that a
             term that contains type real is provable by integer
             arithmetic *)
          profile "th_lemma[arith](3.1)(real)" RealField.REAL_ARITH t'
        else
          (* the following should be reverted to use ARITH_PROVE instead of
             COOPER_PROVE when issue HOL-Theorem-Prover/HOL#1203 is fixed *)
          profile "th_lemma[arith](3.2)(int)" intLib.COOPER_PROVE t'
      val subst = List.map (fn (term, var) => {redex = var, residue = term})
        (Redblackmap.listItems dict)
    in
      (* cache 'thm', instantiate to undo 'generalize_ite' *)
      (state_cache_thm state thm, Thm.INST subst thm)
    end)

  val z3_th_lemma_array = th_lemma_wrapper "array" (fn (state, t) =>
    let
      val thm = profile "th_lemma[array](3)(SIMP_PROVE_UPDATE)"
        SIMP_PROVE_UPDATE t
    in
      (* cache 'thm' *)
      (state_cache_thm state thm, thm)
    end)

  val z3_th_lemma_basic = th_lemma_wrapper "basic" (fn (state, t) =>
    (*TODO: not implemented yet*)
    raise ERR "" "")

  val z3_th_lemma_bv =
  let
    (* TODO: I would like to find out whether PURE_REWRITE_TAC is
             faster than SIMP_TAC here. However, using the former
             instead of the latter causes HOL4 to segfault on various
             SMT-LIB benchmark proofs. So far I do not know the reason
             for these segfaults. *)
    val COND_REWRITE_TAC = (*Rewrite.PURE_REWRITE_TAC*) simpLib.SIMP_TAC
      simpLib.empty_ss [boolTheory.COND_RAND, boolTheory.COND_RATOR]
  in
    th_lemma_wrapper "bv" (fn (state, t) =>
      let
        val thm = profile "th_lemma[bv](3)(WORD_BIT_EQ)" (fn () =>
          Drule.EQT_ELIM (Conv.THENC (simpLib.SIMP_CONV (simpLib.++
            (simpLib.++ (bossLib.std_ss, wordsLib.WORD_ss),
            wordsLib.WORD_BIT_EQ_ss)) [], tautLib.TAUT_CONV) t)) ()
        handle Feedback.HOL_ERR _ =>

          profile "th_lemma[bv](4)(COND_BBLAST)" Tactical.prove (t,
            Tactical.THEN (profile "th_lemma[bv](4.1)(COND_REWRITE_TAC)"
              COND_REWRITE_TAC, profile "th_lemma[bv](4.2)(BBLAST_TAC)"
              blastLib.BBLAST_TAC))
      in
        (* cache 'thm' *)
        (state_cache_thm state thm, thm)
      end)
  end

  fun z3_trans (state, thm1, thm2, t) =
    (state, Thm.TRANS thm1 thm2)

  (* `z3_trans_star` is supposed to handle multiple symmetry and transitivity
     rules. Z3 provides the following example:

     A1 |- R a b   A2 |- R c b   A3 |- R c d
     --------------------------------------- trans*
                A1 u A2 u A3 |- R a d

     Although more generally, the proof rule is supposed to handle any number of
     theorems passed as arguments and any path between the elements.

     R must be a symmetric and transitive relation. So far only equality has
     been observed to be used as `R` (same as in the `symm` and `trans` rules),
     although it's not inconceivable that it may be used for other relations as
     well.

     For the initial implementation, we rely on metisLib.METIS_TAC to find a
     proof. However, if it becomes a bottleneck, a more specialized proof
     handler could be implemented to improve performance. *)

  fun z3_trans_star (state, thms, t) =
    (state, metis_prove (thms, t))

  fun z3_true_axiom (state, t) =
    (state, boolTheory.TRUTH)

  fun z3_unit_resolution (state, thms, t) =
    (state, unit_resolution (thms, t))

  (* end of inference rule implementations *)

  (***************************************************************************)
  (* proof traversal, turning proofterms into theorems                       *)
  (***************************************************************************)

  (* We use a depth-first post-order traversal of the proof, checking
     each premise of a proofterm (i.e., deriving the corresponding
     theorem) before checking the proofterm's inference itself.
     Proofterms that have proof IDs then cause the proof to be updated
     (at this ID) immediately after they have been checked, so that
     future uses of the same proof ID merely require a lookup in the
     proof (rather than a new derivation of the theorem).  To achieve
     a tail-recursive implementation, we use continuation-passing
     style. *)

  fun check_thm (name, thm, concl) =
    if Thm.concl thm !~ concl then
      raise ERR "check_thm" (name ^ ": conclusion is " ^ Hol_pp.term_to_string
        (Thm.concl thm) ^ ", expected: " ^ Hol_pp.term_to_string concl)
    else if !Library.trace > 2 then
      Feedback.HOL_MESG
        ("HolSmtLib: " ^ name ^ " proved: " ^ Hol_pp.thm_to_string thm)
    else ()

  fun zero_prems (state : state, proof : proof)
      (name : string)
      (z3_rule_fn : state * Term.term -> state * Thm.thm)
      (concl : Term.term)
      (continuation : (state * proof) * Thm.thm -> (state * proof) * Thm.thm)
      : (state * proof) * Thm.thm =
  let
    val (state, thm) = profile name z3_rule_fn (state, concl)
      handle Feedback.HOL_ERR _ =>
        raise ERR name (Hol_pp.term_to_string concl)
    val _ = profile "check_thm" check_thm (name, thm, concl)
  in
    continuation ((state, proof), thm)
  end

  fun one_arg_zero_prems (state : state, proof : proof)
      (name : string)
      (z3_rule_fn : state * 'a * Term.term -> state * Thm.thm)
      (arg : 'a, concl : Term.term)
      (continuation : (state * proof) * Thm.thm -> (state * proof) * Thm.thm)
      : (state * proof) * Thm.thm =
  let
    val (state, thm) = profile name z3_rule_fn (state, arg, concl)
      handle Feedback.HOL_ERR _ =>
        raise ERR name (Hol_pp.term_to_string concl)
    val _ = profile "check_thm" check_thm (name, thm, concl)
  in
    continuation ((state, proof), thm)
  end

  fun one_prem (state_proof : state * proof)
      (name : string)
      (z3_rule_fn : state * Thm.thm * Term.term -> state * Thm.thm)
      (pt : proofterm, concl : Term.term)
      (continuation : (state * proof) * Thm.thm -> (state * proof) * Thm.thm)
      : (state * proof) * Thm.thm =
    thm_of_proofterm (state_proof, pt) (continuation o
      (fn ((state, proof), thm) =>
        let
          val (state, thm) = profile name z3_rule_fn (state, thm, concl)
            handle Feedback.HOL_ERR _ =>
              raise ERR name (Hol_pp.thm_to_string thm ^ ", " ^
                Hol_pp.term_to_string concl)
          val _ = profile "check_thm" check_thm (name, thm, concl)
        in
          ((state, proof), thm)
        end))

  and two_prems (state_proof : state * proof)
      (name : string)
      (z3_rule_fn : state * Thm.thm * Thm.thm * Term.term -> state * Thm.thm)
      (pt1 : proofterm, pt2 : proofterm, concl : Term.term)
      (continuation : (state * proof) * Thm.thm -> (state * proof) * Thm.thm)
      : (state * proof) * Thm.thm =
    thm_of_proofterm (state_proof, pt1) (continuation o
      (fn (state_proof, thm1) =>
        thm_of_proofterm (state_proof, pt2) (fn ((state, proof), thm2) =>
          let
            val (state, thm) = profile name z3_rule_fn
              (state, thm1, thm2, concl)
                handle Feedback.HOL_ERR _ =>
                  raise ERR name (Hol_pp.thm_to_string thm1 ^ ", " ^
                    Hol_pp.thm_to_string thm2 ^ ", " ^
                    Hol_pp.term_to_string concl)
            val _ = profile "check_thm" check_thm (name, thm, concl)
          in
            ((state, proof), thm)
          end)))

  and list_prems (state : state, proof : proof)
      (name : string)
      (z3_rule_fn : state * Thm.thm list * Term.term -> state * Thm.thm)
      ([] : proofterm list, concl : Term.term)
      (continuation : (state * proof) * Thm.thm -> (state * proof) * Thm.thm)
      (acc : Thm.thm list)
      : (state * proof) * Thm.thm =
    let
      val acc = List.rev acc
      val (state, thm) = profile name z3_rule_fn (state, acc, concl)
        handle Feedback.HOL_ERR _ =>
          raise ERR name ("[" ^ String.concatWith ", " (List.map
            Hol_pp.thm_to_string acc) ^ "], " ^ Hol_pp.term_to_string concl)
      val _ = profile "check_thm" check_thm (name, thm, concl)
    in
      continuation ((state, proof), thm)
    end
    | list_prems (state_proof : state * proof)
      (name : string)
      (z3_rule_fn : state * Thm.thm list * Term.term -> state * Thm.thm)
      (pt :: pts : proofterm list, concl : Term.term)
      (continuation : (state * proof) * Thm.thm -> (state * proof) * Thm.thm)
      (acc : Thm.thm list)
      : (state * proof) * Thm.thm =
    thm_of_proofterm (state_proof, pt) (fn (state_proof, thm) =>
      list_prems state_proof name z3_rule_fn (pts, concl) continuation
        (thm :: acc))

  and thm_of_proofterm (state_proof, AND_ELIM x) continuation =
        one_prem state_proof "and_elim" z3_and_elim x continuation
    | thm_of_proofterm (state_proof, ASSERTED x) continuation =
        zero_prems state_proof "asserted" z3_asserted x continuation
    | thm_of_proofterm (state_proof, COMMUTATIVITY x) continuation =
        zero_prems state_proof "commutativity" z3_commutativity x continuation
    | thm_of_proofterm (state_proof, DEF_AXIOM x) continuation =
        zero_prems state_proof "def_axiom" z3_def_axiom x continuation
    | thm_of_proofterm (state_proof, ELIM_UNUSED x) continuation =
        zero_prems state_proof "elim_unused" z3_elim_unused x continuation
    | thm_of_proofterm (state_proof, HYPOTHESIS x) continuation =
        zero_prems state_proof "hypothesis" z3_hypothesis x continuation
    | thm_of_proofterm (state_proof, IFF_TRUE x) continuation =
        one_prem state_proof "iff_true" z3_iff_true x continuation
    | thm_of_proofterm (state_proof, INTRO_DEF x) continuation =
        zero_prems state_proof "intro_def" z3_intro_def x continuation
    | thm_of_proofterm (state_proof, LEMMA x) continuation =
        one_prem state_proof "lemma" z3_lemma x continuation
    | thm_of_proofterm (state_proof, MONOTONICITY x) continuation =
        list_prems state_proof "monotonicity" z3_monotonicity x continuation []
    | thm_of_proofterm (state_proof, MP x) continuation =
        two_prems state_proof "mp" z3_mp x continuation
    | thm_of_proofterm (state_proof, MP_EQ x) continuation =
        two_prems state_proof "mp~" z3_mp_eq x continuation
    | thm_of_proofterm (state_proof, NNF_NEG x) continuation =
        list_prems state_proof "nnf_neg" z3_nnf_neg x continuation []
    | thm_of_proofterm (state_proof, NNF_POS x) continuation =
        list_prems state_proof "nnf_pos" z3_nnf_pos x continuation []
    | thm_of_proofterm (state_proof, NOT_OR_ELIM x) continuation =
        one_prem state_proof "not_or_elim" z3_not_or_elim x continuation
    | thm_of_proofterm (state_proof, QUANT_INST x) continuation =
        one_arg_zero_prems state_proof "quant_inst" z3_quant_inst x continuation
    | thm_of_proofterm (state_proof, QUANT_INTRO x) continuation =
        one_prem state_proof "quant_intro" z3_quant_intro x continuation
    | thm_of_proofterm (state_proof, REFL x) continuation =
        zero_prems state_proof "refl" z3_refl x continuation
    | thm_of_proofterm (state_proof, REWRITE x) continuation =
        zero_prems state_proof "rewrite" z3_rewrite x continuation
    | thm_of_proofterm (state_proof, SKOLEM x) continuation =
        zero_prems state_proof "skolem" z3_skolem x continuation
    | thm_of_proofterm (state_proof, SYMM x) continuation =
        one_prem state_proof "symm" z3_symm x continuation
    | thm_of_proofterm (state_proof, TH_LEMMA_ARITH x) continuation =
        list_prems state_proof "th_lemma[arith]" z3_th_lemma_arith x
          continuation []
    | thm_of_proofterm (state_proof, TH_LEMMA_ARRAY x) continuation =
        list_prems state_proof "th_lemma[array]" z3_th_lemma_array x
          continuation []
    | thm_of_proofterm (state_proof, TH_LEMMA_BASIC x) continuation =
        list_prems state_proof "th_lemma[basic]" z3_th_lemma_basic x
          continuation []
    | thm_of_proofterm (state_proof, TH_LEMMA_BV x) continuation =
        list_prems state_proof "th_lemma[bv]" z3_th_lemma_bv x continuation []
    | thm_of_proofterm (state_proof, TRANS x) continuation =
        two_prems state_proof "trans" z3_trans x continuation
    | thm_of_proofterm (state_proof, TRANS_STAR x) continuation =
        list_prems state_proof "trans*" z3_trans_star x continuation []
    | thm_of_proofterm (state_proof, TRUE_AXIOM x) continuation =
        zero_prems state_proof "true_axiom" z3_true_axiom x continuation
    | thm_of_proofterm (state_proof, UNIT_RESOLUTION x) continuation =
        list_prems state_proof "unit_resolution" z3_unit_resolution x
          continuation []
    | thm_of_proofterm ((state, proof), ID id) continuation =
        (case Redblackmap.peek (Lib.fst proof, id) of
          SOME (THEOREM thm) =>
            continuation ((state, proof), thm)
        | SOME pt =>
            thm_of_proofterm ((state, proof), pt) (continuation o
              (* update the proof, replacing the original proofterm with
                 the theorem just derived *)
              (fn ((state, (steps, vars)), thm) =>
                (
                  if !Library.trace > 2 then
                    Feedback.HOL_MESG
                      ("HolSmtLib: updating proof at ID " ^ Int.toString id)
                  else ();
                  ((state, (Redblackmap.insert (steps, id, THEOREM thm), vars)), thm)
                )))
        | NONE =>
            raise ERR "thm_of_proofterm"
              ("proof has no proofterm for ID " ^ Int.toString id))
    | thm_of_proofterm (state_proof, THEOREM thm) continuation =
        continuation (state_proof, thm)

  (* Remove the definitions `defs` from the set of hypotheses in `thm`,
     returning the resulting theorem, i.e.:

     A u defs |- t
     -------------  remove_definitions (defs, var_set)
       A |- t

     Each definition in `defs` must be of the form ``var = term``, where `var`
     must not be free in `t` nor in `A` and must be in `var_set`.

     There is a major complication: some definitions reference variables in
     other definitions and they may even be duplicated (with and without
     expansion), e.g.:

     z1 = x + 1
     z2 = x + 1 + 2
     z2 = z1 + 2
     z3 = 3 + y

     Furthermore, another major complication is that such nested definitions
     can easily cause exponential term blow-up in case all such definitions were
     to be fully expanded (e.g. by substituting each variable with one of its
     definitions), which might occur in a naive attempt at removing these
     definitions. Therefore, a more careful implementation is warranted.

     In general, the variable references can form a directed acyclic graph. For
     efficiency purposes (explained later), we first find a variable that is not
     referenced in any definition of the other variables.

     In the above example, one such variable could be `z2` or `z3` (we'll pick
     `z2` for this example), but not `z1`, since it is referenced in one of the
     definitions of `z2`.

     We then perform the following:

     1. Gather all definitions of this variable. In this example, the
     definitions for ``z2`` would be:

     z2 = z1 + 2
     z2 = x + 1 + 2

     2. Instantiate the variable with one of its definitions (chosen
     arbitrarily). In this example, it could result in the following hypotheses:

     z1 + 2 = z1 + 2
     z1 + 2 = x + 1 + 2

     3. For each of these hypotheses, we create a theorem proving the hypothesis
     so that we can remove it with Drule.PROVE_HYP. To prove such a theorem,
     first we unify the terms on both sides of the equality, such that we obtain
     new definitions for the variables in these hypotheses. For the first one,
     no new definitions are needed, which means such a theorem can be proven
     with REFL. For the second one, we get:

     z1 = x + 1

     We can then substitute `z1` with `x + 1`, then use REFL to prove the
     theorem. This is implemented in `Library.gen_instantiation`. Note that this
     theorem will have `z1 = x + 1` in its set of hypotheses, which
     Drule.PROVE_HYP then adds to the set of hypotheses of `thm`.

     However, this new hypothesis will be removed later when we process `z1`.
     Often, these additional hypotheses are identical to pre-existing ones, so
     they get deduplicated when added to the set of hypotheses of `thm`. By
     processing variables in this specific order, we thus avoid doing a lot of
     repeated work of removing the same definitions over and over again.

     Once all the definitions of the variable we've chosen are removed, we
     recurse into this same function, with the new set of definitions that are
     to be removed (corresponding to one less variable). Note that in general,
     at no point we needed to fully expand a definition (unless it's already
     expanded). *)

  fun remove_definitions (defs, var_set, thm): Thm.thm =
    if HOLset.isEmpty defs then
      thm
    else
      let
        (* For convenience, `dest_defs` will contain a list of `(lhs, rhs)`
           pairs, where `lhs` is the var being defined and `rhs` its
           definition. *)
        val dest_defs = List.map boolSyntax.dest_eq (HOLset.listItems defs)
        val (lhs_l, rhs_l) = ListPair.unzip dest_defs
        (* `ref_set` will contain the set of all variables being referenced *)
        val ref_set = Term.FVL rhs_l Term.empty_tmset
        (* `def_set` will contain the set of all variables being defined.
           It should always be a subset of `var_set`. *)
        val def_set = List.foldl (Lib.flip HOLset.add) Term.empty_tmset lhs_l

        (* `unref_set` will contain the set of all the variables being defined
           but not being referenced *)
        val unref_set = HOLset.difference (def_set, ref_set)

        val () =
          if HOLset.isEmpty unref_set then
            raise ERR "remove_definitions" "no unreferenced variables"
          else
            ()

        (* Pick an arbitrary variable from `unref_set` *)
        val var = Option.valOf (HOLset.find (fn _ => true) unref_set)

        (* Get all the variable's definitions *)
        fun filter_def (v, d) = if Term.term_eq v var then SOME d else NONE
        val defs_to_remove = List.mapPartial filter_def dest_defs

        (* Pick an arbitrary definition for instantiation *)
        val inst = List.hd defs_to_remove

        (* Instantiate the variable with the definition *)
        val thm = Thm.INST [{redex = var, residue = inst}] thm

        (* For each definition corresponding to this variable, create a theorem
           that can eliminate the definition from the set of hypotheses of `thm` *)
        val hyp_thms = List.map (fn def => Library.gen_instantiation (inst, def,
          var_set)) defs_to_remove

        (* Remove all the definitions corresponding to this variable *)
        fun remove_hyp (hyp_thm, thm) = Drule.PROVE_HYP hyp_thm thm
        val thm = List.foldl remove_hyp thm hyp_thms

        (* Compute the new set of definitions to remove when recursing.
           Basically, it's all the definitions in `thm`, i.e. all hypotheses of
           the form ``var = def``, where ``var`` is in `var_set` *)
        fun is_definition hyp = boolSyntax.is_eq hyp andalso
          HOLset.member (var_set, Lib.fst (boolSyntax.dest_eq hyp))
        fun add_def (hyp, set) =
          if is_definition hyp then HOLset.add (set, hyp) else set
        val new_defs = HOLset.foldl add_def Term.empty_tmset (Thm.hypset thm)
      in
        (* Recurse to remove the remaining variables' definitions *)
        remove_definitions (new_defs, var_set, thm)
      end

  (* this function identifies hypotheses in the final theorem that are not in
     the original list of assumptions and then tries to remove them; it's a
     workaround for the following Z3 issue, whose fix is currently still in
     progress:

     https://github.com/Z3Prover/z3/pull/7157 *)
  fun remove_hyps (asl, g, thm) : Thm.thm =
  let
    val hyps = Thm.hypset thm
    (* add the negation of the conclusion of the goal to the list of
       expected hypotheses *)
    val asl = (boolSyntax.mk_neg g) :: asl
    val asms = HOLset.addList (Term.empty_tmset, asl)
    val bad_hyps = HOLset.difference (hyps, asms)
    fun remove_hyp (hyp, thm) : Thm.thm =
    let
      val hyp_thm = Tactical.TAC_PROOF ((asl, hyp), metisLib.METIS_TAC [])
    in
      Drule.PROVE_HYP hyp_thm thm
    end
  in
    HOLset.foldl remove_hyp thm bad_hyps
  end

in
  (* For unit tests *)
  val remove_definitions = remove_definitions

  (* returns a theorem that concludes ``F``, with its hypotheses (a
     subset of) those asserted in the proof *)
  fun check_proof (asl, g, proof) : Thm.thm =
  let
    val _ = if !Library.trace > 1 then
        Feedback.HOL_MESG "HolSmtLib: checking Z3 proof"
      else ()

    (* initial state *)
    val state = {
      asserted_hyps = Term.empty_tmset,
      definition_hyps = Term.empty_tmset,
      thm_cache = Net.empty,
      var_set = Lib.snd proof
    }

    (* ID 0 denotes the proof's root node *)
    val ((state, _), thm) = thm_of_proofterm ((state, proof), ID 0) Lib.I

    val _ = Feq (Thm.concl thm) orelse
      raise ERR "check_proof" "final conclusion is not 'F'"

    (* remove the definitions introduced by Z3 from the set of hypotheses *)
    val final_thm = profile "check_proof(remove_definitions)" remove_definitions
      (#definition_hyps state, #var_set state, thm)

    (* check that the final theorem contains no hyps other than those
       that have been asserted *)
    val _ = profile "check_proof(hypcheck)" HOLset.isSubset (Thm.hypset final_thm,
        #asserted_hyps state) orelse
      raise ERR "check_proof" "final theorem contains additional hyp(s)"

    (* if the final theorem contains hyps that are not in `asl`, it likely means
       that we've run into a Z3 issue where it slightly modifies the original
       assumptions; as a workaround we try to remove those hyps here *)
    val final_thm = profile "check_proof(hyp_removal)" remove_hyps
      (asl, g, final_thm)
  in
    final_thm
  end

end  (* local *)

end
