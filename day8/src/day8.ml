open Core
open Hardcaml
open Signal
open Always

let systolic_queue_sz = 200 (* Larger sizes reduce execution cycles but increase resource usage*)
(* Safe assumption based on inputs *)
let max_points = 1024
let num_pts_bits = 10
let coord_bits = 20
let dist_bits = 48

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
    ans1 : 'a [@bits 64];
    ans2 : 'a [@bits 64];
    finished : 'a;
  } [@@deriving sexp_of, hardcaml]
end

module StateMachine = struct
  type t =
    | ParseNum1 | Wait1 | ParseNum2 | Wait2 | ParseNum3 | Store
    | InitUF
    | PreGen | Generate | GenerateFlush | DrainQueue
    | RAMWaitA | UFRootA | RAMWaitCompressA | UFCompressRootA
    | RAMWaitB | UFRootB | RAMWaitCompressB | UFCompressRootB
    | UFUnionWait | UFUnion | UFWriteSizeWait | UFWriteSize
    | ScanSizeWait | ScanSize
    | CalcAns2Wait | CalcAns2
    | Done
  [@@deriving sexp_of, compare, enumerate]
end

let create _scope (i : _ Inputs.t) =
  (* Registers *)
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let spec_reset = Reg_spec.create ~clock:i.clock () in
  let sm = State_machine.create (module StateMachine) spec in

  let num_buffer = Variable.reg spec ~width:coord_bits in
  let coord_x = Variable.reg spec ~width:coord_bits in
  let coord_y = Variable.reg spec ~width:coord_bits in
  let line_count = Variable.reg spec ~width:num_pts_bits in
  let total_nodes = Variable.reg spec ~width:num_pts_bits in

  let coord_wr_addr = Variable.reg spec ~width:num_pts_bits in
  let coord_wr_data = Variable.reg spec ~width:(3 * coord_bits) in
  let coord_wr_en = Variable.reg spec ~width:1 in
  let coord_rd_addr_a = Variable.reg spec ~width:num_pts_bits in
  let coord_rd_addr_b = Variable.reg spec ~width:num_pts_bits in

  (* RAM to store coordinates *)
  let coord_ram = Ram.create ~size:max_points ~collision_mode:Read_before_write
    ~write_ports:[| { write_clock=i.clock; write_address=coord_wr_addr.value; 
                      write_data=coord_wr_data.value; write_enable=coord_wr_en.value } |]
    ~read_ports:[| { read_clock=i.clock; read_address=coord_rd_addr_a.value; read_enable=vdd };
                   { read_clock=i.clock; read_address=coord_rd_addr_b.value; read_enable=vdd } |] ()
  in
  let data_a = coord_ram.(0) in
  let data_b = coord_ram.(1) in

  let gen_v1 = Variable.reg spec ~width:num_pts_bits in
  let gen_v2 = Variable.reg spec ~width:num_pts_bits in
  let dist_threshold = Variable.reg spec ~width:dist_bits in

  let pipe_v1 = Variable.reg spec ~width:num_pts_bits in
  let pipe_v2 = Variable.reg spec ~width:num_pts_bits in
  let pipe_valid = Variable.reg spec ~width:1 in

  (* Euclidean distance calculation *)
  let split_coords d = (select d 19 0, select d 39 20, select d 59 40) in
  let (x1, y1, z1) = split_coords data_a in
  let (x2, y2, z2) = split_coords data_b in
  let sq_diff a b = 
    let sa = uresize a 21 in
    let sb = uresize b 21 in
    let d = mux2 (sa >=: sb) (sa -: sb) (sb -: sa) in
    uresize (d *: d) dist_bits
  in
  let dist_calc = (sq_diff x1 x2) +: (sq_diff y1 y2) +: (sq_diff z1 z2) in

  let mode_drain = Variable.reg spec ~width:1 in

  (* Insert distances between points into systolic priority queue if larger than threshold *)
  let q_in_valid = pipe_valid.value &: (dist_calc >: dist_threshold.value) in
  let q_in_dist = mux2 q_in_valid dist_calc (ones dist_bits) in
  let q_in_v1 = pipe_v1.value in
  let q_in_v2 = pipe_v2.value in

  let infinity_spec = Reg_spec.override spec_reset ~clear_to:(ones dist_bits) in
  let zero_spec = Reg_spec.override spec_reset ~clear_to:(zero num_pts_bits) in

  (* Systolic priority queue -> distance, point 1, point 2 *)
  (* Latched values - reading *)
  let latch_dist = Array.init systolic_queue_sz ~f:(fun _ -> Variable.reg infinity_spec ~width:dist_bits) in
  let latch_v1 = Array.init systolic_queue_sz ~f:(fun _ -> Variable.reg zero_spec ~width:num_pts_bits) in
  let latch_v2 = Array.init systolic_queue_sz ~f:(fun _ -> Variable.reg zero_spec ~width:num_pts_bits) in

  (* Flow values - propagating through the queue *)
  let flow_dist = Array.init (systolic_queue_sz + 1) ~f:(fun _ -> wire dist_bits) in
  let flow_v1 = Array.init (systolic_queue_sz + 1) ~f:(fun _ -> wire num_pts_bits) in
  let flow_v2 = Array.init (systolic_queue_sz + 1) ~f:(fun _ -> wire num_pts_bits) in

  (* Union Find Data Structure *)
  let uf_rd_addr = Variable.reg spec ~width:num_pts_bits in
  let uf_wr_addr = Variable.reg spec ~width:num_pts_bits in
  let uf_wr_data = Variable.reg spec ~width:num_pts_bits in
  let uf_wr_en = Variable.reg spec ~width:1 in

  let size_wr_addr = Variable.reg spec ~width:num_pts_bits in
  let size_wr_data = Variable.reg spec ~width:num_pts_bits in
  let size_wr_en = Variable.reg spec ~width:1 in
  let size_rd_addr = Variable.reg spec ~width:num_pts_bits in

  let uf_parent_ram = Ram.create ~size:max_points ~collision_mode:Read_before_write
    ~write_ports:[| { write_clock=i.clock; write_address=uf_wr_addr.value; 
                      write_data=uf_wr_data.value; write_enable=uf_wr_en.value } |]
    ~read_ports:[| { read_clock=i.clock; read_address=uf_rd_addr.value; read_enable=vdd } |] ()
  in
  let uf_size_ram = Ram.create ~size:max_points ~collision_mode:Read_before_write
    ~write_ports:[| { write_clock=i.clock; write_address=size_wr_addr.value; 
                      write_data=size_wr_data.value; write_enable=size_wr_en.value } |]
    ~read_ports:[| { read_clock=i.clock; read_address=size_rd_addr.value; read_enable=vdd } |] ()
  in
  let parent_read = uf_parent_ram.(0) in
  let size_read = uf_size_ram.(0) in

  let current_v1 = Variable.reg spec ~width:num_pts_bits in
  let current_v2 = Variable.reg spec ~width:num_pts_bits in
  let root_a = Variable.reg spec ~width:num_pts_bits in
  let root_b = Variable.reg spec ~width:num_pts_bits in
  let curr_node = Variable.reg spec ~width:num_pts_bits in
  let path_node = Variable.reg spec ~width:num_pts_bits in
  let comp_count = Variable.reg spec ~width:num_pts_bits in
  let edges_processed = Variable.reg spec ~width:32 in
  let size_a = Variable.reg spec ~width:num_pts_bits in

  let scan_idx = Variable.reg spec ~width:num_pts_bits in
  (* Store the 3 biggest components to calculate the answer for part 1 *)
  let max1 = Variable.reg spec ~width:num_pts_bits in
  let max2 = Variable.reg spec ~width:num_pts_bits in
  let max3 = Variable.reg spec ~width:num_pts_bits in
  let ans1 = Variable.reg spec ~width:64 in
  let ans2 = Variable.reg spec ~width:64 in
  let ans1_done = Variable.reg spec ~width:1 in

  let ascii_comma = of_int ~width:8 (Char.to_int ',') in
  let ascii_newline = of_int ~width:8 (Char.to_int '\n') in
  let ascii_0 = of_int ~width:8 (Char.to_int '0') in

  let head_dist = latch_dist.(0).value in
  let head_v1 = latch_v1.(0).value in
  let head_v2 = latch_v2.(0).value in
  let head_valid = head_dist <: ones dist_bits in

  (* Systolic priority queue logic
     If filling - send bigger distances to the right
     If draining - read out to the left to get smallest distances first *)
  
  (* Initialize flow[0] with input value *)
  let () = flow_dist.(0) <== q_in_dist in
  let () = flow_v1.(0) <== q_in_v1 in
  let () = flow_v2.(0) <== q_in_v2 in

  (* Build the systolic array logic *)
  let systolic_logic = 
    let stmts = ref [] in
    for idx = 0 to systolic_queue_sz - 1 do
      let curr_dist = latch_dist.(idx).value in
      let curr_v1 = latch_v1.(idx).value in
      let curr_v2 = latch_v2.(idx).value in
      
      (* Incoming flow from left *)
      let incoming_dist = flow_dist.(idx) in
      let incoming_v1 = flow_v1.(idx) in
      let incoming_v2 = flow_v2.(idx) in
      
      (* Right neighbor for drain mode *)
      let right_dist = if idx = systolic_queue_sz - 1 then ones dist_bits else latch_dist.(idx + 1).value in
      let right_v1 = if idx = systolic_queue_sz - 1 then zero num_pts_bits else latch_v1.(idx + 1).value in
      let right_v2 = if idx = systolic_queue_sz - 1 then zero num_pts_bits else latch_v2.(idx + 1).value in

      (* Swap if incoming value is smaller than current (for min-priority queue) *)
      let swap = incoming_dist <: curr_dist in
      
      (* When filling: if swap, cell takes incoming and current flows right
         When draining: shift from right to left *)
      let next_dist = mux2 mode_drain.value right_dist (mux2 swap incoming_dist curr_dist) in
      let next_v1 = mux2 mode_drain.value right_v1 (mux2 swap incoming_v1 curr_v1) in
      let next_v2 = mux2 mode_drain.value right_v2 (mux2 swap incoming_v2 curr_v2) in
      
      (* Output flow: if swap, the larger value (current) flows right; otherwise incoming flows right *)
      let out_dist = mux2 swap curr_dist incoming_dist in
      let out_v1 = mux2 swap curr_v1 incoming_v1 in
      let out_v2 = mux2 swap curr_v2 incoming_v2 in
      
      (* Connect flow to next position *)
      let () = flow_dist.(idx + 1) <== out_dist in
      let () = flow_v1.(idx + 1) <== out_v1 in
      let () = flow_v2.(idx + 1) <== out_v2 in

      stmts := !stmts @ [
        if_ i.clear [
          latch_dist.(idx) <-- ones dist_bits;
          latch_v1.(idx) <-- zero num_pts_bits;
          latch_v2.(idx) <-- zero num_pts_bits
        ] [
          latch_dist.(idx) <-- next_dist;
          latch_v1.(idx) <-- next_v1;
          latch_v2.(idx) <-- next_v2
        ]
      ]
    done;
    !stmts
  in

  compile (systolic_logic @ [
    coord_wr_en <-- gnd;
    uf_wr_en <-- gnd;
    size_wr_en <-- gnd;
    mode_drain <-- gnd;
    pipe_valid <-- gnd;

    sm.switch [
      ParseNum1, [
        when_ i.valid_in [
          if_ (i.char_in ==: ascii_comma) [
            coord_x <-- num_buffer.value;
            num_buffer <-- zero coord_bits;
            sm.set_next Wait1
          ] @@ elif (i.char_in >=: ascii_0) [
            num_buffer <-- ((sll num_buffer.value 1) +: (sll num_buffer.value 3) +:
                           uresize (i.char_in -: ascii_0) coord_bits)
          ] []
        ];
        when_ ((~:(i.valid_in)) &: (line_count.value >: zero num_pts_bits)) [
          total_nodes <-- line_count.value;
          scan_idx <-- zero num_pts_bits;
          sm.set_next InitUF
        ]
      ];

      Wait1, [
        when_ i.valid_in [
          if_ (i.char_in >=: ascii_0) [
            num_buffer <-- uresize (i.char_in -: ascii_0) coord_bits;
            sm.set_next ParseNum2
          ] []
        ]
      ];

      ParseNum2, [
        when_ i.valid_in [
          if_ (i.char_in ==: ascii_comma) [
            coord_y <-- num_buffer.value;
            num_buffer <-- zero coord_bits;
            sm.set_next Wait2
          ] @@ elif (i.char_in >=: ascii_0) [
            num_buffer <-- ((sll num_buffer.value 1) +: (sll num_buffer.value 3) +:
                           uresize (i.char_in -: ascii_0) coord_bits)
          ] []
        ]
      ];

      Wait2, [
        when_ i.valid_in [
          if_ (i.char_in >=: ascii_0) [
            num_buffer <-- uresize (i.char_in -: ascii_0) coord_bits;
            sm.set_next ParseNum3
          ] []
        ]
      ];

      ParseNum3, [
        when_ i.valid_in [
          if_ (i.char_in ==: ascii_newline) [
            sm.set_next Store
          ] @@ elif (i.char_in >=: ascii_0) [
            num_buffer <-- ((sll num_buffer.value 1) +: (sll num_buffer.value 3) +:
                           uresize (i.char_in -: ascii_0) coord_bits)
          ] []
        ]
      ];

      Store, [
        coord_wr_addr <-- line_count.value;
        coord_wr_data <-- ((sll (uresize num_buffer.value 60) 40) |:
                          (sll (uresize coord_y.value 60) 20) |:
                          (uresize coord_x.value 60));
        coord_wr_en <-- vdd;
        line_count <-- line_count.value +: of_int ~width:num_pts_bits 1;
        num_buffer <-- zero coord_bits;
        sm.set_next ParseNum1
      ];

      InitUF, [
        uf_wr_addr <-- scan_idx.value;
        uf_wr_data <-- scan_idx.value;
        size_wr_addr <-- scan_idx.value;
        size_wr_data <-- of_int ~width:num_pts_bits 1;
        uf_wr_en <-- vdd;
        size_wr_en <-- vdd;
        scan_idx <-- scan_idx.value +: of_int ~width:num_pts_bits 1;

        when_ (scan_idx.value ==: total_nodes.value -: of_int ~width:num_pts_bits 1) [
          comp_count <-- total_nodes.value;
          gen_v1 <-- zero num_pts_bits;
          gen_v2 <-- of_int ~width:num_pts_bits 1;
          dist_threshold <-- zero dist_bits;
          sm.set_next PreGen
        ]
      ];

      PreGen, [
        coord_rd_addr_a <-- gen_v1.value;
        coord_rd_addr_b <-- gen_v2.value;
        sm.set_next Generate
      ];

      Generate, [
        coord_rd_addr_a <-- gen_v1.value;
        coord_rd_addr_b <-- gen_v2.value;
        pipe_v1 <-- gen_v1.value;
        pipe_v2 <-- gen_v2.value;
        pipe_valid <-- vdd;
        sm.set_next PreGen;

        if_ (gen_v2.value ==: total_nodes.value -: of_int ~width:num_pts_bits 1) [
          gen_v1 <-- gen_v1.value +: of_int ~width:num_pts_bits 1;
          gen_v2 <-- gen_v1.value +: of_int ~width:num_pts_bits 2;
          when_ (gen_v1.value ==: total_nodes.value -: of_int ~width:num_pts_bits 2) [
            sm.set_next GenerateFlush
          ]
        ] [
          gen_v2 <-- gen_v2.value +: of_int ~width:num_pts_bits 1
        ]
      ];

      GenerateFlush, [
        pipe_valid <-- gnd;
        sm.set_next DrainQueue
      ];

      DrainQueue, [
        if_ head_valid [
          mode_drain <-- vdd;
          current_v1 <-- head_v1;
          current_v2 <-- head_v2;
          dist_threshold <-- head_dist;
          curr_node <-- head_v1;
          uf_rd_addr <-- head_v1;
          sm.set_next RAMWaitA
        ] @@ elif (comp_count.value ==: of_int ~width:num_pts_bits 1) [
          sm.set_next Done
        ] [
          gen_v1 <-- zero num_pts_bits;
          gen_v2 <-- of_int ~width:num_pts_bits 1;
          sm.set_next Generate
        ]
      ];
      
      RAMWaitA, [
        sm.set_next UFRootA
      ];

      UFRootA, [
        (* If node's parent is node, then it is the root of the component *)
        if_ (parent_read ==: curr_node.value) [
          root_a <-- curr_node.value;
          path_node <-- current_v1.value;
          uf_rd_addr <-- current_v1.value;
          sm.set_next RAMWaitCompressA
        ] [
          curr_node <-- parent_read;
          uf_rd_addr <-- parent_read;
          sm.set_next RAMWaitA
        ]
      ];

      RAMWaitCompressA, [
        sm.set_next UFCompressRootA
      ];

      UFCompressRootA, [
        if_ (path_node.value ==: root_a.value) [
          curr_node <-- current_v2.value;
          uf_rd_addr <-- current_v2.value;
          sm.set_next RAMWaitB
        ] [
          uf_wr_addr <-- path_node.value;
          uf_wr_data <-- root_a.value;
          uf_wr_en <-- vdd;
          path_node <-- parent_read;
          uf_rd_addr <-- parent_read;
          sm.set_next RAMWaitCompressA
        ]
      ];
      
      RAMWaitB, [
        sm.set_next UFRootB
      ];

      UFRootB, [
        if_ (parent_read ==: curr_node.value) [
          root_b <-- curr_node.value;
          path_node <-- current_v2.value;
          uf_rd_addr <-- current_v2.value;
          sm.set_next RAMWaitCompressB
        ] [
          curr_node <-- parent_read;
          uf_rd_addr <-- parent_read;
          sm.set_next RAMWaitB
        ]
      ];

      RAMWaitCompressB, [
        sm.set_next UFCompressRootB
      ];
      
      UFCompressRootB, [
        if_ (path_node.value ==: root_b.value) [
          size_rd_addr <-- root_a.value;
          sm.set_next UFUnionWait
        ] [
          uf_wr_addr <-- path_node.value;
          uf_wr_data <-- root_b.value;
          uf_wr_en <-- vdd;
          path_node <-- parent_read;
          uf_rd_addr <-- parent_read;
          sm.set_next RAMWaitCompressB
        ]
      ];
      
      UFUnionWait, [
        sm.set_next UFUnion
      ];

      UFUnion, [
        edges_processed <-- edges_processed.value +: of_int ~width:32 1;
        if_ (root_a.value ==: root_b.value) [
          if_ ((edges_processed.value ==: of_int ~width:32 999) &: (~:(ans1_done.value))) [
            scan_idx <-- zero num_pts_bits;
            max1 <-- zero num_pts_bits;
            max2 <-- zero num_pts_bits;
            max3 <-- zero num_pts_bits;
            size_rd_addr <-- zero num_pts_bits;
            sm.set_next ScanSizeWait
          ] [
            sm.set_next DrainQueue
          ]
        ] [
          size_a <-- size_read;
          size_rd_addr <-- root_b.value;
          sm.set_next UFWriteSizeWait
        ]
      ];

      UFWriteSizeWait, [
        sm.set_next UFWriteSize
      ];
      
      UFWriteSize, (
        let size_b_val = size_read in
        let new_size = size_a.value +: size_b_val in
        [
        if_ (size_a.value >=: size_b_val) [
          uf_wr_addr <-- root_b.value;
          uf_wr_data <-- root_a.value;
          uf_wr_en <-- vdd;
          size_wr_addr <-- root_a.value;
          size_wr_data <-- new_size;
          size_wr_en <-- vdd
        ] [
          uf_wr_addr <-- root_a.value;
          uf_wr_data <-- root_b.value;
          uf_wr_en <-- vdd;
          size_wr_addr <-- root_b.value;
          size_wr_data <-- new_size;
          size_wr_en <-- vdd
        ];

        comp_count <-- comp_count.value -: of_int ~width:num_pts_bits 1;

        if_ ((edges_processed.value ==: of_int ~width:32 1000) &: (~:(ans1_done.value))) [
          scan_idx <-- zero num_pts_bits;
          max1 <-- zero num_pts_bits;
          max2 <-- zero num_pts_bits;
          max3 <-- zero num_pts_bits;
          size_rd_addr <-- zero num_pts_bits;
          sm.set_next ScanSize
        ] @@ elif (comp_count.value ==: of_int ~width:num_pts_bits 2) [
          coord_rd_addr_a <-- current_v1.value;
          coord_rd_addr_b <-- current_v2.value;
          sm.set_next CalcAns2Wait
        ] [
          sm.set_next DrainQueue
        ]
      ]);

      ScanSizeWait, [
        sm.set_next ScanSize
      ];

      ScanSize, (
        let sz = size_read in
        [
        if_ (sz >: max1.value) [
          max3 <-- max2.value;
          max2 <-- max1.value;
          max1 <-- sz
        ] @@ elif (sz >: max2.value) [
          max3 <-- max2.value;
          max2 <-- sz
        ] @@ elif (sz >: max3.value) [
          max3 <-- sz
        ] [];

        scan_idx <-- scan_idx.value +: of_int ~width:num_pts_bits 1;
        if_ (scan_idx.value ==: total_nodes.value -: of_int ~width:num_pts_bits 1) [
          ans1 <-- uresize ((uresize max1.value 64) *: (uresize max2.value 64) *: (uresize max3.value 64)) 64;
          ans1_done <-- vdd;
          (* Edge case: if number of components == 1 when the 1000 edge is connected *)
          if_ (comp_count.value ==: of_int ~width:num_pts_bits 1) [
            coord_rd_addr_a <-- current_v1.value;
            coord_rd_addr_b <-- current_v2.value;
            sm.set_next CalcAns2Wait
          ] [
            sm.set_next DrainQueue
          ]
        ] [
          size_rd_addr <-- scan_idx.value +: of_int ~width:num_pts_bits 1;
          sm.set_next ScanSizeWait
        ]
      ]);

      CalcAns2Wait, [
        sm.set_next CalcAns2
      ];

      CalcAns2, [
        ans2 <-- uresize ((uresize (select data_a 19 0) 32) *: (uresize (select data_b 19 0) 32)) 64;
        sm.set_next Done
      ];

      Done, []
    ]
  ]);

  { Outputs.
    ans1 = ans1.value;
    ans2 = ans2.value;
    finished = sm.is Done;
  }
