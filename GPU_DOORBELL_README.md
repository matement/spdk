# SPDK GPU Doorbell — Build & Setup Notes

Personal notes for building and testing the GPU doorbell-mapping changes to SPDK on the CARV cluster nodes.

## What the change does

Normally SPDK rings the NVMe doorbells from the CPU (a plain store to the doorbell register in BAR0). This fork makes the **GPU** do the doorbell write instead, as a first step toward BaM-style GPU-initiated I/O.

The flow:

1. `lib/nvme/nvme_pcie.c` (~line 788–794): the doorbell region of BAR0 (`doorbell_base`) is registered with CUDA using `cudaHostRegister(..., cudaHostRegisterIoMemory)`. Then `cudaHostGetDevicePointer` returns a GPU-visible pointer to it, stored in `gpu_doorbell_base`.
2. `lib/nvme/nvme_pcie_internal.h`: the qpair struct holds GPU-visible doorbell pointers (`gpu_sq_tdbl`, `gpu_cq_hdbl`). At lines ~275 and ~298 the SQ tail and CQ head doorbell rings call `gpu_mmio_write(...)` instead of writing from the CPU.
3. `lib/nvme/gpu_nvme_doorbell.cu`: `gpu_mmio_write` launches a 1-block, 1-thread kernel that does `*dbl = val;`, then `cudaDeviceSynchronize()` so SPDK doesn't continue before the write is done.
4. `lib/nvme/gpu_funcs.h`: C-compatible declaration of `gpu_mmio_write`.

### Bug fixed (Sep 30)

Line 793 used to register `gpu_doorbell_base`, which is still empty (NULL) at that point. It must register `doorbell_base`, the real BAR mapping:

```c
cudaHostRegister((void*)pctrlr->doorbell_base, dbl_size, cudaHostRegisterIoMemory);
cudaHostGetDevicePointer((void**)&pctrlr->gpu_doorbell_base, (void*)pctrlr->doorbell_base, 0);
```

Both calls failed silently before, because their return values weren't checked.

### Open items

- Add error checks to both CUDA calls (print `cudaGetErrorString(err)` on failure).
- Confirm where `gpu_sq_tdbl` / `gpu_cq_hdbl` get assigned (probably `nvme_pcie_common.c` during qpair creation). They must be offsets from `gpu_doorbell_base`, not `doorbell_base`.
- Check that `dbl_size` covers the full doorbell region, rounded to a page (`cudaHostRegisterIoMemory` wants page-aligned address and size).
- Nothing has been tested on real hardware yet. Blocked on node access (see below).

## Build steps

All commands run from the SPDK root (`~/spdk-build/spdk`).

### 1. Configure

```
./configure --with-cuda --disable-unit-tests --disable-tests
```

