#!/usr/bin/env zsh

VERSION="1.1.0"

# Function to display help message
show_help() {
    cat << EOF
wormhole_rotator v$VERSION - A wrapper around magic-wormhole for reliable file transfers

Usage: $0 [<file(s)>|-v|--version|-h|--help]

Commands:
  <file(s)>              Send the specified file(s)
  -v, --version          Show version information
  -h, --help             Show this help message

Without arguments, the script will start in receive mode.

Environment variables:
  WORMHOLE_ROTATOR_MODULO        Time rotation interval in seconds (min: 20, default: 30)
  WORMHOLE_ROTATOR_SALT          Secret salt for code generation (required)
  WORMHOLE_ROTATOR_BIN           Command to run wormhole (default: uvx --from magic-wormhole@latest wormhole)
  WORMHOLE_ROTATOR_DEFAULT_SEND_ARGS      Default arguments for send (default: --no-qr --hide-progress)
  WORMHOLE_ROTATOR_DEFAULT_RECEIVE_ARGS   Default arguments for receive (default: --hide-progress)
EOF
}

# Check if uv is installed
if ! command -v uv &> /dev/null; then
    echo "Error: 'uv' is not installed. Please install it first."
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' is not installed. Please install it first."
    exit 1
fi

# Environment variables with defaults
WORMHOLE_ROTATOR_MODULO=${WORMHOLE_ROTATOR_MODULO:-30}
WORMHOLE_ROTATOR_SALT=${WORMHOLE_ROTATOR_SALT:-""}
WORMHOLE_ROTATOR_BIN=${WORMHOLE_ROTATOR_BIN:-"uvx --from magic-wormhole@latest wormhole"}
WORMHOLE_ROTATOR_DEFAULT_SEND_ARGS=${WORMHOLE_ROTATOR_DEFAULT_SEND_ARGS:-"--no-qr --hide-progress"}
WORMHOLE_ROTATOR_DEFAULT_RECEIVE_ARGS=${WORMHOLE_ROTATOR_DEFAULT_RECEIVE_ARGS:-"--hide-progress"}

# Check if WORMHOLE_ROTATOR_MODULO is below 20
if [[ $WORMHOLE_ROTATOR_MODULO -lt 20 ]]; then
    echo "Error: WORMHOLE_ROTATOR_MODULO must be at least 20"
    exit 1
fi

# Check if WORMHOLE_ROTATOR_SALT is empty
if [[ -z "$WORMHOLE_ROTATOR_SALT" ]]; then
    echo "Error: WORMHOLE_ROTATOR_SALT cannot be empty"
    exit 1
fi

# Function to execute commands properly and check exit code
execute_wormhole_command() {
    eval "$@"
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo "Error: Command failed with exit code $exit_code"
        echo "Failed command: $@"
        exit $exit_code
    fi
    return 0
}

# Function to generate a mnemonic based on current timestamp and an optional suffix
generate_mnemonic() {
    local suffix="$1"
    
    # Calculate current timestamp in UTC and apply modulo
    local CURRENT_TIMESTAMP=$(date -u +%s)
    local REMAINDER=$((CURRENT_TIMESTAMP % WORMHOLE_ROTATOR_MODULO))

    # If remainder is less than 10, increase modulo by 1
    local MODULO=$WORMHOLE_ROTATOR_MODULO
    if [[ $REMAINDER -lt 10 ]]; then
      ADJ_MODULO=$((MODULO + 1))
    else
      ADJ_MODULO=$MODULO
    fi

    # Create PERIOD_KEY with optional suffix
    local PERIOD_KEY="$(((CURRENT_TIMESTAMP / MODULO) * ADJ_MODULO))${WORMHOLE_ROTATOR_SALT}${suffix}"

    # Calculate SHA-256 hash of the PERIOD_KEY
    local PERIOD_KEY_HASH=$(echo -n "$PERIOD_KEY" | sha256sum | awk '{print $1}')

    # Derive base MNEMONIC words
    local MNEMONIC_WORDS=$(uvx HumanReadableSeed@latest toread "$PERIOD_KEY_HASH" | tr ' ' '-')

    # Calculate sha256sum of the mnemonic words
    local MNEMONIC_HASH=$(echo -n "$MNEMONIC_WORDS" | sha256sum | awk '{print $1}')

    # Extract integers from the hash
    local HASH_INTS=$(echo "$MNEMONIC_HASH" | tr -cd '0-9')

    # Apply modulo to cap prefix
    local PREFIX=$((${HASH_INTS:0:5} % 999))

    # Create the final mnemonic with the prefix
    echo "${PREFIX}-${MNEMONIC_WORDS}"
}

# Generate the base mnemonic
MNEMONIC=$(generate_mnemonic "")

# Process commands
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
    exit 0
elif [[ "$1" == "-v" || "$1" == "--version" ]]; then
    echo "wormhole_rotator v$VERSION"
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
    execute_wormhole_command "$WORMHOLE_ROTATOR_BIN send --text \"$JSON_CONTENT\" $WORMHOLE_ROTATOR_DEFAULT_SEND_ARGS --code $MNEMONIC"
    
    # Then send each file with a rotated mnemonic
    local FILE_INDEX=0
    for file in "${FILES[@]}"; do
        FILE_INDEX=$((FILE_INDEX + 1))
        local FILE_MNEMONIC=$(generate_mnemonic "newfile$FILE_INDEX")
        echo "Sending file $FILE_INDEX/$COUNT_FILES: $file"
        echo "Using mnemonic: $FILE_MNEMONIC"
        execute_wormhole_command "$WORMHOLE_ROTATOR_BIN send \"$file\" $WORMHOLE_ROTATOR_DEFAULT_SEND_ARGS --code $FILE_MNEMONIC"
    done
elif [[ $# -eq 0 ]]; then
    echo "Using base mnemonic: $MNEMONIC"
    # First, receive the count as JSON
    echo "Receiving file count..."
    # Use command substitution but preserve the function's ability to check exit codes
    local COUNT_FILES_JSON
    COUNT_FILES_JSON=$(eval "$WORMHOLE_ROTATOR_BIN receive --only-text $WORMHOLE_ROTATOR_DEFAULT_RECEIVE_ARGS $MNEMONIC")
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
        echo "Receiving file $i/$COUNT_FILES"
        echo "Using mnemonic: $FILE_MNEMONIC"
        execute_wormhole_command "$WORMHOLE_ROTATOR_BIN receive $WORMHOLE_ROTATOR_DEFAULT_RECEIVE_ARGS $FILE_MNEMONIC"
    done
else
    echo "Usage: $0 [<file(s)>|-v|--version]"
    echo "  - With no arguments: receive files"
    echo "  - With file arguments: send files"
    exit 1
fi
