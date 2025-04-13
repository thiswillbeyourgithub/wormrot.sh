#!/usr/bin/env zsh

VERSION="1.1.2"
# Base timestamp calculated once at script start
BASE_TIMESTAMP=$(date -u +%s)

# Function to display help message
show_help() {
    cat << EOF
wormrot v$VERSION - A wrapper around magic-wormhole for reliable file transfers

Usage: $0 [<file(s)>|-v|--version|-h|--help]

Commands:
  <file(s)>              Send the specified file(s)
  -v, --version          Show version information
  -h, --help             Show this help message

Without arguments, the script will start in receive mode.

Environment variables:
  WORMROT_MODULO        Time rotation interval in seconds (min: 20, default: 60)
  WORMROT_SECRET          Secret secret for code generation (required)
  WORMROT_BIN           Command to run wormhole (default: uvx --from magic-wormhole@latest wormhole)
  WORMROT_HRS_BIN       Command to run HumanReadableSeed (default: uvx HumanReadableSeed@latest)
  WORMROT_DEFAULT_SEND_ARGS      Default arguments for send (default: --no-qr --hide-progress)
  WORMROT_DEFAULT_RECEIVE_ARGS   Default arguments for receive (default: --hide-progress)
EOF
}


# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' is not installed. Please install it first."
    exit 1
fi

# Environment variables with defaults
WORMROT_MODULO=${WORMROT_MODULO:-60}
WORMROT_SECRET=${WORMROT_SECRET:-""}
WORMROT_BIN=${WORMROT_BIN:-"uvx --from magic-wormhole@latest wormhole"}
WORMROT_HRS_BIN=${WORMROT_HRS_BIN:-"uvx --from HumanReadableSeed@latest"}
WORMROT_DEFAULT_SEND_ARGS=${WORMROT_DEFAULT_SEND_ARGS:-"--no-qr --hide-progress"}
WORMROT_DEFAULT_RECEIVE_ARGS=${WORMROT_DEFAULT_RECEIVE_ARGS:-"--hide-progress"}

# Check if WORMROT_MODULO is below 20
if [[ $WORMROT_MODULO -lt 20 ]]; then
    echo "Error: WORMROT_MODULO must be at least 20"
    exit 1
fi

# Check if WORMROT_SECRET is empty
if [[ -z "$WORMROT_SECRET" ]]; then
    echo "Error: WORMROT_SECRET cannot be empty"
    exit 1
fi

# Timeout handler function
timeout_handler() {
    echo "Error: Operation timed out after $WORMROT_MODULO seconds" >&2
    echo "Failed command: $CURRENT_COMMAND" >&2
    kill -TERM $$
    exit 1
}

# Function to execute commands properly with timeout and check exit code
execute_wormhole_command() {
    local CURRENT_COMMAND="$@"
    
    # Set up timeout trap
    trap timeout_handler ALRM
    
    # Start timer in background
    (
        sleep $WORMROT_MODULO
        kill -ALRM $$ 2>/dev/null
    ) &
    local TIMER_PID=$!
    
    # Execute the command
    eval "$@"
    local exit_code=$?
    
    # Kill the timer and reset trap
    kill $TIMER_PID 2>/dev/null
    trap - ALRM
    
    if [[ $exit_code -ne 0 ]]; then
        echo "Error: Command failed with exit code $exit_code" >&2
        echo "Failed command: $@" >&2
        exit $exit_code
    fi
    return 0
}

