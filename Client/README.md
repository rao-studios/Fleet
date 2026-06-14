# FleetClient

A macOS app to drive Fleet's fine-tune loop interactively and **test memory
retention** of small on-device LLMs.

It walks the whole loop for text:

1. **Models** — download/warm a HuggingFace MLX model.
2. **Datasets** — build a dataset from **notes** and **Q&A pairs** (or import text
   files). Each dataset gets a UUID, stored in `fleet-db`.
3. **Fine-tune** — train a LoRA on a dataset. The adapter's UUID is **tied to the
   dataset's UUID** (`TrainedAdapter.datasetId`).
4. **Chat** — A/B the **base model vs the fine-tuned LoRA** on the same prompt,
   with the source dataset shown alongside so you can judge recall.

It's a standalone SwiftPM executable (like Totem/Client) that depends on the
Fleet package next door and calls it in-process.

## Run

```bash
swift build
./build-metallib.sh          # compile MLX Metal shaders next to the binary (one time per build)
swift run FleetClient
```

> **Metal note:** Frigate's MLX GPU backend loads `mlx.metallib` from **next to
> the running binary** at runtime. Run `./build-metallib.sh` after `swift build`
> (if your machine lacks the standalone Metal toolchain, copy the one the Fleet
> package builds: `cp ../.build/debug/mlx.metallib .build/debug/mlx.metallib`).
> Prefer `swift run FleetClient` — the colocated metallib in `.build` persists
> across rebuilds.
>
> **Running from Xcode:** Xcode builds to `DerivedData/.../Build/Products/Debug/`,
> which has no `mlx.metallib`, so the app fails with *"Failed to load the default
> metallib"*. Copy it next to the Xcode product:
> ```bash
> cp .build/debug/mlx.metallib \
>    "$(ls -d ~/Library/Developer/Xcode/DerivedData/Client-*/Build/Products/Debug)/mlx.metallib"
> ```
> Repeat after **Clean Build Folder** (which wipes the products dir). For everyday
> use, `swift run FleetClient` avoids this entirely.

## Design

Reuses Totem/Client's warm design language (cream `#FAF9F6`, ink `#2D3142`, gold
`#AE9060`, light-italic-serif headings) with a distinct gold **Fleet mark**
(connected-nodes glyph) and the orbiting-ring motion.

## Storage — `fleet-db`

Datasets and adapters live under `~/Documents/fleet-db` (modeled on Totem's
`FilePersistence`):

```
fleet-db/
  datasets/<uuid>           a TrainingDataset
  adapters/<uuid>           a TrainedAdapter (datasetId ties it to its dataset)
  loras/<adapterUUID>/      adapter_config.json + adapters.safetensors
```
