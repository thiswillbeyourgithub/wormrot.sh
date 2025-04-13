# wormrot.sh

A script that generates synchronized, time-based magic-wormhole codes between computers without requiring prior communication.

## Overview

`wormrot.sh` (for *magic-wormhole rotator*, obviously) is a wrapper around [magic-wormhole](https://magic-wormhole.readthedocs.io/) that automatically generates synchronized codes based on time. This eliminates the need to manually share codes between sender and receiver, making file transfers more seamless.

This tool explicitly supports sending multiple files in a single operation, handling the complexity of coordinating multiple transfers automatically.

This project is in the same vein as my [knockd_rotator](https://github.com/thiswillbeyourgithub/knockd_rotator) and uses my [HumanReadableSeed](https://github.com/thiswillbeyourgithub/HumanReadableSeed) to generate deterministic, human-readable codes.

## Why Use This?

`wormrot.sh` solves a common problem: when transferring files with magic-wormhole, you normally need to share a code from the sender to the receiver. This can be somewhat annoying.

With `wormrot.sh`:
- Both parties simply run the same command on their respective machines
- The code is automatically generated based on the current time and a shared secret and modulo
- No communication of codes during the transfer is required
- The code changes predictably over time, making it virtually impossible for attackers to guess
- Send multiple files in a single operation with automatic coordination between sender and receiver

It's especially useful for regularly transferring files between your own devices or with trusted parties who have the same secret and modulo configured.

## Installation

1. Set up the `WORMROT_SECRET` environment variable (must be non-empty)
2. Set up the `WORMROT_MODULO` environment variable (changing it increases security, setting it too low can make it hard to synchronize)
3. Make the script executable

```bash
chmod +x wormrot.sh
```

Note: By default, the script uses `uvx` to call the latest versions of HumanReadableSeed and magic-wormhole. If you don't have `uv` installed, you'll need to specify appropriate binary paths using the `WORMROT_HRS_BIN` and `WORMROT_BIN` environment variables.

## Usage

First, set up the secret environment variable:

```bash
export WORMROT_SECRET="your-secret-here"
```

**Important**: Sender and receiver scripts must be started at roughly the same time (within the same time window as defined by WORMROT_MODULO). Starting the scripts in different time windows will cause the codes to be different and the transfer to fail.

The script automatically detects what you want to do:
- Run with file paths to send files
- Run without arguments to receive files

### Sending files

```bash
# Provide file paths to send files
./wormrot.sh /path/to/file1 /path/to/file2
```

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
- `WORMROT_BIN`: Command to run wormhole (default: "uvx --from magic-wormhole@latest wormhole")
- `WORMROT_HRS_BIN`: Command to run HumanReadableSeed (default: "uvx HumanReadableSeed@latest")
- `WORMROT_DEFAULT_SEND_ARGS`: Default arguments for send command (default: "--no-qr --hide-progress")
- `WORMROT_DEFAULT_RECEIVE_ARGS`: Default arguments for receive command (default: "--hide-progress")

## How It Works

The script generates synchronized codes through a series of steps:

1. **Time Synchronization**: 
   - Gets the current UNIX timestamp (using UTC time)
   - Applies modulo to create time windows (default 60s)
   - Adjusts modulo slightly for timestamps with small remainders

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
   - The timestamp is calculated once at script start and used for all mnemonic generation
   - For sending: First sends the number of files, then sends each file with a unique suffix-based code
   - For receiving: First receives the file count, then receives each file using the same suffix pattern

The beauty of this approach is that both sides independently generate the same code without direct communication. However, both sender and receiver must start their scripts within the same time window (as defined by WORMROT_MODULO) to ensure they generate the same set of codes. If the script is launched less than 10s before the next window a helpful error occurs, suggesting to wait.

## Development

This tool was created with the help of [aider.chat](https://github.com/Aider-AI/aider/issues).

## License

See the LICENSE file for details.
