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
WORMHOLE_ROTATING_DEFAULT_ARGS=${WORMHOLE_ROTATING_DEFAULT_ARGS:-"--no-qr"}

# Check if WORMHOLE_ROTATING_SALT is empty
if [[ -z "$WORMHOLE_ROTATING_SALT" ]]; then
    echo "Error: WORMHOLE_ROTATING_SALT cannot be empty"
    exit 1
fi

# Calculate current timestamp and apply modulo
CURRENT_TIMESTAMP=$(date +%s)
REMAINDER=$((CURRENT_TIMESTAMP % WORMHOLE_ROTATING_MODULO))

# If remainder is less than 10, increase modulo by 1
if [[ $REMAINDER -lt 10 ]]; then
    WORMHOLE_ROTATING_MODULO=$((WORMHOLE_ROTATING_MODULO + 1))
fi

# Create PERIOD_KEY
PERIOD_KEY="$(((CURRENT_TIMESTAMP / WORMHOLE_ROTATING_MODULO) * WORMHOLE_ROTATING_MODULO))${WORMHOLE_ROTATING_SALT}"

# Derive MNEMONIC
MNEMONIC=$(uvx HumanReadableSeed@latest toread "$PERIOD_KEY" | tr ' ' '-')

# Process commands
if [[ "$1" == "send" ]]; then
    $WORMHOLE_ROTATING_BIN send ${@:2} $WORMHOLE_ROTATING_DEFAULT_ARGS --code $MNEMONIC
elif [[ "$1" == "receive" ]]; then
    # Check if there are additional arguments
    if [[ $# -gt 1 ]]; then
        echo "Error: 'receive' command doesn't accept additional arguments"
        exit 1
    fi
    $WORMHOLE_ROTATING_BIN receive $WORMHOLE_ROTATING_DEFAULT_ARGS $MNEMONIC
else
    echo "Usage: $0 [send <file>|receive]"
    exit 1
fi
