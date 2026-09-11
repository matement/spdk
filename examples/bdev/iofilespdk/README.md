# SPDK + CUDA: GPU-to-Storage Buffer Write

A CUDA kernel writes directly into the DMA buffer SPDK uses for NVMe
I/O — the GPU is the only thing that writes into that buffer, no
`cudaMemcpy` on that side.

## What it does

1. Reads an input file (`-f <path>`) into a GPU-visible buffer
   (`gpu_alloc_buffer`, backed by `cudaHostAlloc`).
2. Allocates an SPDK DMA buffer (`spdk_dma_zmalloc`), sized to a whole
   number of the target bdev's blocks.
3. A CUDA kernel (`gpu_copy_buffer`) copies the input into that SPDK
   buffer — the buffer is registered with CUDA via `cudaHostRegister`/
   `cudaHostGetDevicePointer`, and the kernel writes into it directly.
4. SPDK writes that buffer to the target bdev, reads it back, and
   dumps the result to `readback.bin` for verification.

## Verified

Byte-for-byte round-trip (`diff`/`sha256sum`) on a `Malloc0` bdev, for
text and binary files (e.g. ELF executables).

## Files

- `iofilespdk.c` — SPDK app: args, bdev open, buffer setup, I/O
  callbacks.
- `gpu_fill.h` / `gpu_fill.cu` — `gpu_alloc_buffer`, `gpu_free_buffer`,
  `gpu_copy_buffer`.
- `Makefile` — adds an `nvcc` build step to SPDK's example Makefile.

---

## Execution steps

### 1. Build SPDK itself (once, if not already built)

```bash
cd spdk
git submodule update --init
sudo ./scripts/pkgdep.sh
./configure
make -j$(nproc)
```

If `pkgdep.sh` leaves Python module errors (`jinja2`, `tabulate`):

```bash
sudo apt install -y python3-jinja2 python3-tabulate
```

### 2. Build this app

```bash
cd examples/bdev/iofilespdk
make clean
make gpu_fill.o && make
```

`gpu_fill.o` must be built explicitly before `make` — it isn't yet
wired into the app's dependency chain, so plain `make` alone will
fail with "cannot find gpu_fill.o".

### 3. Set up hugepages (every session / after reboot)

```bash
sudo PERSIST_HUGE=yes PCI_ALLOWED="none" scripts/setup.sh
cat /proc/meminfo | grep -i huge
```

`PCI_ALLOWED="none"` allocates hugepages without touching any PCI
device — safe regardless of what hardware is present.

On some machines/clusters, `uio_pci_generic` fails to load
(`modprobe: Operation not permitted`) even with full sudo. If so,
force `vfio-pci` instead:

```bash
sudo DRIVER_OVERRIDE=vfio-pci PERSIST_HUGE=yes PCI_ALLOWED="none" scripts/setup.sh
```

### 4. Create a bdev config

RAM-backed, for testing (no hardware needed):

```bash
cat > malloc_bdev.json << 'EOF'
{
  "subsystems": [
    {
      "subsystem": "bdev",
      "config": [
        {
          "method": "bdev_malloc_create",
          "params": { "name": "Malloc0", "num_blocks": 65536, "block_size": 512 }
        }
      ]
    }
  ]
}
EOF
```

Real NVMe device (after binding it — see step 6):

```bash
cat > nvme_bdev.json << 'EOF'
{
  "subsystems": [
    {
      "subsystem": "bdev",
      "config": [
        {
          "method": "bdev_nvme_attach_controller",
          "params": { "name": "Nvme0", "trtype": "PCIe", "traddr": "0000:XX:00.0" }
        }
      ]
    }
  ]
}
EOF
```

### 5. Run — IMPORTANT: run from a writable, sudo-executable directory

Some systems (notably NFS-mounted home directories on shared
clusters) block `sudo` from **executing** binaries and from
**writing files** under that mount, even with full root privileges.
If that's the case here:

```bash
cp build/examples/iofilespdk /tmp/iofilespdk_run
chmod +x /tmp/iofilespdk_run
cd /tmp
```

**`cd /tmp` matters** — `readback.bin` is written to the current
working directory using a relative path. If you run the binary while
your shell's cwd is still inside a restricted mount, the write
silently fails with "Couldnt open readback.bin", even though
everything else works correctly.

```bash
sudo /tmp/iofilespdk_run -f <file> -b Malloc0 -c /tmp/malloc_bdev.json
```

(adjust paths to wherever you copied things)

### 6. Real NVMe device (optional)

Identify the device and confirm it's not your boot disk or in use by
anyone else before doing anything:

```bash
lsblk
lspci | grep -i nvme
for d in nvme0n1 nvme1n1; do echo -n "$d -> "; basename $(readlink -f /sys/block/$d/device/device); done
lsof /dev/nvme1n1 2>/dev/null      # or whichever device you're targeting
```

Bind it:

```bash
sudo DRIVER_OVERRIDE=vfio-pci PCI_ALLOWED="0000:XX:00.0" scripts/setup.sh
lsblk   # the device should disappear from this list
```

Run with the NVMe config from step 4:

```bash
sudo /tmp/iofilespdk_run -f <file> -b Nvme0n1 -c /tmp/nvme_bdev.json
```

Release it when done:

```bash
sudo scripts/setup.sh reset
```

### 7. Verify

```bash
diff <file> readback.bin && echo MATCH
sha256sum <file> readback.bin
```

Matching output confirms every byte survived: file → GPU-visible
buffer → GPU kernel copy → SPDK DMA buffer → device write → device
read → disk.

---

## Relationship to BaM

This proves the shared-buffer primitive — GPU and the SSD-facing DMA
buffer are the same memory — not BaM's full model. A CPU thread still
owns the SPDK queue pair and calls `spdk_bdev_write`; the GPU doesn't
submit I/O or poll completions itself. That's the natural next step.