# Afton ABI v1

**Status:** Draft — v1, internal ABI for AftonJIT.
**Scope:** Internal calling convention for all JIT-generated code. The C FFI boundary (SysV-compatible layer) is **out of scope** and implemented separately.

---

## 1. Overview

Afton ABI is a deliberately simple, register-only calling convention designed for JIT code generation. It removes stack arguments, variadics, and platform-specific classification in favor of a fixed, uniform rule set. Functions with more than 6 user arguments are rejected at JIT compile time.

Key decisions:

- **Max 6 user arguments.** More → compile error.
- **All arguments in registers.** No stack-passed arguments in v1.
- **Fixed stack frame.** `RSP` does not move inside a function body.
- **Frame pointer always.** `RBP` is reserved as FP.
- **Scalars:** int/pointer → GPR; float/double → YMM (caller-saved).
- **Aggregates ≤32 bytes:** float fields → YMM (callee-saved); non-float fields → GPR.
- **Flat aggregates only.** Only scalar fields (`int`, `float`, `double`, pointers, bool, enum) are allowed inside aggregates. Nested aggregates and arrays inside aggregates → compile error.
- **Mixed aggregates allowed.** E.g. `struct { int a; float b; }` → `a` in a GPR, `b` in a YMM.
- **YMM naming.** All float/vector registers are referred to as `YMMn` (256-bit). The lower 128 bits are never referred to as `XMMn` in this document.
- **Callee-saved YMM pool.** `YMM6`–`YMM15` are callee-saved. Used registers are spilled in the prologue; unused are not touched. CFI per function marks each as saved/unchanged.
- **Fixed YMM spill area.** The frame reserves 10 × 32 = 320 bytes for YMM6–YMM15 spills (§5).

---

## 2. Register Model

### 2.1 General-purpose registers (GPR)

| Role | Registers |
|---|---|
| Argument registers | `R8`, `R9`, `R10`, `R11`, `R12`, `R13` (6 slots) |
| Caller-saved | `RDI`, `RBX`, `R8`–`R14` |
| Callee-saved | `RAX`, `RCX`, `RDX` |
| Frame pointer | `RBP` (always, never repurposed) |
| Reserved | `R14` (reserved for future use; not used in v1) |

> **Note:** This differs from SysV (where `RBX` and `R12`–`R15` are callee-saved and `R8`–`R11` are caller-saved). The FFI layer translates at the C boundary.

### 2.2 Float registers (YMM)

| Role | Registers | Saved by |
|---|---|---|
| Float scalar argument registers | `YMM0`–`YMM5` (6 slots) | caller |
| Aggregate float-field registers | `YMM6`–`YMM15` (10 slots) | callee |
| General-purpose float (scratch) | `YMM6`–`YMM15` (same physical registers) | callee (must spill if used) |

`YMM6`–`YMM15` are **callee-saved**. If the JIT register allocator uses one of them for scratch (outside aggregate field passing), it must spill it in the prologue and restore in the epilogue, exactly like `RAX`/`RCX`/`RDX`.

---

## 3. Argument Passing

### 3.1 Counters

Three independent slot counters:

- **GPR counter** — next free GPR from `R8`..`R13`.
- **YMM scalar counter** — next free YMM from `YMM0`..`YMM5` (for float scalars).
- **YMM aggregate counter** — next free YMM from `YMM6`..`YMM15` (for aggregate float fields).

### 3.2 Scalars

| Type class | Slots | Register |
|---|---|---|
| Integer, pointer, enum, bool, function pointer | 1 GPR | next free GPR (`R8`..`R13`) |
| `float`, `double` | 1 YMM | next free scalar YMM (`YMM0`..`YMM5`) |

### 3.3 Aggregates (`struct`, `union`, `array`)

A small aggregate is passed in registers iff:

- Total size **≤ 32 bytes**.
- Function has **≤ 3 user arguments** total.
- All fields are scalar — no nested aggregates, no arrays inside aggregates.
- Enough free GPR and YMM slots exist.

**Field-wise decomposition, in declaration order:**

- A `float` or `double` field → one YMM from `YMM6`..`YMM15` (aggregate YMM counter).
- Any other field (`int`, pointer, `bool`, `enum`, etc.) → one GPR chunk (8 bytes) from `R8`..`R13` (GPR counter).
- Fields smaller than 8 bytes still consume a full 8-byte GPR chunk (zero/sign-extended or bitcast; layout follows the source type).

If any condition fails → **compile error**.

**Example:** `struct Small { int a; float b; }` (8 bytes, fits):

- `a` → `R8`
- `b` → `YMM6`

### 3.4 Hidden arguments

Two hidden GPR arguments may be prepended, SysV-style:

**`sret`** — large aggregate return by value.

