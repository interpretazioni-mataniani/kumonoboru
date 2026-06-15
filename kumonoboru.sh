#!/bin/bash
## Script to run Restic backups to a B2 backend.
## It makes sure each of the preconfigured repositories can be safely backed up.
#+ Kumonoboru logs to a .prom file, which can subsequently be picked up by a Prometheus file handler,
#+ thus generating alerts.

source /usr/share/okoru/okoru.sh

show_help()
{
    echo "Kumonoboru - Back up important location to the B2 cloud using Restic." 
    echo "  {-c|--clean}                 -- Force prune of the remote repositories"
    echo "  {-r|--repository} repository -- Only backup the specified repository."
    echo "  {-l|--limit} #[Kbps]         -- Limit upload & download speed"
    echo "  {-v|--verbose}	       -- Print debug messages"
    echo "  {-h|--show_help}                  -- Print this show_help message and exit"
    exit 0
}

## Pass arguments to the script
flags()
{
    while test $# -gt 0
    do
        case "$1" in
	(-c|--clean)
	    export CLEAN="1"
	    shift;;
        (-r|--repository)
	    shift
	    export REPOSITORY="$1"
	    shift;;
        (-l|--limit)
	    shift
	    export BWLIMIT="$1"
	    shift;;
        (-h|--show_help)
	    show_help;;
        (*) show_help;;
        esac
    done
}
flags "$@"

## File to write results to; picked up by node_exporter textfile collector.
## Override via environment variable if needed.
PROM_FILE="${PROM_FILE:-/var/lib/node_exporter/textfile_collector/kumonoboru.prom}"


## Monitoring codes:
#+ -3 - failed cleaning
#+ -2 - failed integrity check
#+ -1 - failed to unlock
#+  0 - succesfully backed up
#+  1 - failed backup
#+  2 - passed integrity check
#+  3-  succesfully cleaned

#Defaults
if [[ -z $BWLIMIT ]]; then
	export BWLIMIT="0"
else
	info "Bandwidth will be limited to" "$BWLIMIT Kbps"
fi
if [[ -n $CLEAN ]]; then
	info "Cleaning will take place per request."
fi
if [[ -n $REPOSITORY ]]; then
	info "Will only process repository" "$REPOSITORY"
fi

## Restic B2 credentials and repository password.
## When installed as a package, these are set via EnvironmentFile=/etc/kumonoboru/env
## and do not need to be defined here.
: "${B2_ACCOUNT_ID:?B2_ACCOUNT_ID not set — define it in /etc/kumonoboru/env}"
: "${B2_ACCOUNT_KEY:?B2_ACCOUNT_KEY not set — define it in /etc/kumonoboru/env}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD not set — define it in /etc/kumonoboru/env}"


## Safety function; accepts repository to check
safety(){
	REPOSITORY="$1"
	info "Checking if repository $REPOSITORY is in use"
	if [[ -n $(ps aux | grep restic | grep "$REPOSITORY") ]]; then
		warn "Repository $REPOSITORY is in use - ignoring"
		echo "system_backup{name=\"$REPOSITORY\"} -1" >> $PROM_FILE
		return 1
	else
		info "Repository $REPOSITORY is not in use - unlocking"
		restic -q -r b2:$REPOSITORY unlock
	fi
}

## Backup function; accepts repository and path to backup
backup(){
	REPOSITORY="$1"
	REPOSITORY_PATH="$2"
	if safety "$REPOSITORY"; then
		info "Backing up repository" "$REPOSITORY"
		if restic --cache-dir="$RESTIC_CACHE_DIR" -r b2:"$REPOSITORY" backup "$REPOSITORY_PATH" --limit-upload="$BWLIMIT" --limit-download="$BWLIMIT"; then
			ok "$REPOSITORY_PATH completed upload to $REPOSITORY."
			echo "system_backup{name=\"$REPOSITORY\"} 0" >> $PROM_FILE
		else
			error "$REPOSITORY failed to upload path $REPOSITORY_PATH"
			echo "system_backup{name=\"$REPOSITORY\"} 1" >> $PROM_FILE
		fi
	fi
}

