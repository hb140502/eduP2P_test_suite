#!/bin/bash

usage_str="""
Usage: ${0} [OPTIONAL ARGUMENTS] <PEER ID> <CONTROL SERVER PUBLIC KEY> <CONTROL SERVER IP> <CONTROL SERVER PORT> <LOG LEVEL> <PERFORMANCE TEST ROLE> [WIREGUARD INTERFACE]

[OPTIONAL ARGUMENTS] can be provided for a performance test:
    -k <packet_loss|bitrate>
    -v <comma-separated string of positive real numbers>
    -d <seconds>

<LOG LEVEL> should be one of {trace|debug|info} (in order of most to least log messages), but can NOT be info if one if the peers is using userspace WireGuard (then IP of the other peer is not logged)

<PERFORMANCE TEST ROLE> should be either 'client', 'server' or 'none'

If [WIREGUARD INTERFACE] is not provided, this peer will use userspace WireGuard"""

# Use functions and constants from util.sh
. ../../test_suite/util.sh

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

# Make sure all mandatory arguments have been passed
if [[ $# < 7 || $# > 8 ]]; then
    print_err "expected 7 or 8 positional parameters, but received $#"
    exit 1
fi

id=$1
control_pub_key=$2
control_ip=$3
control_port=$4
log_lvl=$5
log_dir=$6
performance_test_role=$7
wg_interface=$8

# Create WireGuard interface if wg_interface is set
if [[ -n $wg_interface ]]; then
    sudo ip link add $wg_interface type wireguard
    sudo wg set $wg_interface listen-port 0 # 0 means port is chosen randomly
    sudo ip link set $wg_interface up
fi

# Create pipe to redirect input to toverstok CLI
pipe="toverstok_in_${id}"
mkfifo $pipe

# Create temporary file to store toverstok CLI output
out="toverstok_out_${id}.txt"

# Redirect pipe to toverstok binary, and also store its output in a temporary file
(sudo ./toverstok < $pipe 2>&1 | tee $out &) # Use sed to copy the combined output stream to the specified log file, until the test suite's exit code is found &)

# Ensure pipe remains open by continuously feeding input in background
(
    while true; do
        echo "" > $pipe
    done
)&

# Save pid of above background process to kill later
feed_pipe_pid=$!

function clean_exit () {
    exit_code = $1

    # Kill process continuosly feeding input to toverstok
    sudo kill $feed_pipe_pid
    wait $feed_pipe_pid &> /dev/null

    # Remove pipe
    sudo rm $pipe

    # Remove temporary toverstok output file
    sudo rm $out

    # Terminate toverstok, which remains open with userspace WireGuard
    toverstok_pid=$(pgrep toverstok) && sudo kill $toverstok_pid

    # Remove http server output files
    if [[ -n $http_ipv4_out ]]; then rm $http_ipv4_out; fi
    if [[ -n $http_ipv6_out ]]; then rm $http_ipv6_out; fi

    # Kill http servers 
    if [[ -n $http_ipv4_pid ]]; then kill $http_ipv4_pid; fi
    if [[ -n $http_ipv6_pid ]]; then kill $http_ipv6_pid; fi

    # Delete external WireGuard interface in case external WireGuard was used
    if [[ -n $wg_interface ]]; then sudo ip link del $wg_interface; fi

    exit $exit_code
}

# Generate commands from template and put them in the pipe
while read line; do
    eval $line > $pipe
done < commands_template.txt

# Get own virtual IPs and peer's virtual IPs; method is different for exernal WireGuard vs userspace WireGuard
if [[ -n $wg_interface ]]; then
    # Store virtual IPs as "<IPv4> <IPv6>"" when they are logged
    ips=$(timeout 10s tail -n +1 -f $out | sed -rn "/.*sudo ip address add (\S+) dev ${wg_interface}; sudo ip address add (\S+) dev ${wg_interface}.*/{s//\1 \2/p;q}")

    if [[ -z $ips ]]; then echo "TS_FAIL: could not find own virtual IPs in logs"; clean_exit 1; fi

    # Split IPv4 and IPv6
    ipv4=$(echo $ips | cut -d ' ' -f1) 
    ipv6=$(echo $ips | cut -d ' ' -f2)

    # Add virtual IPs to WireGuard interface
    sudo ip address add $ipv4 dev $wg_interface
    sudo ip address add $ipv6 dev $wg_interface
    
    # Remove network prefix length from own virtual IPs
    ipv4=$(echo $ipv4 | cut -d '/' -f1)
    ipv6=$(echo $ipv6 | cut -d '/' -f1)

    # Wait until timeout or until WireGuard interface is updated to contain peer's virtual IPs
    timeout=10
    peer_ips=$(wg show $wg_interface allowed-ips | cut -d$'\t' -f2) # IPs are shown as "<wg pubkey>\t<IPv4> <IPv6>"

    while [[ -z $peer_ips ]]; do
        sleep 1s
        let "timeout--"

        if [[ $timeout -eq 0 ]]; then
            echo "TS_FAIL: timeout waiting for eduP2P to update the WireGuard interface"
            clean_exit 1
        fi

        peer_ips=$(wg show $wg_interface allowed-ips | cut -d$'\t' -f2)
    done

    # Split IPv4 and IPv6, and remove network prefix length
    peer_ipv4=$(echo $peer_ips | cut -d ' ' -f1 | cut -d '/' -f1) 
    peer_ipv6=$(echo $peer_ips | cut -d ' ' -f2 | cut -d '/' -f1)
else
    # Wait until timeout or until TUN interface created with userspace WireGuard is updated to contain peer's virtual IPs
    timeout=10
    
    while ! ip address show ts0 | grep -Eq "inet [0-9.]+"; do
        sleep 1s
        let "timeout--"

        if [[ $timeout -eq 0 ]]; then
            echo "TS_FAIL: timeout waiting for eduP2P to update the WireGuard interface"
            clean_exit 1
        fi
    done

    # Extract own virtual IPs from TUN interface
    ipv4=$(ip address show ts0 | grep -Eo "inet [0-9.]+" | cut -d ' ' -f2)
    ipv6=$(ip address show ts0 | grep -Eo -m 1 "inet6 [0-9a-f:]+" | cut -d ' ' -f2)

    # Store peer IPs as "<IPv4> <IPv6>"" when they are logged
    peer_ips=$(timeout 10s tail -n +1 -f $out | sed -rn "/.*IPv4:(\S+) IPv6:(\S+).*/{s//\1 \2/p;q}")

    if [[ -z $peer_ips ]]; then echo "TS_FAIL: could not find peer's virtual IPs in logs"; clean_exit 1; fi

    # Split IPv4 and IPv6
    peer_ipv4=$(echo $peer_ips | cut -d ' ' -f1)
    peer_ipv6=$(echo $peer_ips | cut -d ' ' -f2)
fi

# Start HTTP servers on own virtual IPs for peer to access, and save their pids to kill them during cleanup
http_ipv4_out="http_ipv4_output_${id}.txt"
python3 -m http.server -b $ipv4 80 &> $http_ipv4_out &
http_ipv4_pid=$!

http_ipv6_out="http_ipv6_output_${id}.txt"
python3 -m http.server -b $ipv6 80 &> $http_ipv6_out &
http_ipv6_pid=$!

# Try connecting to peer's HTTP server hosted on IP addres
function try_connect() {
    peer_addr=$1

    if ! curl --retry 3 --retry-all-errors -I -s -o /dev/null $peer_addr; then
        echo "TS_FAIL: could not connect to peer's HTTP server with address: ${peer_ip}"
        clean_exit 1
    fi
}

try_connect "http://${peer_ipv4}"

# Peers try to connect directly after initial connection, wait until they are finished or until timeout in case direct connection is impossible
timeout 10s tail -f -n +1 $out | sed -n "/ESTABLISHED direct peer connection/q"

# Try connecting to peer's HTTP server hosted on its IPv4 address
try_connect "http://[${peer_ipv6}]"

# Wait until timeout or until peer connected to server (peer's IP will appear in server output)
timeout 10s tail -f -n +1 $http_ipv4_out | sed -n "/${peer_ipv4}/q"
timeout 10s tail -f -n +1 $http_ipv6_out | sed -n "/${peer_ipv6}/q"

# Optional performance test with iperf
function performance_test () {
    performance_test_val=$1
    performance_test_dir=$2

    # Default values
    bitrate=$(( 10**6 )) # Default iperf UDP bitrate is 1 Mbps

    # Assign performance_test_val to performance_test_var
    case $performance_test_var in
        "packet_loss")
            ./set_packet_loss.sh $performance_test_val
            ;;
        "bitrate")
            bitrate=$(( $performance_test_val * 10**6 )) # Convert to bits/sec
            ;;
    esac

    echo $bitrate

    # Run performance test
    connect_timeout=3

    case $performance_test_role in
    "client") 
        logfile=$performance_test_dir/$performance_test_var=$performance_test_val.json

        # Retry until server is listening or until timeout
        while ! iperf3 -c $peer_ipv4 -p 12345 -u -t $performance_test_duration -b $bitrate --json --logfile $logfile; do
            sleep 1s
            let "connect_timeout--"

            if [[ $connect_timeout -eq 0 ]]; then
                echo "TS_FAIL: timeout while trying to connect to peer's iperf server to test performance"
                clean_exit 1
            fi

            rm $logfile # File is created and contains an error message, delete for next iteration
        done 
        ;;
    "server") 
        test_timeout=$(($connect_timeout + $performance_test_duration + 1))
        mkdir $log_dir
        timeout ${test_timeout}s iperf3 -s -B $ipv4 -p 12345 --json -1 # -1 to close after first connection

        if [[ $? -ne 0 ]]; then
            echo "TS_FAIL: timeout while listening on iperf server to test performance"
            clean_exit 1
        fi
        ;;
esac
}

performance_test_dir=$log_dir/performance_tests_$performance_test_var
performance_test_values=$(echo $performance_test_values | tr ',' ' ') # Replace commas by spaces to iterate over each value easily

for performance_test_val in $performance_test_values; do
    mkdir -p $performance_test_dir
    performance_test $performance_test_val $performance_test_dir
done

echo "TS_PASS"
clean_exit 0