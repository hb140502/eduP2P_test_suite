#!/bin/bash

usage_str="""
Usage: ${0} [OPTIONAL ARGUMENTS] <CONTROL SERVER PORT> <RELAY SERVER PORT> <LOG LEVEL>

This script runs multiple system tests sequentially

The type of tests that are run depends on [OPTIONAL ARGUMENTS], of which at least one should be provided:
    -c <packet loss>
        Run the test suite's connectivity tests with all combinations of RFC 3489 NATs
        The percentage of packets that should be dropped during the tests should be provided as a real number in the interval [0, 100)
    -e 
        Extends the connectivity tests to all combinations of RFC 4787 NATs
    -f <file>
        Run custom tests from an existing file. One test should be specified on a single line, and this line should be a call to the run_system_test function found in this script
    -p
        Run the test suite's performance tests


<LOG LEVEL> should be one of {trace|debug|info} (in order of most to least log messages), but can NOT be info if one if the peers is using userspace WireGuard (then IP of the other peer is not logged)"""

# Use functions and constants from util.sh
. ./util.sh

# Validate optional arguments
while getopts ":c:ef:ph" opt; do
    case $opt in
        c)  
            connectivity=true
            packet_loss=$OPTARG

            # Make sure packet_loss is a real number
            real_regex="^[0-9]+[.]?([0-9]+)?$"
            validate_str $packet_loss $real_regex

            # Make sure packet loss is in the interval [0, 100)
            in_interval=$(echo "$packet_loss >= 0 && $packet_loss < 100" | bc) # 1=true, 0=false

            if [[ $in_interval -eq 0 ]]; then
                print_err "packet loss argument is not in the interval [0, 100)"
                exit 1
            fi
            ;;
        e)
            extended=true
            ;;
        f)
            file=$OPTARG

            # Make sure file exists
            if [[ ! -f $file ]]; then
                print_err "$file does not exist"
                exit 1
            fi
            ;;
        p)
            performance=true
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

control_port=$1
relay_port=$2
log_lvl=$3

