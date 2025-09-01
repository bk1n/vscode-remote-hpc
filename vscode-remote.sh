#!/bin/bash

# Set your SGE parameters for GPU and CPU jobs here (examples below)
# Tip: mirror what you'd pass to qsub/qlogin. For example, for a GPU session you use:
#   qlogin -q gpu -l gpu=N -pe sharedmem M -l h='node3c01'
# Then set SGE_PARAM_GPU accordingly (e.g. "-q gpu -l gpu=1 -pe sharedmem 8 -l h=node3c01").
SGE_PARAM_CPU="-q gpu -l h='node3c01' -o /dev/null -e /dev/null"
SGE_PARAM_GPU="-q gpu -l h='node3c01' -o /dev/null -e /dev/null"

# The time you expect a job to start in (seconds)
# If a job doesn't start within this time, the script will exit and cancel the pending job
TIMEOUT=30


####################
# don't edit below this line
####################

function usage ()
{
    echo "Usage :  $0 [command]

    General commands:
    list      List running vscode-remote jobs
    cancel    Cancels running vscode-remote jobs
    ssh       SSH into the node of a running job
    help      Display this message

    Job commands (see usage below):
    cpu       Connect to a CPU node
    gpu       Connect to a GPU node

    You should _NOT_ manually call the script with 'cpu' or 'gpu' commands.
    They should be used in the ProxyCommand in your ~/.ssh/config file, for example:
        Host vscode-remote-cpu
            User USERNAME
            IdentityFile ~/.ssh/vscode-remote
            ProxyCommand ssh HPC-LOGIN \"~/bin/vscode-remote cpu\"
            StrictHostKeyChecking no  

    You can have a CPU and GPU job running at the same time, just add them as separate hosts in your config.
    "
} 

