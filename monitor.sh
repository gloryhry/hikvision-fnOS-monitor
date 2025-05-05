#!/bin/bash

# System Monitor Script for Vertical Display (376x960)
# Displays FnOS Logo, CPU/Mem Usage, Avg CPU Temp, Network Info/Speed, Uptime

# --- Configuration ---
INTERVAL=5 # Refresh interval in seconds (0.2 Hz)
CHART_WIDTH=10 # Width of the network speed chart in characters (used for scaling, sparkline uses HISTORY_POINTS)
HISTORY_POINTS=50 # Number of data points for network speed history (increased)
# Width of the network speed chart in characters (REMOVED)
# Number of data points for network speed history (REMOVED)

# --- Colors ---
RED='\033[1;31m'
ORANGE='\033[38;5;214m'
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
CYAN='\033[1;36m'
BLUE='\033[1;34m'
WHITE='\033[1;37m'
RESET='\033[0m'
BOLD='\033[1m'

# --- FnOS Logo Placeholder ---
# TODO: Replace this with the actual ASCII art logo
FNOS_LOGO="
${BOLD}${CYAN} 
███████╗███╗   ██╗ ██████╗ ███████╗
██╔════╝████╗  ██║██╔═══██╗██╔════╝
█████╗  ██╔██╗ ██║██║   ██║███████╗
██╔══╝  ██║╚██╗██║██║   ██║╚════██║
██║     ██║ ╚████║╚██████╔╝███████║
╚═╝     ╚═╝  ╚═══╝ ╚═════╝ ╚══════╝ 
script by Glory & Gemini 2.5 Pro
${RESET}
"

# --- Network Interface State (for speed calculation) ---
declare -A last_times # Associative array to store last timestamp per interface
declare -A last_rx_bytes # Associative array to store last RX bytes per interface
declare -A rx_history # Associative array to store RX speed history per interface
declare -A tx_history # Associative array to store TX speed history per interface
declare -A last_tx_bytes # Associative array to store last TX bytes per interface
declare -A last_valid_rx_kbs # Associative array to store last valid RX speed per interface
declare -A last_valid_tx_kbs # Associative array to store last valid TX speed per interface
# Temporary file for sharing speed data between processes
TEMP_DIR=$(mktemp -d -t monitor_speeds_XXXXXX)
SPEED_FILE="$TEMP_DIR/speeds.dat"
BG_PID_FILE="$TEMP_DIR/pid" # File to store background process ID


# --- Functions ---


# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if sar is available early on
has_sar=false
if command_exists sar; then
    has_sar=true
fi
# Check for hardware info commands
has_lscpu=$(command_exists lscpu && echo true || echo false)
has_dmidecode=$(command_exists dmidecode && echo true || echo false)
has_lspci=$(command_exists lspci && echo true || echo false)

# Get CPU Usage (%)
get_cpu_usage() {
    if command_exists mpstat; then
        # Using mpstat (more reliable)
        mpstat 1 1 | awk '/Average:/ {printf "%.0f", 100 - $NF}'
    elif command_exists top; then
        # Fallback using top
        top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{printf "%.0f", 100 - $1}'
    else
        echo "N/A"
    fi
}

# Get Memory Usage (%)
get_mem_usage() {
    if command_exists free; then
        free -m | awk '/Mem:/ {printf "%.0f", $3*100/$2}'
    else
        echo "N/A"
    fi
}

# Get Average CPU Temperature (°C)
get_avg_cpu_temp() {
    if ! command_exists sensors; then
        echo "N/A"
        return
    fi
    local temp_sum=0
    local temp_count=0
    while IFS= read -r line; do
        # Try to extract temp, handling different formats like +50.0°C or 50.0°C
        local temp=$(echo "$line" | grep -oP '[\+\-]?\d+\.\d+' | head -n 1)
        if [[ -n "$temp" ]]; then
            # Use awk for float addition
            temp_sum=$(awk -v sum="$temp_sum" -v add="$temp" 'BEGIN {printf "%.1f", sum+add}')
            ((temp_count++))
        fi
    done < <(sensors | grep -i 'Core ') # Get lines containing 'Core'

    if (( temp_count > 0 )); then
        # Use awk for floating point division
        awk -v sum="$temp_sum" -v count="$temp_count" 'BEGIN {printf "%.1f", sum/count}'
    else
        # Fallback if no 'Core' lines found, check general package temp
         local pkg_temp=$(sensors | grep -i 'Package id 0' | grep -oP '[\+\-]?\d+\.\d+' | head -n 1)
         if [[ -n "$pkg_temp" ]]; then
             echo "$pkg_temp"
         else
             echo "N/A"
         fi
    fi
}

