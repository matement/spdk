# SPDK GPU Doorbell — Build, Run & Notes

Personal notes for the GPU doorbell work in my SPDK fork (github.com/matement/spdk).

## Status

### Nov 12, 2026 (shuttle6, after the system update)

- SPDK is now `v26.09-pre` with DPDK 26.03.0. The full build (lib, modules, examples) completes with the fixes listed under "Build".
- `libspdk_nvme.a` contains `gpu_nvme_doorbell.o` and `gpu_qpair.o`. `hello_world` contains the `gpu_qpair: cudaHostRegister(SQ/CQ) failed` messages, so the SQ/CQ registration code is linked in.
- The hardware on shuttle6 changed since October. NVMe devices now: KIOXIA EXCERIA PLUS G4 (`0000:06:00.0`, boot disk, mounted at `/`, never touch) and Lexar NM790 4TB (`0000:19:00.0`). The Samsung at `0000:43:00.0` is no longer listed.
- The Lexar had an old RAID member signature and a GPT on it. After wiping them, `setup.sh` bound it to `vfio-pci`. `gpu_qpair_test` ran fine on it on Nov 12 (steps and expected output: "5. Run gpu_qpair_test"; paste the real output there).

### Oct 2, 2026 (shuttle6, Samsung `0000:43:00.0`)

**Working on real hardware.** The GPU rings the NVMe doorbells, and with `iofilespdk` the GPU also fills the data buffer:

- `hello_world`: attaches the drive, writes and reads back. Passes.
- `iofilespdk`, 16-byte text file: `diff` MATCH, identical SHA-256.
- `iofilespdk`, 8 MB random file: `cmp` MATCH. The write took ~2 ms and the read ~1.2 ms. The I/O is split into many NVMe commands, so many GPU doorbell rings.

This works **across sockets**: the GPU (`0000:6f:00.0`, NUMA 1, root complex `pci0000:6e`) and the NVMe (`0000:43:00.0`, NUMA 0, root complex `pci0000:42`) sit on different CPUs, and the GPU's MMIO writes still reach the drive.

Not done yet: the submission/completion queues and the data path for normal SPDK I/O still live in host memory. The GPU only rings the doorbells (and, in `iofilespdk`, fills the buffer). Bulk GPU↔NVMe data transfer, where cross-socket placement matters for speed, is untested.

## How it works

Normally the CPU rings an NVMe doorbell with a plain store to a register in BAR0. Here the GPU does that store.

1. `lib/nvme/nvme_pcie.c`, in `nvme_pcie_ctrlr_allocate_bars` (~line 788): after SPDK maps BAR0, the first doorbell page is registered with CUDA (`cudaHostRegister(..., cudaHostRegisterIoMemory)`). `cudaHostGetDevicePointer` then gives a GPU-visible pointer, stored in `pctrlr->gpu_doorbell_base`. On 64-bit systems with unified addressing it equals the host address.
2. `lib/nvme/nvme_pcie_common.c` (~line 234): each queue pair gets `gpu_sq_tdbl` / `gpu_cq_hdbl`, computed from `gpu_doorbell_base` the same way SPDK computes the normal CPU pointers.
3. `lib/nvme/nvme_pcie_internal.h` (~lines 275, 298): the SQ tail and CQ head doorbell rings call `gpu_mmio_write(...)` instead of writing from the CPU.
4. `lib/nvme/gpu_nvme_doorbell.cu`: `gpu_mmio_write` launches a 1-block, 1-thread kernel that does `*dbl = val;`, then `cudaDeviceSynchronize()`.
5. `lib/nvme/gpu_funcs.h`: C-compatible declaration of `gpu_mmio_write`.

The registration code that works:

```c
size_t dbl_size = 0x1000;   /* first doorbell page only, see "MSI-X" below */

(void)*(volatile uint32_t *)pctrlr->doorbell_base;   /* fault the page in, see "lazy mapping" below */

cudaError_t err = cudaHostRegister((void*)pctrlr->doorbell_base, dbl_size, cudaHostRegisterIoMemory);
printf("cudaHostRegister(%p, 0x%zx): %s\n", (void *)pctrlr->doorbell_base, dbl_size, cudaGetErrorString(err));

err = cudaHostGetDevicePointer((void**)&pctrlr->gpu_doorbell_base, (void*)pctrlr->doorbell_base, 0);
printf("cudaHostGetDevicePointer: %s -> %p\n", cudaGetErrorString(err), (void *)pctrlr->gpu_doorbell_base);
```