- Occupies the **first GPR slot** (`R8`).
- Shifts user GPR arguments to `R9`..`R13`.
- Does **not** shift YMM counters.

**`env`** — closure environment / C-callback context.

- Occupies the **next free GPR slot after `sret`** (or `R8` if no `sret`).
- Shifts user GPR arguments accordingly.
- Does **not** shift YMM counters.

### 3.5 Limits and interactions

- **Total user arguments ≤ 6** (GPR-class + YMM-class combined).
- **GPR slots** (including hidden `sret`/`env`) **≤ 6** (`R8`..`R13`).
- **Scalar YMM slots ≤ 6** (`YMM0`..`YMM5`).
- **Aggregate YMM slots ≤ 10** (`YMM6`..`YMM15`).

| Case | Max user GPR args | Max user scalar YMM args |
|---|---|---|
| No `sret`, no `env` | 6 (`R8`–`R13`) | 6 (`YMM0`–`YMM5`) |
| With `sret` | 5 (`R9`–`R13`) | 6 (`YMM0`–`YMM5`) |
| With `sret` + `env` | 4 (`R10`–`R13`) | 6 (`YMM0`–`YMM5`) |

Combined user argument count is still capped at 6.

---

## 4. Return Values

| Return type | Register |
|---|---|
| Integer, pointer, enum, bool | `RAX` |
| `float`, `double` | `YMM0` |
| Small aggregate (≤32 bytes) | field-wise: non-float fields → `RAX`, `RDX` (GPR, up to 2 chunks); float fields → `YMM0`, `YMM1` (scalar YMM, caller-saved) |
| Large aggregate | `sret` — caller passes buffer address in `R8`; callee writes and returns the same address in `RAX` |
| `void` | undefined (do not rely on `RAX`) |

Return-register YMMs are the **caller-saved scalar YMMs** (`YMM0`–`YMM1`), not the callee-saved aggregate pool. This keeps return independent of the callee-saved YMM discipline.

**v1 restriction:** a small aggregate returned in registers may contain at most **2 non-float 8-byte chunks** (`RAX`, `RDX`) and at most **2 float/double fields** (`YMM0`, `YMM1`). Larger mixed aggregates → use `sret`.

---

## 5. Frame Layout

Every function has a **fixed frame**, allocated in one instruction in the prologue. `RSP` does not move inside the function body.

### 5.1 Layout (top to bottom, growing downward)

```
        ...
  [rbp+8]     return address           (pushed by call)
  [rbp+0]     caller's RBP             (saved by prologue)
  [rbp-8]     spill RAX
  [rbp-16]    spill RCX
  [rbp-24]    spill RDX
  [rbp-32]    YMM spill area (10 × 32 = 320 bytes):
  [rbp-64]      slot for YMM6
  ...           ...
  [rbp-352]     slot for YMM15
  [rbp-360]   first local / sret buffer / temporary
  ...
  [rbp-FRAME_SIZE]                    (== RSP, fixed)
```

The YMM spill area is **always reserved** (320 bytes), even if the function uses no aggregate YMM registers. This keeps `FRAME_SIZE` and `RSP` uniform across functions. Only **used** YMM6–YMM15 slots are actually written; unused slots are padding. CFI (§8) marks each YMM slot as saved/unchanged per function.

### 5.2 Callee-saved spills

- **GPR:** `RAX`, `RCX`, `RDX` are **always spilled** to `[rbp-8]`, `[rbp-16]`, `[rbp-24]` in the prologue, restored in the epilogue.
- **YMM:** each of `YMM6`–`YMM15` that the function actually uses (for aggregate fields or as scratch) is spilled to its fixed slot `[rbp-32-32*i]` (i = 0..9) and restored in the epilogue. Unused ones are not touched.

### 5.3 `FRAME_SIZE`

```
FRAME_SIZE = round_up_16(24 + 320 + locals + sret_buffer + padding)
```

`FRAME_SIZE` is always a multiple of 16. The minimum frame (no locals, no sret) is `round_up_16(24 + 320) = 352` bytes.

> **Trade-off:** 352-byte minimum frame is large for deep recursion. If this is unacceptable, restrict the aggregate YMM pool to `YMM6`–`YMM9` (4 registers, 128-byte spill area, minimum frame 160 bytes) and forbid aggregates with more than 4 float/double fields. This is the only v1 knob; decide before implementation.

---

## 6. Prologue and Epilogue

### 6.1 Prologue

```asm
    endbr64                    ; CET/IBT, always emitted (see §9)
    push rbp
    mov  rbp, rsp
    sub  rsp, FRAME_SIZE       ; multiple of 16
    mov  [rbp-8],  rax         ; spill GPR callee-saved
    mov  [rbp-16], rcx
    mov  [rbp-24], rdx
    ; spill only used YMM6–YMM15:
    ; vmovups [rbp-32-32*i], ymmN   for each used ymmN
    ; body follows
```

