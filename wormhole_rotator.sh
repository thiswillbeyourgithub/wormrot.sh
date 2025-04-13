#!/usr/bin/env zsh

VERSION="1.1.0"

# Check if uv is installed
if ! command -v uv &> /dev/null; then
    echo "Error: 'uv' is not installed. Please install it first."
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

# Function to execute commands properly
execute_wormhole_command() {
    eval "$@"
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
        MODULO=$((MODULO + 1))
    fi

    # Create PERIOD_KEY with optional suffix
    local PERIOD_KEY="$(((CURRENT_TIMESTAMP / MODULO) * MODULO))${WORMHOLE_ROTATOR_SALT}${suffix}"

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
if [[ "$1" == "-v" || "$1" == "--version" ]]; then
    echo "wormhole_rotator v$VERSION"
    exit 0
elif [[ "$1" == "send" || ($# -gt 0 && "$1" != "receive") ]]; then
    # Count valid files from arguments
    local FILES=()
    local start_idx=1
    # If first arg is "send", start processing from the second argument
    if [[ "$1" == "send" ]]; then
        start_idx=2
    fi
    
    for arg in "${@:$start_idx}"; do
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
    
    # First, send the count using the base mnemonic
    echo "Sending file count: $COUNT_FILES"
    execute_wormhole_command "$WORMHOLE_ROTATOR_BIN send --text \"$COUNT_FILES\" $WORMHOLE_ROTATOR_DEFAULT_SEND_ARGS --code $MNEMONIC"
    
    # Then send each file with a rotated mnemonic
    local FILE_INDEX=0
    for file in "${FILES[@]}"; do
        FILE_INDEX=$((FILE_INDEX + 1))
        local FILE_MNEMONIC=$(generate_mnemonic "newfile$FILE_INDEX")
        echo "Sending file $FILE_INDEX/$COUNT_FILES: $file"
        echo "Using mnemonic: $FILE_MNEMONIC"
        execute_wormhole_command "$WORMHOLE_ROTATOR_BIN send \"$file\" $WORMHOLE_ROTATOR_DEFAULT_SEND_ARGS --code $FILE_MNEMONIC"
    done
elif [[ "$1" == "receive" || $# -eq 0 ]]; then
    # Check if there are additional arguments when "receive" is explicitly specified
    if [[ "$1" == "receive" && $# -gt 1 ]]; then
        echo "Error: 'receive' command doesn't accept additional arguments"
        exit 1
    fi
    
    echo "Using base mnemonic: $MNEMONIC"
    # First, receive the count
    echo "Receiving file count..."
    local COUNT_FILES=$(execute_wormhole_command "$WORMHOLE_ROTATOR_BIN receive --only-text $WORMHOLE_ROTATOR_DEFAULT_RECEIVE_ARGS $MNEMONIC")
    
    if ! [[ "$COUNT_FILES" =~ ^[0-9]+$ ]]; then
        echo "Error: Expected a number for file count, received: $COUNT_FILES"
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
    echo "Usage: $0 [<file(s)>|send <file(s)>|receive|-v|--version]"
    echo "  - With no arguments: receive files"
    echo "  - With file arguments: send files"
    echo "  - Explicit 'send' or 'receive' commands can also be used"
    exit 1
fi
