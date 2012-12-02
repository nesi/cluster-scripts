#!/usr/bin/env bash 

###################################################################################
#
# Run a series of grompp and mdrun/mdrun_mpi commands using mdp files as input
# for each run.
# The list of mdp files can be specified in 2 ways:
#  * Use the -f parameter to pass in a file that contains a list of mdp files,
#    one mdp file per line. The mdp files are processed in the order they are
#    listed in the input file
#  * Don't specify a file. In that case all mdp files in the data directory
#    will be picked up. The mdp files must be named in a way that 'ls *.mdp'
#    will get them in the correct order.
#
###################################################################################

# Variables 
export GROMACS=/share/apps/gromacs
export GMXLIB=${GROMACS}/share/gromacs/top
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH}:${GROMACS}/lib

ERROR_RC=127

grompp_cmd="${GROMACS}/bin/grompp"
mdrun_cmd="${GROMACS}/bin/mdrun"
data_dir=""
initial_gro_file=""
topology_file=""
mdps=""
grompp_maxwarn=""
mdrun_nt=""
mpi_mode=""
tuned=""

# Print usage information
function print_usage {
  echo "
  Usage: $0 <Parameters>

  Parameters:
    -d <data directory>
       Directory where all input files for the run are located, and where the mdrun
       output files will be stored
    -i <initial .gro file>
       Name of the inital .gro file to be used in the first iteration.
       (Relative to the data directory)
    [-t <topology file>]
       Name of an optional topology file, relative to data directory. Defaults to topol.top.
    [-f <file containing a list of mdp files>]
       Optional parameter. Specify a file in the data directory that contains a list
       of all mdp files to be processed in the order as specified in the file.
       One mdp file per line.
    [-h]
       Optional parameter. Print this help
    [-mpi]
       Optional parameter. Perform GROMACS simulation across multiple CPUs or systems
    [-grompp_maxwarn <number>]
       Optional parameter. -maxwarn parameter for grompp
    [-nt <number_of_threads>]
       Optional parameter. -nt parameter for mdrun
    [-tuned]
      Optional parameter. Use gromacs in-build auto-tuning capability
  
  Examples:
    $0 -d /home/dmer018/funnel_web_test -i confout.gro
    $0 -d /home/dmer018/funnel_web_test -i confout.gro -f mdp_files.txt
    $0 -d /home/dmer018/funnel_web_test -i confout.gro -mpi -grompp_maxwarn 2
  "
}

