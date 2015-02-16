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
declare LOG_LEVEL=0

################################################################################
### FUNCTIONS ##################################################################
################################################################################

function take_lockfile() {
  # enable noclobber bash option then attempt to create our lock file.
  # this is much more atomic than checking for the log file first before
  # creating it.
  logmsg 4 "Attempting to take lockfile: $LOCKFILE"
  set -C
  echo $$ > $LOCKFILE || { logmsg 0 "Unable to take lockfile: $LOCKFILE"; return 1; }
  set +C
  # cleanup our lockfile any time we exit
  trap "rm -f $LOCKFILE; exit" INT TERM EXIT
  logmsg 4 "Lockfile taken successfully"
  return 0
}

function renice_self() {
  declare -r my_pid="$1"
  logmsg 4 'Adjusting nice and ionice numbers'
  renice -n 15 -p $my_pid > /dev/null
  ionice -c 2 -n 7 -p $my_pid > /dev/null
  return 0
}

function xe_param() {
  # Quick hack to grab the required paramater from the output of the xe command
  _param="$1"
  while read _data ; do
    _line=$(echo $_data | egrep "$_param")
    if [ $? -eq 0 ]; then
      # do not quote this line otherwise we end up with extra
      # whitespace surrounding the value
      echo ${_line#*:}
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
    logmsg 4 "Deleting snapshot VDI: $vdi_uuid"
    xe vdi-destroy uuid=$vdi_uuid > /dev/null
  done

  # Now we can remove the snapshot itself
  logmsg 4 "Deleting snapshot: $delete_uuid"
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
  return 0
}

function do_xva_backup() {
  declare vm_uuid="$1"
  declare vm_name="$(get_vm_name_by_uuid $vm_uuid)"
  declare working_snapshot="$2"
  declare xva_path="$3"
  declare xva_fname="$4"

  # does our destination exist?
  if [ ! -d "$xva_path" ] ; then
    logmsg 4 "Creating missing destination: $xva_path"
    mkdir "$xva_path"
  fi

  # check there is not already a backup made with todays date, otherwise, we
  # can't do this backup because `xe vm-export` will barf.
  declare rolled_backup_fname="$xva_path/${xva_fname}.prev"
  if [ -e "$xva_path/$xva_fname" ] ; then
    logmsg 4 "Rolling previous backup to ${rolled_backup_fname}"
    mv -f "$xva_path/${xva_fname}" "${rolled_backup_fname}"
  fi

  # create a XVA file from the snapshot
  logmsg 4 "Exporting $working_snapshot ($vm_name) to $xva_path/$xva_fname"
  if xe vm-export vm="$working_snapshot" filename="$xva_path/$xva_fname" > /dev/null ; then
    # remove previous rolled backup if reqd.
    logmsg 5 "Export completed successfully"
    if [ -e "$rolled_backup_fname" ] ; then
      logmsg 5 "Removing rolled backup: $rolled_backup_fname"
      rm -f "$rolled_backup_fname"
    fi
    return 0
  else
    logmsg 0 "Export of $working_snapshot ($vm_name) FAILED"
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
      logmsg 3 "Removing expired backup: $expired_backup"
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
  logmsg 3 "Dumping pool metadata to $pool_db_fname"
  [ -f "$pool_db_fname" ] && rm -f "$pool_db_fname"
  xe pool-dump-database file-name="$pool_db_fname"

  # sr metadata
  logmsg 3 "Dumping storage repository metadata to $pool_sr_fname"
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

function logmsg() {
  declare log_level="$1"
  shift
  declare log_msg="$*"
  if [ $LOG_LEVEL -ge $log_level ] ; then
    printf "%s | %s\n" "$(date)" "$log_msg"
  fi
  return 0
}

function usage {
  printf "Usage: %s [options]\n" "$0"
  printf "Options:\n"
  printf "   %-30s %-50s\n" '-d /path/to/backups/'  'Path to write backups to. Default: none'
  printf "   %-30s %-50s\n" '-n name-label'         'Optional: Backup a specfic VM only'
  printf "   %-30s %-50s\n" '-r number'             'Optional: Number of backups to retain per VM'
  printf "   %-30s %-50s\n" '-a'                    'Optional: Backup all VMs (not just running VMs)'
  printf "   %-30s %-50s\n" '-v num'                'Verbosity level 0-9 (higher number == more output)'
  printf "   %-30s %-50s\n" '-q'                    'Be quiet'
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
  declare xva_fname=        # filename (no path) of the backup destination
  declare -i retain_cnt=3   # number of backups to retain per vm
  
  declare -r date_ymd=$(date +"%Y%m%d") # date format must be %Y%m%d so we can sort
  declare -r date_day=$(date +"%a")     # Sun, Mon, Tue etc

  # fetch cmdline options
  while getopts ":hqv:d:an:r:" opt; do
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
      v)
        LOG_LEVEL="$OPTARG"
        ;;
      q)
        LOG_LEVEL=-1
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
    logmsg 0 'This does not appear to be a XenServer host. Aborting.'
    exit 1
  fi
  source /etc/xensource-inventory

  # this script should be run on the pool master
  # note: $INSTALLATION_UUID comes from /etc/xensource-inventory
  master_uuid=$(xe pool-list params=master --minimal)
  if [ "$master_uuid" != "$INSTALLATION_UUID" ] ; then
    logmsg 0 'xsbup must be run on the pool master and this host does not appear to be the master.'
    logmsg 0 $(printf "Pool master: %n" "$master_uuid")
    logmsg 0 $(printf "This host:   %s" "$INSTALLATION_UUID")
    exit 1
  fi

  # validate configuration
  logmsg 4 'Validating configuration'
  [ ! -d "$dest_path" ] && { logmsg 0 $(printf "Not a valid path: %s" "$dest_path"); exit 1; }
  [ ! -w "$dest_path" ] && { logmsg 0 $(printf "Permission denied: %s" "$dest_path"); exit 1; }

  # try and take our lockfile
  take_lockfile

  # renice ourself to minimize performance impact on the system
  renice_self "$$"

  logmsg 0 'xsbup started'
  logmsg 0 $(printf "Backups will be written to %s" "$dest_path")

  # what virtual machines are we going to backup?
  if [ -n "$backup_all_vms" ] ; then
    # backup all virtual machines
    logmsg 0 'Going to backup ALL Virtual Machines'
    declare -r vms_to_backup=$(xe vm-list is-control-domain=false | xe_param uuid)
  elif [ -n "$target_vm" ] ; then
    # backup the vm with this name-label
    logmsg 0 $(printf 'Going to backup Virtual Machine "%s" only' "$target_vm")
    declare -r vms_to_backup=$(xe vm-list name-label="$target_vm" | xe_param uuid)
  else
    # backup only running VMs
    logmsg 0 'Going to backup all RUNNING Virtual Machines'
    declare -r vms_to_backup=$(xe vm-list power-state=running is-control-domain=false | xe_param uuid)
  fi

  # loop through the list of VMs and backup each one
  for vm_uuid in $vms_to_backup ; do
    vm_name="$(get_vm_name_by_uuid $vm_uuid)"
    xva_fname="${vm_name}-${date_ymd}.xva"

    logmsg 0 $(printf 'Backup for VM "%s" started' "$vm_name")

    logmsg 1 "Preparing VM for backup"
    snapshot_uuid=$(prepare_vm_for_backup "$vm_uuid" )
    if [ -n "$snapshot_uuid" ] ; then
      logmsg 2 "Snapshot UUID is $snapshot_uuid"
      uuid_to_backup="$snapshot_uuid"
    else
      uuid_to_backup="$vm_uuid"
    fi
    
    logmsg 1 "Starting export to XVA"
    do_xva_backup "$vm_uuid" "$uuid_to_backup" "$dest_path/$vm_name" "$xva_fname"

    if [ -n "$snapshot_uuid" ] ; then
      logmsg 1 "Removing snapshot"
      delete_snapshot "$snapshot_uuid" || true
    fi

    logmsg 1 "Removing expired backups outside retention period"
    cleanup_xva_backups "$vm_uuid" "$retain_cnt" "$dest_path/$vm_name"

    logmsg 0 $(printf 'Backup for VM "%s" completed' "$vm_name")
  done

  # dump some metadata to disk with the backups
  logmsg 0 'Dumping metadata'
  dump_pool_metadata "$dest_path"

  logmsg 0 'xbsup complete; exiting.'
  return 0
}

main $@

exit 0
