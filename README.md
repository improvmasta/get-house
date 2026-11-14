# Get House

House is a console for a home server: one place to see and run the machine, its guests and the apps on them, with every change recorded and undoable. This repository holds the one script that puts House on a fresh Proxmox machine.

## Start

On the Proxmox host, signed in as root, paste:

```
curl -fsSL https://raw.githubusercontent.com/improvmasta/get-house/main/bootstrap.sh | bash
```

When it finishes it prints an address to open in a browser and a setup code. Everything after that happens in House.

## What you need

- A machine with Proxmox VE installed and reachable on your network.
- That machine able to reach the internet.
- About 10 GB of free storage and 1 GB of memory for House's own container.

Nothing else. No domain, no cloud account, no router changes.

## What it asks

1. **New house, or rebuilding one.** Rebuilding is for when you have a House repository and its key from before.
2. **The host's network.** It shows the machine's name, address, gateway and DNS, where each is saved, and anything wrong with them. Then:
   - **Keep and Verify** leaves them as they are.
   - **Change Now** sets them. This is the time to do it: the name and address are hard to change once the machine has guests.
3. **House's address.** It offers the first free address near the host's.

## What it changes

- **Only if you choose Change Now:** `/etc/network/interfaces`, `/etc/hosts`, `/etc/hostname` and `/etc/resolv.conf`. The files as they were are kept in `/root/house-undo/`.
- **A new container** named `house`: Debian 12, 1 core, 1 GB, 8 GB, running House in Docker and nothing else.
- **One line in root's `authorized_keys`:** House's own SSH key, so House can set up its own Proxmox user and token. Your own keys and settings are not touched.

It does not make other guests, install apps or touch your router. Those are done in House, where each has a plan to read first and an undo.

## If something goes wrong

- **Run it again.** It looks at what is already there and picks up where it stopped.
- **A network change made over SSH** goes back by itself after two minutes unless you sign in at the new address and confirm it. The script prints the exact line to run.
- **A network change made at the machine's own screen** is applied directly. The script prints the line that puts the old settings back.
- **To see what it would do without doing it,** put `HOUSE_DRY_RUN=1` before `bash`:

```
curl -fsSL https://raw.githubusercontent.com/improvmasta/get-house/main/bootstrap.sh | HOUSE_DRY_RUN=1 HOUSE_YES=1 bash
```

## Removing it

Delete the `house` container in Proxmox, and remove the line ending in `house@house` from `/root/.ssh/authorized_keys`. If you changed the network and want it back, the old files are in `/root/house-undo/`.

## Status

New. The script passes its tests against a simulated Proxmox and has been dry-run on a real one. Treat a first run on a machine you care about as a test, and use the dry run first.

## Settings

Each can be set before `bash`, the way `HOUSE_DRY_RUN` is above.

| Setting | What it does |
|---|---|
| `HOUSE_MODE` | `new` or `rebuild`: skips the first question |
| `HOUSE_NETWORK` | `keep` or `change`: skips that question |
| `HOUSE_ADDRESS` | House's address, instead of the one offered |
| `HOUSE_CTID` | The container's ID, instead of the next free |
| `HOUSE_STORAGE` | Where the container's disk goes, instead of the storage with the most room |
| `HOUSE_PORT` | The port House listens on (8480) |
| `HOUSE_YES` | `1`: take every offered answer without asking |
| `HOUSE_DRY_RUN` | `1`: say what would be done and change nothing |