# Function to generate a mnemonic based on base timestamp and an optional suffix
generate_mnemonic() {
    local suffix="$1"
    local check_time_boundary=${2:-false}
    
    # Use the global BASE_TIMESTAMP instead of recalculating
    local MODULO_REMAINDER=$((BASE_TIMESTAMP % WORMROT_MODULO))
    
    # Debug output to stderr so it doesn't affect function output
    echo "Debug - Timestamp modulo-remainder: $MODULO_REMAINDER (threshold: 10)" >&2

    # If modulo-remainder is less than 10 and we're checking time boundaries, exit with error
    if [[ $MODULO_REMAINDER -lt 10 && "$check_time_boundary" == true ]]; then
        local time_to_wait=$((10 - MODULO_REMAINDER))
        echo "Error: Too close to the next time period boundary." >&2
        echo "Please wait at least $time_to_wait seconds before starting the transfer." >&2
        echo "MNEMONIC_GENERATION_FAILED" >&2
        return 1
    fi
    
    # Use unmodified WORMROT_MODULO
    local ADJ_MODULO=$WORMROT_MODULO

    # Create PERIOD_KEY with optional suffix - using BASE_TIMESTAMP
    local PERIOD_KEY="$(((BASE_TIMESTAMP / ADJ_MODULO) * ADJ_MODULO))${WORMROT_SECRET}${suffix}"

    # Calculate SHA-256 hash of the PERIOD_KEY
    local PERIOD_KEY_HASH=$(echo -n "$PERIOD_KEY" | sha256sum | awk '{print $1}')

    # Derive base MNEMONIC words
    local MNEMONIC_WORDS
    MNEMONIC_WORDS=$($WORMROT_HRS_BIN toread "$PERIOD_KEY_HASH" 2>/dev/null | tr ' ' '-')
    
    # Check if the command failed
    if [[ $? -ne 0 || -z "$MNEMONIC_WORDS" ]]; then
        echo "Error: Failed to generate mnemonic words using $WORMROT_HRS_BIN" >&2
        echo "MNEMONIC_GENERATION_FAILED" >&2
        return 1
    fi

    # Calculate sha256sum of the mnemonic words
    local MNEMONIC_HASH=$(echo -n "$MNEMONIC_WORDS" | sha256sum | awk '{print $1}')

    # Extract integers from the hash
    local HASH_INTS=$(echo "$MNEMONIC_HASH" | tr -cd '0-9')

    # Apply modulo to cap prefix
    local PREFIX=$((${HASH_INTS:0:5} % 999))

    # Create the final mnemonic with the prefix
    echo "${PREFIX}-${MNEMONIC_WORDS}"
}

# Generate the base mnemonic with time boundary checking
MNEMONIC=$(generate_mnemonic "" true)
MNEMONIC_EXIT_CODE=$?

# Check if generate_mnemonic failed and exit immediately
if [[ $MNEMONIC_EXIT_CODE -ne 0 ]]; then
    echo "Error: Mnemonic generation failed with exit code $MNEMONIC_EXIT_CODE" >&2
    echo "Aborting operation." >&2
    exit 1
fi

# Check if we got a valid mnemonic
if [[ -z "$MNEMONIC" ]]; then
    echo "Error: Failed to generate a valid mnemonic" >&2
    exit 1
fi

# Process commands
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
    exit 0
elif [[ "$1" == "-v" || "$1" == "--version" ]]; then
    echo "wormrot v$VERSION"
    exit 0
