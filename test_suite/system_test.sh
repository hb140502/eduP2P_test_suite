#!/bin/bash

usage_str="""
Usage: ${0} [OPTIONAL ARGUMENTS] <TEST TARGET> <NAMESPACE CONFIGURATION> [NAT CONFIGURATION 1]:[NAT CONFIGURATION 2] [WIREGUARD INTERFACE 1]:[WIREGUARD INTERFACE 2] <TEST INDEX> <CONTROL SERVER PUBLIC KEY> <CONTROL SERVER IP> <CONTROL SERVER PORT> <RELAY SERVER PORT> <IP ADDRESS LIST> <LOG LEVEL> <LOG DIRECTORY> <REPOSITORY DIRECTORY>

[OPTIONAL ARGUMENTS] can be provided for a performance test:
    -k <packet_loss|bitrate>
    -v <comma-separated string of positive real numbers>
    -d <seconds>
    
<NAMESPACE CONFIGURATION> specifies the peer and router namespaces to be used in this system test. It should be a string with one of the following formats:
    1. <PEER 1>-<PEER 2>, for peers in the public network
    2. <PEER 1>-<ROUTER 1>:<PEER 2>, for one peer in a private network and the other in the public network
    3. <PEER 1>-<ROUTER 1>-<PEER 2> for peers in the same private network
    4. <PEER 1>-<ROUTER 1>:<ROUTER 2>-<PEER 2> for peers in different private networks

[NAT CONFIGURATION 1] and [NAT CONFIGURATION 2] specify the type of NAT applied to packets sent by peer 1 and 2 respectively. They should equal an empty string if the corresponding peer is in the public network, and otherwise follow this format:
    <NAT MAPPING TYPE>-<NAT FILTERING TYPE>, where both may be one of the following numbers: 
        0 - Endpoint-Independent
        1 - Address-Dependent
        2 - Address and Port-Dependent
Examples of valid NAT configurations: 0-1:1-2 (both peers in private networks), 0-1: (peer 2 in public network), : (both peers in public network)

If [WIREGUARD INTERFACE 1] or [WIREGUARD INTERFACE 2] is not provided, the corresponding peer will use userspace WireGuard

<IP ADDRESS LIST> is a string of IP addresses separated by a space that may be the destination IP of packets crossing this NAT device, and are necessary to simulate an Address-Dependent Mapping

<LOG LEVEL> should be one of {trace|debug|info} (in order of most to least log messages), but can NOT be info if one if the peers is using userspace WireGuard (then IP of the other peer is not logged)"""

# Use functions and constants from util.sh
. ./util.sh

performance_test_duration=0 # Default value in case -d is not used

# Validate optional arguments
while getopts ":k:v:d:h" opt; do
    case $opt in
        k)
            performance_test_var=$OPTARG
            validate_str $performance_test_var "^packet_loss|bitrate$"
            ;;
        v)
            performance_test_values=$OPTARG
            real_regex="[0-9]+(.[0-9]+)?"
            validate_str "$performance_test_values" "^$real_regex(,$real_regex)*$"
            ;;
        d)
            performance_test_duration=$OPTARG
            validate_str $performance_test_duration "^[0-9]+*$"
            ;;
        h) 
            echo "$usage_str"
            exit 0
            ;;
        *)
            print_err "invalid option -$opt"
            exit 1
            ;;
    esac
done

# Shift positional parameters indexing by accounting for the optional arguments
shift $((OPTIND-1))

