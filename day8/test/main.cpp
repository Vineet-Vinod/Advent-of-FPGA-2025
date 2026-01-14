#include <iostream>
#include <fstream>
#include <string>
#include <cstdint>
#include "Vday08.h"
#include "verilated.h"

void tick(Vday08* top) {
    top->clock = 0; top->eval();
    top->clock = 1; top->eval();
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vday08* top = new Vday08;

    // Reset
    top->clear = 1;
    top->valid_in = 0;
    tick(top);
    top->clear = 0;
    tick(top);

    // Read and send inputs
    std::ifstream infile("day8/test/input.txt");
    if (!infile.good()) {
        std::cerr << "Error: Could not open input.txt" << std::endl;
        return 1;
    }

    long long cycle = 0;
    std::string line;
    while (std::getline(infile, line)) {
        line += "\n"; 
        for (char c : line) {
            top->char_in = (int)c;
            top->valid_in = 1;
            tick(top);
            cycle++;
        }
        tick(top); // Wait 1 cycle for hardware to store the point in RAM
    }
    
    top->valid_in = 0;
    tick(top);

    // Wait for finish
    const long long TIMEOUT = 50'000'000LL;

    std::cout << "Simulating..." << std::endl;
    while (!top->finished && cycle < TIMEOUT) {
        tick(top);
        cycle++;
    }
    std::cout << std::endl;

    if (cycle >= TIMEOUT) {
        std::cout << "TIMEOUT - took too long to run!" << std::endl;
    } else {
        std::cout << "Finished in " << cycle << " cycles." << std::endl;
    }

    // Compare results to golden model - Python script
    // Read in Python results
    std::ifstream py_res("day8/test/golden_results.txt");
    if (!py_res.good()) {
        std::cerr << "Error: Could not open golden_results.txt" << std::endl;
        return 1;
    }
    
    uint64_t expected_ans1 = 0;
    uint64_t expected_ans2 = 0;
    if (!(py_res >> expected_ans1 >> expected_ans2)) {
        std::cerr << "Error: Failed to read two 64-bit integers from golden_results.txt" << std::endl;
        return 1;
    }

    int fail = 0;
    if ((uint64_t)top->ans1 != expected_ans1) {
        std::cerr << "FAILED Part 1: Expected " << expected_ans1 
                    << " but got " << (uint64_t)top->ans1 << std::endl;
        fail = 1;
    } else {
        std::cout << "PASSED Part 1: HW - " << (uint64_t)top->ans1 << " and PY - " << expected_ans1 << std::endl;
    }

    if ((uint64_t)top->ans2 != expected_ans2) {
        std::cerr << "FAILED Part 2: Expected " << expected_ans2 
                    << " but got " << (uint64_t)top->ans2 << std::endl;
        fail = 1;
    } else {
        std::cout << "PASSED Part 2: HW - " << (uint64_t)top->ans2 << " and PY - " << expected_ans2 << std::endl;
    }

    delete top;
    return fail;
}
