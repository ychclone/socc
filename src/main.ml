open Core
open Ast
open Generate

let _ =
  let lexbuf = Lexing.from_channel In_channel.stdin in
  let result = Parser.program Lexer.token lexbuf in
  (* output ast *)
  (* result |> string_of_prog |> print_string;
     Out_channel.newline stdout; *)
  ignore (gen_temp_lib Out_channel.stdout);
  gen_prog result Out_channel.stdout
