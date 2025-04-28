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
    
    # First, send the count as JSON using the base mnemonic
    local JSON_COUNT_CONTENT="{\"number_of_files\": $COUNT_FILES}"
    echo "Sending file count: $COUNT_FILES"
    echo "Full JSON content: $JSON_COUNT_CONTENT"

    # Check if the JSON content can be parsed by jq
    if ! echo "$JSON_COUNT_CONTENT" | jq . &>/dev/null; then
        echo "Error: Generated JSON count content is not valid: $JSON_COUNT_CONTENT" >&2
        exit 1
    fi

    # Send file count and check exit code
    execute_wormhole_command "$WORMROT_BIN send --text \"$JSON_COUNT_CONTENT\" $WORMROT_DEFAULT_SEND_ARGS --code $MNEMONIC"

    # Then send each file/directory with rotated mnemonics for metadata and data
    local FILE_INDEX=0
    for item_path in "${FILES[@]}"; do
        FILE_INDEX=$((FILE_INDEX + 1))
        local FILE_TO_SEND=""
        local COMPRESSED_TAR=0
        local TEMP_TAR_FILE=""

        # Check if it's a directory
        if [[ -d "$item_path" ]]; then
            COMPRESSED_TAR=1
            # Create tar archive in the current directory using basename
            TEMP_TAR_FILE="$(basename "$item_path").tar.gz"
            echo "Compressing directory: '$item_path' to '$TEMP_TAR_FILE'"
            # Use -C to change directory to the parent of item_path to preserve hierarchy relative to the parent
            local PARENT_DIR=$(dirname "$item_path")
            local ITEM_BASENAME=$(basename "$item_path")
            if ! tar czf "$TEMP_TAR_FILE" -C "$PARENT_DIR" "$ITEM_BASENAME"; then
                echo "Error: Failed to create tar archive for '$item_path'" >&2
                # Attempt cleanup before exiting
                [[ -f "$TEMP_TAR_FILE" ]] && rm "$TEMP_TAR_FILE"
                exit 1
            fi
            FILE_TO_SEND="$TEMP_TAR_FILE"
        else
            # It's a file
            COMPRESSED_TAR=0
            FILE_TO_SEND="$item_path"
        fi

        # Generate mnemonic for metadata
        local META_MNEMONIC=$(generate_mnemonic "meta$FILE_INDEX")
        local META_MNEMONIC_EXIT_CODE=$?
        if [[ $META_MNEMONIC_EXIT_CODE -ne 0 ]]; then
            echo "Error: Metadata mnemonic generation failed for item $FILE_INDEX ('$item_path')" >&2
            [[ -n "$TEMP_TAR_FILE" && -f "$TEMP_TAR_FILE" ]] && rm "$TEMP_TAR_FILE" # Cleanup tar if created
            exit 1
        fi

        # Create metadata JSON
        # Use the original item basename for the filename field if it was a directory
        local FILENAME_IN_JSON
        if [[ "$COMPRESSED_TAR" -eq 1 ]]; then
            FILENAME_IN_JSON=$(basename "$item_path") # Original dir name
        else
            FILENAME_IN_JSON=$(basename "$FILE_TO_SEND") # Original file name
        fi
        local FILE_META_JSON="{\"filename\": \"$FILENAME_IN_JSON\", \"compressed_tar\": $COMPRESSED_TAR}"

        # Check if the metadata JSON is valid
        if ! echo "$FILE_META_JSON" | jq . &>/dev/null; then
             echo "Error: Generated metadata JSON is not valid: $FILE_META_JSON" >&2
             [[ -n "$TEMP_TAR_FILE" && -f "$TEMP_TAR_FILE" ]] && rm "$TEMP_TAR_FILE" # Cleanup tar if created
             exit 1
        fi

        echo "Sending metadata for item $FILE_INDEX/$COUNT_FILES: $FILE_META_JSON"
        echo "Using metadata mnemonic: $META_MNEMONIC"

        # Send metadata JSON
        execute_wormhole_command "$WORMROT_BIN send --text \"$FILE_META_JSON\" $WORMROT_DEFAULT_SEND_ARGS --code $META_MNEMONIC"

        # Generate mnemonic for file data
        local DATA_MNEMONIC=$(generate_mnemonic "data$FILE_INDEX")
        local DATA_MNEMONIC_EXIT_CODE=$?
         if [[ $DATA_MNEMONIC_EXIT_CODE -ne 0 ]]; then
            echo "Error: Data mnemonic generation failed for item $FILE_INDEX ('$item_path')" >&2
            [[ -n "$TEMP_TAR_FILE" && -f "$TEMP_TAR_FILE" ]] && rm "$TEMP_TAR_FILE" # Cleanup tar if created
            exit 1
        fi

        # Send the actual file/archive
        echo "Sending file data $FILE_INDEX/$COUNT_FILES: '$FILE_TO_SEND'"
        echo "Using data mnemonic: $DATA_MNEMONIC"
        execute_wormhole_command "$WORMROT_BIN send \"$FILE_TO_SEND\" $WORMROT_DEFAULT_SEND_ARGS --code $DATA_MNEMONIC"

        # Clean up temporary tar file if created
        if [[ -n "$TEMP_TAR_FILE" && -f "$TEMP_TAR_FILE" ]]; then
            echo "Cleaning up temporary archive: '$TEMP_TAR_FILE'"
            rm "$TEMP_TAR_FILE"
        fi
    done

