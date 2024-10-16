#!/bin/bash

control_port=$1
relay_port=$2
log_lvl=$3

# Make sure all arguments have been passed, and nat_config_str has the correct format
if [[ $# -ne 3 ]]; then
    echo """
Usage: ${0} <CONTROL SERVER PORT> <RELAY SERVER PORT> <LOG LEVEL> 

Executes multiple system tests sequentially, each testing a different NAT configuration

<LOG LEVEL> should be one of {trace|debug|info} (in order of most to least log messages), but can NOT be info if one if the peers is using userspace WireGuard (then IP of the other peer is not logged)"""
    exit 1
fi

# Store repository's root directory for later use
repo_dir=$(cd ..; pwd)

function cleanup () {
    # Kill the two servers if they have already been started by the script
    control_pid=$(pgrep control_server) && sudo kill $control_pid
    relay_pid=$(pgrep relay_server) && sudo kill $relay_pid

    # Kill any other background processes
    kill $(jobs -p) &> /dev/null
}

# Run cleanup when script exits
trap cleanup EXIT 

function build_go() {
    for binary in toverstok control_server relay_server; do
        binary_dir="${repo_dir}/cmd/$binary"
        go build -o "${binary_dir}/$binary" ${binary_dir}/*.go &> /dev/null
    done
}

build_go

function create_log_dir() {
    timestamp=$(date +"%Y-%m-%dT%H_%M_%S")
    log_dir_rel=logs/system_tests_${timestamp} # Relative path for pretty printing
    log_dir=${repo_dir}/test_suite/${log_dir_rel} # Absolute path for use in scripts running from different directories
    mkdir -p ${log_dir}
    echo "Logging to ${log_dir_rel}"
}

create_log_dir

function setup_networks() {
    cd nat_simulation/
    adm_ips=$(sudo ./setup_networks.sh) # setup_networks.sh returns an array of IPs used by hosts in the network simulation setup, this list is needed to simulate a NAT device with an Address-Dependent Mapping
}

setup_networks

function extract_server_pub_key() {
    server_type=$1 # control_server or relay_server
    ip=$2
    port=$3

    cd ${repo_dir}/cmd/$server_type
    pub_key=$(eval "./setup_$server_type.sh $ip $port")

    # If key variable is empty, server did not start successfully
    if [[ -z $pub_key ]]; then
        echo "TS_FAIL: error when starting $server_type with IP ip and port $control_port"
        exit 1
    fi

    echo $pub_key
}

function start_server() {
    server_type=$1 # control_server or relay_server
    ip=$2
    port=$3

    cd ${repo_dir}/cmd/$server_type
    eval "./start_$server_type.sh $ip $port 2>&1 | tee ${log_dir}/$server_type.txt > /dev/null &"
}

function setup_servers() {
    # Get IP of control and relay servers, which reside in the public namespace
    control_ip=$(sudo ip netns exec public ip addr show control | grep -Eo "inet [0-9.]+" | cut -d ' ' -f2)
    relay_ip=$(sudo ip netns exec public ip addr show relay | grep -Eo "inet [0-9.]+" | cut -d ' ' -f2)

    control_pub_key=$(extract_server_pub_key "control_server" $control_ip $control_port)
    relay_pub_key=$(extract_server_pub_key "relay_server" $relay_ip $relay_port)

    # Add relay server to control server config
    cd ${repo_dir}/cmd/control_server
    sudo python3 configure_json.py $relay_pub_key $relay_ip $relay_port

    echo "Starting servers in public namespace"
    start_server "control_server" $control_ip $control_port
    start_server "relay_server" $relay_ip $relay_port
}

setup_servers

n_tests=0
n_failed=0

function run_system_test() {
    test_target=$1
    ns_config_str=$2
    nat_config_str=$3  
    wg_interface_str=$4

    # Run test
    let "n_tests++"
    ./system_test.sh $n_tests $test_target $control_pub_key $control_ip $control_port $relay_port "${adm_ips}" $log_lvl $log_dir $repo_dir $ns_config_str $nat_config_str $wg_interface_str

    if [[ $? -ne 0 ]]; then
        let "n_failed++"
    fi

    # Make sure system_test.sh cleanup finishes before starting next test
    sleep 1s
}

cd $repo_dir/test_suite

echo """
Starting system tests between two peers behind NATs with various combinations of mapping and filtering behaviour:
    - Endpoint-Independent Mapping/Filtering (EIM/EIF)
    - Address-Dependent Mapping/Filtering (ADM/ADF)
    - Address and Port-Dependent Mapping/Filtering (ADPM/ADPF)
"""

echo "Test without NAT"
run_system_test TS_PASS_DIRECT router1-router2 : wg0:

echo -e "\nTests with one peer behind a NAT"
nat_types=("0-0" "0-1" "0-2" "2-2") # Full Cone, Restricted Cone, Port-restricted Cone, Symmetric

for nat in ${nat_types[@]}; do
    run_system_test TS_PASS_DIRECT private1_peer1-router1:router2 $nat: wg0:
done

echo -e "\nTests with both peers behind a NAT"
n_nats=${#nat_types[@]}

for ((i=0; i<$n_nats; i++)); do
    for ((j=$i; j<$n_nats; j++)); do
        nat1=${nat_types[$i]}
        nat2=${nat_types[$j]}

        if [[ $nat1 == "2-2" && $nat2 == "2-2" ]]; then
            test_target="TS_PASS_RELAY"
        else
            test_target="TS_PASS_DIRECT"
        fi

        run_system_test $test_target private1_peer1-router1:router2-private2_peer1 $nat1:$nat2 wg0:
    done
done

# Constants for colored text in output
RED="\033[0;31m"
GREEN="\033[0;32m"
NC="\033[0m" # No color

function print_summary() {
    if [[ $n_failed -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
    else
        echo -e "${RED}$n_failed/$n_tests tests failed!${NC}"
        exit 1
    fi
}

print_summary