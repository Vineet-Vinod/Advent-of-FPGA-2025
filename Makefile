day1:
	dune runtest day1

day1_synth: day1
	dune build day1/test/gen_verilog.exe
	./_build/default/day1/test/gen_verilog.exe
	yosys -p "synth_ecp5 -top day01; stat" _build/day01.v
	
day8:
	dune build day8/test/gen_verilog.exe
	./_build/default/day8/test/gen_verilog.exe
	verilator --cc day08.v --exe day8/test/main.cpp --top-module day08 -O3 -Wno-DEPRECATED -Wno-fatal -Wno-WIDTH -Wno-COMBDLY --Mdir _build/obj_dir
	make -j -C _build/obj_dir -f Vday08.mk
	python3 day8/test/day8_golden_solution.py day8/test/input.txt > day8/test/golden_results.txt
	./_build/obj_dir/Vday08
	rm -f day8/test/golden_results.txt

day8_synth: day08.v
	yosys -p "synth_ecp5 -top day08; stat" day08.v

.PHONY: day1 day1_synth day8 day8_synth
