# Security

Bro Chat talks to nearby phones over Bluetooth LE and the local network, so bugs in the protocol, the mesh relay or the transports matter.

## Reporting a vulnerability

Please don't open a public issue. Use GitHub's private vulnerability reporting instead: on this repository, open **Security**, then **Report a vulnerability**. Only the maintainers can see the report.

Include what an attacker can do, the build or commit, and steps to reproduce. This is a hobby project, so there is no bounty and no guaranteed response time, but reports are read.

## Scope

- `BroKit/` (protocol, crypto, mesh, Bluetooth and LAN transports) and the iOS app in `App/`.
- The tools in `Tools/` are for testing and are out of scope unless the bug also affects the app.
