# xsbup
A basic XenServer daily backup tool.

## Overview

Citrix has for a long time offered a free version of XenServer, and version 6.2
was made open-source in 2013. This has led to many small scale deployments of
XenServer, often with only a single host -- IT staff who use XenServer at their
work often run a free version in their (Home)Lab.

XenServer itself has no automated backup tools, and there are limited
third-party backup tools that match the free offerring of the XenServer
platform.

This script has been developed for use in these small-scale deployments so we
can have automated backups of our guests too.

## Features

* Writes output to .xva files direct to disk -- no need for a dedicated Storage
Repository in XenServer. Example: write to USB disk or NFS share on a NAS
device.

* Running guests are snapshotted before backup is taken.

* Pool metadata is also backed up.

* Designed to run once-per-day, although can be run less-frequently.

## Installation

* `git clone https://github.com/fukawi2/xsbup.git`

* make install

## Usage

**Important:** Only _running_ guests are backed up by default. Use the `-a`
flag to backup _all_ guests.

`xsbup -d /path/to/write/backups`

Check the online help (`xsbup -h`) for more information.

## Notes

* *"XVA is a format specific to Xen-based hypervisors for packaging a single VM
as a single file archive of a descriptor and disk images"* [Source](http://support.citrix.com/proddocs/topic/xencenter-61/xs-xc-vms-exportimport-about.html)