## Repository health check function; accepts repository to examine
check(){
	REPOSITORY="$1"
	PRUNE="$2"
	info "Checking integrity of repository $REPOSITORY"
	if [[ -n $PRUNE ]]; then
		info "Repository already cleaned this run - skipping second prune."
	fi
	if safety "$REPOSITORY"; then
		if restic -r b2:"$REPOSITORY" check --limit-upload="$BWLIMIT" --limit-download="$BWLIMIT"; then
			ok "Repository $REPOSITORY passed integrity check"
			echo "system_backup{name=\"$REPOSITORY\"} 2" >> $PROM_FILE
			info "Current snapshots:"
			restic -r b2:"$REPOSITORY" snapshots
		else
			error "Repository $REPOSITORY failed integrity check"
			echo "system_backup{name=\"$REPOSITORY\"} -2" >> $PROM_FILE
		fi
	fi
}

## Pruning function; enforces backup rotation policy
clean(){
	REPOSITORY="$1"
	if safety "$REPOSITORY"; then
		info "Cleaning repository" "$REPOSITORY"
		if restic -r b2:$REPOSITORY forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune --limit-upload="$BWLIMIT" --limit-download="$BWLIMIT"; then
			ok "Repository $REPOSITORY is clean"
			echo "system_backup{name=\"$REPOSITORY\"} 3" >> $PROM_FILE
			info "Running post-clean integrity check..."
			check "$REPOSITORY" "1"
		else
			error "Failed to clean repository $REPOSITORY"
			echo "system_backup{name=\"$REPOSITORY\"} -3" >> $PROM_FILE
		fi
	fi
}

## Repositories are specified in a local file
#+ Format:
#+ [repo-name] [path-on-local-filesystem]
#+ Kumonoboru will iterate over each entry

REPO_FILE="${REPO_FILE:-/etc/kumonoboru/repositories}"
if [[ ! -f $REPO_FILE ]]; then
	error "Repository file $REPO_FILE not found."
	info "Format: [B2-REPOSITORY] [LOCAL_PATH]  (e.g. my-bucket /opt/ebtb)"
	exit 1
fi

## If a specific repository was requested, look for it in the file and register its' path
if [[ -n $REPOSITORY ]]; then
	repo_name=$(grep "$REPOSITORY" "$REPO_FILE" | awk '{print $1}')
	repo_path=$(grep "$REPOSITORY" "$REPO_FILE" | awk '{print $2}')

	if [[ -z $repo_name ]] || [[ -z $repo_path ]]; then
		error "Could not find repository $REPOSITORY in $REPO_FILE"
	else
		REPOS["$repo_name"]=$repo_path
	fi
## Otherwise, iterate over all entries
else
	declare -A REPOS
	while read -r repo_entry; do
		[[ -z "$repo_entry" || "$repo_entry" == \#* ]] && continue
		repo_name=$(echo "$repo_entry" | awk '{print $1}')
		repo_path=$(echo "$repo_entry" | awk '{print $2}')
		REPOS["$repo_name"]=$repo_path
	done < "$REPO_FILE"
fi

for repo in "${!REPOS[@]}"; do
	repo_path=${REPOS[$repo]}

	# If cleaning was forced, or if it's the first of this month - clean the repository
	if [[ -n $CLEAN ]] || [[ $(date +%d) == "1" ]]; then
		check $repo
		clean $repo
	# Otherwise, proceed with backup
	elif [[ -z $CLEAN ]]; then
		backup $repo $repo_path	
	fi
done

ok "All done; have a nice day!"

## Once the script finishes, the .prom file will live on for 2 minutes before being deleted.
#+ This allows Prometheus to pick up the alert, send out a notification, and move on with its life.
(
	sleep 120
 	rm $PROM_FILE
) 2>1 >/dev/null &