### SQ/CQ work (`gpu_qpair`, in progress)

- `lib/nvme/gpu_qpair.cu` defines `gpu_qpair_fill`, `gpu_read_one_host`, `translate_to_gpu`, `gpu_read_one` and `gpu_complete_one`. Only `gpu_mmio_write`, `gpu_qpair_fill`, `gpu_read_one_host` and `translate_to_gpu` have plain C symbol names; `gpu_read_one` and `gpu_complete_one` are C++-mangled (`_Z12gpu_read_one9gpu_qpairtmm`, `_Z16gpu_complete_one9gpu_qpairt`). Any C caller of the mangled ones needs `extern "C"` on the declaration and definition, or an undefined reference results.
- The SQ and CQ are registered with `cudaHostRegister` with the messages `gpu_qpair: cudaHostRegister(SQ) failed: %s` and `(CQ)`. SQ/CQ are normal host DMA memory (use the mapped flag, not `cudaHostRegisterIoMemory`, which is for BAR MMIO only).
- Test program: `examples/nvme/gpu_qpair_test/gpu_qpair_test.c` (steps under "5. Run gpu_qpair_test"). It ran fine on the Lexar on Nov 12.

## The three bugs it took to get here

### 1. Registering the wrong pointer

The first version registered `gpu_doorbell_base`, which is still NULL at that point. It must register `doorbell_base`, the real BAR mapping. Both CUDA calls failed silently because their return values weren't checked.

### 2. MSI-X table inside the registered range

The original size was "everything from the first doorbell to the end of BAR0" (`regs_size - 0x1000` = 0x3000). On the Samsung drive, `lspci -vv` shows:

```
MSI-X: Vector table: BAR=0 offset=00003000
       PBA:          BAR=0 offset=00002000
```

vfio protects the MSI-X table, so DPDK maps BAR0 around it, and CUDA rejects a range that includes those pages ("invalid argument"). Fix: register only the first doorbell page (0x1000–0x1FFF). With a 4-byte stride, one page holds doorbells for 512 queue pairs.

### 3. vfio maps BAR pages lazily

Even one clean page failed with "invalid argument". vfio's `mmap` only records the range; the real page-table entry is created on the first access (page fault → vfio fills it in). `cudaHostRegisterIoMemory` looks up the physical address by reading the process page tables, but it can't fault the page in itself. SPDK hadn't touched the doorbell page yet at that point, so CUDA found an empty entry.

Fix: read the page once before registering. `volatile` stops the compiler from removing the "useless" read; the value is junk (doorbells are write-only) and thrown away. If you ever register more than one page, touch every page.

Stock SPDK never hits this because the CPU's own first doorbell write faults the page in.

### How each bug showed up

All three gave the same symptom: `Xid 31 ... MMU Fault ... faulted @ 0x0_00000000 ... ACCESS_TYPE_VIRT_WRITE` in dmesg, plus `Initialization timed out in state 22 (wait for identify controller)`. Write to address 0 = the GPU got a NULL doorbell pointer = registration failed. The init timeout follows because the drive never sees the doorbell for its first admin command.

## Build

From the SPDK root (`~/spdk-build/spdk`).

### Configure

```
./configure --with-cuda --disable-unit-tests --disable-tests
grep -E "CONFIG_CUDA|CONFIG_UNIT_TESTS|CONFIG_TESTS" mk/config.mk
```

- `--with-cuda` sets `CONFIG_CUDA=y`. Without it the `.cu → .o` rule in `mk/spdk.common.mk` is skipped and `gpu_mmio_write` is never compiled.
- `--disable-unit-tests --disable-tests`: needed where CUnit is missing. `lib/ut` is built if *either* is enabled.
- If you see paths like `/home/mateo/spdk/...` in errors, `mk/config.mk` is stale. Rerun `./configure` from the current folder.
- `--without-nvme-cuse` exists if `libfuse3-dev` is ever missing. `--without-iscsi-initiator` only controls the iscsi bdev module (needs libiscsi), not `lib/iscsi`.

