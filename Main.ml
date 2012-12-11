open Parser
open Lexer
open Printf
open List
open Type
open Printf
open Int32

type var = {
    name : string;
    is_clock : bool;
    vtype : var_type;
    value : tval list
}
and tval = Undefined | Val of value
and context = {
    local : (string * var) list;
    input : (string * value list) list;
    clock : int
}

let make_var (namelist, t, csexpr) = map (function varid -> 
    {name = (fst varid); is_clock = (snd varid); vtype = t; value = [] }) namelist
let make_var_list lst = concat (map make_var lst)

let print_var_list vlst  =
    print_string "vars:\n";
    print_list (fun (name, var) -> print_string name) vlst;
    print_newline ()

let print_context context = print_var_list context.local

let rec print_program program =
    printf "The program contains %d nodes:\n" (length program.nodes);
    iter print_node program.nodes

and print_node (name, node) = print_node_head node.header

and print_node_head (t, name, args, rets) =
    print_node_type t;
    print_string name; print_newline ();
    print_string "   - input: ";
    print_params args;
    print_string "   - output: ";
    print_params rets

and print_node_type t = match t with
    Node -> print_string " - node:"
  | Function -> print_string " - function:"
and print_params pms = iter print_var_def pms and print_var_def (ids, var_type, _) = print_list (fun x ->
        print_string (fst x)) ids;
        print_char ':';
        print_string (format_var_type var_type);
        print_newline ()

let next_clock context =
    try
        let grab_input name = if mem_assoc name context.input
        then Val (hd (assoc name context.input))
        else Undefined in
        { local = map (fun (name, vr) -> (name, { vr with value = (grab_input vr.name) :: vr.value })) context.local;
          input = map (fun (name, lst) -> (name, tl lst)) context.input;
          clock = context.clock + 1
        }
    with
        Failure t when t = "hd" || t = "tl" -> raise (Failure "reach the end of input")

let pre context = let (prelst, cur) = split (map (fun (name, vr) ->
    ((name, { vr with value = tl vr.value }), hd vr.value)) context.local) in
    ({ context with local = prelst; clock = context.clock - 1 }, cur)

let restore_pre context cur = { context with local = map (fun ((name, vr), v) -> (name, { vr with value
    = v :: vr.value})) (combine context.local cur); clock = context.clock + 1 }

let fstclock context = let (fstlst, rst) = split (map (fun (name, vr) ->
    (let rv = rev vr.value in (name, { vr with value = [hd rv] }), tl rv)) context.local) in
    ({ context with local = fstlst; clock = 1 }, (context.clock, rst))

let restore_fc context rst = { context with local = map (fun ((name, vr), rv) ->
    (name, { vr with value = rev (vr.value @ rv) })) (combine context.local (snd rst)); clock = (fst rst) }

let lookup context name = assoc name context.local
and bind_var context (name:string) (value:value) : context =
    let tbl = context.local in
    let vr = assoc name tbl in
    { context with local =
        (name, {vr with value = (Val value) :: tl vr.value}) :: (remove_assoc name tbl) }

let hdv lst = if lst = [] then Val VNil else hd lst

let rec eval_expr context eqs expr : context * value =
    let get_val x =
        let check var =
            match hdv var.value with
              Undefined -> solve_var context eqs var.name
            | Val v -> (context, v) in
        match x with
          VIdent varname -> check (lookup context varname)
        | t -> (context, t) in
    let eval2 op a b =
        let (c1, ra) = eval_expr context eqs a in
        let (c2, rb) = eval_expr c1 eqs b in
        (c2, op ra rb)
    and eval1 op a =
        let (c, r) = eval_expr context eqs a in (c, op r)
        in match expr with
          Add    (a, b) -> eval2 vadd       a b
        | Minus  (a, b) -> eval2 vminus     a b
        | Mult   (a, b) -> eval2 vmult      a b
        | Divide (a, b) -> eval2 vdivide    a b
        | Div    (a, b) -> eval2 vdiv       a b
        | Mod    (a, b) -> eval2 vmod       a b
        | Neg      a    -> eval1 vneg       a
        | RealConv a    -> eval1 vreal_conv a
        | IntConv  a    -> eval1 vint_conv  a

        | RValue   v    -> get_val v

        | Elist    lst  -> let (c, r) = (fold_right (fun expr (context, res) ->
                           let (c, r) = eval_expr context eqs expr in (c, r ::
                               res) ) lst (context, [])) in (c, VList r)

        | Pre      a    -> let (precon, cur) = pre context in
                           let (c, r) = eval_expr precon eqs a in (restore_pre precon cur, r)
        | Arrow  (a, b) -> if context.clock == 1
                           then let (fstcon, rst) = fstclock context in
                                let (c, r) = eval_expr fstcon eqs a in (restore_fc fstcon rst, r)
                           else eval_expr context eqs b

        | Not      a    -> eval1 vnot  a
        | And    (a, b) -> eval2 vand  a b
        | Or     (a, b) -> eval2 vor   a b
        | Xor    (a, b) -> eval2 vxor  a b

        | Eq     (a, b) -> eval2 veq   a b
        | Ne     (a, b) -> eval2 vne   a b
        | Lt     (a, b) -> eval2 vlt   a b
        | Gt     (a, b) -> eval2 vgt   a b
        | Lteq   (a, b) -> eval2 vlteq a b
        | Gteq   (a, b) -> eval2 vgteq a b

        | Temp     a    -> raise (Failure "Not supported")

and solve_var context eqs varname : context * value =
    let value = hdv (lookup context varname).value in
    match value with
      Undefined -> (
        let eq = find
                 (fun (lhs, expr) -> exists
                    (function LIdent name -> name = varname | _ -> false) lhs) eqs in

        let (context, result) = eval_expr context eqs (snd eq)

        and bind_lhs (vr,v) context = match vr with
          LIdent varname -> bind_var context varname v
        | Underscore -> context

        and lhs = fst eq in

        match result with
          VList lst -> (fold_right bind_lhs (combine lhs lst) context, assoc (LIdent varname) (combine lhs lst))
        | t -> (bind_lhs (hd lhs, t) context, t))
    | Val v -> (context, v)

let run_node { header=(_, _, args, rets); locals = locals; equations=eqs } input =
    (* Build vars *)
    let vars_table = map (fun v -> (v.name, v)) in
    let output_vars = make_var_list rets in
    let context = { local = vars_table
                           (concat [(make_var_list args);
                                    (output_vars);
                                    (make_var_list locals)]);
                    input = input;
                    clock = 0 } in
    let rec cycle context =
    let (context, output) = fold_right (fun var (context, res) -> let (c, r) =
        (solve_var context eqs var.name)
                                                        in (c, r::res))
                    output_vars (context, []) in

    print_list print_value output;
    print_newline ();
    cycle (next_clock context) in cycle (next_clock context)


let _ =
    try
        let lexbuf = Lexing.from_channel (open_in "input.lus")  in
            let result = Parser.file Lexer.initial lexbuf in
                print_program result;
                run_node (assoc "main" result.nodes) [("x", map (fun x ->
                    VInt (of_int x)) [10;3;56;4;3;2])]

    with
    (Parse_Error str) ->
        printf "Error: %s\n" str;
        exit 0