elif [[ $# -gt 0 ]]; then
    # Count valid files from arguments
    local FILES=()
    
    for arg in "$@"; do
        # Skip arguments that start with hyphen (options)
        if [[ "$arg" != -* && -e "$arg" ]]; then
            FILES+=("$arg")
        fi
    done
    
    local COUNT_FILES=${#FILES[@]}
    if [[ $COUNT_FILES -eq 0 ]]; then
        echo "Error: No valid files provided"
        exit 1
    fi
    
    # First, send the count as JSON using the base mnemonic
    local JSON_CONTENT="{\"number_of_files\": $COUNT_FILES}"
    echo "Sending file count: $COUNT_FILES"
    echo "Full JSON content: $JSON_CONTENT"
    
    # Check if the JSON content can be parsed by jq
    if ! echo "$JSON_CONTENT" | jq . &>/dev/null; then
        echo "Error: Generated JSON is not valid. Please check your inputs."
        exit 1
    fi
    
    # Send file count and check exit code
    execute_wormhole_command "$WORMROT_BIN send --text \"$JSON_CONTENT\" $WORMROT_DEFAULT_SEND_ARGS --code $MNEMONIC"
    
    # Then send each file with a rotated mnemonic
    local FILE_INDEX=0
    for file in "${FILES[@]}"; do
        FILE_INDEX=$((FILE_INDEX + 1))
        local FILE_MNEMONIC=$(generate_mnemonic "newfile$FILE_INDEX")
        local MNEMONIC_EXIT_CODE=$?
        
        if [[ $MNEMONIC_EXIT_CODE -ne 0 ]]; then
            echo "Error: Mnemonic generation failed with exit code $MNEMONIC_EXIT_CODE" >&2
            echo "Aborting operation." >&2
            exit 1
        fi
        
        echo "Sending file $FILE_INDEX/$COUNT_FILES: $file"
        echo "Using mnemonic: $FILE_MNEMONIC"
        execute_wormhole_command "$WORMROT_BIN send \"$file\" $WORMROT_DEFAULT_SEND_ARGS --code $FILE_MNEMONIC"
    done
elif [[ $# -eq 0 ]]; then
    echo "Using base mnemonic: $MNEMONIC"
    # First, receive the count as JSON
    echo "Receiving file count..."
    # Use the timeout command execution function
    local COUNT_FILES_JSON
    COUNT_FILES_JSON=$(
      # Set up timeout trap
      trap timeout_handler ALRM
      
      # Start timer in background
      (
          sleep $WORMROT_MODULO
          kill -ALRM $$ 2>/dev/null
      ) &
      local TIMER_PID=$!
      
      # Execute the command
      eval "$WORMROT_BIN receive --only-text $WORMROT_DEFAULT_RECEIVE_ARGS $MNEMONIC"
      local exit_code=$?
      
      # Kill the timer and reset trap
      kill $TIMER_PID 2>/dev/null
      trap - ALRM
      
      if [[ $exit_code -ne 0 ]]; then
          echo "Error: Failed to receive file count. Exit code: $exit_code" >&2
          exit $exit_code
      fi
    )
    # Check if the command was successful
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo "Error: Failed to receive file count. Exit code: $exit_code"
        exit $exit_code
    fi
    echo "Received JSON content: $COUNT_FILES_JSON"
    
    # Fix potentially malformed JSON by adding quotes around keys if missing
    local FIXED_JSON=$(echo "$COUNT_FILES_JSON" | sed 's/{number_of_files:/{"number_of_files":/g')
    
    # Extract the number of files using jq
    local COUNT_FILES=$(echo "$FIXED_JSON" | jq -r '.number_of_files' 2>/dev/null)
    
    # If jq fails or doesn't return a valid number, exit with error
    if ! [[ "$COUNT_FILES" =~ ^[0-9]+$ ]]; then
        echo "Error: Could not extract file count from received JSON: $COUNT_FILES_JSON"
        echo "Make sure the JSON format is correct and contains a 'number_of_files' field."
        exit 1
    fi
    
    echo "Will receive $COUNT_FILES file(s)"
    
    # Then receive each file with a rotated mnemonic
    for ((i=1; i<=COUNT_FILES; i++)); do
        local FILE_MNEMONIC=$(generate_mnemonic "newfile$i")
        local MNEMONIC_EXIT_CODE=$?
        
        if [[ $MNEMONIC_EXIT_CODE -ne 0 ]]; then
            echo "Error: Mnemonic generation failed with exit code $MNEMONIC_EXIT_CODE" >&2
            echo "Aborting operation." >&2
            exit 1
        fi
        
        echo "Receiving file $i/$COUNT_FILES"
        echo "Using mnemonic: $FILE_MNEMONIC"
        execute_wormhole_command "$WORMROT_BIN receive $WORMROT_DEFAULT_RECEIVE_ARGS $FILE_MNEMONIC"
    done
else
    echo "Usage: $0 [<file(s)>|-v|--version]"
    echo "  - With no arguments: receive files"
    echo "  - With file arguments: send files"
    exit 1
fi
