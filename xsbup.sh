#!/bin/bash
# xsbup; a basic XenServer daily backup script

# Copyright (c) 2015 Phillip Smith

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

set -u  # fail on unbound vars
set -e  # die on any error

# global variables
declare -r LOCKFILE='/var/run/snapback.pid'

################################################################################
### FUNCTIONS ##################################################################
################################################################################

function take_lockfile() {
  # enable noclobber bash option then attempt to create our lock file.
  # this is much more atomic than checking for the log file first before
  # creating it.
  set -C
  echo $$ > $LOCKFILE || { "Lockfile $LOCKFILE exists, exiting!"; exit 1; }
  set +C
  # cleanup our lockfile any time we exit
  trap "rm -f $LOCKFILE; exit" INT TERM EXIT
  return 0
}

function renice_self() {
  declare -r my_pid="$1"
  renice -n 15 -p $my_pid > /dev/null
  ionice -c 2 -n 7 -p $my_pid > /dev/null
  return 0
}

function xe_param() {
  # Quick hack to grab the required paramater from the output of the xe command
  _param="$1"
  # TODO: this can be done using bash string manipulation to save
  #       creating extra processes.
  while read _data ; do
    _line=$(echo $_data | egrep "$_param")
    if [ $? -eq 0 ]; then
      echo "$_line" | awk 'BEGIN{FS=": "}{print $2}'
    fi
  done
  return 0
}

function delete_snapshot() {
  # Deletes a snapshot's VDIs before uninstalling it. This is needed as
  # snapshot-uninstall seems to sometimes leave "stray" VDIs in SRs
  declare delete_uuid="$1"

  # delete the associated vdi's first
  for vdi_uuid in $(xe vbd-list vm-uuid=$delete_uuid empty=false | xe_param "vdi-uuid"); do
    xe vdi-destroy uuid=$vdi_uuid > /dev/null
  done

  # Now we can remove the snapshot itself
  xe snapshot-uninstall uuid="$delete_uuid" force=true > /dev/null
  return $?
}

function prepare_vm_for_backup() {
  # we take our backup from a snapshot.
  # First we need to check for a previous snapshot that matches our snapshot name pattern and
  # delete it (this could happen if a previous backup fails early)
  declare vm_uuid="$1"
  declare vm_name="$(get_vm_name_by_uuid $vm_uuid)"
  declare snapshot_name="${vm_name}_xsbup"

  # check for existing backup snapshot and delete if found
  declare previous_snapshots=$(xe snapshot-list name-label="$snapshot_name" | xe_param uuid)
  if [ -n "$previous_snapshots" ] ; then
    # previous_snapshots will be new-line delimited list if there are multiple
    # old snapshots, so we need to loop over them
    for previous_snapshot in $previous_snapshots ; do
      delete_snapshot "$previous_snapshot" > /dev/null
    done
  fi

  # check for any CD images connected to the virtual machine and unmount
  declare cd_vbd_uuid="$(xe vbd-list type=CD empty=false vm-name-label="$vm_name" | xe_param uuid)"
  if [ -n "$cd_vbd_uuid" ] ; then
    # cd in the drive; eject it
    xe vbd-eject uuid=$cd_vbd_uuid
  fi

  if [ "$(get_vm_power_state $vm_uuid)" == 'running' ] ; then
    # running VMs need to be snapshotted before backup
    declare snapshot_uuid=$(xe vm-snapshot vm="$vm_name" new-name-label="$snapshot_name")
    printf "$snapshot_uuid"
  fi
}

function do_xva_backup() {
  declare vm_uuid="$1"
  declare vm_name="$(get_vm_name_by_uuid $vm_uuid)"
  declare working_snapshot="$2"
  declare xva_path="$3"
  declare xva_fname="$4"

  # does our destination exist?
  if [ ! -d "$xva_path" ] ; then
    mkdir "$xva_path"
  fi

  # check there is not already a backup made with todays date, otherwise, we
  # can't do this backup because `xe vm-export` will barf.
  declare rolled_backup_fname="$xva_path/${xva_fname}.prev"
  if [ -e "$xva_path/$xva_fname" ] ; then
    mv -f "$xva_path/${xva_fname}" "${rolled_backup_fname}"
  fi

  # create a XVA file from the snapshot
  if xe vm-export vm="$working_snapshot" filename="$xva_path/$xva_fname" > /dev/null ; then
    # remove previous rolled backup if reqd.
    if [ -e "$rolled_backup_fname" ] ; then
      rm -f "$rolled_backup_fname"
    fi
    return 0
  else
    return 1
  fi
}

