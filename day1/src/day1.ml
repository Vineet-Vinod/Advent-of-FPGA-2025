open Core
open Hardcaml
open Signal

module Inputs = struct
  type 'a t = {
    clock : 'a;
    clear : 'a;
    char_in : 'a [@bits 8];
    valid_in : 'a;
  } [@@deriving sexp_of, hardcaml]
end

module Outputs = struct
  type 'a t = {
    p1_ans : 'a [@bits 32];
    p2_ans : 'a [@bits 32];
  } [@@deriving sexp_of, hardcaml]
end

module StateMachine = struct
  type t =
    | Wait
    | ParseDig
    | Execute
  [@@deriving sexp_of, compare, enumerate]
end

let create _scope (i : _ Inputs.t) =
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let state_machine = Always.State_machine.create (module StateMachine) spec in

  let spec_with_start_pos = Reg_spec.override spec ~clear_to:(of_int ~width:32 50) in
  let st = Always.Variable.reg spec_with_start_pos ~width:32 in

  let p1_ans = Always.Variable.reg spec ~width:32 in
  let p2_ans = Always.Variable.reg spec ~width:32 in
  let mv = Always.Variable.reg spec ~width:32 in
  let is_left = Always.Variable.reg spec ~width:1 in

  let ascii_L = of_int ~width:8 (Char.to_int 'L') in
  let ascii_R = of_int ~width:8 (Char.to_int 'R') in
  let ascii_newline = of_int ~width:8 (Char.to_int '\n') in
  let ascii_0 = of_int ~width:8 (Char.to_int '0') in
  let ascii_9 = of_int ~width:8 (Char.to_int '9') in

  Always.(compile [
    state_machine.switch [
      Wait, [
        when_ i.valid_in [
          if_ (i.char_in ==: ascii_L) [
            is_left <-- vdd;
            mv <-- of_int ~width:32 0; 
            state_machine.set_next ParseDig
          ] @@ elif (i.char_in ==: ascii_R) [
            is_left <-- gnd;
            mv <-- of_int ~width:32 0;
            state_machine.set_next ParseDig
          ] []
        ]
      ];

      ParseDig, [
        when_ i.valid_in [
          if_ (i.char_in ==: ascii_newline) [
            state_machine.set_next Execute
          ] @@ elif ((i.char_in >=: ascii_0) &: (i.char_in <=: ascii_9)) [
             let digit = uresize (i.char_in -: ascii_0) 32 in
             let mv_shift_64 = mv.value *: (of_int ~width:32 10) in
             let mv_shift_32 = uresize mv_shift_64 32 in
             mv <-- mv_shift_32 +: digit
          ] []
        ]
      ];

      Execute, (
         (* Division and Modulo is expensive so I use the multiply and shift approach *)
         let magic_mult = of_int ~width:32 1374389535 in 
         let prod = mv.value *: magic_mult in
         let div_100 = uresize (select prod 63 37) 32 in

         let mod_calc = div_100 *: (of_int ~width:32 100) in
         let mod_calc_32 = uresize mod_calc 32 in
         let mod_100 = mv.value -: mod_calc_32 in
         
         let curr_st = st.value in
         let next_st_l = 
           mux2 (curr_st >=: mod_100)
             (curr_st -: mod_100)
             (curr_st +: (of_int ~width:32 100) -: mod_100) 
         in
         
         let next_st_r = 
           let sum = curr_st +: mod_100 in
           mux2 (sum >=: (of_int ~width:32 100))
             (sum -: (of_int ~width:32 100))
             sum
         in

         let next_st = mux2 is_left.value next_st_l next_st_r in
         let zero32 = of_int ~width:32 0 in

         let cond_next_st_zero = (next_st ==: zero32) in
         let cond_wrap_l = is_left.value &: (curr_st <>: zero32) &: (next_st >: curr_st) in
         let cond_wrap_r = ~: (is_left.value) &: (next_st <: curr_st) in

         [
           when_ cond_next_st_zero [
             p1_ans <-- p1_ans.value +: (of_int ~width:32 1)
           ];

           p2_ans <-- p2_ans.value +: div_100 +: uresize (cond_next_st_zero |: cond_wrap_l |: cond_wrap_r) 32;
           st <-- next_st;
           state_machine.set_next Wait
         ]
      )
    ]
  ]);

  { Outputs.p1_ans = p1_ans.value; Outputs.p2_ans = p2_ans.value }
