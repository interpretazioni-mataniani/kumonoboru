#!/bin/bash
## Script to run Restic backups to a B2 backend.
## It makes sure each of the preconfigured repositories can be safely backed up.
#+ Kumonoboru logs to a .prom file, which can subsequently be picked up by a Prometheus file handler,
#+ thus generating alerts.


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

## File to write results to; picked up by Prometheus and yells about changes.
## It is deleted 5 minutes after the script exits.
PROM_FILE="/your/prometheus/container/directory/data/kumonoboru.prom"


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
    echo -e "Bandwidth will be limited to" "$BWLIMIT Kbps" 
fi
if [[ -n $CLEAN ]]; then
    echo -e "Cleaning will take place per request."
fi
if [[ -n $REPOSITORY ]]; then
	    echo -e "Will only process repository" "$1"
fi	    

## Restic, when using a B2 backend, relies on these environment variables. Either set them here, in some other file, or in your system's environment to proceed - nothing works otherwise.
B2_ACCOUNT_ID=your-B2-account-ID
B2_ACCOUNT_KEY=your-B2-account-key
RESTIC_PASSWORD=your-restic-password


## Safety function; accepts repository to check
safety(){
	REPOSITORY="$1"
	echo -e "Checking if repository $REPOSITORY is in use "
	#Check no other Restic process is using this repository; Free unnecessary locks, if present
	if [[ -n $(ps aux | grep restic | grep "$REPOSITORY") ]]; then
		echo -e "Repository is in use - ignoring"
		echo "system_backup{name=\"$REPOSITORY\"} -1" >> $PROM_FILE
		return 1	#					code for   ^ failed to unlock
#		       ^ If there's a restic process holding the repository, leave it alone.
	else
		echo -e "Repository is not in use - unlocking"
		restic -q -r b2:$REPOSITORY unlock
#		silence ^		    ^ If a lock exists but no process, the repository is safe and should be unlocked.
	fi
}

## Backup function; accepts repository and path to backup
backup(){
	REPOSITORY="$1"
	REPOSITORY_PATH="$2"
	if safety "$REPOSITORY"; then
		echo -e "Backing up repository" "$REPOSITORY"
		if restic --cache-dir="$RESTIC_CACHE_DIR" -r b2:"$REPOSITORY" backup "$REPOSITORY_PATH" --limit-upload="$BWLIMIT" --limit-download="$BWLIMIT"; then
			echo -e "$REPOSITORY_PATH" "completed upload to $REPOSITORY."
			## Report result to Prometheus
			echo "system_backup{name=\"$REPOSITORY\"} 0" >> $PROM_FILE
		else
			echo -e "$REPOSITORY failed to upload path" "$REPOSITORY_PATH"
			echo "system_backup{name=\"$REPOSITORY\"} 1" >> $PROM_FILE
		fi
	fi
}

## Repository health check function; accepts repository to examine
check(){
	REPOSITORY="$1"
	PRUNE="$2"
##	^ This variable will have value if repo is already clean, indicating
#+	This is a post backup check.
	echo -e "Checking integrity (prune: $PRUNE) of repository $REPOSITORY"
	if [[ -n $PRUNE ]]; then
		echo -e "This repository has been cleaned already; will not clean again."
	fi
	if safety "$REPOSITORY"; then
		echo -e "Checking health of repository $REPOSITORY" 
		if restic -r b2:"$REPOSITORY" check --limit-upload="$BWLIMIT" --limit-download="$BWLIMIT"; then
			echo -e "Repository $REPOSITORY passed integrity check"
			echo "system_backup{name=\"$REPOSITORY\"} 2" >> $PROM_FILE
			echo -e "Current snapshots:"
			restic -r b2:"$REPOSITORY" snapshots
		else
			echo -e "Repository $REPOSITORY failed integrity check"
			echo "system_backup{name=\"$REPOSITORY\"} -2" >> $PROM_FILE

		fi
	fi
}

## Pruning function; enforces backup rotation policy
clean(){
	REPOSITORY="$1"
	if safety "$REPOSITORY"; then
		echo -e "Cleaning repository" "$REPOSITORY"
		if restic -r b2:$REPOSITORY forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune --limit-upload="$BWLIMIT" --limit-download="$BWLIMIT"; then
			echo -e "Repository $REPOSITORY is clean"
			echo "system_backup{name=\"$REPOSITORY\"} 3" >> $PROM_FILE
			echo -e "Running post clean check..."
			check "$REPOSITORY" "1"
#	 Marks repository as cleaned already ^ so it won't passed to this function again.
		else
				echo -e "Failed to clean repository $REPOSITORY"
				echo "system_backup{name=\"$REPOSITORY\"} -3" >> $PROM_FILE

		fi
	fi
}

## Repositories are specified in a local file
#+ Format:
#+ [repo-name] [path-on-local-filesystem]
#+ Kumonoboru will iterate over each entry

REPO_FILE=".kumonoboru"
if [[ ! -f $REPO_FILE ]]; then
	echo "Repository file $REPO_FILE is undefined. Please define $REPO_FILE."
	echo "Format:"
	echo "[B2-REPOSITORY] [LOCAL_PATH]"
	echo "Example:"
	echo "potato_tmp	/tmp/potato"
	exit 1
fi

## If a specific repository was requested, look for it in the file and register its' path
if [[ -n $REPOSITORY ]]; then
	repo_name=$(cat .kumonoboru | grep $REPOSITORY | awk '{print $1}')
	repo_path=$(cat .kumonoboru | grep $REPOSITORY | awk '{print $2}')

	if [[ -z $repo_name ]] || [[ -z $repo_path ]]; then
		echo "Could not find repository $REPOSITORY"
	else
		REPOS["$repo_name"]=$repo_path
	fi
## Otherwise, iterate over all entries
else
	declare -A REPOS
	while read -r repo_entry; do
		repo_name=$(echo "$repo_entry" | awk '{print $1}')
		repo_path=$(echo "$repo_entry" | awk '{print $2}')
		REPOS["$repo_name"]=$repo_path
	done < .kumonoboru
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

echo "All done; have a nice day!"

## Once the script finishes, the .prom file will live on for 2 minutes before being deleted.
#+ This allows Prometheus to pick up the alert, send out a notification, and move on with its life.
(
	sleep 120
 	rm $PROM_FILE
) 2>1 >/dev/null &