# Function to get CPU info
get_cpu_info() {
    if ! $has_lscpu; then
        echo "N/A (lscpu missing)"
        return
    fi
    # Extract and clean CPU model name, get cores and threads
    local cpu_model=$(lscpu | awk -F: '/^Model name/ {gsub(/^[ \t]+| *\(R\)| *\(TM\)| *CPU @ [0-9.]+GHz$|\(.*\)$/, "", $2); print $2}')
    local threads=$(lscpu | awk -F: '/^CPU\(s\)/ {gsub(/^[ \t]+/, "", $2); print $2}')
    local cores=$(lscpu | awk -F: '/^Core\(s\) per socket/ {cs=$2} /^Socket\(s\)/ {s=$2} END {gsub(/^[ \t]+/, "", cs); gsub(/^[ \t]+/, "", s); print cs*s}')
    if [[ -n "$cpu_model" && -n "$cores" && -n "$threads" ]]; then
        # Return model, cores, threads separated by a special character (|)
        # Limit model name length
        printf -v cpu_model_short "%.25s" "$cpu_model" # Can be a bit longer now
        if [ ${#cpu_model} -gt 25 ]; then cpu_model_short+="..."; fi
        echo "${cpu_model_short}|${cores}|${threads}"
    else
        echo "N/A|N/A|N/A" # Ensure consistent output format
    fi
}

# Function to get Memory info (Total Size only)
get_mem_info() {
    if ! command_exists free; then
        echo "N/A (free missing)"
        return
    fi

    # Get total memory in MiB and convert to GiB with one decimal place
    local total_mem_gib=$(free -m | awk '/Mem:/ {printf "%.1f", $2 / 1024}')

    if [[ -n "$total_mem_gib" ]]; then
        printf "%sG" "$total_mem_gib"
    else
        echo "N/A"
    fi
}


# Function to get GPU info
get_gpu_info() {
    if ! $has_lspci; then
        echo "N/A (lspci missing)"
        return
    fi
    # Try different patterns to extract GPU name reliably, removing vendor and revision
    local gpu_info=$(lspci | grep -i 'vga\|3d\|display' | head -n 1 | sed -e 's/^.*controller:[[:space:]]*//' -e 's/Corporation //g' -e 's/\[.*\]//g' -e 's/ (rev [0-9a-fA-F]\+) *//' | awk '{$1=$1};1') # Clean up extra spaces
    if [[ -z "$gpu_info" || "$gpu_info" == *"controller:"* ]]; then # Check if extraction failed or was incomplete
        gpu_info=$(lspci | grep -i 'vga\|3d\|display' | head -n 1 | awk -F ': ' '{print $NF}' | sed -e 's/Corporation //g' -e 's/\[.*\]//g' -e 's/ (rev [0-9a-fA-F]\+) *//' | awk '{$1=$1};1')
    fi

    if [[ -n "$gpu_info" ]]; then
        # Limit length if too long for display
        printf "%.30s" "$gpu_info"
        if [ ${#gpu_info} -gt 30 ]; then echo -n "..."; fi
    else
        echo "N/A"
    fi
}

# Get Detailed Network Interface Information
# Outputs blocks of key:value pairs for each physical interface, separated by "---"
get_network_interfaces_info() {
    if ! command_exists ip; then
        echo "" # Return empty if ip command not found
        return
    fi

    # Improved filtering for physical interfaces (excluding common virtual ones)
    local interfaces=$(ip -o link show up | awk -F': ' '!/lo:|docker|veth|virbr|br-|bond|dummy|tun|tap/ {print $2}')

    for iface in $interfaces; do
        # Check if it's likely a physical device (has a 'device' symlink or directory)
        if [[ -e "/sys/class/net/${iface}/device" ]]; then
            echo "iface:${iface}" # Start of interface block

            # --- IP Acquisition Method ---
            local ip4_method="Static" # Default
            # Check 'ip addr' for dynamic flag
            if ip addr show "$iface" 2>/dev/null | grep -q " dynamic"; then
                ip4_method="DHCP"
            fi
            # Try nmcli if available for potentially more reliable method detection
            if command_exists nmcli; then
                 local nmcli_method=$(nmcli -t -f IP4.METHOD dev show "$iface" 2>/dev/null | cut -d':' -f2)
                 if [[ "$nmcli_method" == "auto" ]]; then
                     ip4_method="DHCP"
                 elif [[ "$nmcli_method" == "manual" ]]; then
                     ip4_method="Static"
                 elif [[ "$nmcli_method" == "disabled" ]]; then
                     ip4_method="Disabled"
                 # Add other methods if needed (shared, link-local etc.)
                 fi
            fi
            echo "ip_method:${ip4_method}"


            # --- IPv4 Info ---
            local ip4_addr_prefix=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d\.]+\/\d+' | head -n 1)
            local ip4_addr="N/A"
            local ip4_mask="N/A"
            if [[ -n "$ip4_addr_prefix" ]]; then
                ip4_addr=$(echo "$ip4_addr_prefix" | cut -d'/' -f1)
                local prefix_len=$(echo "$ip4_addr_prefix" | cut -d'/' -f2)
                # Convert prefix length to subnet mask
                if [[ "$prefix_len" =~ ^[0-9]+$ ]] && (( prefix_len >= 0 && prefix_len <= 32 )); then
                    local full_octets=$((prefix_len / 8))
                    local partial_octet_bits=$((prefix_len % 8))
                    local mask=""
                    local i
                    for ((i=0; i<4; i++)); do
                        if (( i < full_octets )); then
                            mask+="255."
                        elif (( i == full_octets )) && (( partial_octet_bits > 0 )); then
                            # Calculate partial octet value using bitwise operations
                            local partial_val=$(( (0xFF << (8 - partial_octet_bits)) & 0xFF ))
                            mask+="${partial_val}."
                        else
                            mask+="0."
                        fi
                    done
                    ip4_mask=${mask%.} # Remove trailing dot
                fi
            fi
            echo "ip4_addr:${ip4_addr}"
            echo "ip4_mask:${ip4_mask}"

            local ip4_gw=$(ip route show default dev "$iface" 2>/dev/null | awk '/default via/ {print $3}' | head -n 1)
            echo "ip4_gw:${ip4_gw:-N/A}"

            # --- IPv6 Info ---
            local ip6_addr_list=()
            while IFS= read -r line; do
                 # Extract global scope addresses, exclude temporary/link-local if desired
                 if echo "$line" | grep -q "scope global"; then
                    local addr=$(echo "$line" | awk '{print $2}') # Gets address/prefix
                    ip6_addr_list+=("$addr")
                 fi
            done < <(ip -6 addr show "$iface" 2>/dev/null)
            # Join addresses with newline
            local ip6_addrs_str="N/A"
            if [ ${#ip6_addr_list[@]} -gt 0 ]; then
                 ip6_addrs_str=$(printf "%s\n" "${ip6_addr_list[@]}")
            fi
            # Escape newlines for storage in the variable, will be unescaped later
            echo "ip6_addr:${ip6_addrs_str//$'\n'/\\n}"

            local ip6_gw=$(ip -6 route show default dev "$iface" 2>/dev/null | awk '/default via/ {print $3}' | head -n 1)
            echo "ip6_gw:${ip6_gw:-N/A}"

            # --- DNS Info ---
            local ipv4_dns_servers=() # Array for IPv4 DNS
            local ipv6_dns_servers=() # Array for IPv6 DNS
            local temp_dns_servers=() # Temporary array for resolvectl/resolv.conf

            if command_exists resolvectl; then
                # Get DNS servers specifically for this interface using resolvectl
                local resolvectl_dns=$(resolvectl status "$iface" 2>/dev/null | awk '/DNS Servers:/ {$1=$2=""; print $0}' | sed 's/^[ \t]*//')
                if [[ -n "$resolvectl_dns" ]]; then
                     read -ra temp_dns_servers <<< "$resolvectl_dns"
                else
                    # Fallback to global DNS if interface-specific fails or is empty
                    local global_dns=$(resolvectl status 2>/dev/null | awk '/Current DNS Server:/ {print $4} /DNS Servers:/ {$1=$2=""; print $0}' | sed 's/^[ \t]*//' | head -n 1)
                    if [[ -n "$global_dns" ]]; then
                         read -ra temp_dns_servers <<< "$global_dns"
                    fi
                fi
                # Separate IPv4 and IPv6 from resolvectl output
                for dns in "${temp_dns_servers[@]}"; do
                    # Check for IPv4 format
                    if [[ "$dns" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                        ipv4_dns_servers+=("$dns")
                    # Check for likely IPv6 format (contains at least two colons)
                    elif [[ "$dns" == *:*:* ]]; then
                        ipv6_dns_servers+=("$dns")
                    fi
                done

            elif command_exists nmcli; then
                 # Get DNS using nmcli (already separated)
                 local ip4_dns_str=$(nmcli -t -f IP4.DNS dev show "$iface" 2>/dev/null | cut -d':' -f2 | tr ';' ' ')
                 local ip6_dns_str=$(nmcli -t -f IP6.DNS dev show "$iface" 2>/dev/null | cut -d':' -f2 | tr ';' ' ')
                 # Add non-empty DNS servers to the respective arrays
                 [[ -n "$ip4_dns_str" ]] && read -ra dns4_arr <<< "$ip4_dns_str" && ipv4_dns_servers+=("${dns4_arr[@]}")
                 [[ -n "$ip6_dns_str" ]] && read -ra dns6_arr <<< "$ip6_dns_str" && ipv6_dns_servers+=("${dns6_arr[@]}")
            else
                # Fallback: Try parsing resolv.conf
                if [[ -r "/etc/resolv.conf" ]]; then
                    while IFS= read -r line || [[ -n "$line" ]]; do
                        # Extract address after 'nameserver '
                        local addr=$(echo "$line" | awk '/^nameserver/ {print $2}')
                        if [[ -n "$addr" ]]; then
                             # Check for IPv4 format
                             if [[ "$addr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                                 ipv4_dns_servers+=("$addr")
                             # Check for likely IPv6 format (contains at least two colons)
                             elif [[ "$addr" == *:*:* ]]; then
                                 ipv6_dns_servers+=("$addr")
                             fi
                        fi
                    done < /etc/resolv.conf
                fi
            fi

            # Format IPv4 DNS
            local formatted_dns4="N/A"
            if [ ${#ipv4_dns_servers[@]} -gt 0 ]; then
                formatted_dns4=$(printf "%s\n" "${ipv4_dns_servers[@]}" | awk '!seen[$0]++' | tr '\n' ' ' | sed 's/^[ \t]*//;s/[ \t]*$//')
            fi
            echo "dns4:${formatted_dns4:-N/A}"

            # Format IPv6 DNS
            local formatted_dns6="N/A"
            if [ ${#ipv6_dns_servers[@]} -gt 0 ]; then
                formatted_dns6=$(printf "%s\n" "${ipv6_dns_servers[@]}" | awk '!seen[$0]++' | tr '\n' ' ' | sed 's/^[ \t]*//;s/[ \t]*$//')
            fi
            echo "dns6:${formatted_dns6:-N/A}"

            echo "---" # End of interface block
        fi
    done
}

# Calculate Network Speed (KB/s) for a specific interface using sar if available
# Calculate Network Speed (KB/s) for a specific interface.
# Returns two values separated by space: "rx_speed_kbs tx_speed_kbs"
# Returns "N/A N/A" if speed cannot be determined.
calculate_interface_speed() {
    local interface_name="$1"
    local rx_speed_kbs="N/A"
    local tx_speed_kbs="N/A"

    if $has_sar; then
        # Use sar for potentially more accurate real-time speed
        local sar_output=$(sar -n DEV 1 1 2>/dev/null | grep "^Average:" | grep "$interface_name")
        if [[ -n "$sar_output" ]]; then
            rx_speed_kbs=$(echo "$sar_output" | awk '{printf "%.1f", $5}')
            tx_speed_kbs=$(echo "$sar_output" | awk '{printf "%.1f", $6}')
        else
            rx_speed_kbs="N/A"
            tx_speed_kbs="N/A"
        fi
        # Echo the result for sar method
        echo "$rx_speed_kbs $tx_speed_kbs"

    else
        # Fallback to original /sys method if sar is not available
        local stats_file_rx="/sys/class/net/${interface_name}/statistics/rx_bytes"
        local stats_file_tx="/sys/class/net/${interface_name}/statistics/tx_bytes"

        if [[ ! -e "$stats_file_rx" ]] || [[ ! -e "$stats_file_tx" ]]; then
            echo "N/A N/A" # Echo N/A if stats files don't exist
            return
        fi

        local current_time=$(date +%s%N)
        local current_rx_bytes=$(cat "$stats_file_rx" 2>/dev/null || echo 0)
        local current_tx_bytes=$(cat "$stats_file_tx" 2>/dev/null || echo 0)

        local last_if_time=${last_times[$interface_name]:-0}
        local last_if_rx_bytes=${last_rx_bytes[$interface_name]:-0}
        local last_if_tx_bytes=${last_tx_bytes[$interface_name]:-0}

        # Calculate speed only if last_time for this interface is not 0
        if (( last_if_time > 0 )); then
            local time_diff=$((current_time - last_if_time))

            if (( time_diff > 0 )); then
                local rx_diff=$((current_rx_bytes - last_if_rx_bytes))
                local tx_diff=$((current_tx_bytes - last_if_tx_bytes))

                if (( rx_diff < 0 )); then rx_diff=0; fi
                if (( tx_diff < 0 )); then tx_diff=0; fi

                rx_speed_kbs=$(awk -v diff="$rx_diff" -v time="$time_diff" 'BEGIN { printf "%.1f", (diff * 1000000000) / time / 1024 }')
                tx_speed_kbs=$(awk -v diff="$tx_diff" -v time="$time_diff" 'BEGIN { printf "%.1f", (diff * 1000000000) / time / 1024 }')
                echo "$rx_speed_kbs $tx_speed_kbs" # Echo calculated speeds
            else
                 # Time diff is zero or negative
                 echo "0.0 0.0" # Echo 0.0 speeds
            fi
        else
             # First run for this interface
             echo "0.0 0.0" # Echo 0.0 speeds
        fi

        # Update last values for this specific interface
        last_times[$interface_name]=$current_time
        last_rx_bytes[$interface_name]=$current_rx_bytes
        last_tx_bytes[$interface_name]=$current_tx_bytes
    fi
}

# --- Background Speed Calculation ---

# This function runs in the background, calculates speeds, and writes to SPEED_FILE
update_network_speeds_background() {
   # Just ensure the process exits cleanly on termination signals
   # The main script's cleanup is responsible for removing TEMP_DIR
   # No trap here - let the main process handle termination via kill
   # trap 'exit 0' INT TERM

   # Store the PID of this background process
   echo $$ > "$BG_PID_FILE"

   while true; do
       local temp_speed_file="${SPEED_FILE}.tmp" # Use a temporary file for atomic update
       > "$temp_speed_file" # Clear/create the temp file

       # Get detailed interface info within the loop
       local all_interface_data=()
       mapfile -t all_interface_data < <(get_network_interfaces_info)
       local current_iface_name=""

       if [ ${#all_interface_data[@]} -gt 0 ]; then
            # Loop through the detailed output, extract only interface names
            for line in "${all_interface_data[@]}"; do
                if [[ "$line" == iface:* ]]; then
                    current_iface_name="${line#iface:}" # Extract name after "iface:"
                    if [[ -n "$current_iface_name" ]]; then
                        # Calculate speed for the extracted interface name
                        read -r rx_kbs tx_kbs < <(calculate_interface_speed "$current_iface_name")
                        # Write interface and speeds to the temporary file
                        echo "${current_iface_name}:${rx_kbs:-N/A}:${tx_kbs:-N/A}" >> "$temp_speed_file"
                    fi
                fi
                # Reset if separator is found (optional, but helps clarity)
                # if [[ "$line" == "---" ]]; then
                #     current_iface_name=""
                # fi
            done
       fi
       # Atomically replace the old speed file with the new one
       mv "$temp_speed_file" "$SPEED_FILE"
       sleep "$INTERVAL"
   done
}


# Format speed with appropriate units (KB/s, MB/s, GB/s)
# Takes speed in KB/s as input
# Outputs a formatted string like " 123.4 MB/s" suitable for printf
format_speed() {
    local speed_kbs=$1
    local unit="KB/s"
    local speed_val_fmt="N/A"
    local unit_fmt=""

    # Handle non-numeric input gracefully
    # Handle non-numeric or "N/A" input gracefully
    if ! [[ "$speed_kbs" =~ ^[0-9]+(\.[0-9]+)?$ ]] || [[ "$speed_kbs" == "N/A" ]]; then
         # If input is invalid or N/A, display it as N/A, but don't return early
         # The calling code might use the last valid speed for history/sparkline
         speed_val_fmt="N/A"
         unit_fmt=""
         # We still need to proceed to print the formatted N/A string
    else
        local speed_val=$(echo "$speed_kbs" | awk '{print $1}') # Ensure we have just the number

        # Define thresholds
        local mb_threshold=1024.0
        local gb_threshold=1048576.0 # 1024 * 1024

        # Use awk for comparison and calculation
        if (( $(awk -v speed="$speed_val" -v threshold="$gb_threshold" 'BEGIN { print (speed >= threshold) }') )); then
            speed_val_fmt=$(awk -v speed="$speed_val" -v div="$gb_threshold" 'BEGIN { printf "%.1f", speed / div }')
            unit_fmt="GB/s"
        elif (( $(awk -v speed="$speed_val" -v threshold="$mb_threshold" 'BEGIN { print (speed >= threshold) }') )); then
            speed_val_fmt=$(awk -v speed="$speed_val" -v div="$mb_threshold" 'BEGIN { printf "%.1f", speed / div }')
            unit_fmt="MB/s"
        else
            speed_val_fmt=$(awk -v speed="$speed_val" 'BEGIN { printf "%.1f", speed }')
            unit_fmt="KB/s"
        fi
    fi # Add missing fi here
    # Format output: value right-aligned in 6 chars, unit left-aligned in 4 chars
    printf "%6s %-4s" "$speed_val_fmt" "$unit_fmt"
}


# Get System Uptime
get_uptime() {
    if command_exists uptime; then
        # More compact representation
        uptime -p | sed -e 's/up //' -e 's/ years\?, /y /' -e 's/ months\?, /mo /' -e 's/ weeks\?, /w /' -e 's/ days\?, /d /' -e 's/ hours\?, /h /' -e 's/ minutes\?/m/'
    else
        echo "N/A"
    fi
}

# Generate a progress bar string
# Usage: generate_bar 75 20 $GREEN
generate_bar() {
    local percentage=$1
    local width=$2
    local color=$3
    local filled_width=$(( percentage * width / 100 ))
    local empty_width=$(( width - filled_width ))
    local bar=""

    # Ensure percentage is within 0-100
    if (( percentage < 0 )); then percentage=0; fi
    if (( percentage > 100 )); then percentage=100; fi

    # Build the bar string
    bar+="${color}"
    printf -v filled_chars "%*s" "$filled_width" ""
    bar+="${filled_chars// /█}" # Use block character for filled part
    printf -v empty_chars "%*s" "$empty_width" ""
    bar+="${RESET}${empty_chars// /░}" # Use shaded character for empty part

    printf "[%s] %3d%%" "$bar" "$percentage"
}


# Generate a sparkline chart from a space-separated list of numbers
# Usage: generate_sparkline "10 20 5 30 15"
generate_sparkline() {
    local data_str="$1"
    local ticks=(⣀ ⣤ ⣶ ⣿) # Use Braille characters
    local num_ticks=${#ticks[@]}
    local -a values=($data_str) # Convert space-separated string to array
    local count=${#values[@]}
    local sparkline=""

    if (( count == 0 )); then
        printf "%-${HISTORY_POINTS}s" "" # Return empty space if no data
        return
    fi

    # Find min and max values using awk for float comparison
    local min_max=$(echo "${values[@]}" | tr ' ' '\n' | awk '
        BEGIN { min = "inf"; max = "-inf" }
        {
            if ($1 != "N/A") {
                if (min == "inf" || $1 < min) min = $1;
                if (max == "-inf" || $1 > max) max = $1;
            }
        }
        END { if (min == "inf") min=0; if (max == "-inf") max=0; printf "%.1f %.1f", min, max }
    ')
    local min_val=$(echo "$min_max" | cut -d' ' -f1)
    local max_val=$(echo "$min_max" | cut -d' ' -f2)
    local delta=$(awk -v max="$max_val" -v min="$min_val" 'BEGIN { print max - min }')

    # Build the sparkline string
    local i
    for (( i=0; i<count; i++ )); do
        local value="${values[$i]}"
        if [[ "$value" == "N/A" ]]; then
            sparkline+="?" # Represent N/A with a question mark
            continue
        fi

        local tick_index=0
        if (( $(awk -v delta="$delta" 'BEGIN { print (delta > 0) }') )); then
            # Use awk for float calculation and comparison
            tick_index=$(awk -v val="$value" -v min="$min_val" -v delta="$delta" -v num_ticks="$num_ticks" \
                'BEGIN { idx = int(((val - min) / delta) * (num_ticks - 1)); if (idx < 0) idx = 0; if (idx >= num_ticks) idx = num_ticks - 1; print idx }')
        elif (( $(awk -v max="$max_val" 'BEGIN { print (max > 0) }') )); then
             # If delta is 0 but max is > 0 (all values are the same and non-zero)
             tick_index=$((num_ticks - 1)) # Use the highest tick
        else
             # If delta is 0 and max is 0 (all values are 0)
             tick_index=0 # Use the lowest tick
        fi
        sparkline+="${ticks[$tick_index]}"
    done

    # Pad the sparkline to the HISTORY_POINTS width
    printf "%-${HISTORY_POINTS}s" "$sparkline"
}

# --- Cleanup Function ---
cleanup() {
   # --- Lock file to prevent multiple executions ---
   local lock_dir="$TEMP_DIR/cleanup.lock"
   if mkdir "$lock_dir" 2>/dev/null; then
       # --- Cleanup logic runs only if lock acquired ---
       trap '' INT TERM # Disable further traps within cleanup to prevent re-entrancy

       echo -e "${RESET}" >&2
       tput cnorm >&2
       echo "Cleanup: Starting cleanup process (lock acquired)..." >&2

       if [[ -f "$BG_PID_FILE" ]] && [[ -s "$BG_PID_FILE" ]]; then
       local bg_pid
       bg_pid=$(cat "$BG_PID_FILE")
       if [[ "$bg_pid" =~ ^[0-9]+$ ]]; then
           echo "Cleanup: Found background PID $bg_pid." >&2
           if kill -0 "$bg_pid" 2>/dev/null; then
               echo "Cleanup: Attempting graceful shutdown of background process $bg_pid..." >&2
              kill -- -"$bg_pid" 2>/dev/null # Send SIGTERM to the entire process group

              # Wait loop with timeout (approx 2 seconds)
               local waited=0
               while kill -0 "$bg_pid" 2>/dev/null && (( waited < 20 )); do # Wait up to 2 seconds (20 * 0.1s)
                   sleep 0.1
                   ((waited++))
               done

               # Check if it's still alive after waiting
               if kill -0 "$bg_pid" 2>/dev/null; then
                  echo "Cleanup: Background process group $bg_pid did not terminate gracefully after ${waited}00ms. Sending SIGKILL." >&2
                  kill -9 -- -"$bg_pid" 2>/dev/null # Force kill the entire process group
                  sleep 0.1 # Give SIGKILL a moment
               else
                   echo "Cleanup: Background process $bg_pid terminated gracefully after ${waited}00ms." >&2
               fi
           else
                echo "Cleanup: Background process $bg_pid was not running." >&2
           fi
       else
            echo "Cleanup: Invalid PID found in $BG_PID_FILE: $bg_pid" >&2
       fi
   else
       echo "Cleanup: PID file $BG_PID_FILE not found or empty." >&2
   fi

   echo "Cleanup: Removing temporary directory $TEMP_DIR..." >&2
   rm -rf "$TEMP_DIR"

      printf "\nMonitor stopped.\n"
      # Make sure the main script exits!
      exit 0
      # --- End of locked cleanup logic ---
  else
      # If lock fails, it means cleanup is already in progress.
      echo "Cleanup: Cleanup already running, exiting subsequent call." >&2
      # We don't exit here, let the first call finish.
      return
  fi
}
trap cleanup INT TERM # Call cleanup on Ctrl+C or termination

# --- Main Loop ---
# Hide cursor
tput civis
# --- Initialization ---
# Get initial list of interfaces to pre-populate history
mapfile -t initial_interfaces_list < <(get_network_interfaces_info)
initial_rx_hist_entry=$(printf '0.0 %.0s' $(seq 1 $HISTORY_POINTS)) # String of "0.0 0.0 ..."
initial_tx_hist_entry=$(printf '0.0 %.0s' $(seq 1 $HISTORY_POINTS)) # String of "0.0 0.0 ..."

for iface_info in "${initial_interfaces_list[@]}"; do
    iface_name="${iface_info%%:*}"
    # Initialize history with zeros to ensure sparkline is drawn immediately
    rx_history[$iface_name]="$initial_rx_hist_entry"
    tx_history[$iface_name]="$initial_tx_hist_entry"
    # Initialize last valid speeds
    last_valid_rx_kbs[$iface_name]="0.0"
    last_valid_tx_kbs[$iface_name]="0.0"
done

# --- Start Background Speed Calculation ---
update_network_speeds_background &
# Give the background process a moment to start and create the PID file
sleep 0.1
if [[ ! -f "$BG_PID_FILE" ]]; then
   echo "Error: Background process failed to start." >&2
   cleanup # Attempt cleanup before exiting
   exit 1
fi


while true; do
   # --- Gather Data ---
    cpu_usage=$(get_cpu_usage)
    mem_usage=$(get_mem_usage)
    avg_temp=$(get_avg_cpu_temp)
    # Get all network interface info (name:ip pairs)
    mapfile -t interfaces_list < <(get_network_interfaces_info)
    uptime_info=$(get_uptime)
    # Get Hardware Info
    cpu_info=$(get_cpu_info)
    mem_info=$(get_mem_info)
    gpu_info=$(get_gpu_info)


    # --- Display Data ---
    clear
    echo -e "$FNOS_LOGO"
    # Hardware Info Section
    # Split CPU info for multi-line display
    IFS='|' read -r cpu_model_disp cpu_cores_disp cpu_threads_disp <<< "$cpu_info"
    printf "${WHITE}%-10s: ${CYAN}%s${RESET}\n" "CPU" "$cpu_model_disp"
    if [[ "$cpu_cores_disp" != "N/A" ]]; then
      printf "${WHITE}%-10s  ${CYAN}%sC %sT${RESET}\n" "" "$cpu_cores_disp" "$cpu_threads_disp" # Indented second line for cores/threads
    fi
    printf "${WHITE}%-10s: ${CYAN}%s${RESET}\n" "Memory" "$mem_info" 
    printf "${WHITE}%-10s: ${CYAN}%s${RESET}\n" "GPU" "$gpu_info"
    echo "----------------------------------------"
    # CPU Usage Bar
    cpu_bar=$(generate_bar "$cpu_usage" 20 "$GREEN")
    echo -e "${WHITE}CPU       : ${cpu_bar}${RESET}"
    # Memory Usage Bar
    mem_bar=$(generate_bar "$mem_usage" 20 "$YELLOW")
    echo -e "${WHITE}Memory    : ${mem_bar}${RESET}"
    # Average Temperature with Icon and Color Coding
    temp_color="$GREEN" # Default to green
    if (( $(awk -v temp="$avg_temp" 'BEGIN { print (temp >= 75) }') )); then
        temp_color="$RED"
    elif (( $(awk -v temp="$avg_temp" 'BEGIN { print (temp >= 60) }') )); then
        temp_color="$YELLOW"
    fi
     # Handle N/A case for temperature
    if [[ "$avg_temp" == "N/A" ]]; then
        printf "${WHITE}%-10s: ${ORANGE}N/A${RESET}\n" "Avg Temp"
    else
        printf "${WHITE}%-10s: ${temp_color}%.1f°C${RESET}\n" "Avg Temp" "$avg_temp"
    fi

    printf "${WHITE}%-10s: ${CYAN}%s${RESET}\n" "Uptime" "$uptime_info"
    echo "----------------------------------------"
    echo -e "${BOLD}${WHITE}Network Interfaces:${RESET}"

    # Read all detailed interface info into an array
    mapfile -t all_interface_data < <(get_network_interfaces_info)

    # Process the data array to display detailed info
    current_iface="" # Removed local
    declare -A iface_details # Associative array to hold details for the current interface
    interface_found=false # Removed local, flag to track if any interfaces were processed

    if [ ${#all_interface_data[@]} -eq 0 ]; then
        echo "  No active physical network interfaces found."
    else
        for line in "${all_interface_data[@]}"; do
            if [[ "$line" == "---" ]]; then
                # End of an interface block, print the formatted info
                if [[ -n "$current_iface" ]]; then
                    interface_found=true
                    printf "${BOLD}${BLUE}%s${RESET}\n" "$current_iface"
                    printf "IP Method:  %s\n" "${iface_details[ip_method]:-N/A}"
                    printf "${WHITE}IPv4${RESET}:\n"
                    printf "    Address:        %s\n" "${iface_details[ip4_addr]:-N/A}"
                    printf "    Subnet Mask:    %s\n" "${iface_details[ip4_mask]:-N/A}"
                    printf "    Gateway:        %s\n" "${iface_details[ip4_gw]:-N/A}"
                    printf "    DNS:            %s\n" "${iface_details[dns4]:-N/A}" # Use dns4
                    printf "${WHITE}IPv6${RESET}:\n"
                    # Handle potentially multi-line IPv6 addresses (unescape newlines)
                    ip6_addrs_display="      N/A" # Removed local
                    if [[ "${iface_details[ip6_addr]}" != "N/A" ]]; then
                         # Replace escaped newlines with actual newlines and indent
                         ip6_addrs_display=$(printf "%s" "${iface_details[ip6_addr]}" | sed 's/\\n/\n      /g')
                         ip6_addrs_display="      ${ip6_addrs_display}" # Indent first line
                    fi
                    printf "  Address:\n%s\n" "$ip6_addrs_display"
                    # printf "    Gateway:    %s\n" "${iface_details[ip6_gw]:-N/A}"
                    # printf "    DNS:        %s\n" "${iface_details[dns6]:-N/A}" # Use dns6
                    echo "" # Add a blank line between interfaces
                fi
                # Reset for the next interface
                current_iface=""
                unset iface_details
                declare -A iface_details
            else
                # Split line into key and value
                key="${line%%:*}"   # Removed local
                value="${line#*:}" # Removed local
                if [[ "$key" == "iface" ]]; then
                    current_iface="$value"
                elif [[ -n "$key" ]]; then # Ensure key is not empty before using as subscript
                    # Store value in associative array
                    iface_details["$key"]="$value" # Quote the key
                fi
            fi
        done
        # If the loop finished but no "---" was encountered (e.g., only one interface found)
        # and no interface was printed, print a message.
        if ! $interface_found; then
             echo "  No active physical network interfaces found."
        fi
    fi

    # --- Network Speed Section ---
    # Get a simple list of physical interface names for the speed section
    # This ensures the speed display works even if get_network_interfaces_info fails partially
    interfaces_for_speed=() # Removed local
     while IFS= read -r line; do
        # Check if it's likely a physical device
        if [[ -e "/sys/class/net/${line}/device" ]]; then
            interfaces_for_speed+=("$line")
        fi
    done < <(ip -o link show up | awk -F': ' '!/lo:|docker|veth|virbr|br-|bond|dummy|tun|tap/ {print $2}')


    echo "----------------------------------------"
    echo -e "${BOLD}${WHITE}Network Speed:${RESET}"

    if [ ${#interfaces_for_speed[@]} -eq 0 ]; then
         echo "  N/A"
    else
        # --- Read Pre-calculated Speeds --- (Keep this logic)
        declare -A current_speeds
        if [[ -f "$SPEED_FILE" ]]; then
            while IFS=: read -r iface rx tx; do
                # Ensure keys match interface names exactly
                current_speeds["${iface}_rx"]="${rx:-N/A}"
                current_speeds["${iface}_tx"]="${tx:-N/A}"
            done < "$SPEED_FILE"
        fi

        # Loop through interfaces for speed display (Use interfaces_for_speed)
        for iface_name in "${interfaces_for_speed[@]}"; do
             # Get pre-calculated speed from the associative array
             raw_rx_kbs=${current_speeds["${iface_name}_rx"]:-"N/A"}
             raw_tx_kbs=${current_speeds["${iface_name}_tx"]:-"N/A"}

             # Determine speed to use for history/sparkline (use last valid if current is N/A)
             rx_kbs_for_hist="$raw_rx_kbs"
             tx_kbs_for_hist="$raw_tx_kbs"

             # Check if raw RX speed is valid number
             if ! [[ "$raw_rx_kbs" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                 rx_kbs_for_hist="${last_valid_rx_kbs[$iface_name]:-0.0}" # Use last valid or 0.0
             else
                 last_valid_rx_kbs[$iface_name]="$raw_rx_kbs" # Update last valid speed
             fi

             # Check if raw TX speed is valid number
             if ! [[ "$raw_tx_kbs" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                 tx_kbs_for_hist="${last_valid_tx_kbs[$iface_name]:-0.0}" # Use last valid or 0.0
             else
                 last_valid_tx_kbs[$iface_name]="$raw_tx_kbs" # Update last valid speed
             fi

             # --- Update RX History (using determined speed) ---
             current_rx_hist_str="${rx_history[$iface_name]:-}"
             declare -a current_rx_hist_arr=($current_rx_hist_str)
             current_rx_hist_arr+=("$rx_kbs_for_hist") # Add speed for history
             rx_hist_count=${#current_rx_hist_arr[@]}
             if (( rx_hist_count > HISTORY_POINTS )); then
                 current_rx_hist_arr=("${current_rx_hist_arr[@]:1}")
             fi
             rx_history[$iface_name]=$(printf "%s " "${current_rx_hist_arr[@]}")

             # --- Update TX History (using determined speed) ---
             current_tx_hist_str="${tx_history[$iface_name]:-}"
             declare -a current_tx_hist_arr=($current_tx_hist_str)
             current_tx_hist_arr+=("$tx_kbs_for_hist") # Add speed for history
             tx_hist_count=${#current_tx_hist_arr[@]}
             if (( tx_hist_count > HISTORY_POINTS )); then
                 current_tx_hist_arr=("${current_tx_hist_arr[@]:1}")
             fi
             tx_history[$iface_name]=$(printf "%s " "${current_tx_hist_arr[@]}")

             # --- Generate Sparklines (using potentially updated history) ---
             # Initialize history if it doesn't exist for this interface yet
             if [[ -z "${rx_history[$iface_name]}" ]]; then
                 rx_history[$iface_name]=$(printf '0.0 %.0s' $(seq 1 $HISTORY_POINTS))
             fi
              if [[ -z "${tx_history[$iface_name]}" ]]; then
                 tx_history[$iface_name]=$(printf '0.0 %.0s' $(seq 1 $HISTORY_POINTS))
             fi
             rx_sparkline=$(generate_sparkline "${rx_history[$iface_name]}")
             tx_sparkline=$(generate_sparkline "${tx_history[$iface_name]}")


             # --- Format Speed with Units (use raw speed for display, format_speed handles N/A) ---
             formatted_rx_str=$(format_speed "$raw_rx_kbs")
             formatted_tx_str=$(format_speed "$raw_tx_kbs")

             # --- Print Speed and Sparklines ---
             # Line 1: Interface name
             printf "  [${BLUE}%-10s${RESET}]\n" \
                    "$iface_name"
             # Line 2: RX speed (formatted with unit) and sparkline
             printf " ${GREEN}↓ :%s${RESET} [${GREEN}%s${RESET}]\n" \
                    "$formatted_rx_str" "$rx_sparkline"
             # Line 3: TX speed (formatted with unit) and sparkline
             printf " ${YELLOW}↑ :%s${RESET} [${YELLOW}%s${RESET}]\n" \
                    "$formatted_tx_str" "$tx_sparkline"
        done
    fi

    echo "----------------------------------------"
    # echo -e "${WHITE}Update: ${INTERVAL}s | Press Ctrl+C to exit${RESET}"

    sleep "$INTERVAL"
done