# Make sure all required arguments have been passed
if [[ $# -ne 13 ]]; then
    print_err "expected 13 positional parameters, but received $#"
    exit 1
fi

test_target=$1
ns_config_str=$2
nat_config_str=$3  
wg_interface_str=$4
test_idx=$5
control_pub_key=$6
control_ip=$7
control_port=$8
relay_port=$9
adm_ips=${10}
log_lvl=${11}
log_dir=${12}
repo_dir=${13}

# Validate namespace configuration string
ns_regex="([^-:]+)"
ns_config1_regex="^${ns_regex}-${ns_regex}$"
ns_config2_regex="^${ns_regex}-${ns_regex}:${ns_regex}$"
ns_config3_regex="^${ns_regex}-${ns_regex}-${ns_regex}$"
ns_config4_regex="^${ns_regex}-${ns_regex}:${ns_regex}-${ns_regex}$"
validate_str $ns_config_str "$ns_config1_regex|$ns_config2_regex|$ns_config3_regex|$ns_config4_regex"

# Remove empty string elements in BASH_REMATCH, so that it only contains the matches of exactly one configuration
BASH_REMATCH=(${BASH_REMATCH[@]}) 

# Parse namespace configuration string into individual peers and routers
n_groups=$((${#BASH_REMATCH[@]} - 1))
peer_ns_list=(${BASH_REMATCH[1]} ${BASH_REMATCH[$n_groups]})
router_ns_list=()

for ((i=2; i<$n_groups; i++)); do
    router_ns_list+=(${BASH_REMATCH[$i]})
done

if [[ $ns_config_str =~ $ns_config3_regex ]]; then
    hairpinning=true
fi

# NAT configuration parsing depends on the amount of routers
n_routers=${#router_ns_list[@]} 
nat_config_regex="([0-2])-([0-2])"
nat_map=()
nat_filter=()

# Ensure the NAT configuration is provided for all routers
case $n_routers in 
    0) validate_str $nat_config_str "^:$";;
    1) validate_str $nat_config_str "^$nat_config_regex:$";;
    2) validate_str $nat_config_str "^$nat_config_regex:$nat_config_regex$";;
esac

# Store the individual Mapping and Filtering types
for ((i=0; i<$n_routers; i++)); do
    map_idx=$((1 + 2 * $i))
    filter_idx=$((2 + 2 * $i))
    nat_map+=(${BASH_REMATCH[$map_idx]})
    nat_filter+=(${BASH_REMATCH[$filter_idx]})
done

# Parse WireGuard interfaces string into individual interfaces
wg_interface_regex="^([^:]*):([^:]*)$"
validate_str $wg_interface_str $wg_interface_regex 
wg_interfaces=(${BASH_REMATCH[1]} ${BASH_REMATCH[3]})

# Prepare a string describing this system test
NAT_TYPES_LONG=("Endpoint-Independent" "Address-Dependent" "Address and Port-Dependent")
NAT_TYPES=("EI" "AD" "APD")

function describe_nat() {
    i=$1

    if [[ $i < $n_routers ]]; then 
        echo "${NAT_TYPES[${nat_map[$i]}]}M-${NAT_TYPES[${nat_filter[$i]}]}F"
    else
        echo "No-NAT"
    fi
}

# Prepare a string describing the NAT setup
if [[ $hairpinning == true ]]; then
    nat1_description=$(describe_nat 0)
    nat_setup="$nat1_description with hairpinning"
else
    nat1_description=$(describe_nat 0)
    nat2_description=$(describe_nat 1)
    nat_setup="$nat1_description <-> $nat2_description"
fi

# Prepare a string describing the test description
if [[ -n $performance_test_var ]]; then
    test_description="Test $test_idx (performance). $nat_setup, variable=$performance_test_var, target=$test_target, result="
else
    test_description="Test $test_idx (connectivity). $nat_setup, target=$test_target, result="
fi

# Output test description 
echo -n "$test_description"

# Add log subdirectory for this system test
new_dir="${log_dir}/${test_idx}_${nat1_description}_${nat2_description}"
mkdir $new_dir
log_dir=$new_dir

# Cleanup function called at end of script
function cleanup () {
    # Kill the conntrack processes started by the nat simulation scripts
    conntrack_pids=$(pidof conntrack)
    if [[ -n $conntrack_pids ]]; then sudo kill $conntrack_pids &> /dev/null; fi

    # Log final nftables configuration and conntrack list of the routers
    for router_ns in ${router_ns_list[@]}; do
        echo "nftables configuration after test finished:" >> ${log_dir}/$router_ns.txt
        sudo ip netns exec $router_ns nft list ruleset >> ${log_dir}/$router_ns.txt

        echo "conntrack list after test finished:" >> ${log_dir}/$router_ns.txt
        sudo ip netns exec $router_ns conntrack -L &>> ${log_dir}/$router_ns.txt
    done

    # Reset nftables configuration of the routers
    for router_ns in ${router_ns_list[@]}; do
        sudo ip netns exec $router_ns nft flush ruleset
    done

    # Reset nftables configuration of the public network
    sudo ip netns exec public nft flush chain inet filter forward
}

trap cleanup EXIT 

# Start NAT simulation on each router
cd ${repo_dir}/test_suite/nat_simulation

for ((i=0; i<${#router_ns_list[@]}; i++)); do
    router_ns=${router_ns_list[$i]}
    sudo ip netns exec $router_ns ./setup_nat_mapping.sh ${router_ns}_pub 10.0.$((i+1)).0/24 ${nat_map[$i]} "${adm_ips}"
    sudo ip netns exec $router_ns ./setup_nat_filtering_hairpinning.sh ${router_ns}_pub ${router_ns}_priv 192.168.$((i+1)).254 10.0.$((i+1)).0/24 ${nat_filter[$i]} 2>&1 | \
    tee ${log_dir}/$router_ns.txt > /dev/null & # combination of tee and redirect to /dev/null is necessary to avoid weird behaviour caused by redirecting a script run with sudo
done

# Start peers
cd ${repo_dir}/cmd/toverstok

function get_peer_performance_test_role() {
    i=$1
    roles=("server" "client")

    if [[ -n $performance_test_var ]]; then
        echo ${roles[$i]}
    else
        echo "none"
    fi
}

# Store PIDs of peer scripts
peer_pids=()

for i in {0..1}; do 
    peer_id="peer$((i+1))"
    peer_ns=${peer_ns_list[$i]}
    peer_logfile="$log_dir/$peer_id.txt"
    performance_test_role=$(get_peer_performance_test_role $i)

    if [[ $performance_test_role != "none" ]]; then
        optional_args="-k $performance_test_var -v $performance_test_values -d $performance_test_duration"
    fi
    
    touch $peer_logfile # Make sure file already exists so tail command later in script does not fail
    sudo ip netns exec $peer_ns ./setup_client.sh $optional_args `# Optional arguments` \
    $peer_id $control_pub_key $control_ip $control_port $log_lvl $log_dir $performance_test_role ${wg_interfaces[$i]} `# Positional parameters` \
    &> >(sed -r "/TS_(PASS|FAIL)/q" > $peer_logfile) & # Use sed to copy STDOUT and STDERR to a log file until the test suite's exit code is found (sed is run in subshell so $! will return the pid of setup_client.sh)

    peer_pids+=($!)
done

# Constants for colored text in output
RED="\033[0;31m"
GREEN="\033[0;32m"
NC="\033[0m" # No color

# Throw error if one of the two peers did not exit with TS_PASS or timed out
for i in {0..1}; do 
    peer_id="peer$((i+1))"
    export LOG_FILE=${log_dir}/$peer_id.txt # Export to use in bash -c
    n_performance_tests=${#performance_test_values}
    timeout_duration=$((30 + $n_performance_tests * $performance_test_duration))
    timeout ${timeout_duration}s bash -c 'tail -n 1 -f $LOG_FILE | sed -n "/TS_PASS/q2; /TS_FAIL/q3"' # bash -c is necessary to use timeout with | and still get the right exit codes

    # Branch on exit code of previous command
    case $? in
        0|1) echo -e "${RED}TS_FAIL: error when searching for exit code in logs of $peer_id${NC}"; exit 1 ;; # 0 and 1 indicate tail/sed failure
        2) ;; # 2 indicates TS_PASS was found
        3) echo -e "${RED}TS_FAIL: test failed for $peer_id; view this peer's logs for more information${NC}"; exit 1 ;; # 3 indicates TS_FAIL was found
        124) echo -e "${RED}TS_FAIL: timeout when searching for exit code in logs of $peer_id${NC}"; exit 1 ;; # 124 is default timeout exit code
        *) echo -e "${RED}TS_FAIL: unknown error${NC}"; exit 1 ;;
    esac
done

# Verify whether peers established a direct connection by searching for specific log message in either of the peers' logs
if grep -q "ESTABLISHED direct peer connection" ${log_dir}/peer*; then
    test_result="TS_PASS_DIRECT"
else
    test_result="TS_PASS_RELAY"
fi

# Output test result 
if [[ $test_target != $test_result ]]; then
    echo -e "${RED}$test_result${NC}"
    exit 1
fi

echo -e "${GREEN}$test_result${NC}"

# Wait for peer scripts to exit (might still be doing cleanup after outputting exit code)
wait ${peer_pids[@]} &> /dev/null