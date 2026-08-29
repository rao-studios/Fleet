# Fleet

**LoRA-gated JSON state machines.** Fleet trains LoRA adapters on small on-device
LLMs so their output *always* conforms to a fixed schema of semantic keys, and
enforces that schema token by token while decoding.

Give Fleet N input JSON documents and N output JSON documents paired by index. It
reads the key template out of the outputs — keys, nesting, and value types, with
the values ignored — trains a LoRA to produce the right values for those keys, and
then constrains generation so the structure cannot come out wrong. Structure comes
from the schema; values come from the LoRA.

Fleet never reimplements training, model loading, or inference. It drives
[Frigate](https://github.com/rao-studios/Frigate)'s MLX/GPU machinery.

## Try it in one command

```bash
swift build
./build-metallib.sh     # macOS: compile MLX Metal shaders (once per build)

swift run fleet smoke
```

`smoke` generates a deterministic mock dataset, trains a LoRA on it, then runs a
held-out input through the gate and checks the output against the schema:

```
1. Generating 16 Weather report pairs (seed 42)…
Schema: {"advisories":[string],"avg_temp_c":number,"storm_risk":boolean,"summary":string}
Content id: 525db6b2ce92d9dcee3252082b211e2736ff03363b3fb440a91f3186e0e56bb0

2. Training 30 iterations…
  iter 9  loss 1.9557
  iter 29 loss 0.6809

3. Testing the gate on a held-out input…
  input:    {"city":"Tromso","readings":[17.53,22.77,12.66,16.61,13.37],"wind_kph":31.78}
  produced: {"advisories":[],"avg_temp_c":13.11,"storm_risk":false,"summary":"Cold in Tromso"}

✓ Output matched the schema. 54% of tokens were forced.
```

> **macOS note:** Frigate's MLX GPU backend loads compiled Metal shaders at
> runtime. Run `./build-metallib.sh` once after `swift build`, otherwise MLX fails
> with *"Failed to load the default metallib"*.

## How the gate works

The schema compiles into a character-level state machine, and every decoding step
consults it:

- **Structural positions** — braces, quoted keys, colons, commas — are *forced*.
  The model is not consulted at all; Fleet emits the longest token matching the
  literal text. A model that has never seen your schema still cannot misspell a key.
- **Value positions** are *masked*. The model chooses, but only from tokens whose
  every character keeps the machine alive: string bodies with proper escaping,
  JSON number grammar (no `01`, no `1.`), `true`/`false`, and arrays whose length
  the model decides but whose element type it cannot change.
- A token is admissible when **all** of its characters are, so a token like `",`
  that closes a string and opens the next key works naturally.

Generation ends when the machine accepts. The output parses by construction.

Schema extraction is strict on purpose: every output must have the identical key
structure and value types. Array *lengths* may vary; nothing else may. A
union-with-optionals schema would make the decoder guess which keys are present,
which is exactly what a fixed state machine is meant to eliminate.

## Content-addressed LoRAs

A LoRA's id is the SHA256 of its **training inputs only** — never the outputs:

```
fleet-db/
  registry                 the index: LoRAs, groups, datasets
  datasets/<uuid>          the input/output pairs
  loras/<cid>/             adapters.safetensors, adapter_config.json,
                           schema.json, dataset-snapshot.json, manifest.json
```

So when the same questions get new answers because the world moved on, retraining
lands on the same id and **replaces the adapter in place**, keeping its label,
its groups, and its birthday, and bumping its generation. That is the groundwork
for on-demand LoRAs addressable by the inputs a caller already has. The dataset
snapshot beside the weights records which outputs that generation actually learned.

## The macOS app

[`Client/`](Client/) (`FleetClient`) drives the whole loop, with a debugger at
every step.

- **Datasets** — generate deterministic mock data (three built-in domains) or
  import a folder of inputs and a folder of matching outputs. The schema debugger
  shows the extracted key tree and, when outputs disagree, points at the exact
  offender: `output[7] $.warnings[2]: expected number (from output 0), found string`.
- **Train** — pick a dataset, model, and knobs. Before starting it tells you which
  content id you are about to create *or replace*, then streams the loss curve.
- **Library** — every stored LoRA with its generation, schema, labels, and groups.
- **Playground** — run an input and inspect the **gate trace**: each token colored
  by whether the schema forced it or the LoRA chose it, click one to see where in
  the schema it landed, how many tokens were admissible, and what the model ranked
  highest.
- **Totem sources** — browse documents on connected Totems (Fleet hosts the
  Conduit gRPC server; Totems dial in).

## CLI

```bash
fleet dataset mock --domain orderTriage --count 40 --seed 42
fleet dataset import --inputs ./in --outputs ./out
fleet dataset validate <dataset-id>      # schema preview + every disagreement
fleet train <dataset-id> --iterations 200 --rank 8
fleet test --cid <cid> --input ./case.json --trace
fleet loras list | label | delete
fleet groups create | list
```

## Architecture

| Target | Role | Heavy deps |
|---|---|---|
| `FleetCore` | JSON model + canonical form, schema extraction, content ids, the gate automaton and token trie, mock domains, prompt format | none (Foundation) |
| `FleetStore` | `fleet-db`: content-addressed LoRA storage, the registry, groups, cursor pagination, startup reconciliation | none (Foundation) |
| `FleetTraining` | `StateTrainer` over Frigate's `LoRATrain`, plus the attribution manifest | Frigate / MLX |
| `FleetInference` | `StructuredSession` and the gated `LogitSampler` that applies the schema at decode time | Frigate / MLX |
| `FleetService` | the orchestration facade the app and CLI both drive | — |
| `FleetConduit` | Fleet as a Conduit mothership Totems dial into | Conduit (gRPC) |
| `FleetTasks` | experimental objective → validated job DAG → task deployment | none (Foundation) |
| `Fleet` | umbrella re-exporting the above | — |
| `FleetCLI` | the `fleet` executable | swift-argument-parser |

The split that matters: **all** of the gate's logic — schema to automaton to token
masks — lives in `FleetCore` behind a `TokenVocabulary` protocol, so it is tested
against a handful of hand-written tokens with no MLX runtime. `FleetInference`
only adapts a real tokenizer to that protocol and runs the loop.

### Experimental agentic task deployment

`FleetTasks` begins the coordination layer Bonnie will use. An injected planning
model converts one large objective into a small JSON job graph; Fleet validates
the graph before a `TaskDeployment` actor lets workers atomically claim ready
jobs. See [`Docs/BONNIE_TASK_DEPLOYMENT.md`](Docs/BONNIE_TASK_DEPLOYMENT.md).

## Roadmap

- **gRPC ingestion** — a Conduit service wrapping `FleetService` so another
  application can create datasets and request LoRAs over the wire. The facade is
  already shaped request/response for this.
- **Totem documents → pairs** — browsing and the transport are live; deriving
  input/output pairs from Totem documents lands with the ingestion work.
- **On-demand LoRAs** — the content-addressed store is the foundation: ask for a
  LoRA by its input set, get the current generation or train one.

## Dependencies

- [Frigate](https://github.com/rao-studios/Frigate) — vendored MLX engine (inference, LoRA training).
- [Conduit](https://github.com/rao-studios/Conduit) — gRPC transport shared with Totem.
- [swift-argument-parser](https://github.com/apple/swift-argument-parser) — CLI.

Licensed under GPLv3.
