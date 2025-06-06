#!/usr/bin/env zsh

VERSION="1.3.0"
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
  WORMROT_BIN           Command to run wormhole (default: uvx --quiet --from magic-wormhole@latest wormhole)
  WORMROT_HRS_BIN       Command to run HumanReadableSeed (default: uvx --quiet HumanReadableSeed@latest)
  WORMROT_DEFAULT_SEND_ARGS      Default arguments for send (default: --no-qr --hide-progress)
  WORMROT_DEFAULT_RECEIVE_ARGS   Default arguments for receive (default: --hide-progress)
EOF
}


# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' is not installed. Please install it first."
    exit 1
fi

# Check if sha256sum is installed
if ! command -v sha256sum &> /dev/null; then
    echo "Error: 'sha256sum' is not installed. Please install it first (usually part of coreutils)."
    exit 1
fi

# Check if uvx is installed
if command -v uvx &> /dev/null; then
    # uvx is available, use it for default bin values
    DEFAULT_WORMROT_BIN="uvx --quiet --from magic-wormhole@latest wormhole"
    DEFAULT_WORMROT_HRS_BIN="uvx --quiet HumanReadableSeed@latest"
else
    # uvx is not available, use plain commands
    DEFAULT_WORMROT_BIN="wormhole"
    DEFAULT_WORMROT_HRS_BIN="HumanReadableSeed"
fi

# Environment variables with defaults
WORMROT_MODULO=${WORMROT_MODULO:-60}
WORMROT_SECRET=${WORMROT_SECRET:-""}
WORMROT_BIN=${WORMROT_BIN:-"$DEFAULT_WORMROT_BIN"}
WORMROT_HRS_BIN=${WORMROT_HRS_BIN:-"$DEFAULT_WORMROT_HRS_BIN"}
WORMROT_DEFAULT_SEND_ARGS=${WORMROT_DEFAULT_SEND_ARGS:-"--no-qr --hide-progress"}
WORMROT_DEFAULT_RECEIVE_ARGS=${WORMROT_DEFAULT_RECEIVE_ARGS:-"--accept-file --hide-progress"}

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