### 6.2 Epilogue

```asm
    ; restore used YMM6–YMM15:
    ; vmovups ymmN, [rbp-32-32*i]
    mov  rax, [rbp-8]          ; restore GPR callee-saved
    mov  rcx, [rbp-16]
    mov  rdx, [rbp-24]
    mov  rsp, rbp              ; or `leave`
    pop  rbp
    ret
```

`leave` (= `mov rsp, rbp; pop rbp`) may replace the last three lines.

---

## 7. Stack Alignment

- On entry: `RSP % 16 == 8`.
- After `push rbp`: `RSP % 16 == 0`.
- After `sub rsp, FRAME_SIZE` (`FRAME_SIZE % 16 == 0`): `RSP % 16 == 0`.
- Before every `call`: `RSP % 16 == 0` ✓.
- After `mov rsp, rbp; pop rbp; ret`: caller observes `RSP % 16 == 0` ✓.

No `and rsp, -16` — frame is fixed and statically known.

---

## 8. Unwinding / CFI

A minimal `.eh_frame` FDE is generated per JIT function. Because the frame is uniform, most fields are constant; only the set of used YMM6–YMM15 slots varies.

The FDE describes:

- `RBP` saved at `[RBP]`;
- return address at `[RBP+8]`;
- `RSP == RBP` inside the function body;
- `RAX`, `RCX`, `RDX` saved at `[RBP-8]`, `[RBP-16]`, `[RBP-24]`;
- for each `YMM6`–`YMM15`: either "saved at `[RBP-32-32*i]`" or "unchanged" (per function).

Registration: `__register_frame` (Linux/macOS). Windows `RtlAddFunctionTable` deferred.

---

## 9. CET / IBT

`endbr64` is emitted at the start of every JIT function and at every indirect call target.

---

## 10. Bytecode VReg Mapping

In Afton bytecode, argument positions are encoded as virtual registers:

| Bytecode | Opcode |
|---|---|
| `ARG1` | `0x1A` |
| `ARG2` | `0x2A` |
| `ARG3` | `0x3A` |
| `ARG4` | `0x4A` |
| `ARG5` | `0x5A` |
| `ARG6` | `0x6A` |

These are **positions**, not registers. Position `n` (`ARGn`) maps to physical registers based on the type class and preceding hidden arguments.

### 10.1 Scalar arguments

| Bytecode | int/pointer scalar | float/double scalar |
|---|---|---|
| `ARG1` (`0x1A`) | `R8` | `YMM0` |
| `ARG2` (`0x2A`) | `R9` | `YMM1` |
| `ARG3` (`0x3A`) | `R10` | `YMM2` |
| `ARG4` (`0x4A`) | `R11` | `YMM3` |
| `ARG5` (`0x5A`) | `R12` | `YMM4` |
| `ARG6` (`0x6A`) | `R13` | `YMM5` |

Counters are independent: a mixed signature follows the GPR and YMM scalar counters, not the table rows.

### 10.2 Aggregate arguments

An aggregate at position `ARGn` is decomposed **field-wise, in declaration order**:

- each `float`/`double` field → next free `YMM6`..`YMM15`;
- each other field → next free GPR chunk from `R8`..`R13`.

The aggregate's starting position in the GPR/YMM aggregate counters depends on how many GPR/YMM slots preceding arguments consumed.

**Example:** `fn f(struct Small s)` where `struct Small { int a; float b; int c; }`:

- `a` → `R8`
- `b` → `YMM6`
- `c` → `R9`

**Example:** `fn f(int x, struct Small s)` where `struct Small { float a; float b; }`:

- `x` → `R8`
- `a` → `YMM6`
- `b` → `YMM7`

### 10.3 Hidden arguments shift (GPR only)

| Hidden args | `ARG1` GPR | `ARG2` GPR | `ARG3` GPR |
|---|---|---|---|
| none | `R8` | `R9` | `R10` |
| `sret` | `R9` | `R10` | `R11` |
| `sret` + `env` | `R10` | `R11` | `R12` |

YMM counters are **not shifted** by hidden arguments.

### 10.4 Example with aggregate + scalar float

`fn f(struct Small s, float x)` where `struct Small { int a; float b; }`:

- `s.a` → `R8`
- `s.b` → `YMM6`
- `x` → `YMM0` (scalar YMM counter, independent)

---

## 11. Out of Scope for v1