# Read and process command-line parameters
function process_commandline_params {
    while [ $# -gt 0 ]; do
        case $1 in
            -d) data_dir=${2}; shift 2; data_dir=$(echo $data_dir|sed 's/\\//g');;
            -f) mdps=${2}; shift 2;;
            -i) initial_gro_file=${2}; shift 2;;
	    -t) topology_file=${2}; shift 2;;
            -h) print_usage; exit 0;;
            -mpi)
                if [ -z "${LOADL_HOSTFILE}" ] ; then
                   handle_fatal_error "$0 must be invoked via LoadLeveler if in MPI mode." "no"
                fi
		mpi_mode="mpi"
                shift 1;;
            -grompp_maxwarn) grompp_maxwarn="-maxwarn ${2}"; shift 2;;
            -nt) 
		mdrun_nt="-nt ${2}"; shift 2;;
	    -tuned)
		tuned="true"
            *) shift 1;;
        esac
    done

    # checking whether incompatible options were specified
    if [  ! -z "${mdrun_nt}" ] && [ ! -z "${mpi_mode}" ] ; then
	    handle_fatal_error "-mpi and -mdrun_nt options can't be set both at the same time"
    fi

   # setting mdrun_cmd
   if [ ! -z "${mpi_mode} ]; then
       # tuned mode
       if [ -z "${tuned} ]; then
                num_procs="$(cat ${LOADL_HOSTFILE} | wc -l)"
                mdrun_cmd="${GROMACS}/bin/g_tune_pme -launch -np ${num_procs} -r 2"
                export MDRUN="${GROMACS}/bin/mdrun_mpi"
                export MPIRUN="mpirun -x LD_LIBRARY_PATH -mca btl_openib_ib_timeout 30 -mca btl_openib_ib_min_rnr_timer 30 -machinefile ${LOADL_HOSTFILE}"
       # un-tuned mpi
       else
                mdrun_cmd="mpirun -x LD_LIBRARY_PATH -mca btl_openib_ib_timeout 30 -mca btl_openib_ib_min_rnr_timer 30 -machinefile ${LOADL_HOSTFILE} ${GROMACS}/bin/mdrun_mpi"
       fi
   fi
       
}

function handle_fatal_error {
    msg=${1}
    no_usage=${2}
    echo "${msg}" >&2
    if [ -z "${no_usage}" ] ; then 
    	print_usage
    fi
    exit ${ERROR_RC}
}

function check_prerequisites {
    # Check data directory
    if [ "" == "${data_dir}" ]; then
        handle_fatal_error "Error: data directory has not been specified"
    elif [ ! -d ${data_dir} ]; then
        handle_fatal_error "Error: ${data_dir} is not a directory or doesn't exist" "no"
    fi

    # Check inital gro file
    if [ "" == "${initial_gro_file}" ]; then
        handle_fatal_error "Error: Initial .gro file has not been specified"
    elif [ ! -f ${data_dir}/${initial_gro_file} ]; then
        handle_fatal_error "Error: ${data_dir}/${initial_gro_file} is not a file or doesn't exist" "no"
    fi

    # Check file that contains list of mdp files
    if [ -n "${mdps}" ]; then
        mdps="${data_dir}/${mdps}"
        if [ ! -f ${mdps} ]; then
            handle_fatal_error "Error: ${mdps} is not a file or doesn't exist" "no"
        fi
    fi
    # Check topology file
    if [ "" == "${topology_file}" ]; then
	topology_file="topol.top"
    fi
    if [ ! -f ${data_dir}/${topology_file} ]; then
        handle_fatal_error "Error: ${data_dir}/${topology_file} is not a file or doesn't exist" "no"
    fi

}

##################### Main program ###########################

process_commandline_params "$@"
check_prerequisites
cd ${data_dir}

previous_prefix=""

if [ -n "${mdps}" ]; then
    mdp_files=$(cat ${mdps})
else
    mdp_files=$(ls *.mdp)
fi

# Loop over all mdp files and run grompp and mdrun
for mdp_file in ${mdp_files}; do

    prefix=${mdp_file%.*}

    if [ -z "${previous_prefix}" ]; then
        gro_file="${initial_gro_file}"
        after_gro="after_${prefix}.gro"
    else
        gro_file="after_${previous_prefix}.gro"
        after_gro="after_${prefix}.gro"
    fi


    #echo "DEBUG ${grompp_cmd} -f ${prefix}.mdp -c ${gro_file} -p -o ${prefix} ${grompp_maxwarn}"
    ${grompp_cmd} -f ${prefix}.mdp -c ${gro_file} -p ${topology_file} -o ${prefix} ${grompp_maxwarn}
    if [ "$?" != "0" ]; then
      handle_fatal_error "${grompp_cmd} failed while processing ${mdp_file}" "no"
    fi

    #echo "DEBUG ${mdrun_cmd} -v ${mdrun_nt} -s ${prefix} -e ${prefix} -x ${prefix} -c ${after_gro} -g ${prefix} -o ${prefix}"
    ${mdrun_cmd} -v ${mdrun_nt} -s ${prefix} -e ${prefix} -x ${prefix} -c ${after_gro} -g ${prefix} -o ${prefix}
    if [ "$?" != "0" ]; then
      handle_fatal_error "${mdrun_cmd} failed while processing ${mdp_file}" "no"
    fi

    previous_prefix="${prefix}"

done

