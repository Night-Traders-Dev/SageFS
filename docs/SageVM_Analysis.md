# SageVM Repository Analysis

**Repository:** [Night-Traders-Dev/SageVM](https://github.com/Night-Traders-Dev/SageVM)

## Overview
SageVM is a pure SageLang implementation of the Sage Virtual Machine (SGVM), acting as a high-performance execution substrate for SageOS. It supports dual-architecture execution (Stack-based and Register-based) natively.

## Key Features
- **Unified CLI (`sagevm`)**: A single tool to compile (`sagevm compile`), run (`sagevm run`), disassemble (`sagevm dis`), and inspect (`sagevm hex`) binaries. It features automatic architecture detection via magic headers.
- **Dual Architecture Engine**:
  - **SVM (Stack Virtual Machine)**: Traditional variable-length bytecode architecture utilizing a 65,536-entry operand stack. Optimized for code density.
  - **SRVM (Sage RISC-V Virtual Machine)**: Modern RV64I-based register architecture with 32x64-bit registers. Uses fixed-width 32-bit instructions for high-speed dispatch, boasting a 30-40% improvement in interpretation overhead.
- **100% Opcode Parity**: Comprehensive support across 89 SVM opcodes and standard RV64I base instruction sets.
- **Delegation Bridge**: Facilitates guest-to-host delegation for system resources including GPU, I/O, and native modules.
- **OOP & Exception Handling**: Native support for classes, inheritance, and structured exception handling (`try/catch/finally`) across both architectural targets.
- **Performance Optimizations**: Recent iterations include interpreter hot-loop optimization, stack-based local variable caching, and state synchronization fixes.

## Project Structure
- `src/sgvm_cli.sage`: Unified Command Line Interface entry point.
- `src/svm/`: Source logic for the traditional Stack Virtual Machine, including `sgvm_compiler.sage`, `sgvm_core.sage`, `sgvm_vm.sage`, and disassembly/hexdump logic.
- `src/srvm/`: Source logic for the new RISC-V Register Virtual Machine, featuring the `srvm_compiler.sage`, `srvm_core.sage`, and `srvm_vm.sage`.

## Integration with SageFS
Integrating SageVM into SageFS allows us to produce portable compiled versions of the filesystem tools (like `mkfs.sagefs`, `mount.sagefs`, etc.) in both Stack (`.sgvm`) and Register (`.sgrv`) formats. We have added these compilation steps to `sagemake` using the `--build-vm-stack` and `--build-vm-riscv` flags, enabling the delivery of SageVM-compatible binaries alongside the standard native executables.
