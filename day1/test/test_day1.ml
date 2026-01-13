open Core
open Hardcaml
open Day1

let%expect_test "Day 1 Input" =
  let module Sim = Cyclesim.With_interface (Inputs) (Outputs) in
  let scope = Scope.create () in
  let sim = Sim.create (create scope) in
  
  let clear = Cyclesim.in_port sim "clear" in
  let char_in = Cyclesim.in_port sim "char_in" in
  let valid_in = Cyclesim.in_port sim "valid_in" in
  let p1_ans_out = Cyclesim.out_port sim "p1_ans" in
  let p2_ans_out = Cyclesim.out_port sim "p2_ans" in

  (* Reset *)
  Cyclesim.reset sim;
  valid_in := Bits.gnd;
  clear := Bits.vdd;  
  Cyclesim.cycle sim; 
  clear := Bits.gnd;
  Cyclesim.cycle sim;

  (* Send input *)
  let lines = In_channel.read_lines "input.txt" in
  List.iter lines ~f:(fun line ->
    let line_with_newline = line ^ "\n" in
    
    String.iter line_with_newline ~f:(fun char ->
      char_in := Bits.of_int ~width:8 (Char.to_int char);
      valid_in := Bits.vdd;
      Cyclesim.cycle sim;
      
      (* Execute in hardware takes 1 cycle to perform the math 
         and update st after '\n' is sent so we wait 1 cycle *)
      if Char.equal char '\n' then (
        valid_in := Bits.gnd;
        Cyclesim.cycle sim
      )
    )
  );

  (* Wait for final settling and print *)
  valid_in := Bits.gnd;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;

  let ans1_hw = Bits.to_int !p1_ans_out in
  let ans2_hw = Bits.to_int !p2_ans_out in

  (* Golden model - Python script *)
  let py_lines = In_channel.read_lines "golden_solution.txt" in
  let ans1_py = Int.of_string (List.nth_exn py_lines 0) in
  let ans2_py = Int.of_string (List.nth_exn py_lines 1) in

  if ans1_hw = ans1_py then 
    printf "Part 1 PASSED\n"
  else 
    printf "Part 1 FAILED: HW=%d vs PY=%d\n" ans1_hw ans1_py;

  if ans2_hw = ans2_py then 
    printf "Part 2 PASSED\n"
  else 
    printf "Part 2 FAILED: HW=%d vs PY=%d\n" ans2_hw ans2_py;

  [%expect {|
    Part 1 PASSED
    Part 2 PASSED
    |}]
;;

let%expect_test "generate verilog" =
  let scope = Scope.create () in
  let module C = Circuit.With_interface (Inputs) (Outputs) in
  let circ = C.create_exn ~name:"day01" (create scope) in
  Rtl.output Verilog ~output_mode:(To_file "day01.v") circ;
  printf "Generated day01.v\n";
  [%expect {| Generated day01.v |}]
;;
