# rustnab documentation

This directory holds the plan for rustnab, the Rust replacement for pynab, and reference documents that describe pynab as it behaves today. The reference documents exist so that rustnab stays wire-compatible with pynab services and reproduces the rabbit's behavior. They were written before the rustnab decisions were made, so where they assume something the plan rules out (the 2018 board, reading the Postgres database, Rust type sketches), the plan wins.

Start with [the plan](rustnab-plan.md). It records every decision, the reason for it, the milestones and the open risks. Then [the milestone 0 spikes](m0-spikes.md), the hardware experiments that must pass before daemon code is written. The sound overlay they install is in `hardware/overlays`.

Reference documents:

- [Protocol specification](protocol-spec.md), the nabd TCP protocol on port 10543 that rustnab keeps as its legacy ingress.
- [Packet reference](packet-reference.md), every packet type on that protocol.
- [State machine](state-machine.md), the daemon states and transitions the rabbit expects.
- [Service architecture](service-architecture.md), how pynab services are structured and what they expect from the daemon.
- [Hardware interface](hardware-spec.md), the peripherals and how pynab drives them. The plan's board reference section is the authority on pins.
- [Hardware models](hardware-models.md), the rabbit and board variants pynab knows about.