function query_sge () {
    # Robustly query SGE using XML output so we get the full job name (qstat truncates the text view).
    # We match jobs whose full name begins with $JOB_NAME (e.g. vscode-remote-gpu_12345).
    local line
    line=$(qstat -u "$USER" -xml 2>/dev/null | awk -v name="$JOB_NAME" '
        /<job_list /       { injob=1; id=""; nm=""; st=""; q=""; next }
        injob && /<JB_job_number>/ { sub(".*<JB_job_number>",""); sub("</JB_job_number>.*",""); id=$0; next }
        injob && /<JB_name>/       { sub(".*<JB_name>","");       sub("</JB_name>.*","");       nm=$0; next }
        injob && /<state>/         { sub(".*<state>","");         sub("</state>.*","");         st=$0; next }
        injob && /<queue_name>/    { sub(".*<queue_name>","");    sub("</queue_name>.*","");    q=$0; next }
        injob && /<\/job_list>/ {
            if (index(nm, name)==1) { print id" "nm" "st" "q; exit }
            injob=0
        }
    ')
    if [ -n "$line" ]; then
        read -r JOB_ID JOB_FULLNAME JOB_STATE JOB_QUEUE <<< "$line"

        # Extract node from queue column (format queue@node)
        if [ -n "$JOB_QUEUE" ]; then
            JOB_NODE=${JOB_QUEUE#*@}
            JOB_NODE=${JOB_NODE%%.*}
        else
            JOB_NODE=""
        fi

        # Our job name encodes the port as NAME_PORT (underscore as separator)
        IFS='_' read -r _ JOB_PORT <<< "$JOB_FULLNAME"

        >&2 echo "Job is $JOB_STATE ( id: $JOB_ID, name: $JOB_FULLNAME${JOB_NODE:+, node: $JOB_NODE} )"
    else
        JOB_ID=""
        JOB_FULLNAME=""
        JOB_STATE=""
        JOB_NODE=""
        JOB_PORT=""
    fi
}

function cleanup () {
    if [ ! -z "${JOB_SUBMIT_ID}" ]; then
    qdel $JOB_SUBMIT_ID
    >&2 echo "Cancelled pending job $JOB_SUBMIT_ID"
    fi
}

function timeout () {
    if (( $(date +%s)-START > TIMEOUT )); then 
        >&2 echo "Timeout, exiting..."
        cleanup
        exit 1
    fi
}

function cancel () {
    query_sge > /dev/null 2>&1
    while [ -n "${JOB_ID}" ]; do
        echo "Cancelling running job $JOB_ID${JOB_NODE:+ on $JOB_NODE}"
        qdel $JOB_ID >/dev/null 2>&1
        timeout
        sleep 2
        query_sge > /dev/null 2>&1
    done
}

function list () {
    # Use XML so names aren’t truncated in the listing either.
    qstat -u "$USER" -xml 2>/dev/null | awk -v name="$JOB_NAME" '
        /<job_list /       { injob=1; id=""; nm=""; st=""; q=""; next }
        injob && /<JB_job_number>/ { sub(".*<JB_job_number>",""); sub("</JB_job_number>.*",""); id=$0; next }
        injob && /<JB_name>/       { sub(".*<JB_name>","");       sub("</JB_name>.*","");       nm=$0; next }
        injob && /<state>/         { sub(".*<state>","");         sub("</state>.*","");         st=$0; next }
        injob && /<queue_name>/    { sub(".*<queue_name>","");    sub("</queue_name>.*","");    q=$0; next }
        injob && /<\/job_list>/ {
            if (index(nm, name)==1) printf "%s %s %s %s\n", id, st, nm, q
            injob=0
        }
    '
}

function ssh_connect () {
    ROOT_NAME=$JOB_NAME

    JOB_NAME=$ROOT_NAME-cpu
    query_sge
    CPU_NODE=$JOB_NODE

    JOB_NAME=$ROOT_NAME-gpu
    query_sge
    GPU_NODE=$JOB_NODE

    if [ ! -z "${CPU_NODE}" ] && [ ! -z "${GPU_NODE}" ]; then
        echo "Multiple jobs found, please specify which node to connect to:"
        echo "1) $CPU_NODE (CPU)"
        echo "2) $GPU_NODE (GPU)"
        read -p "Enter 1 or 2: " choice
        if [ "$choice" == "1" ]; then
            GPU_NODE=
        elif [ "$choice" == "2" ]; then
            CPU_NODE=
        else
            echo "Invalid choice"
            exit 1
        fi
    fi

    if [ ! -z "${CPU_NODE}" ]; then
        NODE=$CPU_NODE
        TYPE=CPU
    elif [ ! -z "${GPU_NODE}" ]; then
        NODE=$GPU_NODE
        TYPE=GPU
    else
        echo "No running job found"
        exit 1
    fi

    echo "Connecting to $NODE ($TYPE) via SSH"
    ssh $NODE
}

function connect () {
    query_sge

    echo JOB_STATE: $JOB_STATE

    if [ -z "${JOB_STATE}" ]; then
        PORT=$(shuf -i 10000-65000 -n 1)

        echo $SGE_PARAM
        echo $PORT

        list=($(qsub -terse -N ${JOB_NAME}_$PORT $SGE_PARAM $SCRIPT_DIR/vscode-remote-job.sh $PORT 2>/dev/null))
        # qsub -terse returns the job id on a single line
        JOB_SUBMIT_ID=${list[0]}
        >&2 echo "Submitted new $JOB_NAME job (id: ${JOB_SUBMIT_ID:-unknown})"
    fi

    # In SGE, running state is typically 'r'
    while [ "$JOB_STATE" != "r" ]; do
        timeout
        sleep 5
        query_sge
        echo $JOB_STATE
    done

    >&2 echo "Connecting to $JOB_NODE"

    while ! nc -z $JOB_NODE $JOB_PORT; do 
        timeout
        sleep 1 
    done

    nc $JOB_NODE $JOB_PORT
}

if [ ! -z "$1" ]; then
    JOB_NAME=vscode-remote
    SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

    echo $JOB_NAME
    echo $SCRIPT_DIR

    START=$(date +%s)
    trap "cleanup && exit 1" INT TERM
    case $1 in
        list)   list ;;
        cancel) cancel ;;
        ssh)    ssh_connect ;;
        cpu)    JOB_NAME=$JOB_NAME-cpu; SGE_PARAM=$SGE_PARAM_CPU; connect ;;
        gpu)    JOB_NAME=$JOB_NAME-gpu; SGE_PARAM=$SGE_PARAM_GPU; connect ;;
        help)   usage ;;
        *)  echo -e "Command '$1' does not exist" >&2
            usage; exit 1 ;;
    esac  
    exit 0
else
    usage
    exit 0
fi
