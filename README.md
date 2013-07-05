# SmartOS on Vagrant

SmartOS provides the best Node.js experience, and is an all-around powerhouse operating system.
Many developers use Vagrant to manage runtimes and build environments.

We want to bring an up to date version of SmartOS to Vagrant.

## Install/Run

1. Install SmartOS on Virtualbox
2. Setup port forwarding from `localhost:2222` to `vbox:22`

The `GLOBALZ` folder is an unpacked set of scripts to install on the SmartOS global zone.

1. Run `make package`
2. Copy `vagrant-tools.tar.gz` to SmartOS (scp, or `python -m SimpleHTTPServer`)
3. On SmartOS run `tar -zxf vagrant-tools.tar.gz -C /`
4. Restart SmartOS

An SMF job *should* prepare the OS. 
The first time you do this, it may take a while since it has to download a new VM image.

Vagrant rougly connects to your instance with the following line:

```
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/.vagrant.d/insecure_private_key -p 2222 vagrant@localhost
```

## Todo

- add resiliency to scripts
- add automation
- let SmartOS/VirtualBoxTools be pluggable for fast updates

## Goals

1. to automate the *vagrant-ification* of a base smarts build
2. users should be able to get running with

		vagrant init smartos http://example/smartos-vagrant.box
		vagrant up
		vagrant ssh
	
3. The box should include *Nodejs* and all necessary build tools for compiling c++ node extensions
4. create an awesome single-page advertising how awesome smartos vagrant boxes are

## Plans

[Andrzej Szeszo](https://twitter.com/aszeszo) has provided a great head-start with his build scripts and running example.
We plan to expand upon this.

### Prepare Script

A prep-script should run on a base SmartOS box. Todos in no particular order:

- create a `vagrant` zone
- add nodejs packages to vagrant zone
- assign global and vagrant zones to use DHCP
- setup dns
- `vagrant ssh` should reach the vagrant zone, not the global zone