elif [[ $# -eq 0 ]]; then
    # --- RECEIVE MODE ---
    echo "Using base mnemonic: $MNEMONIC"
    # First, receive the count as JSON
    echo "Receiving file count..."
    # Use the timeout command execution function to receive the file count JSON
    local COUNT_FILES_JSON_RAW="" # Initialize to empty string
    local receive_count_subshell_output
    receive_count_subshell_output=$(
      # Set up timeout trap for receiving count
      trap timeout_handler ALRM
      
      # Start timer in background for receiving count
      (
          sleep $WORMROT_MODULO
          kill -ALRM $$ 2>/dev/null
      ) &
      local COUNT_TIMER_PID=$!

      # Execute the receive command for count
      eval "$WORMROT_BIN receive --only-text $WORMROT_DEFAULT_RECEIVE_ARGS $MNEMONIC"
      local receive_count_exit_code=$?

      # Kill the timer and reset trap for count
      kill $COUNT_TIMER_PID 2>/dev/null
      trap - ALRM

      # Check exit code for count receive
      if [[ $receive_count_exit_code -ne 0 ]]; then
          echo "Error: Failed to receive file count JSON. Exit code: $receive_count_exit_code" >&2
          # Exit the subshell with the error code
          exit $receive_count_exit_code
      fi
      # If successful, the output of eval will be captured
    )
    # Capture the exit code of the subshell
    local subshell_exit_code=$?
    # Assign the captured output to the variable
    COUNT_FILES_JSON_RAW="$receive_count_subshell_output"

    # Check if the subshell command itself failed (e.g., trap triggered or eval failed)
    if [[ $subshell_exit_code -ne 0 ]]; then
        echo "Error during file count reception. Subshell exit code: $subshell_exit_code" >&2
        # If the output variable is empty, it means the command likely failed before producing output
        if [[ -z "$COUNT_FILES_JSON_RAW" ]]; then
            echo "No JSON data received for file count." >&2
        else
            echo "Received partial/invalid count JSON: '$COUNT_FILES_JSON_RAW'" >&2
        fi
        exit $subshell_exit_code
    fi

    echo "Received raw count JSON: '$COUNT_FILES_JSON_RAW'"

    # Extract the number of files using jq
    local COUNT_FILES=$(echo "$COUNT_FILES_JSON_RAW" | jq -r '.number_of_files' 2>/dev/null)
    
    # If jq fails or doesn't return a valid number, exit with error
    if ! [[ "$COUNT_FILES" =~ ^[1-9][0-9]*$ || "$COUNT_FILES" == "0" ]]; then # Allow 0 files
        echo "Error: Could not extract a valid file count from received JSON: '$COUNT_FILES_JSON_RAW'" >&2
        echo "Make sure the JSON format is correct (e.g., {\"number_of_files\": 1}) and contains a non-negative integer 'number_of_files' field." >&2
        exit 1
    fi

    echo "Expecting $COUNT_FILES file(s)/archive(s)"

    # Then receive metadata and file/archive for each item
    for ((i=1; i<=COUNT_FILES; i++)); do
        # Generate mnemonic for metadata
        local META_MNEMONIC=$(generate_mnemonic "meta$i")
        local META_MNEMONIC_EXIT_CODE=$?
        if [[ $META_MNEMONIC_EXIT_CODE -ne 0 ]]; then
            echo "Error: Metadata mnemonic generation failed for file $i" >&2
            exit 1
        fi

        echo "Receiving metadata for item $i/$COUNT_FILES..."
        echo "Using metadata mnemonic: $META_MNEMONIC"

        # Receive metadata JSON
        local FILE_META_JSON_RAW="" # Initialize
        local receive_meta_subshell_output
        receive_meta_subshell_output=$(
          trap timeout_handler ALRM
          ( sleep $WORMROT_MODULO; kill -ALRM $$ 2>/dev/null ) & local TIMER_PID=$!
          # Execute the receive command for metadata
          eval "$WORMROT_BIN receive --only-text $WORMROT_DEFAULT_RECEIVE_ARGS $META_MNEMONIC"
          local receive_meta_exit_code=$?
          # Kill timer and reset trap
          kill $TIMER_PID 2>/dev/null
          trap - ALRM
          # Check exit code for metadata receive
          if [[ $receive_meta_exit_code -ne 0 ]]; then
              echo "Error: Failed to receive metadata JSON for item $i. Exit code: $receive_meta_exit_code" >&2
              exit $receive_meta_exit_code # Exit subshell on error
          fi
          # Output is captured if successful
        )
        # Capture subshell exit code and output
        local subshell_meta_exit_code=$?
        FILE_META_JSON_RAW="$receive_meta_subshell_output"

        # Check if the subshell command itself failed
        if [[ $subshell_meta_exit_code -ne 0 ]]; then
            echo "Error during metadata reception for item $i. Subshell exit code: $subshell_meta_exit_code" >&2
             if [[ -z "$FILE_META_JSON_RAW" ]]; then
                echo "No JSON data received for metadata item $i." >&2
            else
                echo "Received partial/invalid metadata JSON: '$FILE_META_JSON_RAW'" >&2
            fi
            exit $subshell_meta_exit_code
        fi

        echo "Received raw metadata JSON: '$FILE_META_JSON_RAW'"

        # Parse filename and compressed_tar flag using jq
        local FILENAME_FROM_JSON=$(echo "$FILE_META_JSON_RAW" | jq -r '.filename' 2>/dev/null)
        local COMPRESSED_TAR=$(echo "$FILE_META_JSON_RAW" | jq -r '.compressed_tar' 2>/dev/null)

        # Validate parsed metadata
        if [[ -z "$FILENAME_FROM_JSON" || "$FILENAME_FROM_JSON" == "null" ]]; then
            echo "Error: Could not extract filename from metadata JSON: '$FILE_META_JSON_RAW'" >&2
            exit 1
        fi
        if ! [[ "$COMPRESSED_TAR" =~ ^[01]$ ]]; then
            echo "Error: Could not extract valid compressed_tar flag (0 or 1) from metadata JSON: '$FILE_META_JSON_RAW'" >&2
            exit 1
        fi

        echo "Metadata parsed - Filename: '$FILENAME_FROM_JSON', Compressed: $COMPRESSED_TAR"

        # Generate mnemonic for file data
        local DATA_MNEMONIC=$(generate_mnemonic "data$i")
        local DATA_MNEMONIC_EXIT_CODE=$?
        if [[ $DATA_MNEMONIC_EXIT_CODE -ne 0 ]]; then
            echo "Error: Data mnemonic generation failed for file $i" >&2
            exit 1
        fi

        echo "Receiving file data for item $i/$COUNT_FILES..."
        echo "Using data mnemonic: $DATA_MNEMONIC"

        if [[ "$COMPRESSED_TAR" -eq 1 ]]; then
            # Receive compressed tar archive to a temporary file
            # The archive itself will have a .tar.gz name from the sender, but we receive it to a temp name
            local TEMP_RECEIVED_FILE
            TEMP_RECEIVED_FILE=$(mktemp --suffix=".wormrot-received.tar.gz")
            if [[ -z "$TEMP_RECEIVED_FILE" ]]; then
                echo "Error: Failed to create temporary file for receiving archive." >&2
                exit 1
            fi
            echo "Receiving archive to temporary file: '$TEMP_RECEIVED_FILE'"

            # Use execute_wormhole_command for receiving the file data
            # We don't use --output-file here, wormhole will use the filename from metadata if available,
            # but we redirect stdout to the temp file to be safe and handle potential name conflicts.
            # Update: Using --output-file is more robust as wormhole handles overwriting prompts etc.
            execute_wormhole_command "$WORMROT_BIN receive $WORMROT_DEFAULT_RECEIVE_ARGS --output-file \"$TEMP_RECEIVED_FILE\" $DATA_MNEMONIC"
            local receive_archive_exit_code=$?

            if [[ $receive_archive_exit_code -ne 0 ]]; then
                echo "Error: Failed to receive archive data for item $i. Exit code: $receive_archive_exit_code" >&2
                [[ -f "$TEMP_RECEIVED_FILE" ]] && rm "$TEMP_RECEIVED_FILE" # Clean up temp file on error
                exit $receive_archive_exit_code
            fi

            # Check if the received file actually exists and is not empty
            if [[ ! -s "$TEMP_RECEIVED_FILE" ]]; then
                 echo "Error: Received temporary archive file '$TEMP_RECEIVED_FILE' is missing or empty." >&2
                 [[ -f "$TEMP_RECEIVED_FILE" ]] && rm "$TEMP_RECEIVED_FILE"
                 exit 1
            fi

            echo "Archive received. Extracting..."
            # Extract the archive into the current directory
            # tar should recreate the directory structure stored within the archive
            if ! tar xzf "$TEMP_RECEIVED_FILE"; then
                 echo "Error: Failed to extract received archive: '$TEMP_RECEIVED_FILE'" >&2
                 # Keep the temp file for debugging in case of extraction error
                 echo "Temporary archive kept at: $TEMP_RECEIVED_FILE" >&2
                 exit 1
            fi

            echo "Extraction complete for '$FILENAME_FROM_JSON'. Cleaning up temporary file."
            rm "$TEMP_RECEIVED_FILE"
        else
            # Receive regular file using the filename from JSON
            echo "Receiving file directly to: '$FILENAME_FROM_JSON'"
            # Use execute_wormhole_command for receiving the file data with --output-file
            execute_wormhole_command "$WORMROT_BIN receive $WORMROT_DEFAULT_RECEIVE_ARGS --output-file \"$FILENAME_FROM_JSON\" $DATA_MNEMONIC"
            local receive_file_exit_code=$?

            if [[ $receive_file_exit_code -ne 0 ]]; then
                echo "Error: Failed to receive file data for item $i ('$FILENAME_FROM_JSON'). Exit code: $receive_file_exit_code" >&2
                # Note: wormhole might have created a partial file, manual cleanup might be needed.
                exit $receive_file_exit_code
            fi
            echo "File '$FILENAME_FROM_JSON' received."
        fi
    done
else
    echo "Usage: $0 [<file(s)/dir(s)>|-v|--version|-h|--help]"
    echo "  - With no arguments: receive files"
    echo "  - With file arguments: send files"
    exit 1
fi