# Function to execute commands properly and check exit code
execute_wormhole_command() {
    local CURRENT_COMMAND="$@"

    # Execute the command
    eval "$@"
    local exit_code=$?

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
    MNEMONIC_WORDS=$(eval "$WORMROT_HRS_BIN toread $PERIOD_KEY_HASH" | tr ' ' '-')
    
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

    # Send each file/directory with rotated mnemonics for metadata and data
    local FILE_INDEX=0
    for item_path in "${FILES[@]}"; do
        FILE_INDEX=$((FILE_INDEX + 1))
        # Directly use the item path provided by the user
        local FILE_TO_SEND="$item_path"

        # Calculate sha256sum of the file/directory to be sent
        # Note: sha256sum on a directory might not be meaningful or consistent across systems.
        # We'll calculate it on the file if it's a file, otherwise skip for directories for now.
        # The receiver side will need adjustment too.
        # Let's calculate hash only for files for simplicity and robustness.
        local FILE_HASH=""
        if [[ -f "$FILE_TO_SEND" ]]; then
            echo "Calculating sha256sum for file '$FILE_TO_SEND'..."
            FILE_HASH=$(sha256sum "$FILE_TO_SEND" | awk '{print $1}')
            if [[ $? -ne 0 || -z "$FILE_HASH" ]]; then
                echo "Error: Failed to calculate sha256sum for '$FILE_TO_SEND'" >&2
                exit 1
            fi
            echo "Calculated hash: $FILE_HASH"
        elif [[ -d "$FILE_TO_SEND" ]]; then
             echo "Skipping sha256sum calculation for directory '$FILE_TO_SEND'."
             # Set hash to a known value indicating it's a directory and hash wasn't calculated
             FILE_HASH="DIRECTORY_HASH_SKIPPED"
        else
            echo "Error: Item '$FILE_TO_SEND' is neither a file nor a directory." >&2
            exit 1
        fi

        # --- Metadata Transfer ---
        # Determine if this is the first mnemonic generation for time boundary check
        local check_boundary=false
        if [[ $FILE_INDEX -eq 1 ]]; then
            check_boundary=true
        fi

        # Generate mnemonic for metadata
        local META_MNEMONIC=$(generate_mnemonic "meta$FILE_INDEX" $check_boundary)
        local meta_exit_code=$?
        if [[ $meta_exit_code -ne 0 || -z "$META_MNEMONIC" ]]; then
            echo "Error: Failed to generate metadata mnemonic for item $FILE_INDEX" >&2
            exit 1
        fi

        # Create metadata JSON including index and total count
        # Use the original item basename for the filename field
        local FILENAME_IN_JSON=$(basename "$item_path")
        # Include the calculated hash (or placeholder), index, and total in the metadata JSON
        local FILE_META_JSON="{\"filename\": \"$FILENAME_IN_JSON\", \"sha256sum\": \"$FILE_HASH\", \"index\": $FILE_INDEX, \"total\": $COUNT_FILES}"

        # Check if the metadata JSON is valid
        if ! echo "$FILE_META_JSON" | jq . &>/dev/null; then
             echo "Error: Generated metadata JSON is not valid: $FILE_META_JSON" >&2
             exit 1
        fi

        echo "Sending metadata for item $FILE_INDEX/$COUNT_FILES: $FILE_META_JSON"
        # Print the mnemonic *just before* using it
        echo "Prepare for metadata $FILE_INDEX/$COUNT_FILES. Code: $META_MNEMONIC"
        # Send metadata JSON - Use single quotes around the JSON for --text
        execute_wormhole_command "$WORMROT_BIN send --text '$FILE_META_JSON' $WORMROT_DEFAULT_SEND_ARGS --code $META_MNEMONIC"

        # --- Data Transfer ---
        # Generate mnemonic for file data (never check boundary here)
        local DATA_MNEMONIC=$(generate_mnemonic "data$FILE_INDEX" false)
        local data_exit_code=$?
        if [[ $data_exit_code -ne 0 || -z "$DATA_MNEMONIC" ]]; then
            echo "Error: Failed to generate data mnemonic for item $FILE_INDEX" >&2
            exit 1
        fi

        # Send the actual file/archive
        echo "Sending file data $FILE_INDEX/$COUNT_FILES: '$FILE_TO_SEND'"
        # Print the mnemonic *just before* using it
        echo "Prepare for data $FILE_INDEX/$COUNT_FILES. Code: $DATA_MNEMONIC"
        # Send the actual file or directory
        execute_wormhole_command "$WORMROT_BIN send \"$FILE_TO_SEND\" $WORMROT_DEFAULT_SEND_ARGS --code $DATA_MNEMONIC"

    done
    echo "All $COUNT_FILES items sent."

elif [[ $# -eq 0 ]]; then
    # --- RECEIVE MODE ---
    # We don't know the number of files initially. We'll get it from the first metadata message.
    local RECEIVED_COUNT=0
    local EXPECTED_TOTAL=-1 # Initialize to unknown

    echo "Starting receive mode. Waiting for first metadata..."

    while true; do
        local CURRENT_INDEX=$((RECEIVED_COUNT + 1))

        # --- Metadata Reception ---
        # Determine if this is the first mnemonic generation for time boundary check
        local check_boundary=false
        if [[ $CURRENT_INDEX -eq 1 ]]; then
            check_boundary=true
        fi

        # Generate mnemonic for the current metadata
        local META_MNEMONIC=$(generate_mnemonic "meta${CURRENT_INDEX}" $check_boundary)
        local meta_exit_code=$?
        if [[ $meta_exit_code -ne 0 || -z "$META_MNEMONIC" ]]; then
            echo "Error: Failed to generate metadata mnemonic for item $CURRENT_INDEX" >&2
            exit 1
        fi

        # Display expected total if known
        local progress_indicator=""
        if [[ $EXPECTED_TOTAL -ne -1 ]]; then
            progress_indicator=" $CURRENT_INDEX/$EXPECTED_TOTAL"
        fi
        echo "Receiving metadata for item$progress_indicator..."
        # Print the mnemonic *just before* using it
        echo "Prepare for metadata$progress_indicator. Code: $META_MNEMONIC"

        # Receive metadata JSON
        local FILE_META_JSON_RAW="" # Initialize
        # Execute the receive command for metadata directly
        FILE_META_JSON_RAW=$(eval "$WORMROT_BIN receive --only-text $WORMROT_DEFAULT_RECEIVE_ARGS $META_MNEMONIC")
        local receive_meta_exit_code=$?

        # Check exit code for metadata receive
        if [[ $receive_meta_exit_code -ne 0 ]]; then
            echo "Error: Failed to receive metadata JSON for item $CURRENT_INDEX. Exit code: $receive_meta_exit_code" >&2
            if [[ -z "$FILE_META_JSON_RAW" ]]; then
               echo "No JSON data received for metadata item $CURRENT_INDEX." >&2
           else
               echo "Received partial/invalid metadata JSON: '$FILE_META_JSON_RAW'" >&2
           fi
            exit $receive_meta_exit_code
        fi

        echo "Received raw metadata JSON: '$FILE_META_JSON_RAW'"

        # Parse filename, sha256sum, index, and total using jq
        local FILENAME_FROM_JSON=$(echo "$FILE_META_JSON_RAW" | jq -r '.filename' 2>/dev/null)
        local EXPECTED_HASH=$(echo "$FILE_META_JSON_RAW" | jq -r '.sha256sum' 2>/dev/null)
        local RECEIVED_INDEX=$(echo "$FILE_META_JSON_RAW" | jq -r '.index' 2>/dev/null)
        local RECEIVED_TOTAL=$(echo "$FILE_META_JSON_RAW" | jq -r '.total' 2>/dev/null)

        # Validate parsed metadata
        if [[ -z "$FILENAME_FROM_JSON" || "$FILENAME_FROM_JSON" == "null" ]]; then
            echo "Error: Could not extract filename from metadata JSON: '$FILE_META_JSON_RAW'" >&2
            exit 1
        fi
        # Validate the hash format (64 hex characters) or the placeholder for directories
        if [[ -z "$EXPECTED_HASH" || "$EXPECTED_HASH" == "null" ]] || \
           ( [[ "$EXPECTED_HASH" != "DIRECTORY_HASH_SKIPPED" ]] && ! [[ "$EXPECTED_HASH" =~ ^[a-f0-9]{64}$ ]] ); then
            echo "Error: Could not extract valid sha256sum (or directory placeholder) from metadata JSON: '$FILE_META_JSON_RAW'" >&2
            exit 1
        fi
        # Validate index and total are positive integers
        if ! [[ "$RECEIVED_INDEX" =~ ^[1-9][0-9]*$ ]]; then
            echo "Error: Could not extract a valid positive index from metadata JSON: '$FILE_META_JSON_RAW'" >&2
            exit 1
        fi
         if ! [[ "$RECEIVED_TOTAL" =~ ^[1-9][0-9]*$ ]]; then
            echo "Error: Could not extract a valid positive total count from metadata JSON: '$FILE_META_JSON_RAW'" >&2
            exit 1
        fi

        # Process index and total
        if [[ $EXPECTED_TOTAL -eq -1 ]]; then
            # First metadata received, store the total and validate index
            if [[ $RECEIVED_INDEX -ne 1 ]]; then
                echo "Error: Expected index 1 for the first item, but received $RECEIVED_INDEX." >&2
                exit 1
            fi
            EXPECTED_TOTAL=$RECEIVED_TOTAL
            echo "Expecting $EXPECTED_TOTAL total item(s) based on first metadata."
            # Now that we know the total, pre-generate remaining mnemonics if needed (optional optimization)
            # For simplicity, we'll generate them one by one in the loop.
        else
            # Subsequent metadata, validate index and total consistency
            if [[ $RECEIVED_INDEX -ne $CURRENT_INDEX ]]; then
                 echo "Error: Expected index $CURRENT_INDEX, but received $RECEIVED_INDEX." >&2
                 exit 1
            fi
            if [[ $RECEIVED_TOTAL -ne $EXPECTED_TOTAL ]]; then
                 echo "Error: Expected total $EXPECTED_TOTAL, but received $RECEIVED_TOTAL in metadata for item $CURRENT_INDEX." >&2
                 exit 1
            fi
        fi

        echo "Metadata parsed - Filename: '$FILENAME_FROM_JSON', Expected Hash: $EXPECTED_HASH, Index: $RECEIVED_INDEX/$EXPECTED_TOTAL"

        # --- Data Reception ---
        # Generate mnemonic for the current file data (never check boundary here)
        local DATA_MNEMONIC=$(generate_mnemonic "data${CURRENT_INDEX}" false)
        local data_exit_code=$?
        if [[ $data_exit_code -ne 0 || -z "$DATA_MNEMONIC" ]]; then
            echo "Error: Failed to generate data mnemonic for item $CURRENT_INDEX" >&2
            exit 1
        fi

        echo "Receiving file data for item $CURRENT_INDEX/$EXPECTED_TOTAL..."
        # Print the mnemonic *just before* using it
        echo "Prepare for data $CURRENT_INDEX/$EXPECTED_TOTAL. Code: $DATA_MNEMONIC"

        local RECEIVED_FILE_PATH="" # Path to the file/dir after reception
        local CALCULATED_HASH=""    # Hash calculated after reception

        # Receive file/directory using the filename from JSON
        # Wormhole handles receiving directories directly.
        # It will create the directory (or file) with the name specified by the sender.
        # We need to handle potential name collisions on the receiver side.
        local TARGET_NAME="$FILENAME_FROM_JSON"
        local COUNTER=1
        # Check if the target name already exists (could be file or directory)
        if [[ -e "$TARGET_NAME" ]]; then
            echo "Warning: Item '$TARGET_NAME' already exists."
            # Separate name and extension (if any) for renaming logic
            local BASENAME="${TARGET_NAME%.*}"
            local EXTENSION="${TARGET_NAME##*.}"
            # Handle items with no extension or hidden items starting with '.'
            if [[ "$BASENAME" == "$TARGET_NAME" || "$TARGET_NAME" == ".$EXTENSION" ]]; then
                BASENAME="$TARGET_NAME"
                EXTENSION=""
            fi

            # Find an available name by appending _COUNTER
            while [[ -e "$TARGET_NAME" ]]; do
                if [[ -n "$EXTENSION" && "$TARGET_NAME" != .* ]]; then # Avoid adding extension logic to hidden files/dirs
                    TARGET_NAME="${BASENAME}_${COUNTER}.${EXTENSION}"
                else
                    TARGET_NAME="${BASENAME}_${COUNTER}"
                fi
                COUNTER=$((COUNTER + 1))
            done
            echo "Will save as '$TARGET_NAME' instead."
        fi

        # Use execute_wormhole_command for receiving the file/directory data
        # Wormhole's default behavior is to save with the original name.
        # If a collision occurs AND we detected it above, we need to tell wormhole
        # to save with the new name. However, wormhole's --output-file only works for files, not directories.
        # Let's rely on wormhole's default behavior for now, which might ask the user interactively
        # or potentially overwrite if --accept-file is used without care.
        # A better approach might be to receive to a temporary directory, then move/rename.
        # For now, we'll just use the default behavior and the TARGET_NAME is mostly for logging/verification path.
        # The actual path will be determined by wormhole. Let's capture the output to see what it saved.

        # We need to remove --output-file as it doesn't work reliably for directories
        # and wormhole handles naming. We'll verify the hash *after* it's received.
        echo "Receiving item '$FILENAME_FROM_JSON'..."
        # We need to capture the output to know the final path if wormhole renames it.
        # This is tricky as wormhole's output might vary. Let's assume it saves as FILENAME_FROM_JSON for now.
        # If it exists, our check above warns, but wormhole might still overwrite or fail depending on args.
        # Let's proceed assuming it saves as FILENAME_FROM_JSON for hash check, unless renamed.
        RECEIVED_FILE_PATH="$TARGET_NAME" # Use the potentially modified target name

        # Prepare extra arguments for wormhole receive if renaming is needed
        local receive_args_extra=""
        if [[ "$TARGET_NAME" != "$FILENAME_FROM_JSON" ]]; then
            # IMPORTANT: --output-file might only work reliably for files, not directories.
            # If receiving directories fails with this, further refinement is needed.
            receive_args_extra="--output-file \"$TARGET_NAME\""
            echo "Using --output-file \"$TARGET_NAME\" for receive command."
        fi

        # Execute the receive command, potentially with --output-file
        execute_wormhole_command "$WORMROT_BIN receive $WORMROT_DEFAULT_RECEIVE_ARGS $receive_args_extra $DATA_MNEMONIC"
        local receive_item_exit_code=$?

        if [[ $receive_item_exit_code -ne 0 ]]; then
            echo "Error: Failed to receive item data for '$FILENAME_FROM_JSON'. Exit code: $receive_item_exit_code" >&2
            # Cleanup might be complex here as we don't know exactly what wormhole did.
            exit $receive_item_exit_code
        fi
        echo "Item '$FILENAME_FROM_JSON' received (potentially)." # Wormhole manages the actual saving path/name

        # --- HASH VERIFICATION ---
        # Only verify hash if it wasn't skipped (i.e., it was a file)
        if [[ "$EXPECTED_HASH" != "DIRECTORY_HASH_SKIPPED" ]]; then
            echo "Verifying sha256sum for received file '$RECEIVED_FILE_PATH'..."
            # Check if the received file exists before hashing
            if [[ ! -f "$RECEIVED_FILE_PATH" ]]; then
                echo "Error: Received file '$RECEIVED_FILE_PATH' not found after transfer. Cannot verify hash." >&2
                # It might have been saved under a different name if there was a conflict.
                # This part needs improvement to robustly find the received file.
                exit 1
            fi

            CALCULATED_HASH=$(sha256sum "$RECEIVED_FILE_PATH" | awk '{print $1}')
            if [[ $? -ne 0 || -z "$CALCULATED_HASH" ]]; then
                echo "Error: Failed to calculate sha256sum for received file '$RECEIVED_FILE_PATH'" >&2
                # Clean up the potentially corrupted received file
                rm "$RECEIVED_FILE_PATH"
                exit 1
            fi

            echo "Calculated hash: $CALCULATED_HASH"
            echo "Expected hash:   $EXPECTED_HASH"

            if [[ "$CALCULATED_HASH" != "$EXPECTED_HASH" ]]; then
                echo "Error: SHA256SUM MISMATCH for item $CURRENT_INDEX ('$FILENAME_FROM_JSON')!" >&2
                echo "Received file '$RECEIVED_FILE_PATH' might be corrupted." >&2
                # Clean up the corrupted file
                echo "Deleting corrupted file: '$RECEIVED_FILE_PATH'" >&2
                rm "$RECEIVED_FILE_PATH"
                exit 1
            else
                echo "SHA256SUM OK for item $CURRENT_INDEX ('$FILENAME_FROM_JSON')."
            fi
        else
             echo "Skipping hash verification for received directory '$FILENAME_FROM_JSON' (item $CURRENT_INDEX)."
             # Basic check: ensure the directory exists
             if [[ ! -d "$RECEIVED_FILE_PATH" ]]; then
                 echo "Error: Received directory '$RECEIVED_FILE_PATH' not found after transfer." >&2
                 exit 1
             fi
             echo "Directory '$FILENAME_FROM_JSON' received successfully (existence checked)."
        fi


        # --- POST-VERIFICATION PROCESSING ---
        # No extraction needed anymore
        # If hash was verified (or skipped for dir), the item is considered successfully received.
        # The renaming logic previously applied to files now needs reconsideration.
        # The file should now exist at RECEIVED_FILE_PATH (which is TARGET_NAME).
        # The renaming logic previously here is removed as --output-file should handle it.

        echo "Item '$RECEIVED_FILE_PATH' (item $CURRENT_INDEX/$EXPECTED_TOTAL) processed successfully."

        # Increment received count
        RECEIVED_COUNT=$((RECEIVED_COUNT + 1))

        # Check if all expected files have been received
        if [[ $RECEIVED_COUNT -eq $EXPECTED_TOTAL ]]; then
            echo "All $EXPECTED_TOTAL items received successfully."
            break # Exit the while loop
        fi

    done # End of while true loop for receiving items
else
    # Handle case where arguments are provided but are not files (e.g., only options)
    # This part is reached if $# > 0 but the file check loop didn't find any valid files.
    # The original script structure handles -h and -v before the file check.
    # If we reach here, it means invalid arguments were likely given after the options.
    echo "Usage: $0 [<file(s)/dir(s)>|-v|--version|-h|--help]"
    echo "  - With no arguments: receive files/dirs"
    echo "  - With file/dir arguments: send files/dirs"
    echo "Error: Invalid arguments or no valid files specified for sending." >&2
    exit 1
fi
