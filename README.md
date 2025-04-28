# wormrot.sh

A script that generates synchronized, time-based magic-wormhole codes between computers without requiring prior communication.

## Overview

`wormrot.sh` (for *magic-wormhole rotator*, obviously) is a wrapper around [magic-wormhole](https://magic-wormhole.readthedocs.io/) that automatically generates synchronized codes based on time. This eliminates the need to manually share codes between sender and receiver, making file transfers more seamless.

This tool explicitly supports sending multiple files or directories in a single operation, handling the complexity of coordinating multiple transfers automatically.

This project is in the same vein as my [knockd_rotator](https://github.com/thiswillbeyourgithub/knockd_rotator), [fowlrot.sh](https://github.com/thiswillbeyourgithub/fowlrot.sh) and uses my [HumanReadableSeed](https://github.com/thiswillbeyourgithub/HumanReadableSeed) to generate deterministic, human-readable codes.

## Why Use This?

`wormrot.sh` solves a common problem: when transferring files with magic-wormhole, you normally need to share a code from the sender to the receiver. This can be somewhat annoying.

With `wormrot.sh`:
- Both parties simply run the same command on their respective machines
- The code is automatically generated based on the current time and a shared secret and modulo
- No communication of codes during the transfer is required
- The code changes predictably over time, making it virtually impossible for attackers to guess
- Sending a file is a single operation with automatic coordination between sender and receiver
- Ability to send multiple files, even multiple directories

It's especially useful for regularly transferring files between your own devices or with trusted parties who have the same secret and modulo configured.

## Installation

1. Set up the `WORMROT_SECRET` environment variable (must be non-empty). You can generate a strong secret using a command like `openssl rand -hex 64`.
2. Set up the `WORMROT_MODULO` environment variable (changing it increases security, setting it too low can make it hard to synchronize)
3. Make the script executable

```bash
chmod +x wormrot.sh
```

Note: By default, the script checks if `uvx` is installed. If found, it uses `uvx` to call the latest versions of HumanReadableSeed and magic-wormhole. If `uvx` is not installed, it will default to using `wormhole` and `HumanReadableSeed` commands directly, which you can install using `pip install -U magic-wormhole HumanReadableSeed`. On [termux](https://termux.dev/) you might need instead to do `pkg install magic-wormhole-rs coreutils jq`; BUT the Rust implementation does not yet support the text sending features required by `wormrot.sh`.

## Usage

First, set up the secret environment variable:

```bash
export WORMROT_SECRET="your-secret-here"
```

**Important**: Sender and receiver scripts must be started at roughly the same time (within the same time window as defined by WORMROT_MODULO). Starting the scripts in different time windows will cause the codes to be different and the transfer to fail. The script includes a safeguard: it will exit with an error if started less than 10 seconds before the next time window boundary, prompting you to wait briefly.

The script automatically detects what you want to do:
- Run with file paths to send files
- Run without arguments to receive files

### Sending files

```bash
# Provide file paths to send files
./wormrot.sh /path/to/file1 /path/to/file2
```

**Note on Sending Directories:**

If you provide a directory path, `magic-wormhole` handles sending the entire directory recursively.

### Receiving files

```bash
# Run without arguments to receive files
./wormrot.sh
```

### Help and version information

```bash
# Show help
./wormrot.sh -h
# or
./wormrot.sh --help

# Show version
./wormrot.sh -v
# or
./wormrot.sh --version
```

## Configuration

The script can be customized using these environment variables:

- `WORMROT_MODULO`: Time period in seconds (default: 60, minimum: 20). Lowering it makes the code change often but if you take too much time to launch the receive commands they will never find each other.
- `WORMROT_SECRET`: Required secret secret for code generation
- `WORMROT_BIN`: Command to run wormhole (default: "uvx --quiet --from magic-wormhole@latest wormhole" if uvx is installed, otherwise "wormhole")
- `WORMROT_HRS_BIN`: Command to run HumanReadableSeed (default: "uvx --quiet HumanReadableSeed@latest" if uvx is installed, otherwise "HumanReadableSeed")
- `WORMROT_DEFAULT_SEND_ARGS`: Default arguments for send command (default: "--no-qr --hide-progress")
- `WORMROT_DEFAULT_RECEIVE_ARGS`: Default arguments for the *data* receive command (default: "--accept-file --hide-progress"). Note: Metadata reception uses `--only-text`.

## How It Works

The script generates synchronized codes through a series of steps:

1. **Time Synchronization**:
   - Gets the current UNIX timestamp (using UTC time) at script start (the **base timestamp**).
   - Uses the `WORMROT_MODULO` value (default 60s) to define time windows based on the base timestamp.
   - Includes a check to prevent starting if the base timestamp is less than 10 seconds before the next window boundary.

2. **Period Key Generation**:
   - Creates a unique key for the current time period using the formula:
     `PERIOD_KEY = ((current_timestamp / modulo) * modulo) + secret + optional_suffix`
   - The suffix is used to generate different codes for multiple files in the same transfer
   - Calculates SHA-256 hash of the period key for enhanced security

3. **Mnemonic Generation**:
   - Uses my other project [HumanReadableSeed](https://github.com/thiswillbeyourgithub/HumanReadableSeed) to generate memorable words from the hashed period key
   - Formats the words with hyphens

4. **Channel ID Generation**:
   - Calculates a hash of the mnemonic words
   - Extracts digits from the hash
   - Computes a prefix number (modulo 999 to cap it to 3 digits) (what magic-wormhole calls [nameplates or channel id](https://magic-wormhole.readthedocs.io/en/latest/api.html))
   - Creates the final code format: `prefix-mnemonic`

5. **File Transfer Process**:
   - The **base timestamp** is calculated once at script start and used as the foundation for *all* subsequent code generations within that run.
   - For sending multiple items:
     - For *each* item (file or directory), two codes are generated independently using the base timestamp, the secret, and unique suffixes (e.g., `meta1`, `data1` for the first item, `meta2`, `data2` for the second, etc.).
     - First, a code (`metaN`) is used to send metadata as a JSON text message (e.g., `{"filename": "file.txt", "sha256sum": "hash_value", "index": 1, "total": 3}`). For directories, the `sha256sum` field contains the placeholder string `DIRECTORY_HASH_SKIPPED`.
     - Second, a different code (`dataN`) is used to send the actual file or directory content.
   - For receiving: The receiver follows the exact same logic, generating the `metaN` code to receive the metadata JSON, parsing it to get the filename, expected hash (or placeholder), index, and total count. Then, it generates the `dataN` code to receive the corresponding item content. It verifies the hash for files after reception. If a file or directory with the same name already exists, the script detects this and calculates a new name (e.g., `filename_1.ext`). It attempts to use `magic-wormhole`'s `--output-file` option with this new name when receiving *files*. For directories, or if `--output-file` fails, `magic-wormhole`'s default collision handling (which might involve prompting or overwriting depending on options like `--accept-file`) takes effect.

The beauty of this approach is that both sides independently generate the same sequence of codes without direct communication, solely based on the initial timestamp, the shared secret, and the predictable suffix pattern (`meta1`, `data1`, `meta2`, `data2`...). This ensures sender and receiver remain synchronized even during the transfer of many files, provided they both start their scripts within the same time window (as defined by `WORMROT_MODULO`). If the script is launched less than 10s before the next window, a helpful error occurs, suggesting to wait.

## FAQ

### Why not use HMAC with counters instead of time synchronization?

While HMAC with counter-based approaches (similar to TOTP) could be used for code generation, the current time-based implementation offers several advantages:

- **Peer equality**: All clients are equal - there's no distinction between "server" and "client" roles
- **Simplified sharing**: All participants only need to share the same secret and modulo values once
- **Multi-client support**: Any number of clients can exchange files without additional configuration
- **No counter synchronization**: Avoiding the complexity of keeping counters synchronized between multiple parties
- **Predictable validity window**: The time-based approach creates natural windows when codes are valid

The current implementation sacrifices the theoretical security of a pure counter-based approach for significant practical usability benefits in real-world file transfers.

### Why is it sometimes slow?

`wormrot.sh` performs two distinct magic-wormhole operations *per item* being transferred, each requiring its own connection setup, which contributes to the total time:

1.  **Per-Item Metadata Transfer**: For *each* file or directory:
    *   The sender sends a text message containing a JSON object with metadata: the item's original basename, its sha256 hash (or a placeholder for directories), the item's index in the transfer sequence (1, 2, 3...), and the total number of items being sent.
    *   The receiver waits for this metadata message using the corresponding `metaN` code. The total count is learned from the metadata of the *first* item.
2.  **Per-Item Content Transfer**: For *each* file or directory:
    *   The sender sends the actual file content (or the directory contents) using the corresponding `dataN` code.
    *   The receiver waits to receive the file/directory content using the `dataN` code.

Each of these steps (metadata send/receive, data send/receive) involves establishing a connection through the magic-wormhole rendezvous server, generating keys, and confirming the connection. This overhead, repeated twice for *each* file or directory, contributes to the overall transfer time, especially for transfers involving many small items.

### Why not use fowl for multiple file transfers?

A future improvement planned is to use [fowl](https://github.com/meejah/fowl), by the same author as magic-wormhole, to send multiple files through a single tunnel instead of requiring multiple codes. Currently, `wormrot.sh` sends each file individually with a unique code derived from the base time-synchronized code.

## Development

This tool was created with the help of [aider.chat](https://github.com/Aider-AI/aider/issues).

## License

See the LICENSE file for details.