# Make sure all arguments have been passed, and at least one optional argument is provided
if [[ $# -ne 3  || !( -n $file || $connectivity == true || $performance == true )]]; then
    print_err "expected 13 positional parameters, but received $#"
    exit 1
fi

# Make sure at least one option argument is provided
if [[ !( -n $file || $connectivity == true || $performance == true ) ]]; then
    print_err "at least one option should be set"
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
    for binary in test_client control_server relay_server; do
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
    # Get IP of control and relay servers
    control_ip=$(sudo ip netns exec control ip addr show control | grep -Eo "inet [0-9.]+" | cut -d ' ' -f2)
    relay_ip=$(sudo ip netns exec relay ip addr show relay | grep -Eo "inet [0-9.]+" | cut -d ' ' -f2)

    control_pub_key=$(extract_server_pub_key "control_server" $control_ip $control_port)
    relay_pub_key=$(extract_server_pub_key "relay_server" $relay_ip $relay_port)

    # Add relay server to control server config
    cd ${repo_dir}/cmd/control_server
    sudo python3 configure_json.py $relay_pub_key $relay_ip $relay_port

    echo "Starting servers"
    start_server "control_server" $control_ip $control_port
    start_server "relay_server" $relay_ip $relay_port
}

setup_servers

n_tests=0
n_failed=0

# Usage: run_system_test [optional arguments of system_test.sh] <first 4 positional parameters of system_test.sh>
function run_system_test() {
    let "n_tests++"
    ./system_test.sh $@ $n_tests $control_pub_key $control_ip $control_port $relay_port "$adm_ips" $log_lvl $log_dir $repo_dir

    if [[ $? -ne 0 ]]; then
        let "n_failed++"
    fi
}

cd $repo_dir/test_suite

function connectivity_test_logic() {
    ns_config=$1
    wg_config=$2
    nat1_mapping=$3
    nat1_filter=$4
    nat2_mapping=$5
    nat2_filter=$6

    # Determine expected test result
    if [[ $nat1_filter -eq 0 || $nat2_filter -eq 0 ]]; then
        # An EIF NAT always lets the peer's pings through
        test_target="TS_PASS_DIRECT"
    elif [[ $nat1_mapping -eq 0 && $nat2_mapping -eq 0 ]]; then
        # Two peers behind EIM NATs send pings to each other from their own STUN endpoint, to the other's STUN endpoint
        # After sending one ping, the subsequent incoming pings from the peer's STUN endpoint will be accepted, regardless of the filtering behaviour
        test_target="TS_PASS_DIRECT"
    elif [[ $nat1_mapping -eq 0 && $nat1_filter -eq 1 || $nat2_mapping -eq 0 && $nat2_filter -eq 1 ]]; then
        # An EIF-ADF NAT will always let the peer's pings through after sending its first ping
        # This is not a general property of EIM-ADF NATs, but holds in this test suite because each NAT only has one IP address
        test_target="TS_PASS_DIRECT"
    else
        test_target="TS_PASS_RELAY"
    fi

    rfc_3489_nats=("0-0" "0-1" "0-2" "2-2")

    # Skip symmetrical cases
    if [[ $nat2_mapping -gt $nat1_mapping || $nat2_mapping -eq $nat1_mapping && $nat2_filter -ge $nat1_filter ]]; then 
        nat1=$nat1_mapping-$nat1_filter
        nat2=$nat2_mapping-$nat2_filter

        # Only test RFC 3489 NATs unless the extended flag was set
        if [[ (${rfc_3489_nats[@]} =~ $nat1 && ${rfc_3489_nats[@]} =~ $nat2) || $extended == true ]]; then
            nat_config=$nat1:$nat2
            run_system_test $test_target $ns_config $nat_config $wg_config
        fi
    fi
}

if [[ $connectivity == true ]]; then
    sudo ./set_packet_loss.sh $packet_loss
    rfc_3489_nats=("0-0" "0-1" "0-2" "2-2")

    echo """
Starting connectivity tests between two peers (possibly) behind NATs with various combinations of mapping and filtering behaviour:
    - Endpoint-Independent Mapping/Filtering (EIM/EIF)
    - Address-Dependent Mapping/Filtering (ADM/ADF)
    - Address and Port-Dependent Mapping/Filtering (ADPM/ADPF)"""

    echo -e "\nTests with one peer behind a NAT"
    for nat_mapping in {0..2}; do
        for nat_filter in {0..2}; do
            nat=$nat_mapping-$nat_filter

            # Only test RFC 3489 NATs unless the extended flag was set
            if [[ ${rfc_3489_nats[@]} =~ $nat || $extended == true ]]; then
                run_system_test TS_PASS_DIRECT private1_peer1-router1:router2 $nat: wg0:
            fi
        done
    done

    echo -e "\nTests with both peers behind a NAT"
    for nat1_mapping in {0..2}; do
        for nat1_filter in {0..2}; do
            for nat2_mapping in {0..2}; do
                for nat2_filter in {0..2}; do
                    connectivity_test_logic private1_peer1-router1:router2-private2_peer1 wg0: $nat1_mapping $nat1_filter $nat2_mapping $nat2_filter
                done
            done
        done
    done

    echo -e "\nTest hairpinning"
    for nat_mapping in {0..2}; do
        for nat_filter in {0..2}; do
            nat=$nat_mapping-$nat_filter

            # Only test RFC 3489 NATs unless the extended flag was set
            if [[ ${rfc_3489_nats[@]} =~ $nat || $extended == true ]]; then
                run_system_test TS_PASS_DIRECT private1_peer1-router1-private1_peer2 $nat: wg0:
            fi
        done
    done
fi

if [[ $performance == true ]]; then
    echo -e "\nPerformance tests (without NAT)"
    run_system_test -k packet_loss -v 0,0.5,1 -d 1 TS_PASS_DIRECT router1-router2 : wg0:
    run_system_test -k bitrate -v 1,10,100 -d 1 TS_PASS_DIRECT router1-router2 : wg0:
fi

if [[ -n $file ]]; then
    echo -e "\nTests from file: $file"
    while read test_cmd; do
        eval $test_cmd
    done < $file
fi

function print_summary() {
    if [[ $n_failed -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
    else
        echo -e "${RED}$n_failed/$n_tests tests failed!${NC}"
        exit 1
    fi
}

print_summary

# Create graphs for performance tests, if any were included
python3 visualize_performance_tests.py $log_dir