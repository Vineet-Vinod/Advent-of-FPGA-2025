open Core
open Hardcaml
open Day8

module C = Circuit.With_interface (Inputs) (Outputs)

let () =
  let scope = Scope.create ~flatten_design:true () in
  let circuit = C.create_exn ~name:"day08" (create scope) in
  let out = Out_channel.create "day08.v" in
  Rtl.output Verilog ~output_mode:(To_channel out) circuit;
  Out_channel.close out;
  printf "Generated day08.v successfully.\n"