function cleanup_xva_backups() {
  declare vm_uuid="$1"
  declare vm_name="$(get_vm_name_by_uuid $vm_uuid)"
  declare retain_num="$2"
  declare target_path="$3"

  # sort - will be by date by virtue of YMD dates in filenames
  # head - will give us everything EXCEPT the most recent $retain_num
  # Loop through and remove what we find
  ls -1 "${target_path}"/"${vm_name}"-*.xva | \
    sort -n | \
    head -n-$retain_num | \
    while read expired_backup; do
      rm -f "$expired_backup"
    done
  return 0
}

function dump_pool_metadata() {
  # this is based on the actions in `xe-dump-metadata` from Citrix
  # check /opt/xensource/bin/xe-backup-metadata on any xenserver host
  declare target_path="$1"

  declare pool_db_fname="${target_path}/pool_${date_day}.db"
  declare pool_sr_fname="${target_path}/sr_${date_day}.xml"
  declare vdi_mapping_fname="${target_path}/vdi-mapping_${date_day}.txt"
  declare vbd_mapping_fname="${target_path}/vbd-mapping_${date_day}.txt"

  # pool metadata - remove first otherwise xe will complain about
  # an existing file and refuse to continue
  [ -f "$pool_db_fname" ] && rm -f "$pool_db_fname"
  xe pool-dump-database file-name="$pool_db_fname"

  # sr metadata
  /opt/xensource/libexec/backup-sr-metadata.py -f "$pool_sr_fname"

  # not in the citrix backup script, but we'll dump it out so we
  # have a human readable reference copy
  xe vdi-list > "$vdi_mapping_fname"
  xe vbd-list > "$vbd_mapping_fname"
  return 0
}

function get_vm_name_by_uuid() {
  declare vm_uuid="$1"
  xe vm-param-get uuid="$vm_uuid" param-name=name-label
  return 0
}

function get_vm_power_state() {
  declare vm_uuid="$1"
  xe vm-param-get uuid="$vm_uuid" param-name=power-state
  return 0
}

function usage {
  printf "Usage: %s [options]\n" "$0"
  printf "Options:\n"
  printf "   %-30s %-50s\n" '-d /path/to/backups/'  'Path to write backups to. Default: none'
  printf "   %-30s %-50s\n" '-n name-label'         'Optional: Backup a specfic VM only'
  printf "   %-30s %-50s\n" '-r number'             'Optional: Number of backups to retain per VM'
  printf "   %-30s %-50s\n" '-a'                    'Optional: Backup all VMs (not just running VMs)'
  printf "   %-30s %-50s\n" '-h'                    'Display this help and exit'
}

################################################################################
### MAIN #######################################################################
################################################################################

