#!/usr/bin/env zsh

# Check if uv is installed
if ! command -v uv &> /dev/null; then
    echo "Error: 'uv' is not installed. Please install it first."
    exit 1
fi

# Environment variables with defaults
WORMHOLE_ROTATING_MODULO=${WORMHOLE_ROTATING_MODULO:-30}
WORMHOLE_ROTATING_SALT=${WORMHOLE_ROTATING_SALT:-""}
WORMHOLE_ROTATING_BIN=${WORMHOLE_ROTATING_BIN:-"uvx --from magic-wormhole@latest wormhole"}
WORMHOLE_ROTATING_DEFAULT_SEND_ARGS=${WORMHOLE_ROTATING_DEFAULT_SEND_ARGS:-"--no-qr"}
WORMHOLE_ROTATING_DEFAULT_RECEIVE_ARGS=${WORMHOLE_ROTATING_DEFAULT_RECEIVE_ARGS:-""}

# Check if WORMHOLE_ROTATING_SALT is empty
if [[ -z "$WORMHOLE_ROTATING_SALT" ]]; then
    echo "Error: WORMHOLE_ROTATING_SALT cannot be empty"
    exit 1
fi

# Function to execute commands properly
execute_wormhole_command() {
    eval "$@"
}

# Calculate current timestamp and apply modulo
CURRENT_TIMESTAMP=$(date +%s)
REMAINDER=$((CURRENT_TIMESTAMP % WORMHOLE_ROTATING_MODULO))

# If remainder is less than 10, increase modulo by 1
if [[ $REMAINDER -lt 10 ]]; then
    WORMHOLE_ROTATING_MODULO=$((WORMHOLE_ROTATING_MODULO + 1))
fi

# Create PERIOD_KEY
PERIOD_KEY="$(((CURRENT_TIMESTAMP / WORMHOLE_ROTATING_MODULO) * WORMHOLE_ROTATING_MODULO))${WORMHOLE_ROTATING_SALT}"

# Derive base MNEMONIC words
MNEMONIC_WORDS=$(uvx HumanReadableSeed@latest toread "$PERIOD_KEY" | tr ' ' '-')

# Calculate sha256sum of the mnemonic words
MNEMONIC_HASH=$(echo -n "$MNEMONIC_WORDS" | sha256sum | awk '{print $1}')

# Extract integers from the hash
HASH_INTS=$(echo "$MNEMONIC_HASH" | tr -cd '0-9')

# Apply modulo 173 to get prefix
PREFIX=$((${HASH_INTS:0:5} % 173))

# Create the final mnemonic with the prefix
MNEMONIC="${PREFIX}-${MNEMONIC_WORDS}"

# Process commands
if [[ "$1" == "send" ]]; then
    execute_wormhole_command "$WORMHOLE_ROTATING_BIN send ${@:2} $WORMHOLE_ROTATING_DEFAULT_SEND_ARGS --code $MNEMONIC"
elif [[ "$1" == "receive" ]]; then
    # Check if there are additional arguments
    if [[ $# -gt 1 ]]; then
        echo "Error: 'receive' command doesn't accept additional arguments"
        exit 1
    fi
    execute_wormhole_command "$WORMHOLE_ROTATING_BIN receive $WORMHOLE_ROTATING_DEFAULT_RECEIVE_ARGS $MNEMONIC"
else
    echo "Usage: $0 [send <file>|receive]"
    exit 1
fi