- `--with-cuda` sets `CONFIG_CUDA=y`. Without it, the `.cu → .o` rule in `mk/spdk.common.mk` is skipped and `gpu_mmio_write` never gets compiled (you'll see "undefined reference to gpu_mmio_write").
- `--disable-unit-tests --disable-tests` skips `lib/ut` and the unit tests. Needed on machines without CUnit (shuttle6). `lib/ut` is built if *either* setting is on.

Check it applied:

```
grep -E "CONFIG_CUDA|CONFIG_UNIT_TESTS|CONFIG_TESTS" mk/config.mk
```

### 2. Set the GPU architecture

The default in `mk/spdk.common.mk` is `CUDA_ARCH ?= 60`, which recent nvcc rejects ("Unsupported gpu architecture 'sm_60'"). Set it to match the GPU:

```
nvidia-smi --query-gpu=name,compute_cap --format=csv   # find the right value
export CUDA_ARCH=75                                      # Quadro RTX 4000 (Turing) = 7.5
```

Use `export` so it reaches all the recursive make calls.

### 3. Build

Using the error catcher script (see below):

```
./error_catcher.sh -j$(nproc)
cat build_errors.txt        # if the file doesn't exist, the build was clean
```

To rebuild only the NVMe library:

```
./error_catcher.sh -C lib/nvme -j$(nproc)
```

Note: `make lib` does NOT work at the top level (SPDK passes the target into every subdirectory). Use `-C lib/nvme` instead.

### 4. Verify the build

```
ls -la build/lib/libspdk_nvme.a                       # timestamp should be fresh
nm build/lib/libspdk_nvme.a | grep " T gpu_mmio_write" # T = defined, compiled in
ls -la build/bin/spdk_lspci build/examples/thread
```

## Unit tests

Unit tests compile only the single `.c` file being tested (`C_SRCS = $(TEST_FILE)` in `mk/spdk.unittest.mk`), so they can't see the `.cu` object. Each affected test needs a stub near the top of its `_ut.c` file, next to the other `DEFINE_STUB` lines:

```c
DEFINE_STUB_V(gpu_mmio_write, (volatile uint32_t *dbl, uint32_t val));
```

Needed in:

- `test/unit/lib/nvme/nvme_pcie_common.c/nvme_pcie_common_ut.c`
- `test/unit/lib/nvme/nvme_pcie.c/nvme_pcie_ut.c`

The stub does nothing, so tests pass without a GPU. If a test ever checks the doorbell value itself, a plain no-op stub would hide a failure.

## Common problems

| Symptom | Cause / fix |
|---|---|
| `undefined reference to gpu_mmio_write` in the library | `CONFIG_CUDA` not set. Rerun configure with `--with-cuda`. |
| `undefined reference to gpu_mmio_write` only in `*_ut` | Missing `DEFINE_STUB_V` in the test file (see above). |
| `Unsupported gpu architecture 'sm_60'` | `export CUDA_ARCH=75` (or the correct value) before building. |
| `No rule to make target '/home/mateo/spdk/lib/env_dpdk/env.mk'` | Stale absolute paths in `mk/config.mk` from an old configure. Rerun `./configure` from the current folder. |
| `CUnit/Basic.h: No such file or directory` | No CUnit on this machine. Configure with `--disable-unit-tests --disable-tests`, or `sudo dnf install CUnit-devel`. |
| `meson setup` fails | SPDK's top level uses `./configure` + `make`, not meson. Meson is only for subprojects like DPDK. |
| `git pull` says up to date but code differs | `git pull` compares with the remote, not with other nodes. Push from one machine, pull on the other. |

## Error catcher script

Save as `error_catcher.sh` in the SPDK root and `chmod +x` it. Arguments are passed straight to `make`. Logs are overwritten each run.

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

Add the logs to `.gitignore` so they don't get committed:

```
echo -e "build_errors.txt\nbuild_full.log" >> .gitignore
```

## Node notes

### shuttle4 (Ubuntu)

- IOMMU is **off**, so the normal `vfio-pci` bind that SPDK needs fails. Workaround for dev/test only: `echo Y | sudo tee /sys/module/vfio/parameters/enable_unsafe_noiommu_mode` before binding. No DMA isolation in this mode.
- GPU and NVMe drives are on separate PCIe root complexes (different NUMA nodes), so there's no clean P2P path.
- `nvme0n1` (Micron 7450 PRO, `0000:06:00.0`) is the **boot disk**. Never touch it.
- `nvme1n1` (Samsung, `0000:19:00.0`) is unmounted most of the time but gets mounted at `/mnt/backing1` by **gthemis** on and off. Ask before using it.
- Other users (e.g. markakisg) work here with root. Check `w` before anything that touches shared hardware.

### shuttle6 (Rocky Linux 8.10)

- The Quadro RTX 4000 (`0000:6f:00.0`) is bound to `vfio-pci` and **passed through to the BXIv3-base VM** (part of the BXIv3 interconnect testbed in `/opt/qemu-bxi3-image`, maintained by chaix). Do not touch this GPU: no modprobe, no PCI remove/rescan.
- Building here is fine. Running anything that uses the GPU or NVMe is not.
- No CUnit installed. Use `--disable-unit-tests --disable-tests`.
- Older system: python, ninja, vim etc. were updated manually.

### tie0

- No GPU available.

## Hardware checks (read-only)

```
lspci -D | grep -i nvme                      # NVMe PCI addresses
lspci -k -s <bdf>                            # which driver holds a device
lsblk -o NAME,MAJ:MIN,SIZE,MOUNTPOINTS       # what's mounted
sudo fuser -v /dev/nvme1n1                   # anything using the drive right now
cat /sys/bus/pci/devices/<bdf>/resource      # BAR addresses and sizes
nvidia-smi --query-gpu=name,compute_cap --format=csv
w                                            # who's logged in and what they're doing
```
