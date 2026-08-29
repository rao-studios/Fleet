// Fleet umbrella module.
//
// Importing `Fleet` brings the whole service into scope: the JSON/schema/gate
// core, the content-addressed store, training and gated inference, the
// orchestration facade, and the task deployment experiment.
//
// FleetConduit is deliberately not re-exported — it pulls in gRPC, and only the
// app and the Totem integration need it.

@_exported import FleetCore
@_exported import FleetInference
@_exported import FleetService
@_exported import FleetStore
@_exported import FleetTasks
@_exported import FleetTraining
