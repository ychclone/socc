open Core
open Ast
open Context
open X64

let (>>) f g a = g (f a)

let gen_const c =
  match c with
  | Int i -> movl ("$" ^ string_of_int i) "%eax"
  | Char c -> movb ("$" ^ string_of_int (Char.to_int c)) "%al"
  | String s -> my_print_string s
  | _ -> Fn.id (* TODO *)

let gen_unop (uop : unop) ctx =
  match uop with
  | Negate -> neg "%eax" ctx
  | Pos -> ctx
  | Complement -> nnot "%eax" ctx
  | Not ->
    ctx
    |> cmpl "$0" "%eax"
    |> movl "$0" "%eax"
    |> sete "%al"

let gen_compare (inst : string -> context -> context) ctx =
  ctx
  |> cmpl "%ecx" "%eax"
  |> movl "$0" "%eax"
  |> inst "%al"

let gen_binop bop =
  match bop with
  | Add -> addl "%ecx" "%eax"
  | Sub -> subl "%ecx" "%eax"
  | Mult -> imul "%ecx" "%eax"
  | Div -> Fn.id
    >> movl "$0" "%eax"
    >> idivl "%ecx"
  | Mod -> Fn.id
    >> movl "$0" "%edx"
    >> idivl "%ecx"
    >> movl "%edx" "%eax"
  | Xor -> xor "%ecx" "%eax"
  | BitAnd -> ands "%ecx" "%eax"
  | BitOr -> ors "%ecx" "%eax"
  | ShiftL -> sall "%cl" "%eax"
  | ShiftR -> sarl "%cl" "%eax"
  | Eq -> gen_compare sete
  | Neq -> gen_compare setne
  | Lt -> gen_compare setl
  | Le -> gen_compare setle
  | Gt -> gen_compare setg
  | Ge -> gen_compare setge
  | Or -> Fn.id
    >> orl "%ecx" "%eax"
    >> movl "$0" "%eax"
    >> setne "%al"
  | And -> Fn.id
    >> cmpl "$0" "%eax"
    >> movl "$0" "%eax"
    >> setne "%al"
    >> cmpl "$0" "%ecx"
    >> movl "$0" "%ecx"
    >> setne "%cl"
    >> andb "%cl" "%al"

let gen_fun_end =
  (* movq "%rbp" "%rsp";
     popq "%rbp"; *)
  leave >> ret

let assign_op_map = function
  | AddEq -> Add
  | SubEq -> Sub
  | MultEq -> Mult
  | DivEq -> Div
  | ModEq -> Mod
  | BitAndEq -> BitAnd
  | BitOrEq -> BitOr
  | XorEq -> Xor
  | ShiftLEq -> ShiftL
  | ShiftREq -> ShiftR
  | AssignEq ->
    raise (CodeGenError "cannot map assign_op: AssignEq")

let arg_regs =
  Array.of_list ["%rdi"; "%rsi"; "%rdx"; "%rcx"; "%r8"; "%r9"]

let rec get_type_size = function
  | VoidType -> 0
  | ShortIntType -> 2
  | IntType -> 4
  | LongIntType -> 8
  | LongLongIntType -> 8
  | CharType -> 1
  | FloatType -> 4
  | DoubleType -> 8
  | ArrayType (n, t) -> n * get_type_size t
  | ConstType t -> get_type_size t
  | PointerType _ -> 8

let rec get_exp_type ctx = function
  | Assign (_, lexp, _) -> get_exp_type ctx lexp
  | Var id -> (find_var id ctx).var_t
  | Const c -> (* TODO *) LongLongIntType
  | UnOp (_ , e) -> get_exp_type ctx e
  | BinOp (_ , e1, e2)
  | Condition (_, e1, e2) -> get_exp_type ctx e1
  | Call _ -> LongLongIntType
  | AddressOf e -> PointerType (get_exp_type ctx e)
  | Dereference e ->
    (match get_exp_type ctx e with
     | PointerType pt -> pt
     | _ -> (* TODO *) LongLongIntType)
  | SizeofType _ -> (* TODO *) LongLongIntType
  | SizeofExp _ -> (* TODO *) LongLongIntType

