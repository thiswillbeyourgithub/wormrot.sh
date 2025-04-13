#!/usr/bin/env zsh

VERSION="1.0.0"

# Check if uv is installed
if ! command -v uv &> /dev/null; then
    echo "Error: 'uv' is not installed. Please install it first."
    exit 1
fi

# Environment variables with defaults
WORMHOLE_ROTATOR_MODULO=${WORMHOLE_ROTATOR_MODULO:-30}
WORMHOLE_ROTATOR_SALT=${WORMHOLE_ROTATOR_SALT:-""}
WORMHOLE_ROTATOR_BIN=${WORMHOLE_ROTATOR_BIN:-"uvx --from magic-wormhole@latest wormhole"}
WORMHOLE_ROTATOR_DEFAULT_SEND_ARGS=${WORMHOLE_ROTATOR_DEFAULT_SEND_ARGS:-"--no-qr"}
WORMHOLE_ROTATOR_DEFAULT_RECEIVE_ARGS=${WORMHOLE_ROTATOR_DEFAULT_RECEIVE_ARGS:-""}

# Check if WORMHOLE_ROTATOR_SALT is empty
if [[ -z "$WORMHOLE_ROTATOR_SALT" ]]; then
    echo "Error: WORMHOLE_ROTATOR_SALT cannot be empty"
    exit 1
fi

# Function to execute commands properly
execute_wormhole_command() {
    eval "$@"
}

# Calculate current timestamp in UTC and apply modulo
CURRENT_TIMESTAMP=$(date -u +%s)
REMAINDER=$((CURRENT_TIMESTAMP % WORMHOLE_ROTATOR_MODULO))

# If remainder is less than 10, increase modulo by 1
if [[ $REMAINDER -lt 10 ]]; then
    WORMHOLE_ROTATOR_MODULO=$((WORMHOLE_ROTATOR_MODULO + 1))
fi

# Create PERIOD_KEY
PERIOD_KEY="$(((CURRENT_TIMESTAMP / WORMHOLE_ROTATOR_MODULO) * WORMHOLE_ROTATOR_MODULO))${WORMHOLE_ROTATOR_SALT}"

# Calculate SHA-256 hash of the PERIOD_KEY
PERIOD_KEY_HASH=$(echo -n "$PERIOD_KEY" | sha256sum | awk '{print $1}')

# Derive base MNEMONIC words
MNEMONIC_WORDS=$(uvx HumanReadableSeed@latest toread "$PERIOD_KEY_HASH" | tr ' ' '-')

# Calculate sha256sum of the mnemonic words
MNEMONIC_HASH=$(echo -n "$MNEMONIC_WORDS" | sha256sum | awk '{print $1}')

# Extract integers from the hash
HASH_INTS=$(echo "$MNEMONIC_HASH" | tr -cd '0-9')

# Apply modulo 173 to get prefix
PREFIX=$((${HASH_INTS:0:5} % 173))

# Create the final mnemonic with the prefix
MNEMONIC="${PREFIX}-${MNEMONIC_WORDS}"

# Process commands
if [[ "$1" == "-v" || "$1" == "--version" ]]; then
    echo "wormhole_rotator v$VERSION"
    exit 0
elif [[ "$1" == "send" ]]; then
    execute_wormhole_command "$WORMHOLE_ROTATOR_BIN send ${@:2} $WORMHOLE_ROTATOR_DEFAULT_SEND_ARGS --code $MNEMONIC"
elif [[ "$1" == "receive" ]]; then
    # Check if there are additional arguments
    if [[ $# -gt 1 ]]; then
        echo "Error: 'receive' command doesn't accept additional arguments"
        exit 1
    fi
    execute_wormhole_command "$WORMHOLE_ROTATOR_BIN receive $WORMHOLE_ROTATOR_DEFAULT_RECEIVE_ARGS $MNEMONIC"
else
    echo "Usage: $0 [send <file>|receive|-v|--version]"
    exit 1
fi
