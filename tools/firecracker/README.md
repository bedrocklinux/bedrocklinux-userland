Bedrock Firecracker VM
======================

Simple VM to test/develop/debug Bedrock Linux.

Requirements
------------

- Install `firecracker`
- Build Bedrock Linux in the project root (`make -C ../..`)

Usage
-----

Interactive session:

```bash
./run-bedrock-vm.sh
```

One-shot command:

```bash
./run-bedrock-vm.sh <command>
```

Behavior
--------

- Automatically rebuilds VM if `../../bedrock-linux-*-x86_64.sh` changes
- Copies `./include-in-vm` to `/root/include-in-vm` when building image