### System packages (Debian/Ubuntu)

The full list SPDK wants is in `scripts/pkgdep/debian.sh` / `ubuntu.sh` (do not run `pkgdep.sh` itself; it needs root and installs everything). Check what is missing without root:

```
for p in libaio-dev libkeyutils-dev libfuse3-dev libssl-dev libjson-c-dev uuid-dev libncurses5-dev libnuma-dev nasm libcunit1-dev libcmocka-dev libiscsi-dev systemtap-sdt-dev patchelf; do dpkg -s $p >/dev/null 2>&1 || echo "missing: $p"; done
```

- Real blockers on shuttle6: `libaio-dev` (`linux_aio_mgr.c`: `libaio.h` missing) and `libkeyutils-dev` (`module/keyring/linux/keyring.c`: `keyutils.h` missing). Install with `sudo apt-get install`; preview first with `apt-get -s install ...`.
- `libjson-c-dev` was also missing and may be needed by newer SPDK.
- Avoidable with flags: `libncurses5-dev` (`spdk_top`, `--disable-apps`), `libcunit1-dev` and `libcmocka-dev` (unit tests), `libiscsi-dev` (iscsi initiator bdev), `systemtap-sdt-dev` (`--with-usdt`).
- `libfuse3-dev` is installed. A `pkg-config` "not found" earlier was a trailing-dot typo (`fuse3.`), not a missing package.

### glibc 2.36+ clash in `lib/iscsi/iscsi.c`

`error: static declaration of 'arc4random' follows non-static declaration`. glibc ≥ 2.36 declares `arc4random` in `<stdlib.h>`, and SPDK's own static fallback (line ~69) collides with it. There is only one call site (line ~92). Fix: rename the static function and its single caller to the same new, SPDK-specific name. Check with `grep -n arc4random lib/iscsi/*.c` and `git diff lib/iscsi/iscsi.c`.

### GPU architecture

CUDA 13 dropped Volta and older, so sm_75 is the minimum. The RTX 4000 is Turing = 7.5.

**Pass it on the make command line, not with `export`.** `module/accel/cuda/Makefile` has `CUDA_ARCH = 70` (plain assignment), which overrides environment variables but not command-line variables. Alternatively change that line to `CUDA_ARCH ?= 75`.

### Build

```
./error_catcher.sh -j$(nproc) CUDA_ARCH=75
cat build_errors.txt        # no file = clean build
```

Only the NVMe library:

```
./error_catcher.sh -C lib/nvme -j$(nproc) CUDA_ARCH=75
```

`make lib` at the top level does NOT work (SPDK passes the target into every subdirectory). Use `-C`.

`make -j` stops at the first failure and prints "Waiting for unfinished jobs", so several different errors can be hidden behind the first one. Fix, rebuild, repeat. After changing `./configure` flags run `make clean` first.

`iofilespdk` isn't in `examples/bdev/Makefile`, so build it separately. `gpu_fill.o` must be built first:

```
cd examples/bdev/iofilespdk
make clean
make gpu_fill.o && make
cd ../../..
```

The binaries end up in `build/examples/hello_world` and `build/examples/iofilespdk`.

### Verify

```
nm build/lib/libspdk_nvme.a | grep " T gpu_mmio_write"    # T = defined
strings build/examples/hello_world | grep "cudaHostRegister("
```

## Run (shuttle6)

### 0. Pick the drive

Never pass a drive that holds the OS. Always set `PCI_ALLOWED` to one address.

```
lspci -nn | grep -i 'non-volatile'
lsblk -o NAME,SIZE,MODEL,MOUNTPOINTS
cat /proc/mdstat
```

Addresses change between updates and reboots, so re-check each time. Match on model and size, and check that the drive has no mount points.

### 1. Make `setup.sh` work (NFS home)