let rec gen_exp e (ctx : context) =
  match e with
  | Assign (AssignEq, Var id, rexp) ->
    let v = find_var id ctx in
    ctx
    |> gen_exp rexp
    |> movq "%rax" (off v.loc "%rbp")
  | Assign (AssignEq, Dereference pt, rexp) ->
    let sz = get_type_size (get_exp_type ctx e) in
    ctx
    |> gen_exp pt
    |> pushq "%rax"
    |> gen_exp rexp
    |> movq "%rax" "%rcx"
    |> popq "%rax"
    |> if sz <= 4
    then movl "%ecx" "(%rax)"
    else movq "%rcx" "(%rax)"
  | Assign (AssignEq, _, rexp) ->
    raise (CodeGenError
             "the left hand side of an assignment should be a variable or a dereference")
  | Assign (op, lexp, rexp) ->
    let bexp = (BinOp (assign_op_map op, lexp, rexp)) in
    gen_exp (Assign (AssignEq, lexp, bexp)) ctx
  | Var id ->
    let v =  find_var id ctx in
    movq (off v.loc "%rbp") "%rax" ctx
  | Const c ->
    gen_const c ctx
  | UnOp (uop, e) ->
    ctx
    |> gen_exp e
    |> gen_unop uop
  | BinOp (bop, e1, e2) ->
    ctx
    |> gen_exp e1
    |> pushq "%rax"
    |> gen_exp e2
    |> movq "%rax" "%rcx"
    |> popq "%rax"
    |> gen_binop bop
  | Condition (cond, texp, fexp) ->
    let lb0 = get_new_label ~name:"CDA" ctx in
    let lb1 = get_new_label ~name:"CDB" ctx in
    ctx
    |> inc_labelc
    |> gen_exp cond
    |> cmpl "$0" "%eax"
    |> je lb0
    |> gen_exp texp
    |> jmp lb1
    |> label lb0
    |> gen_exp fexp
    |> label lb1
  | AddressOf (Var id) ->
    let v = find_var id ctx in
    ctx
    |> movq "%rbp" "%rax"
    |> addq (cint v.loc) "%rax"
  | AddressOf _ ->
    raise (CodeGenError
             "cannot get the address of an expression which is not a variable")
  | Dereference e ->
    let sz = get_type_size (get_exp_type ctx e) in
    gen_exp e ctx |>
    if sz <= 4
    then movl "(%rax)" "%eax"
    else movq "(%rax)" "%rax"
  | SizeofType t ->
    let sz = get_type_size t in
    movq (cint sz) "%rax" ctx
  | SizeofExp e ->
    (* TODO *)
    let sz = get_type_size (get_exp_type ctx e) in
    movq (cint sz) "%rax" ctx
  | Call (f, args) -> (* TODO *)
    gen_args 0 args ctx
    |> call f

and gen_args i args =
  match args with
  | arg :: args ->
    if i + 1 >= Array.length arg_regs
    then raise (CodeGenError "to many args")
    else
      gen_exp arg
      >> movq "%rax" arg_regs.(i)
      >> gen_args (i + 1) args
  | [] -> Fn.id

let gen_decl_exp (de : decl_exp) ctx =
  (* TODO *)
  (* check if var has been define in the same block *)
  (match get_var_level de.name ctx with
   | Some l ->
     if l = ctx.scope_levelc
     then raise (CodeGenError
                   (de.name ^ " has already been defined in the same block"))
     else ()
   | None -> ());
  (match de.init with
   | Some iexp ->
     gen_exp iexp ctx
   | None ->
     (* init default value *)
     movq "$0" "%rax" ctx)
  |> pushq "%rax"
  |> add_var de.name de.var_type

let deallocate_vars ctx1 ctx2 =
  ignore @@ addq (cint (ctx1.index - ctx2.index)) "%rsp" ctx2;
  keep_labelc ctx1 ctx2