function main() {
  declare dest_path=        # path to write backups to
  declare backup_all_vms=   # user can specfy backup of ALL vms (not just running vms)
  declare target_vm=        # the user can name a specific vm to backup
  declare vms_to_backup=    # a list of UUIDs to backup
  declare uuid_to_backup=   # either the VM UUID or the UUID of a snapshot
  declare vm_name=          # name-label of the vm currently being backed up
  declare xva_file=         # filename (no path) of the backup destination
  declare -i retain_cnt=3      # number of backups to retain per vm
  
  declare -r date_ymd=$(date +"%Y%m%d") # date format must be %Y%m%d so we can sort
  declare -r date_day=$(date +"%a")     # Sun, Mon, Tue etc

  # fetch cmdline options
  while getopts ":hd:an:r:" opt; do
    case $opt in
      d)
        dest_path="$OPTARG"
        ;;
      r)
        retain_cnt="$OPTARG"
        ;;
      n)
        target_vm="$OPTARG"
        ;;
      a)
        backup_all_vms='yes'
        ;;
      h)
        usage
        return 0
        ;;
      \?)
        errit "ERROR: Invalid option: -$OPTARG" >&2
        usage
        return 1
        ;;
      :)
        errit "ERROR: Option -$OPTARG requires an argument." >&2
        return 1
        ;;
    esac
  done
  
  # is this a xenserver box?
  if [ ! -f /etc/xensource-inventory ] ; then
    printf "This does not appear to be a XenServer host. Aborting.\n"
    exit 1
  fi
  source /etc/xensource-inventory

  # this script should be run on the pool master
  # note: $INSTALLATION_UUID comes from /etc/xensource-inventory
  master_uuid=$(xe pool-list params=master --minimal)
  if [ "$master_uuid" != "$INSTALLATION_UUID" ] ; then
    printf "xsbup must be run on the pool master and this host does not appear to be the master\n"
    printf "\tPool master: %s\n" "$master_uuid"
    printf "\tThis host:   %s\n" "$INSTALLATION_UUID"
    exit 1
  fi

  # validate configuration
  [ ! -d "$dest_path" ] && { printf "Not a valid path: %s\n" "$dest_path"; exit 1; }
  [ ! -w "$dest_path" ] && { printf "Permission denied: %s\n" "$dest_path"; exit 1; }

  # try and take our lockfile
  take_lockfile

  # renice ourself to minimize performance impact on the system
  renice_self "$$"

  printf "xsbup started at %s\n" "$(date)"
  printf "\tBackups will be written to %s\n" "$dest_path"

  # what virtual machines are we going to backup?
  if [ -n "$backup_all_vms" ] ; then
    # backup all virtual machines
    printf "Going to backup ALL Virtual Machines\n"
    declare -r vms_to_backup=$(xe vm-list is-control-domain=false | xe_param uuid)
  elif [ -n "$target_vm" ] ; then
    # backup the vm with this name-label
    printf "Going to backup Virtual Machine '%s'\n" "$target_vm"
    declare -r vms_to_backup=$(xe vm-list name-label="$target_vm" | xe_param uuid)
  else
    # backup only running VMs
    printf "Going to backup all RUNNING Virtual Machines\n"
    declare -r vms_to_backup=$(xe vm-list power-state=running is-control-domain=false | xe_param uuid)
  fi

  # loop through the list of VMs and backup each one
  for vm_uuid in $vms_to_backup ; do
    vm_name="$(get_vm_name_by_uuid $vm_uuid)"
    xva_file="${vm_name}-${date_ymd}.xva"

    printf "Backup for VM '%s' started at %s\n" "$vm_name" "$(date)"

    printf "\tPreparing VM for backup... "
    snapshot_uuid=$(prepare_vm_for_backup "$vm_uuid" )
    printf "Done!\n"
    if [ -n "$snapshot_uuid" ] ; then
      printf "\tSnapshot UUID is $snapshot_uuid\n"
      uuid_to_backup="$snapshot_uuid"
    else
      uuid_to_backup="$vm_uuid"
    fi
    
    printf "\tStarting export to XVA... "
    do_xva_backup "$vm_uuid" "$uuid_to_backup" "$dest_path/$vm_name" "$xva_file"
    printf "Done!\n"

    if [ -n "$snapshot_uuid" ] ; then
      printf "\tRemoving snapshot... "
      delete_snapshot "$snapshot_uuid" || true
      printf "Done!\n"
    fi

    printf "\tRemoving expired backups outside retention period... "
    cleanup_xva_backups "$vm_uuid" "$retain_cnt" "$dest_path/$vm_name"
    printf "Done!\n"

    printf "Backup for VM '%s' completed at %s\n" "$vm_name" "$(date)"
  done

  # dump some metadata to disk with the backups
  printf "\tDumping pool metadata... "
  dump_pool_metadata "$dest_path"
  printf "Done!\n"

  return 0
}

main $@

exit 0