| Feature | Status |
|---|---|
| Stack-passed arguments (>6) | Compile error in v1; FFI layer handles SysV stack args |
| Variadic functions | Not supported in v1; FFI layer |
| Register save area (variadic) | Not supported in v1 |
| Windows x64 ABI (shadow space, home space) | Deferred |
| Tail calls | Not supported in v1; forbidden at IR level |
| GC stack maps | Not present (no GC) |
| TLS | Not used in v1 |
| Red zone (128 bytes below `RSP`) | Not used; signal-safe |
| `i128`, `long double`, SIMD vectors as scalar args | Forbidden in v1 |
| Nested aggregates / arrays inside aggregates | Forbidden in v1 (flat aggregates only) |
| Full SysV classification | FFI layer only |

---

## 12. Reference Signature Examples

| Signature | Mapping |
|---|---|
| `fn f(int a, int b, int c)` | `R8`, `R9`, `R10` |
| `fn f(float x, float y)` | `YMM0`, `YMM1` |
| `fn f(int a, float x)` | `R8`, `YMM0` |
| `fn f(int a, int b, int c, int d, int e, int f)` | `R8`–`R13` |
| `fn f(int a, int b, int c, int d, int e, int f, int g)` | **compile error** (7 args) |
| `fn f(struct S s)` where `S { int a; int b; }` | `a`→`R8`, `b`→`R9` |
| `fn f(struct S s)` where `S { float a; float b; }` | `a`→`YMM6`, `b`→`YMM7` |
| `fn f(struct S s)` where `S { int a; float b; int c; }` | `a`→`R8`, `b`→`YMM6`, `c`→`R9` |
| `fn f(struct S s, int x)` where `S { int a; float b; }` | `a`→`R8`, `b`→`YMM6`, `x`→`R9` |
| `fn f(struct S s, int x, int y)` where `S` is 32 bytes all-int | `s`→`R8`–`R11`, `x`→`R12`, `y`→`R13` |
| `fn f(struct S s, int x, int y, int z)` where `S` is 32 bytes | **compile error** (4 user args with aggregate) |
| `fn f(struct Big b)` where `b` is 64 bytes | `&buf`→`R8` (sret); return `R8` in `RAX` |
| `fn f(struct Big b, int a)` where `b` is 64 bytes | `&buf`→`R8` (sret), `a`→`R9` |
| `fn callback(env: *mut (), int a, int b)` | env→`R8`, `a`→`R9`, `b`→`R10` |
| `fn f(struct S s)` where `S { int a; struct T t; }` | **compile error** (nested aggregate) |

---

## 13. Implementation Checklist

1. **Argument dispatcher**
   - Three counters: GPR (`R8`..`R13`), scalar YMM (`YMM0`..`YMM5`), aggregate YMM (`YMM6`..`YMM15`).
   - Reject >6 user arguments.
   - Reject aggregates >32 bytes, nested aggregates, arrays inside aggregates.
   - Reject aggregates when total user args > 3.
   - Handle `sret` (first GPR slot) and `env` (next free GPR slot); they do not shift YMM counters.
   - Decompose aggregate field-wise: float/double → aggregate YMM; everything else → GPR chunk.

2. **Return generator**
   - Scalar → `RAX` / `YMM0`.
   - Small aggregate → non-float fields in `RAX`,`RDX`; float fields in `YMM0`,`YMM1` (v1 limit: ≤2 of each).
   - Large aggregate → `sret` pointer in `R8`, return same pointer in `RAX`.

3. **Prologue generator**
   - `endbr64`, `push rbp`, `mov rbp, rsp`, `sub rsp, FRAME_SIZE`.
   - Spill `RAX`, `RCX`, `RDX` to `[rbp-8]`, `[rbp-16]`, `[rbp-24]`.
   - Spill used `YMM6`–`YMM15` to `[rbp-32-32*i]`.
   - `FRAME_SIZE` multiple of 16.

4. **Epilogue generator**
   - Restore used `YMM6`–`YMM15`.
   - Restore `RAX`, `RCX`, `RDX`.
   - `mov rsp, rbp` (or `leave`), `pop rbp`, `ret`.

5. **CFI emitter**
   - One `.eh_frame` FDE per function.
   - GPR spills fixed; YMM slots marked saved/unchanged per function.
   - Register via `__register_frame`.

6. **CET**
   - `endbr64` at function entry and every indirect call target.

---

## Appendix A: Register Summary

| Register | Afton v1 Role | Saved by |
|---|---|---|
| `RAX` | callee-saved, return value (GPR) | callee |
| `RBX` | general purpose | caller |
| `RCX` | callee-saved | callee |
| `RDX` | callee-saved, 2nd return GPR | callee |
| `RDI` | general purpose | caller |
| `RBP` | **frame pointer (always)** | callee |
| `RSP` | stack pointer | ABI contract |
| `R8`–`R13` | argument registers | caller |
| `R14` | **reserved** (not used in v1) | caller |
| `R15` | general purpose | caller |
| `YMM0`–`YMM5` | float scalar argument registers | caller |
| `YMM6`–`YMM15` | aggregate float-field registers (and callee-saved scratch) | callee |