`scripts/setup.sh` silently exits 1 when run with sudo from the NFS home (root can't read it; `rootdir` ends up as `/..`, and `sudo` reports "Permission denied" when executing a file there). Copy what it needs to local disk, keeping the layout, and run it from there:

```
mkdir -p /tmp/mmentolli-spdk/spdk/include/spdk
cp -r scripts /tmp/mmentolli-spdk/spdk/
cp include/spdk/pci_ids.h /tmp/mmentolli-spdk/spdk/include/spdk/
cd /tmp/mmentolli-spdk/spdk
sudo ./scripts/setup.sh status
```

If a different file is reported missing, `sudo bash -x ./scripts/setup.sh status 2>&1 | tail -30` shows the last command before it exited; copy that file too.

### 2. Free the drive and bind it

`setup.sh` refuses to rebind a drive that has a mount or any signature (`Active devices: mount@...` / `data@...`). This protects boot disks. For a test drive that is disposable:

```
sudo wipefs /dev/nvme1n1
sudo wipefs -a /dev/nvme1n1
```

The first command only lists signatures. `wipefs -a` erases them and is destructive: do it only when the contents don't matter. If an md array is holding the drive, `sudo mdadm --stop /dev/md0` releases it (this erases nothing; `/dev/md0` may already be gone).

Then bind only that drive:

```
PCI_ALLOWED="0000:19:00.0" sudo -E ./scripts/setup.sh
sudo ./scripts/setup.sh status
```

The target should show `vfio-pci` and the boot disk should still show `nvme` with its mounts. `setup.sh` also sets hugepages. To set them by hand:

```
echo 1024 | sudo tee /proc/sys/vm/nr_hugepages
grep Huge /proc/meminfo      # HugePages_Total: 1024
mount | grep huge            # hugetlbfs on /dev/hugepages
```

### 3. Copy everything to /tmp

Root can't read `/home1` (NFS root squash), so anything run with sudo must live elsewhere. Copy as your own user, not with sudo:

```
mkdir -p /tmp/mmentolli-spdk
\cp -f build/examples/hello_world build/examples/iofilespdk /tmp/mmentolli-spdk/
\cp -f examples/bdev/iofilespdk/test1.txt /tmp/mmentolli-spdk/
cp nvme_bdev.json /tmp/mmentolli-spdk/nvme_bdev_shuttle6.json
grep -n traddr /tmp/mmentolli-spdk/nvme_bdev_shuttle6.json
```

- `nvme_bdev.json` in the SPDK root has `0000:19:00.0`, which matches the Lexar. Only edit `traddr` if the drive moves. The old `sed` to `0000:43:00.0` was for the Samsung and is wrong now.
- `\cp -f` bypasses an `cp -i` alias, which otherwise prompts and can leave an old binary in place.
- Check nothing points back into the home folder: `ldd /tmp/mmentolli-spdk/iofilespdk | grep -E "home1|not found"`.
- Build and copy in one go, so a failed build never copies: `./error_catcher.sh -j$(nproc) CUDA_ARCH=75 && \cp -f build/examples/hello_world /tmp/mmentolli-spdk/`

### 4. Run

Keep `sudo dmesg -w` open in another terminal. Run from inside `/tmp/mmentolli-spdk`, because `iofilespdk` writes `readback.bin` to the current directory.

```
cd /tmp/mmentolli-spdk

sudo ./hello_world -r 'trtype:PCIe traddr:0000:19:00.0'

sudo ./iofilespdk -f test1.txt -b Nvme0n1 -c nvme_bdev_shuttle6.json
diff test1.txt readback.bin && echo MATCH

head -c 8M /dev/urandom > big.bin
sudo ./iofilespdk -f big.bin -b Nvme0n1 -c nvme_bdev_shuttle6.json
cmp big.bin readback.bin && echo MATCH
```

Expected: the two `cudaHost...` lines say `no error`, the device pointer is a real address, and the comparison prints MATCH.

`hello_world` and `iofilespdk` write from block 0. Only use a drive whose contents are disposable.

To give the drive back to the kernel afterwards: `cd /tmp/mmentolli-spdk/spdk && sudo ./scripts/setup.sh reset`. The wiped Lexar will then reappear as an empty `/dev/nvme1n1`.

### 5. Run gpu_qpair_test

`examples/nvme/gpu_qpair_test/gpu_qpair_test.c` is `hello_world` plus a GPU-driven read. What it does, in order:

1. Attaches the controller and allocates two I/O qpairs: a normal one and a second one for the GPU.
2. `gpu_qpair_fill` reads the second qpair's queue size, SQ tail, CQ head, phase bit, SQ/CQ memory addresses and doorbell pointers, and the test prints them. `translate_to_gpu` registers the SQ and CQ memory with CUDA and the test prints the addresses again (`after registration`).
3. The CPU writes `Hello world!` to LBA 0 and reads it back through the normal qpair. This confirms the drive works before the GPU is involved.
4. The GPU reads LBA 0 into a separate DMA buffer through the second qpair (`gpu_read_one_host`, command id 1). The test waits up to 1 s for the buffer to change, then prints `GPU read: '...'` and the completion entry (`cid`, phase `p`, `sct`, `sc`).
5. A loop of 600 iterations: zero the buffer, issue a GPU read with command id n+1, compare with `Hello world!`. It stops at the first mismatch and prints `loop stopped at iteration N of 600`. If 600 is larger than the queue size from the `size=` line, the loop also covers SQ tail / CQ head wrap-around and the phase bit flipping.

It writes `Hello world!` to LBA 0 of the drive, so only run it on a disposable drive.

Build and copy:

```
make -C examples/nvme/gpu_qpair_test CUDA_ARCH=75
ldd build/examples/gpu_qpair_test | grep -E "home1|not found"
\cp -f build/examples/gpu_qpair_test /tmp/mmentolli-spdk/
```

Run (the drive must already be bound, see steps 1 and 2; keep `sudo dmesg -w` open in another terminal):

```
cd /tmp/mmentolli-spdk
sudo ./gpu_qpair_test -r 'trtype:PCIe traddr:0000:19:00.0'
```

Always pass `-r`, so it can't probe other devices.

**Pass criteria:**

- `Attached to 0000:19:00.0`, then a `Namespace ID` line.
- A `size=... sq_tail=... cq_head=... phase=...` line, with non-NULL `cmd`, `cpl` and doorbell pointers, and an `after registration` line with GPU-usable `cmd`/`cpl` pointers.
- `Hello world!` (the CPU round trip).
- `GPU read: 'Hello world!'` and a completion line with `cid=1`, `sct=0`, `sc=0`.
- `loop stopped at iteration 600 of 600`.
- No `Xid 31` / MMU fault in `dmesg`.

**If it fails:**

| Output | Meaning / where to look |
|---|---|
| `gpu_qpair_fill failed: <rc>` | Queue info couldn't be read from the second qpair; check that the library has the GPU fields (`gpu_qpair.cu`, `nvme_pcie_common.c`). |
| `translate_to_gpu failed: <rc>`, or `gpu_qpair: cudaHostRegister(SQ) failed: ...` / `(CQ)` | CUDA rejected the SQ/CQ memory. Copy the exact text after `failed:`, plus how the memory was allocated (alignment, flags). |
| `gpu_read_one_host failed: <rc>` / `wrapper failed at N` | The GPU submission failed to launch or complete; check `dmesg` and add `cudaGetLastError()` after the launch. |
| `GPU read: ''` with an all-zero completion | The read never completed within 1 s: the doorbell wasn't seen or the CQ wasn't updated. |
| `sct`/`sc` not 0 | The drive returned an NVMe error for the read (e.g. a bad data address). |
| `iteration N: wrong data ... (tail= head= phase=)` | Data or completion mismatch at iteration N. Compare `tail`, `head` and `phase` against the queue `size=`; a failure near the queue size points at wrap-around handling. |
| `Xid 31 ... faulted @ 0x0` | The GPU used a NULL pointer: a registration failed earlier. |

## Open items

- **Check the kernel launch** in `gpu_mmio_write`: `cudaGetLastError()` after the launch and the return value of `cudaDeviceSynchronize()`. Otherwise a failed launch looks exactly like a lost doorbell.
- **Fail early on registration errors**: return `-1` from `nvme_pcie_ctrlr_allocate_bars` instead of continuing with a NULL pointer.
- **Robust `dbl_size`**: number of queue pairs × 2 × stride (`CAP.DSTRD`), rounded up to a page, and never reaching the lowest MSI-X offset. Touch every page.
- **`cudaHostUnregister`** when the BAR is unmapped.
- **`iofilespdk` read print**: `read_complete` prints the buffer with `%s`. Binary data may have no terminating zero, so it can read past the buffer. Limit it with `%.*s` or skip it for binary files.
- **`iofilespdk.c` line ~63**: `SPDK_NOTICELOG("Couldnt open readback.bin\n", context->file_size);` passes an argument the format string never uses (`-Wformat-extra-args`). Remove the argument or add the matching specifier.
- **Add `iofilespdk` to `examples/bdev/Makefile`** (`DIRS-y`) and wire `gpu_fill.o` into its dependencies.
- **`gpu_qpair` symbols**: decide which of `gpu_read_one` / `gpu_complete_one` are called from C and give them `extern "C"` linkage.
- **Performance**: one kernel launch + sync per doorbell. Measure it; BaM avoids this with a persistent kernel.
- **Next BaM step**: move SQ/CQ into GPU-accessible memory so the GPU builds commands, not just announces them.
- **Same-socket placement** for bulk P2P: ask whether a GPU or NVMe can be moved to the same socket on shuttle6.

## Unit tests

Unit tests compile only the file under test (`C_SRCS = $(TEST_FILE)` in `mk/spdk.unittest.mk`), so they can't see the `.cu` object. Add a stub next to the other `DEFINE_STUB` lines in:

- `test/unit/lib/nvme/nvme_pcie_common.c/nvme_pcie_common_ut.c`
- `test/unit/lib/nvme/nvme_pcie.c/nvme_pcie_ut.c`

```c
DEFINE_STUB_V(gpu_mmio_write, (volatile uint32_t *dbl, uint32_t val));
```

## Common problems

| Symptom | Cause / fix |
|---|---|
| `undefined reference to gpu_mmio_write` (library) | `CONFIG_CUDA` not set. Configure with `--with-cuda`. |
| `undefined reference to gpu_mmio_write` (`*_ut` only) | Missing `DEFINE_STUB_V` in the test file. |
| `undefined reference to gpu_read_one` (or `gpu_complete_one`) from C | These are C++-mangled; add `extern "C"`. |
| `Unsupported gpu architecture 'sm_60'` / `'sm_70'` | Pass `CUDA_ARCH=75` on the make command line. |
| `No rule to make target '/home/mateo/spdk/...'` | Stale `mk/config.mk`. Rerun `./configure`. |
| `CUnit/Basic.h: No such file or directory` | Configure with `--disable-unit-tests --disable-tests`. |
| `fuse3/cuse_lowlevel.h: No such file` | Install `libfuse3-dev` or configure with `--without-nvme-cuse`. |
| `libaio.h` / `keyutils.h: No such file` | Install `libaio-dev` / `libkeyutils-dev`. |
| `static declaration of 'arc4random' follows non-static declaration` | glibc ≥ 2.36 clash in `lib/iscsi/iscsi.c`; rename the static function and its one caller. |
| `cudaHostRegister ... invalid argument` | Page not touched yet (lazy vfio mapping), or range includes MSI-X pages. |
| Xid 31, fault @ 0x0, identify timeout | GPU got a NULL doorbell pointer: registration failed. Check the printed CUDA errors. |
| New code doesn't show up when running | Old binary in `/tmp`. Recopy with `\cp -f`, confirm with `strings`. |
| `setup.sh` prints nothing, exit 1 | Root can't read the NFS home. Copy `scripts/` and `include/spdk/pci_ids.h` to a local dir and run it from there. |
| `Driver cannot attach the device` / `No such device` (-19) | The drive is still on the kernel `nvme` driver (not bound to `vfio-pci`), or the address is wrong. Re-check the BDF and `setup.sh status`. |
| `setup.sh`: `Active devices: data@nvme1n1, so not binding` | A signature (RAID member, GPT, filesystem) is on the drive. List with `wipefs`; erase with `wipefs -a` only if disposable. |
| `Read JSON configuration file ... failed` | Config file not in the directory you're running from. |
| `git pull` says up to date but code differs | `git pull` compares with the remote, not other nodes. Push, then pull. |
| `meson setup` fails | SPDK's top level uses `./configure` + `make`. |

## Error catcher script

`error_catcher.sh` in the SPDK root. Arguments go straight to `make`. Logs are overwritten each run.

```bash
#!/usr/bin/env bash
set -uo pipefail

FULL_LOG="build_full.log"
ERROR_LOG="build_errors.txt"

if [ "$#" -eq 0 ]; then
    CMD=(make -j"$(nproc)")
else
    CMD=(make "$@")
fi

echo "Running: ${CMD[*]}"
"${CMD[@]}" 2>&1 | tee "$FULL_LOG"
BUILD_EXIT_CODE=${PIPESTATUS[0]}
echo "== Build finished with exit code $BUILD_EXIT_CODE ==" | tee -a "$FULL_LOG"

grep -n -i -B3 -E "error|undefined reference|fatal|Error [0-9]+|\*\*\*" \
    "$FULL_LOG" > "$ERROR_LOG"

if [ -s "$ERROR_LOG" ]; then
    echo "Found errors. See: $ERROR_LOG"
else
    echo "No errors found."
    rm -f "$ERROR_LOG"
fi
exit "$BUILD_EXIT_CODE"
```

The grep also matches file names like `accel_error.o` and `strerror_tls.o`; those lines are harmless. Keep the logs out of git:

```
echo -e "build_errors.txt\nbuild_full.log" >> .gitignore
```

## Node notes

### shuttle6 — the working node

The October notes described Rocky Linux 8.10; as of Nov 12 `dpkg` works there, so the OS looks Debian/Ubuntu-based now. Confirm with `cat /etc/os-release` and the kernel with `uname -r`. `sudo -l` shows `(ALL) NOPASSWD: ALL`.

- GPU: Quadro RTX 4000, previously `0000:6f:00.0`, NUMA 1, on the `nvidia` driver (580.95.05, open kernel module, CUDA 13.0). Re-check the address and driver after the update.
- NVMe as of Nov 12:
  - KIOXIA EXCERIA PLUS G4 931.5G, `0000:06:00.0`, boot disk (`/`, `/boot`, `/boot/efi`). Never touch.
  - Lexar NM790 4TB, `0000:19:00.0`, test drive. It was previously a member of a RAID built on another host (`titan-spl:0`); its signatures were wiped on Nov 12 and it is bound to `vfio-pci`.
- The Samsung S4LV008 (`0000:43:00.0`) from October and the Micron 7450 PRO boot disk are no longer present in `lspci`.
- IOMMU works: binding to `vfio-pci` succeeded.
- A DSA device (`0000:f2:01.0`, `idxd`) shows up in `setup.sh status`; leave it alone (`PCI_ALLOWED` skips it).
- Older notes: `gdrdrv` (GDRCopy) was loaded; other BXIv3 VMs (`BXIv3-node-01`, `-node-02`) may run, scripts in `/opt/qemu-bxi3-image` (maintained by chaix). Don't touch their devices.

## Read-only hardware checks

```
lspci -D | grep -i nvme                               # NVMe addresses
lspci -nn | grep -i 'non-volatile'                    # NVMe controllers with IDs
lspci -k -s <bdf>                                     # driver holding a device
sudo lspci -vv -s <bdf> | grep -A2 MSI-X              # where the MSI-X table sits in the BAR
readlink -f /sys/bus/pci/devices/<bdf>                # root complex / path to the CPU
cat /sys/bus/pci/devices/<bdf>/numa_node              # which socket
lsblk -o NAME,SIZE,MODEL,MOUNTPOINTS                  # what's mounted
cat /proc/mdstat                                      # software RAID holding a drive
sudo wipefs /dev/<nvme>                               # list signatures (no -a = read only)
sudo fuser -v /dev/<nvme>                             # anything using a drive
nvidia-smi --query-gpu=name,compute_cap --format=csv
ps aux | grep qemu                                    # VMs that may own devices
w                                                     # who's logged in
```