let rec gen_statement sta ctx =
  match sta with
  | Decl de ->
    gen_decl_exp de ctx
  | Exp e ->
    gen_exp e ctx
  | ReturnVal e ->
    ctx
    |> gen_exp e
    |> gen_fun_end
  | Compound ss ->
    ctx
    |> inc_scope_level
    |> gen_statements ss
    |> deallocate_vars ctx
  | If ifs ->
    let lb0 = get_new_label ~name:"IFA" ctx in
    let lb1 = get_new_label ~name:"IFB" ctx in
    ctx
    |> inc_labelc
    |> gen_exp ifs.cond
    |> cmpl "$0" "%eax"
    |> je lb0
    |> gen_statement ifs.tstat
    |> jmp lb1
    |> label lb0
    |> (match ifs.fstat with
        | Some fs -> gen_statement fs
        | None -> Fn.id)
    |> label lb1
  | While (cond, body) ->
    let lb0 = get_new_label ~name:"WHA" ctx in
    let lb1 = get_new_label ~name:"WHB" ctx in
    ctx
    |> inc_labelc
    |> set_labels lb0 lb1
    |> label lb0
    |> set_labels lb0 lb1
    |> gen_exp cond
    |> cmpl "$0" "%eax"
    |> je lb1
    |> gen_statement body
    |> jmp lb0
    |> label lb1
    |> unset_labels
  | Do (cond, body) ->
    let lb0 = get_new_label ~name:"DOA" ctx in
    let lb1 = get_new_label ~name:"DOB" ctx in
    ctx
    |> inc_labelc
    |> set_labels lb0 lb1
    |> label lb0
    |> gen_statement body
    |> gen_exp cond
    |> cmpl "$0" "%eax"
    |> je lb1
    |> jmp lb0
    |> label lb1
    |> unset_labels
  | For f ->
    gen_for (gen_exp f.init) f.cond f.post f.body ctx
  | ForDecl f ->
    gen_for (gen_decl_exp f.init) f.cond f.post f.body ctx
  | Break ->
    (match ctx.endlb with
     | l :: _ -> jmp l ctx
     | [] -> raise (CodeGenError "not in a loop"))
  | Continue ->
    (match ctx.startlb with
     | l :: _ -> jmp l ctx
     | [] -> raise (CodeGenError "not in a loop"))
  | Label l -> label l ctx
  | Goto l -> jmp l ctx
  | Nop -> ctx

and gen_for gen_init cond post body ctx =
  let lb0 = get_new_label ~name:"FORA" ctx in
  let lb1 = get_new_label ~name:"FORB" ctx in
  let lb2 = get_new_label ~name:"FORC" ctx in
  ctx
  |> inc_scope_level
  |> inc_labelc
  |> set_labels lb0 lb2
  |> gen_init
  |> label lb0
  |> gen_exp cond
  |> cmpl "$0" "%eax"
  |> je lb2
  |> gen_statement body
  |> label lb1
  |> gen_exp post
  |> jmp lb0
  |> label lb2
  |> unset_labels
  |> deallocate_vars ctx

(* TODO *)
and gen_statements stas =
  match stas with
  (* | [ReturnVal e] ->
      gen_statement (ReturnVal e)
     | [s] -> (* when function doesn't have return, return 0 *)
      gen_statement s >>
      gen_statement @@ ReturnVal (Const (Int 0)) *)
  | s :: ss ->
    gen_statement s >>
    gen_statements ss
  | [] -> Fn.id

let rec init_params i params ctx =
  match params with
  | (_, VoidType) :: _ -> ctx
  | (None, _) :: ps -> init_params (i + 1) ps ctx
  | (Some v, t) :: ps ->
    ctx
    (* |> movq arg_regs.(i) "%rax" *)
    |> pushq arg_regs.(i)
    |> add_var v t
    |> init_params (i + 1) ps
  | _ -> ctx

let gen_fun (f : fun_decl) out =
  (* TODO *)
  { fun_name = f.name ; index= -8;
    scope_levelc = 0; labelc = 0;
    startlb = [];  endlb = [];
    vars = []; out = out }
  |> globl f.name
  |> label f.name
  |> pushq "%rbp"
  |> movq "%rsp" "%rbp"
  |> init_params 0 f.params
  |> gen_statements f.body

let gen_temp_lib out =
  { fun_name = "println" ; index= -8;
    scope_levelc = 0; labelc = 0;
    startlb = [];  endlb = [];
    vars = []; out = out; }
  |> Templib.gen_lib

let rec gen_prog p out =
  match p with
  | Prog [] -> ();
  | Prog (f :: fs) ->
    let _ = gen_fun f out in
    Out_channel.newline out;
    gen_prog (Prog fs) out
