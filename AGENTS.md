# ak-lxd-helper

A lightweight web dashboard for managing LXD instances on a single host.
Built as a helper agent for managing LXD via API commands.

## Background and motivation

This project is a personal helper agent built to talk to LXD's REST API
directly over the local Unix socket, avoiding TLS entirely.

## Target environment

- Runs on: an arm64 LXD host (developed against an NVIDIA DGX Spark, GB10).
  The host name is configured via `LXD_HOST` in `.env` (gitignored).
- LXD version: 5.21.4 (snap install on Ubuntu)
- LXD socket: `/var/snap/lxd/common/lxd/unix.socket`
- Accessed from: macOS laptop on local network

## LXD Functions

- Configure and monitor instance via lxc commands
- Add, edit, and remove images
- Add, edit, and remove virtual machines
- Start, stop, restart, and check status of virtual machines
- Connect to running VM consoles
- Execute commands in instances
- More to be added in future
